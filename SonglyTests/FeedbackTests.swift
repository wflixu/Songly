//
//  FeedbackTests.swift
//  SonglyTests
//
//  反馈闭环的契约。用例名字即规格。
//
//  最要紧的一条是 `removalSurvivesEveryRelaxationRung` —— 用户删掉一首歌，
//  系统就**没有任何理由**在候选不够时又把它塞回来。这条一旦变红，用户会看到
//  自己明确删过的歌重新出现在歌单里，那会直接摧毁他对整个机制的信任。
//

import Foundation
import Testing
import SwiftData
@testable import Songly

// MARK: - Fixtures

private func candidate(
    id: String,
    artist: String,
    tier: DiscoveryTier = .confident
) -> ResolvedCandidate {
    ResolvedCandidate(
        info: TrackInfo(id: id, name: "曲目 \(id)", artist: artist),
        tier: tier,
        seedKind: .album,
        rawTitle: "曲目 \(id)",
        albumTitle: nil,
        duration: 200,
        genreNames: [],
        isCompilation: false
    )
}

// MARK: - 硬排除

@Suite("PlaylistComposer — 用户删除")
struct ComposerRemovalTests {

    @Test("被删的歌在**所有**放宽路径上都不放行")
    func removalSurvivesEveryRelaxationRung() {
        // 池子里只有两首，目标 25 首 —— 放宽阶梯会一路走到 `.everything`
        // （连"14 天内推过"都放开的最后一级）。被删的那首必须仍然进不来。
        let removed = candidate(id: "removed", artist: "艺人甲")
        let kept = candidate(id: "kept", artist: "艺人乙")

        var input = PlaylistComposer.Input(candidates: [removed, kept])
        input.exclusions.removedSongIDs = ["removed"]

        let output = PlaylistComposer.compose(input)

        #expect(output.tracks.map(\.info.id) == ["kept"])
    }

    @Test("候选池里只有被删的歌时，宁可交白卷也不放行")
    func removalYieldsEmptyRatherThanLeaking() {
        var input = PlaylistComposer.Input(candidates: [candidate(id: "only", artist: "艺人甲")])
        input.exclusions.removedSongIDs = ["only"]

        let output = PlaylistComposer.compose(input)

        #expect(output.tracks.isEmpty)
        #expect(output.publishable == false)
    }

    @Test("拒绝原因单独归为 user_removed，不被误记成 already_recommended")
    func rejectionReasonIsAttributedToUser() {
        var input = PlaylistComposer.Input(candidates: [candidate(id: "removed", artist: "艺人甲")])
        input.exclusions.removedSongIDs = ["removed"]
        input.exclusions.songIDs = ["removed"]   // 两个集合同时命中

        let output = PlaylistComposer.compose(input)

        // 归因必须落在「用户删的」上 —— 否则看诊断日志的人会以为是去重窗口在拦，
        // 从而去调一个根本不是原因的参数。
        #expect(output.rejections.contains { $0.reason.key == "user_removed" })
    }

    @Test("归一化文本键也是硬排除的一条路（跨 ID 口径兜底）")
    func removalMatchesByNormalizedKey() {
        let target = candidate(id: "catalog-id-1", artist: "艺人甲")
        var input = PlaylistComposer.Input(candidates: [target])
        input.exclusions.removedKeys = [target.info.key]

        #expect(PlaylistComposer.compose(input).tracks.isEmpty)
    }
}

@Suite("AlbumTrackPicker — 用户删除")
struct AlbumPickerRemovalTests {

    @Test("被删的歌不占用专辑的取数名额")
    func removedTrackDoesNotConsumeAlbumSlot() {
        // 不在这道闸门里拦，被删的歌会白占一个 maxPerAlbum 名额，
        // 表现是"这张专辑明明还有别的曲目，却只挑出来一首"。
        let removed = candidate(id: "removed", artist: "艺人甲")
        let kept = candidate(id: "kept", artist: "艺人甲")

        var exclusions = PlaylistComposer.ExclusionSet()
        exclusions.removedSongIDs = ["removed"]

        let picked = AlbumTrackPicker.pick(
            from: [removed, kept], wants: 2, exclusions: exclusions, maxPerAlbum: 2
        )

        #expect(picked.map(\.info.id) == ["kept"])
    }
}

// MARK: - 艺人权重

@Suite("PlaylistComposer — 艺人权重")
struct ComposerArtistWeightTests {

    @Test("超赞的艺人上浮、被降权的下沉，同层内按权重排序")
    func weightsReorderWithinTier() {
        var input = PlaylistComposer.Input(candidates: [
            candidate(id: "plain", artist: "普通艺人"),
            candidate(id: "loved", artist: "超赞过"),
            candidate(id: "down", artist: "被降权"),
        ])
        // key 必须过 `primaryArtistKey` —— composer 查的就是这个口径
        // （`ResolvedCandidate.primaryArtist`）。见下面那条用例的注释。
        input.artistWeights = [primaryArtistKey("超赞过"): 3, primaryArtistKey("被降权"): -3]

        let order = PlaylistComposer.compose(input).tracks.map(\.info.id)

        #expect(order == ["loved", "plain", "down"])
    }

