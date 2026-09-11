//
//  PlaylistComposer.swift
//  Songly
//
//  纯函数作曲家：把候选曲目池收敛成一份**必然满足硬约束**的歌单。
//
//  这是「数量稳定 20–25」与「同一歌手 ≤2 首」的根本解 —— 两者都由确定性代码
//  保证，不依赖 LLM 的行为。全部 `static`、无网络、无 MusicKit、无 SwiftData，
//  因此可以完整单测。
//

import Foundation

enum PlaylistComposer {

    // MARK: - Types

    /// 硬排除集合。`songIDs` 是权威键，其余是文本键（跨窗口历史 / 最近播放 / 曲库）。
    struct ExclusionSet: Equatable, Sendable {
        /// catalog `MusicItemID` —— 权威去重键。
        var songIDs: Set<String> = []
        /// 归一化「歌名 + 艺人」—— 近 N 天已推荐过的。
        var keys: Set<TrackKey> = []
        var recentlyPlayedKeys: Set<TrackKey> = []
        var libraryKeys: Set<TrackKey> = []
    }

    /// 允许放宽哪些排除项。三级递进，只在候选不足时逐级启用。
    struct Relaxation: Equatable, Sendable {
        var allowLibrary: Bool
        var allowRecentlyPlayed: Bool
        var allowAlreadyRecommended: Bool
        /// 只有上一轮结果**低于**这个数，才值得尝试本轮。
        var entryThreshold: Int

        /// 正常路径：全部排除项生效。
        static let strict = Relaxation(
            allowLibrary: false, allowRecentlyPlayed: false,
            allowAlreadyRecommended: false, entryThreshold: Int.max
        )
        /// 允许与曲库重叠。
        static let libraryOverlap = Relaxation(
            allowLibrary: true, allowRecentlyPlayed: false,
            allowAlreadyRecommended: false, entryThreshold: AppConfig.minAcceptableTrackCount
        )
        /// 再允许最近播放过的。
        static let libraryAndRecent = Relaxation(
            allowLibrary: true, allowRecentlyPlayed: true,
            allowAlreadyRecommended: false, entryThreshold: AppConfig.minAcceptableTrackCount
        )
        /// 最后手段：连"近期已推荐过"也放开。
        /// 只在否则连 `publishableTrackCount` 都够不到时才启用 —— 宁可少几首，
        /// 也不要给用户重推三天前刚推过的歌。
        static let everything = Relaxation(
            allowLibrary: true, allowRecentlyPlayed: true,
            allowAlreadyRecommended: true, entryThreshold: AppConfig.publishableTrackCount
        )

        static let ladder: [Relaxation] = [
            .strict, .libraryOverlap, .libraryAndRecent, .everything,
        ]
    }

    enum RejectionReason: Equatable, Sendable {
        case duplicateID
        case duplicateKey
        case alreadyRecommended
        case recentlyPlayed
        case inLibrary
        case contentType(ContentRejection)
        case artistCapped
        /// 通过全部过滤，但配额已满 / 被硬截断挡下。
        case notSelected

        /// 诊断用的稳定短名。放进日志，用来回答"去重到底有没有在跑"。
        var key: String {
            switch self {
            case .duplicateID: return "duplicate_id"
            case .duplicateKey: return "duplicate_key"
            case .alreadyRecommended: return "already_recommended"
            case .recentlyPlayed: return "recently_played"
            case .inLibrary: return "in_library"
            case .contentType(let reason): return "content_\(reason.rawValue)"
            case .artistCapped: return "artist_capped"
            case .notSelected: return "quota_full"
            }
        }
    }

    struct Rejection: Equatable, Sendable {
        let info: TrackInfo
        let reason: RejectionReason
    }

    struct Input: Sendable {
        var candidates: [ResolvedCandidate]
        /// 硬上限：超过即截断。
        var targetCount: Int = AppConfig.targetTrackCount
        /// 低于此数视为不完整（触发补位轮）。
        var minCount: Int = AppConfig.minAcceptableTrackCount
        /// 低于此数直接判定失败。
        var absoluteMinCount: Int = AppConfig.publishableTrackCount
        var maxPerArtist: Int = AppConfig.maxTracksPerArtist
        /// QuickPick 场景关掉三层配额 —— 用户主动点了一个风格，不该再套 70/20/10。
        var tierQuotaEnabled: Bool = true
        var exclusions = ExclusionSet()
        /// 主艺人 → 最近 N 天的出现次数。层内排序靠前，这是"每天都是同几个艺人"
        /// 的真正解药 —— 单次歌单内的上限治不了跨天重复。
        var recentArtistCounts: [String: Int] = [:]
        /// 稳定随机种子（由 `yyyyMMdd + scene` 派生）。注入以便测试。
        var randomSeed: UInt64 = 0
    }

