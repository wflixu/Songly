//
//  RecommendationEngine.swift
//  Songly
//
//  推荐管线的编排者。
//
//  v3 流程（对比 v2 的根本倒置：不再是"LLM 报歌名 → 搜 → 搜到多少算多少"）：
//
//    授权 → 读收藏 → 统计/画像 → 情境
//         → ┌ 轮次循环（≤3 轮）──────────────────────────┐
//           │ 1. LLM 出 seeds（强制工具调用，按 70/20/10） │
//           │ 2. CatalogResolver：seed → 真实曲目          │
//           │ 3. PlaylistComposer：确定性收敛              │
//           │ 4. GapRoundPlanner：够了就停，不够就再来一轮 │
//           └─────────────────────────────────────────────┘
//         → 落库(pending) → 建歌单 → 标记 completed → 通知
//

import Foundation
import SwiftData
import MusicKit

// MARK: - Errors

enum EngineError: LocalizedError {
    case notAuthorized
    case emptyLibrary
    case insufficientCandidates(count: Int)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "需要 Apple Music 访问权限"
        case .emptyLibrary: return "收藏列表为空"
        case .insufficientCandidates(let count): return "只凑到 \(count) 首，不够建一份歌单"
        }
    }
}

// MARK: - Artist Recency

/// 「这位艺人最近什么时候出现过」—— 跨天闸门的输入。
///
/// 与 `recentArtistCounts`（热度，用于层内排序）是**两件事**：那个数次数，这个记日期。
/// 次数区分不了「3 天前 1 次」和「6 天前 1 次」，而这两档一个是禁、一个是限 1 首。
struct ArtistRecencySignals: Sendable {
    /// 归一化艺人 key → 最近一次出现在推荐里的日期。
    var lastSeen: [String: Date] = [:]
    /// 归一化艺人 key → 展示用艺人名（取自最近那条记录）。
    ///
    /// key 是**小写化过**的，直接喂给 prompt 会是 `taylor swift` 这种写法，
    /// 所以另存一份原始写法。
    var displayNames: [String: String] = [:]

    /// 本轮会被硬闸门挡掉的艺人展示名。
    ///
    /// 只报**第一档**（近 `artistBlockedWithinDays` 天）—— 第二档（4–14 天）只是
    /// 限到 1 首，不是「不能提」，写进 prompt 会让模型白白放弃一个可用方向。
    func blockedDisplayNames(now: Date) -> [String] {
        lastSeen
            .filter { $0.value.wholeDays(to: now) <= AppConfig.artistBlockedWithinDays }
            .keys
            .compactMap { displayNames[$0] }
            .sorted()
    }
}

// MARK: - Engine