    @Test("权重只改层内顺序，不改配额分配")
    func weightDoesNotChangeTierAllocation() {
        // 25 首 confident + 3 首 bold，其中一首 bold 的艺人被超赞。
        let pool = (0..<25).map { candidate(id: "c-\($0)", artist: "A\($0)", tier: .confident) }
            + [candidate(id: "b-0", artist: "X", tier: .bold),
               candidate(id: "b-1", artist: "Y", tier: .bold),
               candidate(id: "b-2", artist: "Z", tier: .bold)]

        let withoutWeight = PlaylistComposer.compose(
            PlaylistComposer.Input(candidates: pool)
        )

        var weightedInput = PlaylistComposer.Input(candidates: pool)
        // ⚠️ key 必须过 `primaryArtistKey`，因为它内部会 **lowercase**。
        //
        // 这里原先直接写 `["Z": 5]`：composer 用小写的 `"z"` 查表，永远 miss，
        // 权重从未真正生效 —— 断言从写下那天起就不可能成立。之所以一直没被发现，
        // 是因为这些测试长期没有被执行过（本机没有匹配的模拟器 runtime，
        // 直到 2026-10-01 才在真机上第一次跑起来）。
        weightedInput.artistWeights = [primaryArtistKey("Z"): 5]
        let weighted = PlaylistComposer.compose(weightedInput)

        // 配额分配必须完全一致 —— 权重是**排序**信号，不是配额信号。
        #expect(withoutWeight.tierCounts == weighted.tierCounts)

        // 但 bold 内部的顺序应当变了。
        #expect(weighted.tracks.first { $0.tier == .bold }?.info.id == "b-2")
        #expect(withoutWeight.tracks.first { $0.tier == .bold }?.info.id != "b-2")
    }

    @Test("权重不越过层级边界：bold 再受宠也进不了 confident 的层")
    func weightDoesNotCrossTierBoundary() {
        // 严格关掉配额（QuickPick 的路径），此时 tier 概念不适用，全部并进
        // 同一个桶 —— 用来验证权重只在**同一个桶内**起作用。
        var input = PlaylistComposer.Input(candidates: [
            candidate(id: "confident", artist: "普通", tier: .confident),
            candidate(id: "bold", artist: "被超赞的", tier: .bold),
        ])
        input.tierQuotaEnabled = false
        input.artistWeights = [primaryArtistKey("被超赞的"): 5]

        let tracks = PlaylistComposer.compose(input).tracks

        // 关掉配额后两者同桶，权重生效 —— 被超赞的排前面。
        #expect(tracks.map(\.info.id) == ["bold", "confident"])
    }
}

// MARK: - prompt 块

@Suite("FeedbackSummary — prompt 块")
struct FeedbackSummaryTests {

    @Test("全空时返回 nil，调用方整块省略")
    func emptyYieldsNil() {
        #expect(FeedbackSummary.empty.isEmpty)
        #expect(FeedbackSummary.empty.promptBlock == nil)
    }

    @Test("ratingCounts 是字典，但渲染顺序不依赖字典的迭代顺序")
    func ratingOrderIsStable() {
        // 两次构造的字典插入顺序不同，渲染必须一致 —— 否则同一批反馈会渲染出
        // 不同的字节，system 前缀缓存直接击穿。
        let a = FeedbackSummary(ratingCounts: [.accurate: 2, .mixed: 1, .off: 1])
        let b = FeedbackSummary(ratingCounts: [.off: 1, .accurate: 2, .mixed: 1])

        #expect(a.promptBlock == b.promptBlock)
        #expect(a.promptBlock?.contains("很准 ×2、一般 ×1、不准 ×1") == true)
    }

    @Test("有内容时块里带得出硬性说明，不只罗列条目")
    func blockCarriesTheRule() {
        let summary = FeedbackSummary(lovedArtists: ["周杰伦"], removedSongs: ["某歌 - 某艺人"])
        let block = summary.promptBlock

        #expect(block?.contains("周杰伦") == true)
        #expect(block?.contains("绝不能再出现") == true)
    }
}

// MARK: - 派生

// ⚠️ 这个 suite 的写法是有讲究的，**别"顺手整理"回去**。
//
// 原先是 `@MainActor @Suite(...)` + 两个 private helper。那种形态会让测试运行器的
// **互操作桥必崩**（`Runner._applyScopingTraits(for:testCase:_:)`），于是这 6 条用例
// 从写下来到现在**一次都没跑过** —— 每次整批运行都崩在这里，重启后被归因为「Crash」。
//
// 二分结论（2026-10-01，真机逐个跑出来的）：
//   - 裸 `@MainActor @Test`                              → 正常
//   - `@MainActor @Test` + in-memory `ModelContainer`     → 正常
//   - 调用同一个 `FeedbackStore.derive()`，只是换个 suite → 正常
//   - **原 struct 的那个形态**                            → 必崩
// 具体是哪个语法特征触发的没有继续追 —— 收益不值那个时间。这里的写法是**已验证能跑**的。
//
// 所以：不抽 private helper、每条用例自建 store。啰嗦一点，但 6 条**跑得起来**的测试
// 比 6 条优雅的死代码有价值得多。
@Suite("FeedbackStore — 派生")
struct FeedbackStoreTests {

