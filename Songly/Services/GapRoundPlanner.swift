//
//  GapRoundPlanner.swift
//  Songly
//
//  补位轮的状态机：一手拿当前凑到的歌单，一手拿刚解析出来的结果，
//  决定「够了就收工」还是「带着缺口信息再来一轮」。
//
//  纯函数、无网络、无 MusicKit —— 它是唯一决定"什么时候停"的地方，
//  所以必须能完整单测。最要紧的一条是 `noProgress`：没有它，
//  模型反复提同样解析不出来的歌名，就会白白烧掉三轮的时间和钱。
//

import Foundation

// MARK: - Outcomes

enum StopReason: String, Equatable, Sendable {
    case targetReached
    case maxRounds
    case deadline
    case noProgress
    case poolExhausted
    case cancelled

    var displayName: String {
        switch self {
        case .targetReached: return "已凑够目标"
        case .maxRounds: return "已达轮次上限"
        case .deadline: return "已达时间预算"
        case .noProgress: return "上一轮没有新增"
        case .poolExhausted: return "模型没有给出新线索"
        case .cancelled: return "已取消"
        }
    }
}

enum RoundDecision: Equatable, Sendable {
    case stop(StopReason)
    case continueWith(RoundDelta)
}

/// 上一轮里没能解析成真实曲目的 seed。回传给模型，让**它**换个方向。
struct FailedSeed: Equatable, Sendable {
    let artist: String
    let title: String?
    let album: String?
    let reason: String
}

/// 通过筛选却被歌手上限或配额挡下的曲目。
struct RejectedSummary: Equatable, Sendable {
    let title: String
    let artist: String
    let reason: String
}

/// 下一轮要告诉模型的东西。
struct RoundDelta: Equatable, Sendable {
    let seedTarget: Int
    let tierDeficits: [DiscoveryTier: Int]
    let failedSeeds: [FailedSeed]
    let artistsAtCap: [String]
    let alreadyAccepted: [String]
    /// 差量指令，直接作为 user 消息里的文本块。
    let instruction: String
    /// 回填进 `tool_result` 的结构化结果。
    let outcomeJSON: String
}

// MARK: - Input

struct RoundState: Equatable, Sendable {
    /// 从 1 开始。
    let round: Int
    let composed: PlaylistComposer.Output
    /// 本轮新解析出的候选数量（不是累计）。
    let resolvedThisRound: Int
    /// 本轮模型给出的 seed 数量。
    let newSeedsThisRound: Int
    let failedSeeds: [FailedSeed]
    let artistsAtCap: [String]
    let elapsed: TimeInterval
    let isCancelled: Bool
}

// MARK: - Planner

enum GapRoundPlanner {

    struct Config: Equatable, Sendable {
        var target: Int = AppConfig.targetTrackCount
        var maxRounds: Int = AppConfig.maxGapRounds
        var deadline: TimeInterval = AppConfig.pipelineDeadline
        var overGeneration: Double = AppConfig.seedOverGeneration
        var minSeeds: Int = AppConfig.minSeedsPerGapRound
        var maxSeeds: Int = AppConfig.maxSeedsPerGapRound
        var maxFailedSeedsReported = 20
        var maxRejectedReported = 10
        var maxArtistsAtCapReported = 12

        static let `default` = Config()
    }

    /// 决定停下来还是再跑一轮。判断顺序是有讲究的，见各分支注释。
    static func decide(_ state: RoundState, config: Config = .default) -> RoundDecision {
        // 1. 取消优先 —— 后台任务的 expirationHandler 会调 cancel()，
        //    此时应该立刻收手，而不是再看别的条件。
        if state.isCancelled { return .stop(.cancelled) }

        // 2. 够了就别再花钱。
        if state.composed.tracks.count >= config.target { return .stop(.targetReached) }

        // 3. 轮次上限。
        if state.round >= config.maxRounds { return .stop(.maxRounds) }

        // 4. 时间预算。放在 progress 判断之前，因为它更硬。
        if state.elapsed >= config.deadline { return .stop(.deadline) }

        // 5. 本轮一条都没解析出来 —— 再跑一轮大概率还是同样结果。
        //    第 1 轮豁免：全军覆没时应该带着失败清单再试一次。
        if state.round > 1, state.resolvedThisRound == 0 {
            return .stop(.noProgress)
        }

        // 6. 模型这轮没给出任何 seed。
        //    第 1 轮**豁免**：单次空响应几乎总是暂时性的（或工具调用的形状对不上），
        //    直接判死会让整条管线白跑一趟 —— 至少给它一次重说的机会。
        if state.newSeedsThisRound == 0, state.round > 1 { return .stop(.poolExhausted) }

        return .continueWith(delta(for: state, config: config))
    }

    // MARK: - Delta

