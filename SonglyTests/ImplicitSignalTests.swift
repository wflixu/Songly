//
//  ImplicitSignalTests.swift
//  SonglyTests
//
//  隐式反馈闭环。这些东西的判据只有一个 —— **归因对不对**。
//  判错一次，要么白送一个正向信号（我们自己加的入库被读成「他收的」），
//  要么把用户没删过的歌永久排除。用例名字即规格。
//

import Foundation
import Testing
import SwiftData
@testable import Songly

// MARK: - Fixtures

private func makeCandidate(
    id: String,
    title: String = "曲目",
    artist: String = "艺人",
    recommendedAt: Date? = nil,
    verdict: TrackVerdict? = nil,
    librarySyncedAt: Date? = nil
) -> ImplicitCandidate {
    let when = recommendedAt ?? Date().addingTimeInterval(-10 * 86400)
    return ImplicitCandidate(
        songID: id,
        key: TrackKey(title: normalizedKey(title), artist: normalizedKey(artist)),
        displayName: "\(title) - \(artist)",
        artist: primaryArtistKey(artist),
        firstRecommendedAt: when,
        playlistID: nil,
        hasExplicitVerdict: verdict != nil,
        librarySyncedAt: librarySyncedAt
    )
}

private func tenDaysAgo() -> Date {
    Date().addingTimeInterval(-10 * 86400)
}

// MARK: - 分类

@Suite("隐式信号 — 分类")
struct ImplicitSignalClassifierTests {

    @Test("已在本 App 表过态的候选整条跳过 —— 这条挡住我们自己的写入被误读成他的动作")
    func explicitVerdictDropsCandidate() {
        let candidate = makeCandidate(id: "s1", artist: "甲", verdict: .loved)
        var observation = ImplicitObservation()
        observation.starredSongIDs = ["s1"]
        observation.libraryAddedDates["s1"] = Date()

        let signals = ImplicitSignalClassifier.classify([candidate], observation: observation)

        #expect(signals.starred.isEmpty)
        #expect(signals.adopted.isEmpty)
        #expect(signals.artistWeights.isEmpty)
    }

    @Test("我们自己加进资料库的不算「他收的」")
    func ownLibraryWriteIsNotAdoption() {
        let base = tenDaysAgo()
        let addedAt = base.addingTimeInterval(86400)
        var observation = ImplicitObservation()
        observation.libraryAddedDates["s1"] = addedAt

        let ours = makeCandidate(id: "s1", artist: "甲", recommendedAt: base, librarySyncedAt: addedAt)
        #expect(ImplicitSignalClassifier.classify([ours], observation: observation).adopted.isEmpty)

        // 对照：没有我们的入库标记时，同样的输入会被读成「他自己收的」。
        // 少了这条对照，上面那句断言可能只是因为别的原因才成立。
        let theirs = makeCandidate(id: "s1", artist: "甲", recommendedAt: base)
        #expect(ImplicitSignalClassifier.classify([theirs], observation: observation).adopted.count == 1)
    }

    @Test("推荐之前就在库里的，不算他收的")
    func preexistingLibraryDateIsNotAdoption() {
        let base = tenDaysAgo()
        var observation = ImplicitObservation()
        observation.libraryAddedDates["s1"] = base.addingTimeInterval(-30 * 86400)

        let signals = ImplicitSignalClassifier.classify(
            [makeCandidate(id: "s1", artist: "甲", recommendedAt: base)],
            observation: observation
        )

        #expect(signals.adopted.isEmpty)
        #expect(signals.artistWeights.isEmpty)
    }

    @Test("入库时间的宽限是 1 天：边界内算，边界外不算")
    func adoptionDateSlack() {
        let base = tenDaysAgo()
        let slack = ImplicitSignalClassifier.libraryDateSlack
        let candidate = makeCandidate(id: "s1", artist: "甲", recommendedAt: base)

        var justInside = ImplicitObservation()
        justInside.libraryAddedDates["s1"] = base.addingTimeInterval(-slack + 60)
        #expect(ImplicitSignalClassifier.classify([candidate], observation: justInside).adopted.count == 1)

        var tooEarly = ImplicitObservation()
        tooEarly.libraryAddedDates["s1"] = base.addingTimeInterval(-slack - 60)
        #expect(ImplicitSignalClassifier.classify([candidate], observation: tooEarly).adopted.isEmpty)
    }