actor RecommendationEngine {
    private let musicKitService: MusicKitServiceProtocol
    private let llmService: LLMServiceProtocol
    private let playlistService: PlaylistServiceProtocol
    private let catalogResolver: CatalogResolving
    private let tasteProfileStore: TasteProfileStore
    private let implicitDetector: ImplicitSignalDetecting
    private let modelContainer: ModelContainer

    private var isRunning = false
    private var currentTask: Task<Void, Never>?

    init(
        musicKitService: MusicKitServiceProtocol,
        llmService: LLMServiceProtocol,
        playlistService: PlaylistServiceProtocol,
        catalogResolver: CatalogResolving,
        tasteProfileStore: TasteProfileStore = TasteProfileStore(),
        /// 隐式信号检测器。给默认值是为了让既有测试与预览继续编译 ——
        /// 换测试替身时从这里注入。
        implicitDetector: ImplicitSignalDetecting = ImplicitSignalDetector(),
        modelContainer: ModelContainer
    ) {
        self.musicKitService = musicKitService
        self.llmService = llmService
        self.playlistService = playlistService
        self.catalogResolver = catalogResolver
        self.tasteProfileStore = tasteProfileStore
        self.implicitDetector = implicitDetector
        self.modelContainer = modelContainer
    }

    // MARK: - Public

    /// Start a daily recommendation run.
    /// - Returns: `true` if the run was acquired and started; `false` if the
    ///   engine is already busy (e.g. a background task is running).
    @discardableResult
    func runDailyRecommendation(
        onStateChange: @escaping @Sendable (RecommendationState) -> Void
    ) async -> Bool {
        await start(quickPickStyle: nil, source: "daily", onStateChange: onStateChange)
    }

    /// Start a QuickPick (style-based) recommendation run.
    ///
    /// 走的是同一条管线，只是关掉三层配额 —— 用户已经主动点名了一个风格，
    /// 再套 70/20/10 是多余的。
    @discardableResult
    func runQuickPickRecommendation(
        style: QuickPickStyle,
        onStateChange: @escaping @Sendable (RecommendationState) -> Void
    ) async -> Bool {
        await start(quickPickStyle: style, source: "quick_pick", onStateChange: onStateChange)
    }

    func cancel() {
        // Cooperative cancellation: ask the running pipeline to stop. `isRunning`
        // is reset by the pipeline's `defer` only when it actually exits, so a
        // cancelled-but-still-running task can't be re-entered.
        currentTask?.cancel()
    }

    private func start(
        quickPickStyle: QuickPickStyle?,
        source: String,
        onStateChange: @escaping @Sendable (RecommendationState) -> Void
    ) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true

        let task = Task { [weak self] in
            _ = await self?._runPipeline(
                quickPickStyle: quickPickStyle,
                source: source,
                onStateChange: onStateChange
            )
        }
        currentTask = task
        return true
    }

    // MARK: - Timeout Helper

    private struct TimeoutError: Error {}

    /// Run `operation` with a time budget; returns `nil` on timeout or error.
    /// Used for degradable context signals so a hung fetch can't stall the pipeline.
    private func withTimeout<T>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw TimeoutError()
                }
                guard let result = try await group.next() else { return nil }
                group.cancelAll()
                return result
            }
        } catch {
            return nil
        }
    }

    // MARK: - Pipeline

    private func _runPipeline(
        quickPickStyle: QuickPickStyle?,
        source: String,
        onStateChange: @escaping @Sendable (RecommendationState) -> Void
    ) async {
        let startedAt = Date()
        let reportState = { @MainActor @Sendable (state: RecommendationState) in
            onStateChange(state)
        }

        /// 已落库、但播放列表还没建成的记录。
        ///
        /// 取消若正好落在「persist」与「创建播放列表」之间，这条记录会被留在
        /// 库里永远无法收尾 —— 而 `PlaylistHistoryView` 的 `@Query` 不过滤
        /// status，它会显示成一份 Apple Music 中并不存在的歌单。
        var pendingRecordID: PersistentIdentifier?

        // Release the run guard only when the pipeline actually exits, so a
        // cancelled-but-still-running pipeline can't be re-entered.
        //
        // 取消时必须**补发一个终态**：管线里所有取消分支（`Task.isCancelled`
        // 那几处）都是裸 `return`，一句终态都不发。此前 UI 从没接过 `cancel()`，
        // 所以没人发现；一旦接上，「取消生成」之后界面会永远停在进度卡上 ——
        // 而那张卡只有「取消」一个按钮，没有任何退路，用户只能杀掉 App。
        //
        // 报 `.idle` 而不是 `.error`：取消不是错误。`HomeViewModel` 收到之后会
        // 据实从数据库恢复（今天可能本来就有一份已完成的歌单）。
        defer {
            self.isRunning = false
            if Task.isCancelled {
                if let pending = pendingRecordID {
                    Task { _ = await self.deleteRecommendation(modelID: pending) }
                }
                Task { await reportState(.idle) }
            }
        }

        // ---- Step 1: Authorization ----
        let currentStatus = musicKitService.authorizationStatus()
        if currentStatus == .notDetermined {
            if await musicKitService.requestAuthorization() != .authorized {
                await reportState(.error(message: "需要 Music 访问权限", retryable: false))
                return
            }
        } else if currentStatus != .authorized {
            await reportState(.error(message: "请在设置中开启 Apple Music 访问权限", retryable: false))
            return
        }
        if Task.isCancelled { return }

        // ---- Step 2: Library ----
        await reportState(.readingLibrary)
        let songs: [Song]
        do {
            songs = try await musicKitService.fetchLibrarySongs(limit: AppConfig.maxLibrarySongs)
        } catch {
            if Task.isCancelled { return }
            await reportState(.error(message: "读取收藏失败", retryable: true))
            return
        }
        if Task.isCancelled { return }

        guard !songs.isEmpty else {
            await reportState(.error(message: "收藏列表为空", retryable: false))
            return
        }

        // ---- Step 3: Signals（可降级、各自超时、并发）----
        async let recentlyPlayedTask = withTimeout(AppConfig.contextTimeout) {
            try await self.musicKitService.fetchRecentlyPlayedSongs(limit: AppConfig.recentlyPlayedLimit)
        }
        async let topPlayedTask = withTimeout(AppConfig.contextTimeout) {
            try await self.musicKitService.fetchTopPlayedSongs(limit: AppConfig.topPlayedLimit)
        }
        // ---- Step 3.5: 隐式信号（回读 Apple Music 里的实际行为）----
        //
        // 与 Step 3 并发：8 秒预算必须与那 3 秒的上下文取数**重叠**，而不是叠加。
        // 候选收集要读记录（主线程，很快），网络部分走后台 —— 分工见 `ImplicitCandidate`。
        let implicitInput = await collectImplicitInput()
        async let implicitTask = withTimeout(AppConfig.implicitSignalTimeout) {
            await self.implicitDetector.observe(implicitInput.candidates, playlists: implicitInput.playlists)
        }

        let recentlyPlayed = await recentlyPlayedTask ?? []
        let topPlayed = await topPlayedTask ?? []
        let implicitObservation = await implicitTask ?? .empty
        if Task.isCancelled { return }

        // 分类：把「原始事实」变成权重与硬排除。纯函数，可整天单测。
        let implicitSignals = ImplicitSignalClassifier.classify(
            implicitInput.candidates, observation: implicitObservation
        )
        // 「他删掉了」必须**落盘** —— 不落盘，这条排除会在记录滚出回看窗口时蒸发，
        // 而「删除应当永久生效」正是这套东西的设计前提。
        await persistImplicitRemovals(implicitSignals)
        if Task.isCancelled { return }

        // ---- Step 4: Scene + Profile + Feedback + Exclusions ----
        // 风格模式下情境仍作为背景，只是优先级低于用户点名的风格。
        let scene = SceneContext.sensed()
        let profile = loadTasteProfile()
        // 读一次反馈，同时供三层使用：硬排除（删掉的歌）、层内排序（艺人权重）、
        // prompt（明确的好恶）。见 `FeedbackStore.Derived`。
        let feedback = await deriveFeedback()
        // 显式与隐式合并成一份权重。隐式那侧已经在分类器里夹过一次，
        // 这里合并后再夹到全局范围 —— 两步夹取的理由见 `mergeArtistWeights`。
        let artistWeights = Self.mergeArtistWeights(
            explicit: feedback.artistWeights,
            implicit: implicitSignals.artistWeights
        )
        let exclusions = await makeExclusions(
            songs: songs,
            recentlyPlayed: recentlyPlayed,
            source: source,
            feedback: feedback,
            implicitSignals: implicitSignals
        )
        let artistHeat = await recentArtistCounts(windowDays: AppConfig.artistRecencyWindowDays)
        // 跨天艺人闸门的输入。与上面的 `artistHeat` 是两件事（一个是次数、一个是日期），
        // 见 `ArtistRecencySignals` 的注释。
        let artistRecency = await fetchArtistRecency()
        // 本轮会被闸门挡掉的艺人 —— 喂给 prompt，省得模型把 seed 浪费在它们身上。
        let blockedArtists = artistRecency.blockedDisplayNames(now: startedAt)

        let historyForPrompt = await fetchRecentTrackInfos(
            windowDays: AppConfig.dedupWindowDays,
            sources: ["daily"]
        ).map(PromptTrack.init)

        // ---- Step 5: Round loop ----
        let seedTargets = PromptBuilderV3.seedTargets(for: AppConfig.targetTrackCount)
        var request = SeedRequest(
            system: PromptBuilderV3.systemPrefix(profile: profile, feedback: feedback.summary),
            userMessage: PromptBuilderV3.firstUserMessage(
                scene: scene,
                now: startedAt,
                librarySample: PromptBuilderV3.sampleLibrary(
                    songs.map { PromptTrack(title: $0.title, artist: $0.artistName, playCount: $0.playCount) }
                ),
                stats: LibraryStats(snapshot: songs.map(Self.snapshot)),
                recentlyPlayed: recentlyPlayed.map { PromptTrack(title: $0.title, artist: $0.artistName) },
                topPlayed: topPlayed.map { PromptTrack(title: $0.title, artist: $0.artistName) },
                recentlyRecommended: historyForPrompt,
                implicitSignals: implicitSignals,
                blockedArtists: blockedArtists,
                seedTargets: seedTargets,
                quickPickStyle: quickPickStyle
            )
        )

        var accumulated: [ResolvedCandidate] = []
        /// catalog ID → Song。建歌单要用真实对象，所以每轮都把映射并进来。
        var songsByID: [String: Song] = [:]
        var composition = PlaylistComposer.compose(Self.composerInput(
            candidates: accumulated, exclusions: exclusions,
            artistHeat: artistHeat, artistWeights: artistWeights,
            artistLastSeen: artistRecency.lastSeen, now: startedAt,
            quickPick: quickPickStyle != nil
        ))

        var round = 0
        var stopReason = StopReason.maxRounds
        var roundsRun = 0
        var seedsRequested = 0
        var seedsResolved = 0
        var inputTokens = 0
        var cacheReadTokens = 0
        /// 解析失败的原因分布 —— 这是"为什么解析率低"唯一能回答的地方。
        var failureReasons: [String: Int] = [:]
        var albumExpansions = 0
        /// 模型返回了工具调用却解不出 seed 时，把它**原始**的 input 记下来。
        ///
        /// 没有这个，`seeds_requested: 0` 会有两种完全不同的可能 ——
        /// 模型真的没给，还是它给了但我们的 schema 对不上 —— 而日志里长得一模一样。
        var rawSeedInput: String?

        while round < AppConfig.maxGapRounds {
            if Task.isCancelled {
                stopReason = .cancelled
                break
            }
            round += 1
            roundsRun = round

            await reportState(.generating(progress: round == 1
                ? "正在分析你的音乐品味…"
                : "正在补足第 \(round) 轮候选…"))

            let response: SeedResponse
            do {
                response = try await llmService.requestSeeds(request)
            } catch {
                if Task.isCancelled {
                    stopReason = .cancelled
                    break
                }
                // 第 1 轮失败就没有退路；**不可重试的错误在任何一轮都没有退路** ——
                // 补位轮不会让 401 或「Key 未配置」变好，只会白烧 1–2 分钟，
                // 然后把真实原因换成「候选不足」这种误导性的收尾状态。
                if round == 1 || Self.isNonRetryable(error) {
                    await reportState(.error(
                        message: error.localizedDescription,
                        retryable: !Self.isNonRetryable(error)
                    ))
                    return
                }
                stopReason = .noProgress
                break
            }
            if Task.isCancelled {
                stopReason = .cancelled
                break
            }

            if response.seeds.isEmpty, rawSeedInput == nil {
                let raw = response.toolCalls.first
                    .flatMap { String(data: $0.inputJSON, encoding: .utf8) }
                    ?? "（响应里没有 return_seeds 工具调用）"
                rawSeedInput = String(raw.prefix(400))
                Self.log("模型返回了工具调用但解不出 seed，原始 input：\(rawSeedInput ?? "")")
            }

            seedsRequested += response.seeds.count
            inputTokens += response.usage.inputTokens
            cacheReadTokens += response.usage.cacheReadTokens
            if response.truncated {
                Self.log("seed 输出被 max_tokens 截断，已解析 \(response.seeds.count) 条")
            }

            await reportState(.searchingCatalog(found: 0, total: response.seeds.count))
            let resolution = await catalogResolver.resolve(
                seeds: response.seeds,
                exclusions: exclusions,
                albumBudget: AppConfig.maxAlbumResolutionsPerRound
            )
            if Task.isCancelled {
                stopReason = .cancelled
                break
            }

            seedsResolved += resolution.seedsSucceeded
            accumulated.append(contentsOf: resolution.candidates)
            songsByID.merge(resolution.songsByID) { existing, _ in existing }
            albumExpansions += resolution.albumExpansions
            for failure in resolution.failures {
                failureReasons[failure.reason, default: 0] += 1
            }

            // 留一份给 `artistsAtCap` —— 上限是分档的，判定必须用同一份输入。
            let composerState = Self.composerInput(
                candidates: accumulated, exclusions: exclusions,
                artistHeat: artistHeat, artistWeights: artistWeights,
                artistLastSeen: artistRecency.lastSeen, now: startedAt,
                quickPick: quickPickStyle != nil
            )
            composition = PlaylistComposer.compose(composerState)

            let decision = GapRoundPlanner.decide(RoundState(
                round: round,
                composed: composition,
                resolvedThisRound: resolution.candidates.count,
                newSeedsThisRound: response.seeds.count,
                failedSeeds: resolution.failures,
                artistsAtCap: Self.artistsAtCap(composition, input: composerState),
                elapsed: Date().timeIntervalSince(startedAt),
                isCancelled: false
            ))

            switch decision {
            case .stop(let reason):
                stopReason = reason
            case .continueWith(let delta):
                request.appendRound(
                    previous: response,
                    outcomeJSON: delta.outcomeJSON,
                    instruction: delta.instruction
                )
                continue
            }
            break
        }

        // 诊断 payload **只构造一次**，供两个出口共用：DEBUG 打印 + 落库。
        //
        // ⚠️ 落库那条路绝不能跟着 `#if DEBUG` 走 —— 02:00 的后台任务跑的是
        // Release 构建，而它恰恰是歌单的主要产出路径。跟着 DEBUG 走的话，
        // 数据在 Release 下永远是空的，且不报错、只静默产出零数据。
        let diagnostics = Self.diagnosticsPayload(
            rounds: roundsRun,
            stopReason: stopReason,
            seedsRequested: seedsRequested,
            seedsResolved: seedsResolved,
            candidates: accumulated.count,
            composition: composition,
            stopReasonIsTarget: stopReason == .targetReached,
            elapsed: Date().timeIntervalSince(startedAt),
            scene: scene,
            profileVersion: profile?.version,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            failureReasons: failureReasons,
            albumExpansions: albumExpansions,
            rawSeedInput: rawSeedInput,
            rejectionReasons: Self.rejectionBreakdown(composition.rejections),
            implicitCandidates: implicitInput.candidates.count,
            implicitSignals: implicitSignals,
            implicitObservation: implicitObservation
        )
        Self.logDiagnostics(diagnostics)
        let diagnosticsJSON = Self.encodeDiagnostics(diagnostics)

        // ---- Step 6: Gate ----
        //
        // 缺口没补上但够格发布时**照常发布** —— 20–24 首是好歌单，
        // 不值得为了凑满 25 让用户白等一轮。
        guard composition.publishable, !composition.tracks.isEmpty else {
            let message = EngineError
                .insufficientCandidates(count: composition.tracks.count)
                .localizedDescription
            // **失败也要留痕。**「今天为什么没出歌单」恰恰是最需要数据的场景，
            // 而在此之前这条路径是裸 `return`，什么都没留下 —— 用户只看到 App 没动静。
            _ = await saveFailedRun(
                date: startedAt,
                source: source,
                quickPickStyle: quickPickStyle,
                reason: message,
                tracks: composition.tracks.map(\.info),
                diagnosticsJSON: diagnosticsJSON
            )
            await reportState(.error(message: message, retryable: true))
            return
        }

        // 作曲家只认纯值类型，所以这里按 catalog ID 把 `Song` 取回来。
        // 理论上不会缺（候选都是从 `Song` 造出来的），但绝不 `!` ——
        // 宁可少一首，也不要在这里崩掉整条管线。
        let matchedPairs = composition.tracks.compactMap { candidate -> (TrackInfo, Song)? in
            guard let song = songsByID[candidate.info.id] else {
                Self.log("候选 \(candidate.info.id) 找不到对应的 Song，已跳过")
                return nil
            }
            return (candidate.info, song)
        }
        guard !matchedPairs.isEmpty else {
            await reportState(.error(message: "候选曲目丢失，请稍后重试", retryable: true))
            return
        }
        let matchedTracks = matchedPairs.map(\.0)
        let matchedSongs = matchedPairs.map(\.1)

        // ---- Step 7: Persist FIRST (pending) ----
        await reportState(.persistingRecord)

        let dateKey = startedAt.yyyyMMddString
        let ordinal = await countTodayRecommendations(source: source) + 1
        let dateSuffix = ordinal == 1 ? dateKey : "\(dateKey)-\(String(format: "%02d", ordinal))"

        let playlistName: String
        let playlistDesc: String
        if let style = quickPickStyle {
            playlistName = "\(style.emoji) \(style.rawValue)精选 · \(dateSuffix)"
            playlistDesc = "基于你的收藏，AI 为你生成的 \(style.rawValue)歌单"
        } else {
            playlistName = "\(scene.scene.emoji) Songly 每日推荐 · \(dateSuffix)"
            playlistDesc = "\(scene.scene.displayName)的歌，AI 为你挑选"
        }

        guard let modelID = await saveRecommendation(
            date: startedAt,
            strategy: RecommendationStrategy.styleExploration.rawValue,
            songCount: matchedTracks.count,
            tracks: matchedTracks,
            source: source,
            quickPickStyle: quickPickStyle?.rawValue,
            playlistName: playlistName,
            // 只给每日推荐记场景。QuickPick 的身份是用户点名的那个风格，
            // 记上「深夜」会让卡片的场景带写着与内容不符的由来。
            scene: quickPickStyle == nil ? scene.scene.rawValue : nil,
            // 版本标识 —— 没有它，这一行数据在算法改版后就无法归入任何批次。
            pipelineVersion: AppConfig.pipelineVersion,
            promptVersion: AppConfig.promptVersion,
            modelID: AppConfig.deepseekModel,
            diagnosticsJSON: diagnosticsJSON
        ) else {
            await reportState(.error(message: "数据保存失败，请稍后重试", retryable: true))
            return
        }
        // 从这一刻起库里有一条未收尾的记录，取消路径需要负责清掉它。
        pendingRecordID = modelID

        // ---- Step 8: Playlist ----
        await reportState(.creatingPlaylist)
        let playlist: Playlist
        do {
            playlist = try await playlistService.createPlaylist(
                name: playlistName,
                description: playlistDesc,
                songs: matchedSongs
            )
        } catch {
            // **保留这条记录**并标记为失败，而不是删掉它。
            //
            // 原先这里是 `deleteRecommendation` —— 于是「歌单没建成」这件事在数据上
            // 彻底消失，用户只看到 App 没动静。它已经带着完整的曲目与诊断落过库了，
            // 丢掉太可惜。
            _ = await markRecommendationFailed(
                modelID: modelID,
                reason: "播放列表创建失败：\(error.localizedDescription)"
            )
            // 已是终态，取消路径不必（也不该）再删它。
            pendingRecordID = nil
            await reportState(.error(message: "播放列表创建失败", retryable: true))
            return
        }

        _ = await markRecommendationCompleted(
            modelID: modelID,
            playlistID: playlist.id.rawValue,
            playlistURL: playlist.url
        )
        // 已收尾，取消路径不必再管它。
        pendingRecordID = nil

        // ---- Step 9: Done ----
        await reportState(.completed(trackCount: matchedTracks.count, playlistName: playlist.name))
        await NotificationService.shared.sendRecommendationReady(count: matchedTracks.count)
    }

    // MARK: - Composition Input

    private static func composerInput(
        candidates: [ResolvedCandidate],
        exclusions: PlaylistComposer.ExclusionSet,
        artistHeat: [String: Int],
        artistWeights: [String: Int],
        artistLastSeen: [String: Date],
        now: Date,
        quickPick: Bool
    ) -> PlaylistComposer.Input {
        var input = PlaylistComposer.Input(candidates: candidates)
        input.exclusions = exclusions
        input.recentArtistCounts = artistHeat
        input.artistWeights = artistWeights
        input.recentArtistLastSeen = artistLastSeen
        input.now = now
        // QuickPick：用户已点名风格，不再套 70/20/10。
        input.tierQuotaEnabled = !quickPick
        return input
    }

    /// 显式反馈与隐式信号的艺人权重逐项相加，再夹到全局范围。
    ///
    /// **两步夹取是故意的。** 隐式那侧已经在 `ImplicitSignalClassifier` 里夹过一次
    /// （`AppConfig.implicitArtistWeightRange`），这里合并后再夹到 `FeedbackStore.weightRange`。
    /// 理由：15 个显式超赞已经能顶到 ±5，而隐式信号廉价易累积（每次播放、每次入库
    /// 都可能加一笔）—— 不先夹一道，它们会把用户亲口说的那点分量冲淡。
    private static func mergeArtistWeights(
        explicit: [String: Int],
        implicit: [String: Int]
    ) -> [String: Int] {
        var merged = explicit
        for (artist, weight) in implicit {
            merged[artist, default: 0] += weight
        }
        let range = FeedbackStore.weightRange
        return merged.mapValues { min(max($0, range.lowerBound), range.upperBound) }
    }

    /// 已达本轮上限的艺人 —— 回传给模型，避免它继续往同一个方向提。
    ///
    /// **必须按 `input` 算，不能用全局的 `maxTracksPerArtist`。** 上限现在是分档的
    /// （近 3 天出现过 → 0 首、4–14 天 → 1 首、更早 → 2 首），拿全局值判定会把
    /// 「已经用满 1 首额度」的艺人漏报，模型于是继续往这个方向提 seed。
    /// 用 `allowingRecent: false` 取**严格档**：告诉模型的是「正常情况下还能不能再给」，
    /// 放宽是管线的兜底手段，不该让模型把它算进去。
    private static func artistsAtCap(
        _ composition: PlaylistComposer.Output,
        input: PlaylistComposer.Input
    ) -> [String] {
        var counts: [String: Int] = [:]
        for track in composition.tracks {
            counts[track.primaryArtist, default: 0] += 1
        }
        return counts
            .filter { artist, count in
                count >= input.artistCap(for: artist, allowingRecent: false)
            }
            .keys
            .sorted()
    }

    /// 把拒绝原因按类别计数。同一首歌可能被多个 composer 轮次拒绝，
    /// 这里按 (歌名, 原因) 去重，避免一轮放宽就把计数放大好几倍。
    private static func rejectionBreakdown(
        _ rejections: [PlaylistComposer.Rejection]
    ) -> [String: Int] {
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        for rejection in rejections {
            let identity = "\(rejection.info.id)|\(rejection.reason.key)"
            guard seen.insert(identity).inserted else { continue }
            counts[rejection.reason.key, default: 0] += 1
        }
        return counts
    }

    /// 判断收在 `LLMServiceError.isTerminal` 上，两个调用方（引擎与头像刷新器）
    /// 共用同一份口径 —— 原先这里只认 `.apiKeyNotConfigured`，于是 401 会被
    /// 当成可重试，UI 渲染出一个永远失败的重试按钮。
    private static func isNonRetryable(_ error: Error) -> Bool {
        (error as? LLMServiceError)?.isTerminal ?? false
    }

    // MARK: - Mapping

    /// `ResolvedCandidate` 需要能取回 `Song` 才能建歌单，所以把它挂在上面。
    private static func snapshot(_ song: Song) -> LibraryTrackSnapshot {
        LibraryTrackSnapshot(
            title: song.title,
            artist: song.artistName,
            genreNames: song.genreNames,
            releaseYear: song.releaseDate.map { Calendar.current.component(.year, from: $0) },
            playCount: song.playCount
        )
    }

    // MARK: - Exclusions

    private func makeExclusions(
        songs: [Song],
        recentlyPlayed: [Song],
        source: String,
        feedback: FeedbackStore.Derived,
        implicitSignals: ImplicitSignals
    ) async -> PlaylistComposer.ExclusionSet {
        // 去重窗口是 source 感知的：daily 14 天、quick_pick 7 天，
        // 但**两者都进排除集合** —— 旧实现里 quick_pick 完全不参与去重，
        // 结果它和 daily 会互相撞歌。
        let dailyIDs = await fetchRecentTrackIDs(
            windowDays: AppConfig.dedupWindowDays, sources: ["daily"]
        )
        let quickPickIDs = await fetchRecentTrackIDs(
            windowDays: AppConfig.dedupWindowDaysQuickPick, sources: ["quick_pick"]
        )
        let historyKeys = await fetchRecentTrackInfos(
            windowDays: AppConfig.dedupWindowDays, sources: ["daily"]
        ).map(\.key)

        return PlaylistComposer.ExclusionSet(
            songIDs: dailyIDs.union(quickPickIDs),
            keys: Set(historyKeys),
            recentlyPlayedKeys: Set(recentlyPlayed.map(\.key)),
            libraryKeys: Set(songs.map(\.key)),
            // 用户删掉的歌。**与上面几项不同，它不受放宽阶梯影响** ——
            // 用户说了不要，候选不够也不是把它塞回去的理由。
            //
            // 三个来源并起来：
            // - `removedIDs`：App 内「删除」；
            // - `implicitRemovedIDs`：他从我们建的歌单里自己删掉的（`derive` 读的落盘值，
            //   覆盖全部历史，含回看窗口之外的）；
            // - `implicitSignals.removedIDs`：**本轮**刚发现的。与上一条重叠，但并上它
            //   是为了**不依赖落盘成功** —— 存盘失败时这一轮的排除仍然生效。
            removedSongIDs: feedback.removedIDs
                .union(feedback.implicitRemovedIDs)
                .union(implicitSignals.removedIDs),
            removedKeys: feedback.removedKeys
                .union(feedback.implicitRemovedKeys)
                .union(implicitSignals.removedKeys)
        )
    }

    /// 读一次用户反馈，产出三层都要用的那一份派生结果。
    ///
    /// `FeedbackStore` 是 `@MainActor`（它要碰 `modelContainer.mainContext`），
    /// 所以这里 hop 一次主线程拿结果 —— 与本文件其他 SwiftData 辅助函数的做法一致。
    private func deriveFeedback() async -> FeedbackStore.Derived {
        await MainActor.run {
            FeedbackStore(context: modelContainer.mainContext).derive()
        }
    }

    // MARK: - Logging

    private static func log(_ message: String) {
        #if DEBUG
        print("[Songly] \(message)")
        #endif
    }

    /// 本次运行的完整诊断 payload —— 这是"为什么这次只有 21 首"能被回答的前提。
    ///
    /// **只构造、不输出。** 两个出口共用同一份：DEBUG 打印（`logDiagnostics`）
    /// 与落库（`encodeDiagnostics` → `RecommendationRecord.diagnosticsJSON`）。
    /// 为什么必须拆开，见 `encodeDiagnostics` 的注释。
    private static func diagnosticsPayload(
        rounds: Int,
        stopReason: StopReason,
        seedsRequested: Int,
        seedsResolved: Int,
        candidates: Int,
        composition: PlaylistComposer.Output,
        stopReasonIsTarget: Bool,
        elapsed: TimeInterval,
        scene: SceneContext,
        profileVersion: Int?,
        inputTokens: Int,
        cacheReadTokens: Int,
        failureReasons: [String: Int],
        albumExpansions: Int,
        rawSeedInput: String?,
        rejectionReasons: [String: Int],
        implicitCandidates: Int,
        implicitSignals: ImplicitSignals,
        implicitObservation: ImplicitObservation
    ) -> [String: Any] {
        var counts: [String: Int] = [:]
        for (tier, count) in composition.tierCounts { counts[tier.rawValue] = count }
        return [
            "rounds": rounds,
            "stop_reason": stopReason.rawValue,
            "seeds_requested": seedsRequested,
            // 成功解析出至少一首曲目的 seed 数（不是候选数）。
            "seeds_resolved": seedsResolved,
            "resolve_rate": seedsRequested > 0
                ? (Double(seedsResolved) / Double(seedsRequested) * 100).rounded() / 100
                : 0,
            "candidates_total": candidates,
            "candidates": candidates,
            "album_expansions": albumExpansions,
            // 解析失败的原因分布：catalog_miss / album_not_found / artist_not_found /
            // album_all_excluded / request_failed / missing_title
            "failures": failureReasons,
            // 拒绝原因的成分。**already_recommended > 0 就证明跨天去重在真的工作** ——
            // 这是"每天生成会不会重复"唯一能被观测到的证据。
            "rejection_reasons": rejectionReasons,
            "final": composition.tracks.count,
            "deficit": composition.deficit,
            "tiers": counts,
            "rejections": composition.rejections.count,
            "scene": scene.scene.rawValue,
            "scene_overridden": scene.isOverridden,
            "profile_version": profileVersion ?? -1,
            // 只在"有工具调用但解不出 seed"时出现。它是区分
            // 「模型没给」与「我们的 schema 对不上」的唯一证据。
            "raw_seed_input": rawSeedInput ?? "",
            // 缓存命中率是「system 前缀有没有做到字节稳定」的直接证据。
            // 第 2 轮起应当接近 1.0；若一直是 0，说明前缀被什么东西污染了。
            "input_tokens": inputTokens,
            "cache_read_tokens": cacheReadTokens,
            "cache_hit_rate": inputTokens > 0
                ? (Double(cacheReadTokens) / Double(inputTokens) * 100).rounded() / 100
                : 0,
            "elapsed_s": (elapsed * 10).rounded() / 10,

            // 隐式信号 —— 「完全后台」这个决定下，这里是它**唯一**的可观测性。
            // `notes` 已在检测器里排序，保证同输入同字节。
            "implicit": [
                "candidates": implicitCandidates,
                "starred": implicitSignals.starred.count,
                "adopted": implicitSignals.adopted.count,
                "listened": implicitSignals.listened.count,
                "playlist_removed": implicitSignals.removedSongs.count,
                "weighted_artists": implicitSignals.artistWeights.count,
                "degraded": implicitObservation.degraded,
                "notes": implicitObservation.notes,
            ],

            // 阈值快照。版本号只说「哪一版」，说不清「那一版用的是什么参数」——
            // 改一个窗口天数不会 +1 版本号，结果却会变。把当次真正生效的值记下来，
            // 历史数据才永远解释得通。
            "config": [
                "target_track_count": AppConfig.targetTrackCount,
                "max_tracks_per_artist": AppConfig.maxTracksPerArtist,
                "max_tracks_per_album": AppConfig.maxTracksPerAlbum,
                "max_gap_rounds": AppConfig.maxGapRounds,
                "dedup_window_days": AppConfig.dedupWindowDays,
                "dedup_window_days_quick_pick": AppConfig.dedupWindowDaysQuickPick,
                "artist_recency_window_days": AppConfig.artistRecencyWindowDays,
                // 跨天艺人闸门的两档阈值。**必须进来** —— 它们直接改变选曲结果，
                // 而只靠 `pipelineVersion` 说不清「这一版用的是 3 天还是 5 天」。
                "artist_blocked_within_days": AppConfig.artistBlockedWithinDays,
                "artist_cooldown_days": AppConfig.artistCooldownDays,
                "reject_live_titles": AppConfig.rejectLiveTitles,
            ],
        ]
    }

    /// DEBUG 下把诊断打成人读的一行。
    private static func logDiagnostics(_ payload: [String: Any]) {
        #if DEBUG
        if let json = encodeDiagnostics(payload) {
            print("[Songly] \(json)")
        }
        #endif
    }

    /// 序列化成稳定 JSON（`.sortedKeys` —— 同输入同字节，便于跨批次比对）。
    ///
    /// ⚠️ **刻意不包 `#if DEBUG`。** 落库要经过它，而 02:00 的后台任务跑的是
    /// **Release 构建**。包上之后 Debug 一切正常、Release 静默产出零数据，
    /// 且没有任何报错 —— 这是本次改动最容易踩、也最难发现的一个坑。
    private static func encodeDiagnostics(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - SwiftData Helpers (MainActor-isolated, Sendable-only params)

    private func loadTasteProfile() -> TasteProfile? {
        tasteProfileStore.load()
    }

    @MainActor
    private func countTodayRecommendations(source: String) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let predicate = #Predicate<RecommendationRecord> { record in
            record.date >= today && record.date < tomorrow
                && record.source == source
                // 只数已完成的 —— 这一个数字决定歌单名后缀是 `20261001` 还是
                // `20261001-02`。失败的那次没有建出任何歌单，不该占用一个序号。
                && record.status == "completed"
        }
        let context = modelContainer.mainContext
        return (try? context.fetchCount(FetchDescriptor<RecommendationRecord>(predicate: predicate))) ?? 0
    }

    /// 近 N 天里每位艺人出现过几次。喂给 composer 的**层内排序**。
    ///
    /// ⚠️ 它**挡不住任何人**：`takeNext` 会把整条队列走完，所以只要那一层候选不够，
    /// 排序靠后的艺人照样会被选中。原先这里的注释写着它是「每天都是同几个艺人」的
    /// 真正解药 —— **那句话是错的**，排序只是让重复的靠后一点。
    /// 真正的闸门是 `AppConfig.artistBlockedWithinDays` 那三档
    /// （见 `PlaylistComposer.Input.artistCap`）。
    @MainActor
    private func recentArtistCounts(windowDays: Int) -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in fetchRecentRecords(windowDays: windowDays, sources: ["daily", "quick_pick"]) {
            for info in record.tracks {
                counts[primaryArtistKey(info.artist), default: 0] += 1
            }
        }
        return counts
    }

    /// 每位艺人最近一次出现在推荐里的日期（近 `artistCooldownDays` 天）。
    ///
    /// 与 `recentArtistCounts` 分开是**故意的**：那个数次数、用于排序，这个记日期、
    /// 用于闸门。次数区分不了「3 天前 1 次」和「6 天前 1 次」，而这两档一个禁一个限。
    ///
    /// 只扫已完成的记录（`fetchRecentRecords` 已经保证）—— 失败运行的曲目从未出现在
    /// 任何歌单里，拿它去禁一位艺人等于凭空惩罚。
    @MainActor
    private func fetchArtistRecency() -> ArtistRecencySignals {
        var signals = ArtistRecencySignals()
        for record in fetchRecentRecords(
            windowDays: AppConfig.artistCooldownDays,
            sources: ["daily", "quick_pick"]
        ) {
            for info in record.tracks {
                let key = primaryArtistKey(info.artist)
                guard !key.isEmpty else { continue }
                // 记录已按 date 降序；显式比较是为了不依赖调用方给的顺序。
                if let existing = signals.lastSeen[key], existing >= record.date { continue }
                signals.lastSeen[key] = record.date
                signals.displayNames[key] = info.artist
            }
        }
        return signals
    }

    /// 隐式信号的输入：候选曲目 + 待比对的歌单。都要读记录，所以走主线程。
    ///
    /// **候选去重时两个字段取不同的一条记录**，这是刻意的：
    /// - `hasExplicitVerdict` / `librarySyncedAt` 取**最新**那条（他现在的表态）；
    /// - `firstRecommendedAt` 取**最早**那条（第一次推荐才是归因起点 —— 他在第 2 次
    ///   推荐后才收藏时，用「最近」会漏判）。
    @MainActor
    private func collectImplicitInput() -> (
        candidates: [ImplicitCandidate],
        playlists: [ImplicitPlaylistTarget]
    ) {
        guard AppConfig.implicitSignalsEnabled else { return ([], []) }

        // 已按 date 降序 → 第一次遇到某首歌时，手里就是最新那条记录。
        let records = Array(fetchRecentRecords(
            windowDays: AppConfig.implicitLookbackDays,
            sources: ["daily", "quick_pick"]
        ).prefix(AppConfig.maxImplicitLookbackRecords))

        var newest: [String: (track: TrackInfo, playlistID: String?)] = [:]
        var earliest: [String: Date] = [:]
        var playlists: [ImplicitPlaylistTarget] = []

        for record in records {
            // 只有**建成过歌单**的记录才谈得上「他有没有删歌」。
            if let playlistID = record.playlistID,
               record.status == RecommendationRecord.statusCompleted,
               !record.visibleTracks.isEmpty {
                playlists.append(ImplicitPlaylistTarget(
                    playlistID: playlistID,
                    expectedKeys: record.visibleTracks.map(\.key)
                ))
            }

            for track in record.tracks {
                guard !track.id.isEmpty else { continue }
                if newest[track.id] == nil {
                    newest[track.id] = (track, record.playlistID)
                }
                if let existing = earliest[track.id] {
                    if record.date < existing { earliest[track.id] = record.date }
                } else {
                    earliest[track.id] = record.date
                }
            }
        }

        let candidates = newest.compactMap { id, entry -> ImplicitCandidate? in
            guard let first = earliest[id] else { return nil }
            return ImplicitCandidate(
                songID: id,
                key: entry.track.key,
                displayName: "\(entry.track.name) - \(entry.track.artist)",
                artist: primaryArtistKey(entry.track.artist),
                firstRecommendedAt: first,
                playlistID: entry.playlistID,
                hasExplicitVerdict: entry.track.verdict != nil,
                librarySyncedAt: entry.track.librarySyncedAt
            )
        }
        .sorted { $0.songID < $1.songID }        // 稳定顺序：诊断与测试都要可复现
        .prefix(AppConfig.maxImplicitCandidateIDs)

        return (Array(candidates), playlists)
    }

    /// 把本轮发现的「他删掉了」落进记录。
    ///
    /// 不落盘的话，这条排除会在记录滚出回看窗口时**蒸发** —— 而「删除应当永久生效」
    /// 正是这套东西的设计前提。
    ///
    /// 调用时机很关键：它必须发生在 `deriveFeedback()` **之前**，这样同一轮里
    /// `derive()` 就能读到刚落的值，`makeExclusions` 也就自动覆盖了全部历史。
    @MainActor
    private func persistImplicitRemovals(_ signals: ImplicitSignals) {
        guard !signals.removedKeys.isEmpty else { return }
        let store = FeedbackStore(context: modelContainer.mainContext)
        for record in fetchRecentRecords(
            windowDays: AppConfig.implicitLookbackDays,
            sources: ["daily", "quick_pick"]
        ) {
            for track in record.tracks where signals.removedKeys.contains(track.key) {
                _ = store.markImplicitRemoved(songID: track.id, in: record)
            }
        }
    }

    @MainActor
    private func fetchRecentRecords(windowDays: Int, sources: [String]) -> [RecommendationRecord] {
        let context = modelContainer.mainContext
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date()) ?? Date.distantPast
        let predicate = #Predicate<RecommendationRecord> { record in
            record.date >= cutoff
                && sources.contains(record.source)
                // **只认已完成的。** 这条查询服务于去重窗口、艺人热度与「近 N 天
                // 已推荐过」—— 用的是「用户见过什么」。而 `failed` 记录的曲目
                // 从未出现在任何歌单里，放进来会把用户从没见过的歌排除掉。
                // `pending` 同理：进程若在「落库」与「建歌单」之间被杀，那条记录
                // 会永久留在库里，同样污染这两处（这是个既有隐患，顺手一并修掉）。
                && record.status == "completed"
        }
        let descriptor = FetchDescriptor<RecommendationRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    private func fetchRecentTrackInfos(windowDays: Int, sources: [String]) -> [TrackInfo] {
        fetchRecentRecords(windowDays: windowDays, sources: sources).flatMap(\.tracks)
    }

    @MainActor
    private func fetchRecentTrackIDs(windowDays: Int, sources: [String]) -> Set<String> {
        Set(fetchRecentRecords(windowDays: windowDays, sources: sources).flatMap(\.trackIDs))
    }

    @MainActor
    private func saveRecommendation(
        date: Date,
        strategy: String,
        songCount: Int,
        tracks: [TrackInfo],
        source: String,
        quickPickStyle: String?,
        playlistName: String?,
        scene: String?,
        status: String = RecommendationRecord.statusPending,
        failureReason: String? = nil,
        pipelineVersion: Int = 0,
        promptVersion: Int = 0,
        modelID: String? = nil,
        diagnosticsJSON: String? = nil
    ) -> PersistentIdentifier? {
        let context = modelContainer.mainContext
        let record = RecommendationRecord(
            date: date,
            strategy: strategy,
            songCount: songCount,
            tracks: tracks,
            source: source,
            quickPickStyle: quickPickStyle,
            playlistName: playlistName,
            status: status,
            scene: scene,
            pipelineVersion: pipelineVersion,
            promptVersion: promptVersion,
            modelID: modelID,
            diagnosticsJSON: diagnosticsJSON,
            failureReason: failureReason
        )
        context.insert(record)
        do {
            try context.save()
            return record.persistentModelID
        } catch {
            return nil
        }
    }

    /// 落一条**失败**运行的记录。
    ///
    /// 存在的理由只有一个：让「今天为什么没出歌单」事后有据可查。
    /// 在此之前这条路径什么都不留，用户只看到 App 没动静，我们连「是 LLM 没给够
    /// seed，还是候选全被闸门挡掉了」都无从判断 —— 而这些信息在 `diagnosticsJSON` 里。
    ///
    /// 记录带着 `status == "failed"`，所有展示与去重路径都必须排除它
    /// （见 `RecommendationRecord.statusFailed` 的注释）。
    @MainActor
    private func saveFailedRun(
        date: Date,
        source: String,
        quickPickStyle: QuickPickStyle?,
        reason: String,
        tracks: [TrackInfo],
        diagnosticsJSON: String?
    ) -> PersistentIdentifier? {
        saveRecommendation(
            date: date,
            strategy: RecommendationStrategy.styleExploration.rawValue,
            songCount: tracks.count,
            tracks: tracks,
            source: source,
            quickPickStyle: quickPickStyle?.rawValue,
            playlistName: nil,
            scene: nil,
            status: RecommendationRecord.statusFailed,
            failureReason: reason,
            pipelineVersion: AppConfig.pipelineVersion,
            promptVersion: AppConfig.promptVersion,
            modelID: AppConfig.deepseekModel,
            diagnosticsJSON: diagnosticsJSON
        )
    }

    @MainActor
    private func markRecommendationCompleted(
        modelID: PersistentIdentifier,
        playlistID: String?,
        playlistURL: URL?
    ) -> Bool {
        let context = modelContainer.mainContext
        guard let record = context.model(for: modelID) as? RecommendationRecord else { return false }
        record.status = RecommendationRecord.statusCompleted
        record.playlistID = playlistID
        record.playlistURL = playlistURL
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }

    /// 把一条已落库的记录标记为失败，**不删除** —— 它带着曲目与诊断，
    /// 是「歌单为什么没建成」唯一的一手材料。
    @MainActor
    private func markRecommendationFailed(modelID: PersistentIdentifier, reason: String) -> Bool {
        let context = modelContainer.mainContext
        guard let record = context.model(for: modelID) as? RecommendationRecord else { return false }
        record.status = RecommendationRecord.statusFailed
        record.failureReason = reason
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }

    @MainActor
    private func deleteRecommendation(modelID: PersistentIdentifier) -> Bool {
        let context = modelContainer.mainContext
        guard let record = context.model(for: modelID) as? RecommendationRecord else { return false }
        context.delete(record)
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }
}
