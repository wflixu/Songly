//
//  PipelineTests.swift
//  SonglyTests
//
//  补位轮状态机。它是唯一决定「什么时候停」的地方 —— 判错一次，
//  要么白烧三轮的时间和钱，要么在差 3 首的时候提前收工。
//

import Foundation
import Testing
@testable import Songly

// MARK: - Fixtures

private func composed(
    count: Int,
    tierCounts: [DiscoveryTier: Int] = [:],
    rejections: [PlaylistComposer.Rejection] = []
) -> PlaylistComposer.Output {
    let tracks = (0..<count).map { index in
        ResolvedCandidate(
            info: TrackInfo(id: "id-\(index)", name: "曲目 \(index)", artist: "艺人 \(index)"),
            tier: .confident,
            seedKind: .album,
            rawTitle: "曲目 \(index)"
        )
    }
    return PlaylistComposer.Output(
        tracks: tracks,
        rejections: rejections,
        tierCounts: tierCounts.isEmpty ? [.confident: count] : tierCounts,
        deficit: max(0, AppConfig.minAcceptableTrackCount - count),
        publishable: count >= AppConfig.publishableTrackCount
    )
}

private func state(
    round: Int = 1,
    composed output: PlaylistComposer.Output,
    resolvedThisRound: Int = 10,
    newSeedsThisRound: Int = 45,
    failed: [FailedSeed] = [],
    artistsAtCap: [String] = [],
    elapsed: TimeInterval = 10,
    isCancelled: Bool = false
) -> RoundState {
    RoundState(
        round: round,
        composed: output,
        resolvedThisRound: resolvedThisRound,
        newSeedsThisRound: newSeedsThisRound,
        failedSeeds: failed,
        artistsAtCap: artistsAtCap,
        elapsed: elapsed,
        isCancelled: isCancelled
    )
}

// MARK: - Stop Conditions

@Suite("GapRoundPlanner — 停止条件")
struct GapRoundPlannerStopTests {

    @Test("凑够目标就收工")
    func stopsWhenTargetReached() {
        let decision = GapRoundPlanner.decide(state(composed: composed(count: 25)))
        #expect(decision == .stop(.targetReached))
    }

    @Test("达到轮次上限就停")
    func stopsAtMaxRounds() {
        let decision = GapRoundPlanner.decide(
            state(round: AppConfig.maxGapRounds, composed: composed(count: 10))
        )
        #expect(decision == .stop(.maxRounds))
    }

    @Test("超过时间预算就停")
    func stopsAtDeadline() {
        let decision = GapRoundPlanner.decide(
            state(round: 2, composed: composed(count: 10), elapsed: AppConfig.pipelineDeadline + 1)
        )
        #expect(decision == .stop(.deadline))
    }

    @Test("上一轮零新增就停 —— 防止反复重提同样解析不出来的歌名")
    func stopsOnNoProgress() {
        let decision = GapRoundPlanner.decide(
            state(round: 2, composed: composed(count: 10), resolvedThisRound: 0)
        )
        #expect(decision == .stop(.noProgress))
    }

    @Test("第 1 轮全军覆没不算 noProgress，要带失败清单再试一次")
    func firstRoundAllFailuresStillContinues() {
        // 第 1 轮所有 seed 都没解析出来，是"方向不对"而不是"没救了"——
        // 应该把失败清单回传给它换方向。
        let decision = GapRoundPlanner.decide(
            state(round: 1, composed: composed(count: 0), resolvedThisRound: 0)
        )
        guard case .continueWith = decision else {
            Issue.record("第 1 轮零解析也应该继续，实际是 \(decision)")
            return
        }
    }

    @Test("补位轮里模型不再给新线索就停")
    func stopsWhenPoolExhausted() {
        let decision = GapRoundPlanner.decide(
            state(round: 2, composed: composed(count: 10), newSeedsThisRound: 0)
        )
        #expect(decision == .stop(.poolExhausted))
    }

    @Test("第 1 轮模型返回空不判死，再要一次")
    func firstRoundEmptyResponseIsRetried() {
        // 真机实测踩过：单次空响应（模型没给 seed、或工具调用形状对不上）
        // 直接判死会让整条管线白跑一趟。给一次重说的机会。
        let decision = GapRoundPlanner.decide(
            state(round: 1, composed: composed(count: 0), newSeedsThisRound: 0)
        )
        guard case .continueWith(let delta) = decision else {
            Issue.record("第 1 轮空响应应该重试，实际是 \(decision)")
            return
        }
        // 差量指令要明确指出问题，否则模型不知道自己做错了什么。
        #expect(delta.instruction.contains("没有返回任何 seed"))
    }

    @Test("取消优先于一切")
    func cancellationWins() {
        // 后台任务的 expirationHandler 会调 cancel()，此时应该立刻收手，
        // 哪怕歌单已经凑够了。
        let decision = GapRoundPlanner.decide(
            state(composed: composed(count: 25), isCancelled: true)
        )
        #expect(decision == .stop(.cancelled))
    }