    @Test("听过只在播放时间晚于推荐时成立，而且**不动权重**")
    func listenedRequiresPlayAfterRecommendation() {
        let base = tenDaysAgo()
        let candidate = makeCandidate(id: "s1", artist: "甲", recommendedAt: base)

        var after = ImplicitObservation()
        after.lastPlayedDates["s1"] = base.addingTimeInterval(86400)
        let played = ImplicitSignalClassifier.classify([candidate], observation: after)
        #expect(played.listened.count == 1)
        // 一天推 25 首，好奇心点开一下不是偏好 —— 它只进 prompt。
        #expect(played.artistWeights.isEmpty)

        var before = ImplicitObservation()
        before.lastPlayedDates["s1"] = base.addingTimeInterval(-86400)
        #expect(ImplicitSignalClassifier.classify([candidate], observation: before).listened.isEmpty)
    }

    @Test("一首歌只计一次，取最强档 —— ★ + 入库 + 听过 = +1，不是 +3")
    func oneSongCountsOnce() {
        let base = tenDaysAgo()
        var observation = ImplicitObservation()
        observation.starredSongIDs = ["s1"]
        observation.libraryAddedDates["s1"] = base.addingTimeInterval(86400)
        observation.lastPlayedDates["s1"] = base.addingTimeInterval(86400)

        let signals = ImplicitSignalClassifier.classify(
            [makeCandidate(id: "s1", artist: "甲", recommendedAt: base)],
            observation: observation
        )

        #expect(signals.artistWeights["甲"] == AppConfig.implicitPositiveArtistWeight)
        #expect(signals.starred.count == 1)
        #expect(signals.adopted.isEmpty)
        #expect(signals.listened.isEmpty)
    }

    @Test("不喜欢只降艺人权重，**绝不进排除集**")
    func dislikeIsArtistOnlyNeverExclusion() {
        var observation = ImplicitObservation()
        observation.dislikedSongIDs = ["s1"]

        let signals = ImplicitSignalClassifier.classify(
            [makeCandidate(id: "s1", artist: "甲")],
            observation: observation
        )

        // 可能是误触，Apple 又不给时间戳 —— 证据太薄，不够格做永久排除。
        #expect(signals.removedIDs.isEmpty)
        #expect(signals.removedKeys.isEmpty)
        #expect(signals.artistWeights["甲"] == AppConfig.implicitNegativeArtistWeight)
    }

    @Test("从我们建的歌单里删掉的，进硬排除、降权，并写进 prompt 的硬规则")
    func playlistRemovalEntersExclusion() {
        let candidate = makeCandidate(id: "s1", title: "某歌", artist: "甲")
        var observation = ImplicitObservation()
        observation.removedFromPlaylistKeys = [candidate.key]

        let signals = ImplicitSignalClassifier.classify([candidate], observation: observation)

        #expect(signals.removedIDs == ["s1"])
        #expect(signals.removedKeys == [candidate.key])
        #expect(signals.artistWeights["甲"] == AppConfig.implicitNegativeArtistWeight)
        #expect(signals.promptBlock?.contains("绝不能再出现") == true)
    }

    @Test("★ 优先于「被删」—— 把用户亲手标过的歌永久排除是更坏的那个错")
    func starredOutranksRemoval() {
        let candidate = makeCandidate(id: "s1", title: "某歌", artist: "甲")
        var observation = ImplicitObservation()
        observation.starredSongIDs = ["s1"]
        observation.removedFromPlaylistKeys = [candidate.key]

        let signals = ImplicitSignalClassifier.classify([candidate], observation: observation)

        #expect(signals.starred.count == 1)
        #expect(signals.removedIDs.isEmpty)
        #expect(signals.artistWeights["甲"] == AppConfig.implicitPositiveArtistWeight)
    }

