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

// MARK: - Engine

actor RecommendationEngine {
    private let musicKitService: MusicKitServiceProtocol
    private let llmService: LLMServiceProtocol
    private let playlistService: PlaylistServiceProtocol
    private let catalogResolver: CatalogResolving
    private let tasteProfileStore: TasteProfileStore
    private let modelContainer: ModelContainer

    private var isRunning = false
    private var currentTask: Task<Void, Never>?

    init(
        musicKitService: MusicKitServiceProtocol,
        llmService: LLMServiceProtocol,
        playlistService: PlaylistServiceProtocol,
        catalogResolver: CatalogResolving,
        tasteProfileStore: TasteProfileStore = TasteProfileStore(),
        modelContainer: ModelContainer
    ) {
        self.musicKitService = musicKitService
        self.llmService = llmService
        self.playlistService = playlistService
        self.catalogResolver = catalogResolver
        self.tasteProfileStore = tasteProfileStore
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
            songs = try await musicKitService.fetchLibrarySongs(
                limit: AppConfig.maxLibrarySongs,
                since: await fetchLastSyncDate()
            )
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
        await updateLastSyncDate()

        // ---- Step 3: Signals（可降级、各自超时、并发）----
        async let recentlyPlayedTask = withTimeout(AppConfig.contextTimeout) {
            try await self.musicKitService.fetchRecentlyPlayedSongs(limit: AppConfig.recentlyPlayedLimit)
        }
        async let topPlayedTask = withTimeout(AppConfig.contextTimeout) {
            try await self.musicKitService.fetchTopPlayedSongs(limit: AppConfig.topPlayedLimit)
        }
        let recentlyPlayed = await recentlyPlayedTask ?? []
        let topPlayed = await topPlayedTask ?? []

        // ---- Step 4: Scene + Profile + Exclusions ----
        // 风格模式下情境仍作为背景，只是优先级低于用户点名的风格。
        let scene = SceneContext.sensed()
        let profile = loadTasteProfile()
        let exclusions = await makeExclusions(
            songs: songs,
            recentlyPlayed: recentlyPlayed,
            source: source
        )
        let artistHeat = await recentArtistCounts(windowDays: AppConfig.artistRecencyWindowDays)

        let historyForPrompt = await fetchRecentTrackInfos(
            windowDays: AppConfig.dedupWindowDays,
            sources: ["daily"]
        ).map(PromptTrack.init)

        // ---- Step 5: Round loop ----
        let seedTargets = PromptBuilderV3.seedTargets(for: AppConfig.targetTrackCount)
        var request = SeedRequest(
            system: PromptBuilderV3.systemPrefix(profile: profile),
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
                seedTargets: seedTargets,
                quickPickStyle: quickPickStyle
            )
        )

        var accumulated: [ResolvedCandidate] = []
        /// catalog ID → Song。建歌单要用真实对象，所以每轮都把映射并进来。
        var songsByID: [String: Song] = [:]
        var composition = PlaylistComposer.compose(Self.composerInput(
            candidates: accumulated, exclusions: exclusions,
            artistHeat: artistHeat, quickPick: quickPickStyle != nil
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
                // 第 1 轮失败就没有退路；补位轮失败则保留已有成果收工。
                if round == 1 {
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

            composition = PlaylistComposer.compose(Self.composerInput(
                candidates: accumulated, exclusions: exclusions,
                artistHeat: artistHeat, quickPick: quickPickStyle != nil
            ))

            let decision = GapRoundPlanner.decide(RoundState(
                round: round,
                composed: composition,
                resolvedThisRound: resolution.candidates.count,
                newSeedsThisRound: response.seeds.count,
                failedSeeds: resolution.failures,
                artistsAtCap: Self.artistsAtCap(composition),
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

        Self.logDiagnostics(
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
            rejectionReasons: Self.rejectionBreakdown(composition.rejections)
        )

        // ---- Step 6: Gate ----
        //
        // 缺口没补上但够格发布时**照常发布** —— 20–24 首是好歌单，
        // 不值得为了凑满 25 让用户白等一轮。
        guard composition.publishable, !composition.tracks.isEmpty else {
            await reportState(.error(
                message: EngineError.insufficientCandidates(count: composition.tracks.count).localizedDescription,
                retryable: true
            ))
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
            scene: quickPickStyle == nil ? scene.scene.rawValue : nil
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
            _ = await deleteRecommendation(modelID: modelID)
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
        quickPick: Bool
    ) -> PlaylistComposer.Input {
        var input = PlaylistComposer.Input(candidates: candidates)
        input.exclusions = exclusions
        input.recentArtistCounts = artistHeat
        // QuickPick：用户已点名风格，不再套 70/20/10。
        input.tierQuotaEnabled = !quickPick
        return input
    }

    /// 已达单份歌单上限的艺人 —— 回传给模型，避免它继续往同一个方向提。
    private static func artistsAtCap(_ composition: PlaylistComposer.Output) -> [String] {
        var counts: [String: Int] = [:]
        for track in composition.tracks {
            counts[track.primaryArtist, default: 0] += 1
        }
        return counts
            .filter { $0.value >= AppConfig.maxTracksPerArtist }
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

    private static func isNonRetryable(_ error: Error) -> Bool {
        guard let llmError = error as? LLMServiceError else { return false }
        if case .apiKeyNotConfigured = llmError { return true }
        return false
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
        source: String
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
            libraryKeys: Set(songs.map(\.key))
        )
    }

    // MARK: - Logging

    private static func log(_ message: String) {
        #if DEBUG
        print("[Songly] \(message)")
        #endif
    }

    /// 每次运行打一份诊断 —— 这是"为什么这次只有 21 首"能被回答的前提。
    private static func logDiagnostics(
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
        rejectionReasons: [String: Int]
    ) {
        #if DEBUG
        var counts: [String: Int] = [:]
        for (tier, count) in composition.tierCounts { counts[tier.rawValue] = count }
        let payload: [String: Any] = [
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
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print("[Songly] \(json)")
        }
        #endif
    }

    // MARK: - SwiftData Helpers (MainActor-isolated, Sendable-only params)

    @MainActor
    private func fetchLastSyncDate() -> Date? {
        let context = modelContainer.mainContext
        let results = try? context.fetch(FetchDescriptor<UserPreferences>())
        return results?.first?.lastSyncDate
    }

    @MainActor
    private func updateLastSyncDate() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<UserPreferences>()
        if let prefs = try? context.fetch(descriptor).first {
            prefs.lastSyncDate = Date()
        } else {
            let newPrefs = UserPreferences()
            newPrefs.lastSyncDate = Date()
            context.insert(newPrefs)
        }
        try? context.save()
    }

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
        }
        let context = modelContainer.mainContext
        return (try? context.fetchCount(FetchDescriptor<RecommendationRecord>(predicate: predicate))) ?? 0
    }

    /// 近 N 天里每位艺人出现过几次。喂给 composer 的层内排序首位 ——
    /// 这是"每天都是同几个艺人"的真正解药，单次歌单内的上限治不了跨天重复。
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

    @MainActor
    private func fetchRecentRecords(windowDays: Int, sources: [String]) -> [RecommendationRecord] {
        let context = modelContainer.mainContext
        let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date()) ?? Date.distantPast
        let predicate = #Predicate<RecommendationRecord> { record in
            record.date >= cutoff && sources.contains(record.source)
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
        scene: String?
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
            status: RecommendationRecord.statusPending,
            scene: scene
        )
        context.insert(record)
        do {
            try context.save()
            return record.persistentModelID
        } catch {
            return nil
        }
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