    @Test("判停优先级：取消 > 够数 > 轮次 > 超时 > 无进展")
    func stopPriorityOrder() {
        // 同时满足多个条件时，落在哪个上是确定的，不是随机的。
        #expect(GapRoundPlanner.decide(state(
            round: 9, composed: composed(count: 25), elapsed: 9999, isCancelled: true
        )) == .stop(.cancelled))

        #expect(GapRoundPlanner.decide(state(
            round: 9, composed: composed(count: 25), elapsed: 9999
        )) == .stop(.targetReached))

        #expect(GapRoundPlanner.decide(state(
            round: 9, composed: composed(count: 10), elapsed: 9999
        )) == .stop(.maxRounds))

        #expect(GapRoundPlanner.decide(state(
            round: 2, composed: composed(count: 10), resolvedThisRound: 0, elapsed: 9999
        )) == .stop(.deadline))
    }
}

// MARK: - Delta

@Suite("GapRoundPlanner — 缺口差量")
struct GapRoundPlannerDeltaTests {

    private func delta(
        composed output: PlaylistComposer.Output,
        failed: [FailedSeed] = [],
        artistsAtCap: [String] = []
    ) -> RoundDelta {
        let decision = GapRoundPlanner.decide(
            state(round: 1, composed: output, failed: failed, artistsAtCap: artistsAtCap)
        )
        guard case .continueWith(let delta) = decision else {
            Issue.record("应当是继续，实际是 \(decision)")
            return RoundDelta(
                seedTarget: 0, tierDeficits: [:], failedSeeds: [],
                artistsAtCap: [], alreadyAccepted: [], instruction: "", outcomeJSON: "{}"
            )
        }
        return delta
    }

    @Test("每层缺口按 70/20/10 计算")
    func carriesTierDeficits() {
        // 手上 10 首全在 confident。25 首的配额是 18/5/2。
        let result = delta(composed: composed(count: 10, tierCounts: [.confident: 10]))
        #expect(result.tierDeficits[.confident] == 8)
        #expect(result.tierDeficits[.fresh] == 5)
        #expect(result.tierDeficits[.bold] == 2)
    }

    @Test("缺口很小时也要够最少的 seed 数")
    func enforcesMinSeeds() {
        // 差 1 首也要 8 个 seed —— 因为解析、去重、歌手上限都会吃掉一批。
        let result = delta(composed: composed(count: 24))
        #expect(result.seedTarget == AppConfig.minSeedsPerGapRound)
    }

    @Test("缺口很大时 seed 数被上限截断")
    func enforcesMaxSeeds() {
        let result = delta(composed: composed(count: 0))
        #expect(result.seedTarget == AppConfig.maxSeedsPerGapRound)
    }

    @Test("已收下的曲目会回传，避免模型重提")
    func carriesAlreadyAccepted() {
        let result = delta(composed: composed(count: 10))
        #expect(result.alreadyAccepted.count == 10)
        #expect(result.alreadyAccepted.first?.contains("曲目 0") == true)
    }

    @Test("回传的失败清单与歌手上限清单都有条数上限")
    func reportListsAreCapped() {
        let manyFailed = (0..<50).map {
            FailedSeed(artist: "艺人\($0)", title: "曲\($0)", album: nil, reason: "catalog_miss")
        }
        let manyArtists = (0..<50).map { "艺人\($0)" }

        let result = delta(composed: composed(count: 10), failed: manyFailed, artistsAtCap: manyArtists)

        // 回传几百条只会把 prompt 撑爆，模型也消化不了。
        #expect(result.failedSeeds.count == 20)
        #expect(result.artistsAtCap.count == 12)
    }

    @Test("指令里包含缺口、歌手上限与失败方向")
    func instructionMentionsKeyFacts() {
        let result = delta(
            composed: composed(count: 10, tierCounts: [.confident: 10]),
            failed: [FailedSeed(artist: "查无此人", title: "某曲", album: nil, reason: "catalog_miss")],
            artistsAtCap: ["周杰伦"]
        )
        #expect(result.instruction.contains("周杰伦"))
        #expect(result.instruction.contains("查无此人"))
        #expect(result.instruction.contains("2 首上限"))
    }

    @Test("outcomeJSON 是合法 JSON，且缺口字段可读")
    func outcomeJSONIsValid() throws {
        let result = delta(composed: composed(count: 10, tierCounts: [.confident: 10]))

        let data = try #require(result.outcomeJSON.data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["accepted"] as? Int == 10)
        let need = json["need"] as? [String: Int]
        #expect(need?["confident"] == 8)
        #expect(need?["fresh"] == 5)
        #expect(need?["bold"] == 2)
    }

    @Test("回传的被拒曲目只包含「本来能进但被规则挡下」的")
    func rejectedSummariesOnlyIncludeActionableOnes() throws {
        // 内容类型不符的没必要回传 —— 模型也没法改。
        let rejections = [
            PlaylistComposer.Rejection(
                info: TrackInfo(id: "1", name: "伴奏曲", artist: "A"),
                reason: .contentType(.karaoke)
            ),
            PlaylistComposer.Rejection(
                info: TrackInfo(id: "2", name: "被上限挡下", artist: "B"),
                reason: .artistCapped
            ),
        ]
        let result = delta(composed: composed(count: 10, rejections: rejections))

        let data = try #require(result.outcomeJSON.data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rejected = json["rejected"] as? [[String: Any]]

        #expect(rejected?.count == 1)
        #expect(rejected?.first?["why"] as? String == "artist_capped")
    }
}