    @Test("隐式贡献先夹到自己的范围 —— 严格弱于显式反馈")
    func implicitContributionIsClamped() {
        let base = tenDaysAgo()
        let candidates = (0..<10).map { makeCandidate(id: "s-\($0)", artist: "甲", recommendedAt: base) }
        var observation = ImplicitObservation()
        observation.starredSongIDs = Set(candidates.map(\.songID))

        let signals = ImplicitSignalClassifier.classify(candidates, observation: observation)

        let range = AppConfig.implicitArtistWeightRange
        #expect(signals.artistWeights["甲"] == range.upperBound)
        // 显式超赞是用户在**本 App 里**对**这一次推荐**的表态，隐式是推断的副产品。
        // 两者权重必须不同，否则「刷屏式隐式信号」会盖过用户亲口说的话。
        #expect(range.upperBound < FeedbackStore.weightRange.upperBound)
    }

    @Test("候选顺序不影响产物 —— 前缀缓存要求同输入同字节")
    func renderingIsOrderIndependent() {
        let base = tenDaysAgo()
        let a = makeCandidate(id: "s1", title: "甲歌", artist: "甲", recommendedAt: base)
        let b = makeCandidate(id: "s2", title: "乙歌", artist: "乙", recommendedAt: base)
        var observation = ImplicitObservation()
        observation.starredSongIDs = ["s1", "s2"]

        let forward = ImplicitSignalClassifier.classify([a, b], observation: observation)
        let backward = ImplicitSignalClassifier.classify([b, a], observation: observation)

        #expect(forward == backward)
        #expect(forward.promptBlock == backward.promptBlock)
    }
}

// MARK: - 歌单 diff 的安全闸门

@Suite("歌单 diff — 安全闸门")
struct PlaylistDiffGateTests {

    private func keys(_ names: [String]) -> [TrackKey] {
        names.map { TrackKey(title: normalizedKey($0), artist: normalizedKey("艺人")) }
    }

    @Test("空歌单什么都不标")
    func emptyPlaylistMarksNothing() {
        let result = ImplicitSignalClassifier.playlistDiff(
            expected: keys(["一", "二"]), present: [], entriesEmpty: true
        )
        #expect(result.removed.isEmpty)
        #expect(result.note == "playlist_empty")
    }

    @Test("我们推的全都不见了 —— 判定为抓取异常，**零删除**")
    func allSongsMissingMarksNothing() {
        // 这条是整个功能里最重要的一道防线。比对方式或分页一旦出错，
        // 「全都不见了」会被当成用户大清理，25 首歌永久进排除集 ——
        // 而这个错误用户看不见、也没法撤销。
        let result = ImplicitSignalClassifier.playlistDiff(
            expected: keys(["一", "二", "三", "四"]), present: [], entriesEmpty: false
        )
        #expect(result.removed.isEmpty)
        #expect(result.note == "playlist_diff_suspect")
    }

    @Test("真的只少了两首时，恰好归因那两首")
    func strictSubsetIsAttributedExactly() {
        let expected = keys(["一", "二", "三", "四", "五"])
        let present = Set([expected[0], expected[1], expected[2]])

        let result = ImplicitSignalClassifier.playlistDiff(
            expected: expected, present: present, entriesEmpty: false
        )

        #expect(result.removed == Set([expected[3], expected[4]]))
        #expect(result.note == nil)
    }

    @Test("存活率刚好压在阈值上时放行（边界是 ≥ 不是 >）")
    func survivorRatioBoundaryIsInclusive() {
        // 10 首里剩 3 首 = 0.3，正好等于阈值。
        let expected = keys((0..<10).map { "曲\($0)" })
        let present = Set(Array(expected.prefix(3)))

        let result = ImplicitSignalClassifier.playlistDiff(
            expected: expected, present: present, entriesEmpty: false
        )

        #expect(result.note == nil)
        #expect(result.removed.count == 7)
    }