    struct Output: Sendable, Equatable {
        var tracks: [ResolvedCandidate]
        var rejections: [Rejection]
        var tierCounts: [DiscoveryTier: Int]
        /// `max(0, minCount - tracks.count)`。> 0 表示该跑补位轮了。
        var deficit: Int
        /// 是否够格建成歌单（>= `absoluteMinCount`）。
        var publishable: Bool
    }

    // MARK: - Entry Point

    /// 把候选池收敛成歌单。
    ///
    /// 三条**不可违反**的不变量：
    /// 1. `tracks.count <= targetCount` 恒成立（最后一步硬截断兜底）；
    /// 2. 没有任何艺人的曲目数超过 `maxPerArtist` —— 包括所有放宽 / 回填路径；
    /// 3. compose 之后不再有任何过滤。
    static func compose(_ input: Input) -> Output {
        let target = max(0, input.targetCount)

        // ---- S1 + S2：去重（稳定，先到先得）----
        var seenIDs = Set<String>()
        var seenKeys = Set<TrackKey>()
        var dedupRejections: [Rejection] = []
        var unique: [ResolvedCandidate] = []
        unique.reserveCapacity(input.candidates.count)

        for candidate in input.candidates {
            guard seenIDs.insert(candidate.info.id).inserted else {
                dedupRejections.append(Rejection(info: candidate.info, reason: .duplicateID))
                continue
            }
            guard seenKeys.insert(candidate.info.key).inserted else {
                dedupRejections.append(Rejection(info: candidate.info, reason: .duplicateKey))
                continue
            }
            unique.append(candidate)
        }

        guard target > 0 else {
            return Output(
                tracks: [], rejections: dedupRejections, tierCounts: [:],
                deficit: input.minCount, publishable: false
            )
        }

        // ---- S3 + S4 + S5 + S6 + S7：逐级放宽，取最好的一轮 ----
        var best: Attempt?

        for relaxation in Relaxation.ladder {
            if let current = best, current.tracks.count >= relaxation.entryThreshold {
                break
            }
            let attempt = runPass(unique, relaxation: relaxation, input: input, target: target)
            if let current = best, current.tracks.count > attempt.tracks.count { continue }
            best = attempt
        }

        let attempt = best ?? Attempt(tracks: [], tierCounts: [:], rejections: [])

        // ---- S9：硬截断（belt-and-braces）----
        let tracks = Array(attempt.tracks.prefix(target))

        return Output(
            tracks: tracks,
            rejections: dedupRejections + attempt.rejections,
            tierCounts: attempt.tierCounts,
            deficit: max(0, input.minCount - tracks.count),
            publishable: tracks.count >= input.absoluteMinCount
        )
    }

    // MARK: - One Relaxation Pass

    private struct Attempt {
        var tracks: [ResolvedCandidate]
        var tierCounts: [DiscoveryTier: Int]
        var rejections: [Rejection]
    }