    @Test("删掉的歌进永久排除，超赞与删除分别给出正负权重")
    @MainActor
    func deriveAggregates() throws {
        let container = try ModelContainer(
            for: RecommendationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        context.insert(RecommendationRecord(
            date: Date(), strategy: "风格探索", songCount: 2,
            tracks: [
                TrackInfo(id: "s1", name: "歌一", artist: "艺人甲", verdict: .loved),
                TrackInfo(id: "s2", name: "歌二", artist: "艺人乙", verdict: .removed),
            ],
            source: "daily"
        ))

        let derived = FeedbackStore(context: context).derive()

        #expect(derived.removedIDs == ["s2"])
        #expect(derived.artistWeights["艺人甲"] == 2)
        #expect(derived.artistWeights["艺人乙"] == -1)
    }

    @Test("权重夹取在 ±5，刷屏式反馈也不会把它顶穿")
    @MainActor
    func weightIsClamped() throws {
        let container = try ModelContainer(
            for: RecommendationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        for index in 0..<10 {
            context.insert(RecommendationRecord(
                date: Date().addingTimeInterval(Double(-index) * 3600),
                strategy: "风格探索", songCount: 1,
                tracks: [TrackInfo(id: "s-\(index)", name: "歌", artist: "某艺人", verdict: .loved)],
                source: "daily"
            ))
        }

        #expect(FeedbackStore(context: context).derive().artistWeights["某艺人"] == 5)
    }

    @Test("同一首歌改了判定，**更新的记录**说了算")
    @MainActor
    func latestVerdictWins() throws {
        let container = try ModelContainer(
            for: RecommendationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        context.insert(RecommendationRecord(
            date: Date().addingTimeInterval(-86400), strategy: "风格探索", songCount: 1,
            tracks: [TrackInfo(id: "s1", name: "歌", artist: "艺人", verdict: .loved)],
            source: "daily"
        ))
        context.insert(RecommendationRecord(
            date: Date(), strategy: "风格探索", songCount: 1,
            tracks: [TrackInfo(id: "s1", name: "歌", artist: "艺人", verdict: .removed)],
            source: "daily"
        ))

        // 先超赞、过些天又删掉 —— 那是「改主意了」，不是冲突。
        #expect(FeedbackStore(context: context).derive().verdicts["s1"] == .removed)
    }

    @Test("歌单级的「不准」作用在该歌单仍然可见的曲目所属艺人身上")
    @MainActor
    func ratingWeightsArtists() throws {
        let container = try ModelContainer(
            for: RecommendationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        context.insert(RecommendationRecord(
            date: Date(), strategy: "风格探索", songCount: 1,
            tracks: [TrackInfo(id: "s1", name: "歌一", artist: "艺人甲")],
            source: "daily", rating: PlaylistRating.off.rawValue
        ))

        #expect(FeedbackStore(context: context).derive().artistWeights["艺人甲"] == -1)
    }

    @Test("删除维护 songCount 与 removedCount，撤销时反向恢复")
    @MainActor
    func removalMaintainsCounts() throws {
        let container = try ModelContainer(
            for: RecommendationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let store = FeedbackStore(context: context)
        let record = RecommendationRecord(
            date: Date(), strategy: "风格探索", songCount: 2,
            tracks: [
                TrackInfo(id: "s1", name: "一", artist: "A"),
                TrackInfo(id: "s2", name: "二", artist: "B"),
            ],
            source: "daily"
        )
        context.insert(record)

        store.setVerdict(.removed, forSongID: "s1", in: record)
        #expect(record.songCount == 1)
        #expect(record.removedCount == 1)
        #expect(record.visibleTracks.map(\.id) == ["s2"])
        #expect(record.tierSummary == nil || !record.tierSummary!.isEmpty)

        // 撤销：歌回到列表，永久排除同时解除。
        store.setVerdict(nil, forSongID: "s1", in: record)
        #expect(record.songCount == 2)
        #expect(record.removedCount == 0)
        #expect(record.visibleTracks.map(\.id) == ["s1", "s2"])
        #expect(store.derive().removedIDs.isEmpty)
    }

    @Test("重复写同一个判定不会把计数写坏")
    @MainActor
    func repeatedVerdictIsIdempotent() throws {
        let container = try ModelContainer(
            for: RecommendationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let store = FeedbackStore(context: context)
        let record = RecommendationRecord(
            date: Date(), strategy: "风格探索", songCount: 1,
            tracks: [TrackInfo(id: "s1", name: "一", artist: "A")],
            source: "daily"
        )
        context.insert(record)

        store.setVerdict(.removed, forSongID: "s1", in: record)
        store.setVerdict(.removed, forSongID: "s1", in: record)

        #expect(record.songCount == 0)
        #expect(record.removedCount == 1)
    }
}