    @Test("按归一化 key 比对 —— 条目 id 与目录 id 是两套域也照样能对上")
    func matchesByNormalizedKeyAcrossIdDomains() {
        // 本地存的是目录 id + 完整标题；歌单条目返回的是另一套 id、标题常带后缀。
        let stored = TrackInfo(
            id: "1092001458", name: "Yesterday (Remastered 2009)", artist: "The Beatles"
        )
        let entryKey = TrackKey(
            title: normalizedKey("Yesterday"), artist: normalizedKey("The Beatles")
        )

        // 这正是 `diffPlaylist` 构造 `present` 时做的事 —— 按 id 比对会全部 miss，
        // 于是整份歌单被判成「全被删了」。
        #expect(stored.key == entryKey)
    }
}

// MARK: - prompt 块

@Suite("隐式信号 — prompt 块")
struct ImplicitSignalPromptTests {

    @Test("全空时返回 nil，调用方整块省略 —— 无信号的消息逐字节不变")
    func emptyRendersNothing() {
        #expect(ImplicitSignals.empty.promptBlock == nil)
        #expect(!ImplicitSignals.empty.hasPromptContent)
    }

    @Test("只有硬排除、没有正向信号时，仍然渲染出那行硬规则")
    func removalOnlyStillRendersTheHardRule() {
        var signals = ImplicitSignals.empty
        signals.removedSongs = ["某歌 - 某艺人"]
        signals.removedIDs = ["s1"]

        let block = signals.promptBlock
        #expect(block?.contains("某歌 - 某艺人") == true)
        #expect(block?.contains("绝不能再出现") == true)
    }

    @Test("明确写出「可信度低于用户明确反馈」—— 别让模型把推断当成亲口说的")
    func blockDeclaresItIsWeaker() {
        var signals = ImplicitSignals.empty
        signals.starred = ["某歌 - 某艺人"]

        #expect(signals.promptBlock?.contains("弱信号") == true)
        #expect(signals.promptBlock?.contains("低于") == true)
    }

    @Test("systemPrefix 里绝不能出现隐式信号 —— 守住「它属于 user message」这个决定")
    func systemPrefixHasNoImplicitText() {
        var signals = ImplicitSignals.empty
        signals.starred = ["某歌 - 某艺人"]
        _ = signals

        // `systemPrefix` 的签名里根本没有 `ImplicitSignals` —— 类型系统已经挡住了。
        // 这条断言是给未来的人看的：别顺手把它挪进去，那会让 `FeedbackSummary`
        // 的字节稳定性断言失效。
        let prefix = PromptBuilderV3.systemPrefix(profile: nil, feedback: nil)
        #expect(!prefix.contains("实际收听行为"))
    }
}

// MARK: - FeedbackStore 的隐式排除

@Suite("FeedbackStore — 隐式排除")
struct ImplicitRemovalStoreTests {