    private static func runPass(
        _ unique: [ResolvedCandidate],
        relaxation: Relaxation,
        input: Input,
        target: Int
    ) -> Attempt {
        var rejections: [Rejection] = []

        // ---- S3 + S4：开池 ----
        var open: [ResolvedCandidate] = []
        open.reserveCapacity(unique.count)

        for candidate in unique {
            let info = candidate.info

            // S4：内容类型过滤（先于配额 —— 被拒的曲目不该占用配额名额）。
            if let reason = ContentTypeFilter.rejection(for: candidate) {
                rejections.append(Rejection(info: info, reason: .contentType(reason)))
                continue
            }

            // S3：硬排除。
            if !relaxation.allowAlreadyRecommended,
               input.exclusions.songIDs.contains(info.id) {
                rejections.append(Rejection(info: info, reason: .alreadyRecommended))
                continue
            }
            if !relaxation.allowAlreadyRecommended,
               input.exclusions.keys.contains(info.key) {
                rejections.append(Rejection(info: info, reason: .alreadyRecommended))
                continue
            }
            if !relaxation.allowRecentlyPlayed,
               input.exclusions.recentlyPlayedKeys.contains(info.key) {
                rejections.append(Rejection(info: info, reason: .recentlyPlayed))
                continue
            }
            if !relaxation.allowLibrary,
               input.exclusions.libraryKeys.contains(info.key) {
                rejections.append(Rejection(info: info, reason: .inLibrary))
                continue
            }

            open.append(candidate)
        }

        // ---- S5：分桶 + 层内排序 ----
        // 关掉配额时（QuickPick），tier 概念不适用，全部并入与 `confident` 同一个桶。
        func bucketTier(_ candidate: ResolvedCandidate) -> DiscoveryTier {
            input.tierQuotaEnabled ? candidate.tier : .confident
        }

        var queues: [DiscoveryTier: [ResolvedCandidate]] = [:]
        for tier in DiscoveryTier.allCases {
            queues[tier] = open
                .filter { bucketTier($0) == tier }
                .sorted { isOrderedBefore($0, $1, input: input) }
        }

        // ---- S6 + S7：配额选择 + 缺口逐层抬升 ----
        var cursors: [DiscoveryTier: Int] = [:]
        var tierCounts: [DiscoveryTier: Int] = [:]
        var artistCounts: [String: Int] = [:]
        var selected: [ResolvedCandidate] = []

        /// 从某一层取出下一个可接受的候选。跳过已达歌手上限的（并记录归因）。
        func takeNext(from tier: DiscoveryTier) -> ResolvedCandidate? {
            guard let queue = queues[tier] else { return nil }
            var index = cursors[tier] ?? 0

            while index < queue.count {
                let candidate = queue[index]
                index += 1

                let artist = candidate.primaryArtist
                if (artistCounts[artist] ?? 0) >= input.maxPerArtist {
                    rejections.append(Rejection(info: candidate.info, reason: .artistCapped))
                    continue
                }

                cursors[tier] = index
                artistCounts[artist, default: 0] += 1
                return candidate
            }

            cursors[tier] = index
            return nil
        }

        // S6：按 70/20/10 逐层取到本层上限。
        let quota = TierQuota(total: target)
        for tier in TierQuota.tierOrder {
            var taken = 0
            while taken < quota.cap(for: tier), selected.count < target {
                guard let candidate = takeNext(from: tier) else { break }
                selected.append(candidate)
                tierCounts[tier, default: 0] += 1
                taken += 1
            }
        }

        // S7：仍有缺口时逐层抬高上限。
        // 顺序 `fresh → bold → confident`：`bold` 被刻意压到 10%，缺口应由
        // 「下一个更有把握的层级」承接，而不是把它抬成 5 倍。`confident` 排最后
        // 是因为它一旦有余量，S6 早就填满了 —— 此时它必然是短缺的一方。
        if selected.count < target {
            for tier in [DiscoveryTier.fresh, .bold, .confident] {
                while selected.count < target {
                    guard let candidate = takeNext(from: tier) else { break }
                    selected.append(candidate)
                    tierCounts[tier, default: 0] += 1
                }
            }
        }

        // 记下通过全部过滤、却因配额已满或硬截断而没进的曲目 —— 供诊断用。
        let selectedIDs = Set(selected.map(\.info.id))
        for tier in DiscoveryTier.allCases {
            guard let queue = queues[tier] else { continue }
            let start = cursors[tier] ?? 0
            guard start < queue.count else { continue }
            for candidate in queue[start...] where !selectedIDs.contains(candidate.info.id) {
                rejections.append(Rejection(info: candidate.info, reason: .notSelected))
            }
        }

        return Attempt(tracks: selected, tierCounts: tierCounts, rejections: rejections)
    }

    // MARK: - Ordering

    /// 层内排序。逐级比较，最后用稳定噪声打散，保证同一天的推荐可复现。
    private static func isOrderedBefore(
        _ lhs: ResolvedCandidate,
        _ rhs: ResolvedCandidate,
        input: Input
    ) -> Bool {
        let left = orderingKey(lhs, input: input)
        let right = orderingKey(rhs, input: input)
        if left != right { return left.lexicographicallyPrecedes(right) }

        let leftNoise = stableNoise(lhs.info.id, seed: input.randomSeed)
        let rightNoise = stableNoise(rhs.info.id, seed: input.randomSeed)
        if leftNoise != rightNoise { return leftNoise < rightNoise }

        // 最终 tie-break：保证结果与输入顺序无关，完全确定。
        return lhs.info.id < rhs.info.id
    }

    /// 比较用的排序键，**优先级从高到低**：
    /// 1. `inLibrary` / `recentlyPlayed` —— 只有放宽后才可能非 0，让回填候选永远垫底；
    /// 2. `artistHeat` —— 近 7 天出现越多的艺人越靠后（跨天去重的关键）；
    /// 3. `seedRank` —— 专辑扩展取到的曲目优先（最可能是深挖结果）；
    /// 4. `isCompilation` —— 合辑垫后。
    private static func orderingKey(_ candidate: ResolvedCandidate, input: Input) -> [Int] {
        let inLibrary = input.exclusions.libraryKeys.contains(candidate.info.key) ? 1 : 0
        let recentlyPlayed = input.exclusions.recentlyPlayedKeys.contains(candidate.info.key) ? 1 : 0
        let artistHeat = input.recentArtistCounts[candidate.primaryArtist] ?? 0
        return [inLibrary, recentlyPlayed, artistHeat, candidate.seedRank, candidate.isCompilation ? 1 : 0]
    }
}