    private static func delta(for state: RoundState, config: Config) -> RoundDelta {
        let composed = state.composed
        let deficit = max(0, config.target - composed.tracks.count)

        // 超额要货：解析、去重、歌手上限都会吃掉一批。
        let seedTarget = min(
            max(Int((Double(deficit) * config.overGeneration).rounded()), config.minSeeds),
            config.maxSeeds
        )

        let quota = TierQuota(total: config.target)
        var tierDeficits: [DiscoveryTier: Int] = [:]
        for tier in DiscoveryTier.allCases {
            tierDeficits[tier] = max(0, quota.cap(for: tier) - (composed.tierCounts[tier] ?? 0))
        }

        let failed = Array(state.failedSeeds.prefix(config.maxFailedSeedsReported))
        let artistsAtCap = Array(state.artistsAtCap.prefix(config.maxArtistsAtCapReported))
        let accepted = composed.tracks.prefix(config.target).map { "\($0.info.name) - \($0.info.artist)" }

        let rejected = composed.rejections
            .filter { rejection in
                // 只回传"本来能进、但被规则挡下"的那些 ——
                // 内容类型不符的没必要让模型知道，它也没法改。
                switch rejection.reason {
                case .artistCapped, .notSelected: return true
                default: return false
                }
            }
            .prefix(config.maxRejectedReported)
            .map { RejectedSummary(title: $0.info.name, artist: $0.info.artist, reason: $0.reason.key) }

        let instruction = buildInstruction(
            round: state.round,
            seedTarget: seedTarget,
            tierDeficits: tierDeficits,
            failed: failed,
            artistsAtCap: artistsAtCap,
            deficit: deficit,
            producedNoSeeds: state.newSeedsThisRound == 0
        )

        let outcomeJSON = buildOutcomeJSON(
            resolved: state.resolvedThisRound,
            accepted: composed.tracks.count,
            tierDeficits: tierDeficits,
            failed: failed,
            rejected: rejected,
            artistsAtCap: artistsAtCap,
            alreadyAccepted: accepted
        )

        return RoundDelta(
            seedTarget: seedTarget,
            tierDeficits: tierDeficits,
            failedSeeds: failed,
            artistsAtCap: artistsAtCap,
            alreadyAccepted: Array(accepted),
            instruction: instruction,
            outcomeJSON: outcomeJSON
        )
    }

    private static func buildInstruction(
        round: Int,
        seedTarget: Int,
        tierDeficits: [DiscoveryTier: Int],
        failed: [FailedSeed],
        artistsAtCap: [String],
        deficit: Int,
        producedNoSeeds: Bool
    ) -> String {
        var lines: [String] = []

        if producedNoSeeds {
            lines.append("上一轮你没有返回任何 seed（return_seeds 的 seeds 数组是空的）。请这次务必按要求给出线索。")
        }

        let shortfall = DiscoveryTier.allCases
            .filter { (tierDeficits[$0] ?? 0) > 0 }
            .map { "\($0.displayName) \((tierDeficits[$0] ?? 0)) 首" }
            .joined(separator: "、")

        lines.append("第 \(round) 轮补位：还差 \(deficit) 首\(shortfall.isEmpty ? "" : "（\(shortfall)）")。请再给 \(seedTarget) 个 seed，全部聚焦缺口。")

        if !artistsAtCap.isEmpty {
            lines.append("以下艺人已达单份歌单 2 首上限，不要再提：\(artistsAtCap.joined(separator: "、"))。")
        }

        if !failed.isEmpty {
            lines.append("以下线索在国区曲库里没能找到，请换别的方向，不要重复：")
            for seed in failed {
                let label = seed.title ?? seed.album ?? ""
                lines.append("  - \(seed.artist)\(label.isEmpty ? "" : "《\(label)》")")
            }
        }

        lines.append("不要重复已经在歌单里的曲目。")

        return lines.joined(separator: "\n")
    }

    private static func buildOutcomeJSON(
        resolved: Int,
        accepted: Int,
        tierDeficits: [DiscoveryTier: Int],
        failed: [FailedSeed],
        rejected: [RejectedSummary],
        artistsAtCap: [String],
        alreadyAccepted: [String]
    ) -> String {
        let payload: [String: Any] = [
            "resolved": resolved,
            "accepted": accepted,
            "need": Dictionary(
                uniqueKeysWithValues: DiscoveryTier.allCases.map { ($0.rawValue, tierDeficits[$0] ?? 0) }
            ),
            "failed": failed.map { seed -> [String: Any] in
                var dict: [String: Any] = ["artist": seed.artist, "why": seed.reason]
                if let title = seed.title { dict["title"] = title }
                if let album = seed.album { dict["album"] = album }
                return dict
            },
            "rejected": rejected.map { ["title": $0.title, "artist": $0.artist, "why": $0.reason] },
            "artists_at_cap": artistsAtCap,
            "already_accepted": alreadyAccepted,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