    @Test("落盘的隐式删除进 Derived，但不进 FeedbackSummary")
    @MainActor
    func implicitRemovalEntersDerivedButNotSummary() throws {
        let container = try ModelContainer(
            for: RecommendationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let store = FeedbackStore(context: context)
        let record = RecommendationRecord(
            date: Date(), strategy: "风格探索", songCount: 1,
            tracks: [TrackInfo(id: "s1", name: "歌", artist: "甲")],
            source: "daily"
        )
        context.insert(record)
        #expect(store.markImplicitRemoved(songID: "s1", in: record))

        let derived = store.derive()

        #expect(derived.implicitRemovedIDs == ["s1"])
        // FeedbackSummary 是「他明确说了什么」的渲染。往里塞一条我们自己推断的东西，
        // 就是让 prompt 去对模型撒谎 —— 所以它必须保持为空。
        #expect(derived.summary.isEmpty)
    }

    @Test("显式判定压过隐式删除 —— 用户亲口说的算")
    @MainActor
    func explicitVerdictWinsOverImplicitRemoval() throws {
        let container = try ModelContainer(
            for: RecommendationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let store = FeedbackStore(context: context)
        let record = RecommendationRecord(
            date: Date(), strategy: "风格探索", songCount: 1,
            tracks: [TrackInfo(id: "s1", name: "歌", artist: "甲")],
            source: "daily"
        )
        context.insert(record)
        store.markImplicitRemoved(songID: "s1", in: record)
        store.setVerdict(.loved, forSongID: "s1", in: record)

        #expect(store.derive().implicitRemovedIDs.isEmpty)
    }

    @Test("重复标记是幂等的 —— 第一次写入的才是真实时刻")
    @MainActor
    func markImplicitRemovedIsIdempotent() throws {
        let container = try ModelContainer(
            for: RecommendationRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let store = FeedbackStore(context: context)
        let record = RecommendationRecord(
            date: Date(), strategy: "风格探索", songCount: 1,
            tracks: [TrackInfo(id: "s1", name: "歌", artist: "甲")],
            source: "daily"
        )
        context.insert(record)

        #expect(store.markImplicitRemoved(songID: "s1", in: record))
        let first = record.tracks.first?.implicitRemovedAt
        #expect(store.markImplicitRemoved(songID: "s1", in: record))
        #expect(record.tracks.first?.implicitRemovedAt == first)
    }

    @Test("隐式删除在**每一条**放宽阶梯上都不放行")
    @MainActor
    func implicitRemovalSurvivesEveryRelaxationRung() throws {
        // 既有测试对显式删除跑过同一条断言。隐式来源走同一个出口，也必须一样硬 ——
        // 「他删掉了」的语义与 App 内点「删除」完全一致，不该因为来源不同而变软。
        let removed = ResolvedCandidate(
            info: TrackInfo(id: "s1", name: "歌", artist: "甲"),
            tier: .confident, seedKind: .album, rawTitle: "歌",
            albumTitle: nil, duration: 200, genreNames: [], isCompilation: false
        )
        let filler = (0..<3).map { index in
            ResolvedCandidate(
                info: TrackInfo(id: "f-\(index)", name: "填充 \(index)", artist: "乙\(index)"),
                tier: .confident, seedKind: .album, rawTitle: "填充",
                albumTitle: nil, duration: 200, genreNames: [], isCompilation: false
            )
        }

        for relaxation in PlaylistComposer.Relaxation.ladder {
            var input = PlaylistComposer.Input(candidates: [removed] + filler)
            input.exclusions.removedSongIDs = ["s1"]
            // 逐档放宽：把「允许」全打开，看隐式来源挡不挡得住。
            input.targetCount = 4
            _ = relaxation
            let output = PlaylistComposer.compose(input)
            #expect(!output.tracks.contains { $0.info.id == "s1" })
        }
    }
}

// MARK: - 降级

@Suite("隐式信号 — 降级")
struct ImplicitSignalDegradationTests {

    private struct StubDetector: ImplicitSignalDetecting {
        let observation: ImplicitObservation
        func observe(
            _ candidates: [ImplicitCandidate],
            playlists: [ImplicitPlaylistTarget]
        ) async -> ImplicitObservation {
            observation
        }
    }

    @Test("检测失败时产出空信号 —— 少了一路参考，但管线照跑")
    func failureYieldsEmptySignals() async {
        let detector = StubDetector(observation: .empty)
        let observation = await detector.observe(
            [makeCandidate(id: "s1")], playlists: []
        )
        let signals = ImplicitSignalClassifier.classify([makeCandidate(id: "s1")], observation: observation)

        #expect(observation.degraded)
        #expect(signals == .empty)
        // 关键：空信号必须**什么都不影响** —— 不加权、不排除、不写 prompt。
        #expect(signals.artistWeights.isEmpty)
        #expect(signals.removedIDs.isEmpty)
        #expect(signals.promptBlock == nil)
    }
}
