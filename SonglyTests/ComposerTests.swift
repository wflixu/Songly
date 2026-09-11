//
//  ComposerTests.swift
//  SonglyTests
//
//  PlaylistComposer 是「数量稳定 20–25」与「同一歌手 ≤2 首」的根本保证。
//  这些用例名字即规格 —— 任何一条变红都意味着用户能感知到的回归。
//

import Foundation
import Testing
@testable import Songly

// MARK: - Fixtures

private func makeCandidate(
    id: String,
    title: String,
    artist: String,
    tier: DiscoveryTier = .confident,
    seedKind: SeedKind = .album,
    album: String? = nil,
    duration: TimeInterval = 200,
    genreNames: [String] = [],
    isCompilation: Bool = false
) -> ResolvedCandidate {
    ResolvedCandidate(
        info: TrackInfo(id: id, name: title, artist: artist),
        tier: tier,
        seedKind: seedKind,
        rawTitle: title,
        albumTitle: album,
        duration: duration,
        genreNames: genreNames,
        isCompilation: isCompilation
    )
}

/// 造 `count` 首互不相同的曲目，每首一个独立艺人（所以歌手上限不会干扰）。
private func distinctCandidates(
    count: Int,
    tier: DiscoveryTier,
    idPrefix: String
) -> [ResolvedCandidate] {
    (0..<count).map { index in
        makeCandidate(
            id: "\(idPrefix)-\(index)",
            title: "\(idPrefix) 曲目 \(index)",
            artist: "\(idPrefix) 艺人 \(index)",
            tier: tier
        )
    }
}

// MARK: - Count Invariants

@Suite("PlaylistComposer — 数量")
struct ComposerCountTests {

    @Test("候选充足时停在上限，不多不少")
    func composerNeverExceedsMax() {
        let output = PlaylistComposer.compose(.init(
            candidates: distinctCandidates(count: 200, tier: .confident, idPrefix: "m")
        ))
        #expect(output.tracks.count == 25)
        #expect(output.deficit == 0)
        #expect(output.publishable)
    }

    @Test("三层都有货时能凑够目标")
    func composerReachesMinWithAbundantPool() {
        let output = PlaylistComposer.compose(.init(
            candidates: distinctCandidates(count: 20, tier: .confident, idPrefix: "c")
                + distinctCandidates(count: 20, tier: .fresh, idPrefix: "f")
                + distinctCandidates(count: 20, tier: .bold, idPrefix: "b")
        ))
        #expect(output.tracks.count == 25)
        #expect(output.deficit == 0)
    }

    @Test("候选不够时如实报告缺口")
    func composerReportsDeficitOnThinPool() {
        let output = PlaylistComposer.compose(.init(
            candidates: distinctCandidates(count: 3, tier: .confident, idPrefix: "t")
        ))
        #expect(output.tracks.count == 3)
        #expect(output.deficit == 17)
        #expect(!output.publishable)
    }

    @Test("刚好够格建歌单")
    func composerPublishesAtAbsoluteMin() {
        let output = PlaylistComposer.compose(.init(
            candidates: distinctCandidates(count: 15, tier: .confident, idPrefix: "y")
        ))
        #expect(output.tracks.count == 15)
        #expect(output.publishable)
    }

    @Test("差一首就不建歌单")
    func composerNeverTrimsBelowAbsoluteMin() {
        let output = PlaylistComposer.compose(.init(
            candidates: distinctCandidates(count: 14, tier: .confident, idPrefix: "x")
        ))
        #expect(output.tracks.count == 14)
        #expect(!output.publishable)
    }
}

// MARK: - Artist Cap

@Suite("PlaylistComposer — 歌手上限")
struct ComposerArtistCapTests {

    @Test("同一歌手绝不超过 2 首")
    func composerArtistCapNeverExceeded() {
        let candidates = (0..<50).map { index in
            makeCandidate(id: "x-\(index)", title: "曲目 \(index)", artist: "艺人 \(index % 3)")
        }
        let output = PlaylistComposer.compose(.init(candidates: candidates))

        #expect(output.tracks.count == 6)
        for artist in ["艺人 0", "艺人 1", "艺人 2"] {
            let count = output.tracks.filter { $0.primaryArtist == artist }.count
            #expect(count == 2)
        }
    }

    @Test("候选严重不足时上限也不放宽")
    func composerArtistCapHoldsUnderDeficit() {
        // 只有 2 个艺人、曲目全在曲库里。放宽后能拿到 4 首 —— 仍然够不到 20，
        // 但绝不能因为"缺货"就把某个艺人放到 3 首。
        let candidates = (0..<10).map { index in
            makeCandidate(id: "lib-\(index)", title: "曲目 \(index)", artist: "艺人 \(index % 2)")
        }
        var input = PlaylistComposer.Input(candidates: candidates)
        input.exclusions.libraryKeys = Set(candidates.map(\.info.key))

        let output = PlaylistComposer.compose(input)
        #expect(output.tracks.count == 4)
        #expect(output.deficit == 16)
        for artist in ["艺人 0", "艺人 1"] {
            #expect(output.tracks.filter { $0.primaryArtist == artist }.count == 2)
        }
    }

    @Test("feat. 折叠成主艺人后参与上限判定")
    func composerPrimaryArtistFeatCollapses() {
        let candidates = [
            makeCandidate(id: "f1", title: "曲一", artist: "周杰伦 feat. 方文山"),
            makeCandidate(id: "f2", title: "曲二", artist: "周杰伦"),
            makeCandidate(id: "f3", title: "曲三", artist: "周杰伦"),
        ]
        let output = PlaylistComposer.compose(.init(candidates: candidates))

        #expect(output.tracks.count == 2)
        #expect(output.rejections.contains { $0.reason == .artistCapped })
    }
}

// MARK: - Tier Quota

@Suite("PlaylistComposer — 三层配额")
struct ComposerTierQuotaTests {

    @Test("配额精确落在 70/20/10 上")
    func composerTierQuota() {
        let output = PlaylistComposer.compose(.init(
            candidates: distinctCandidates(count: 100, tier: .confident, idPrefix: "c")
                + distinctCandidates(count: 100, tier: .fresh, idPrefix: "f")
                + distinctCandidates(count: 100, tier: .bold, idPrefix: "b")
        ))
        #expect(output.tracks.count == 25)
        #expect(output.tierCounts[.confident] == 18)
        #expect(output.tierCounts[.fresh] == 5)
        #expect(output.tierCounts[.bold] == 2)
    }

    @Test("缺口由 fresh 承接，bold 不被抬成 5 倍")
    func composerSpillPrefersFresh() {
        // confident 只有 10 首，fresh / bold 各 50 首。
        // 缺口应该由「下一个更有把握的层级」吃掉，而不是把刻意压到 10% 的 bold 撑大。
        let output = PlaylistComposer.compose(.init(
            candidates: distinctCandidates(count: 10, tier: .confident, idPrefix: "c")
                + distinctCandidates(count: 50, tier: .fresh, idPrefix: "f")
                + distinctCandidates(count: 50, tier: .bold, idPrefix: "b")
        ))
        #expect(output.tracks.count == 25)
        #expect(output.tierCounts[.confident] == 10)
        #expect(output.tierCounts[.bold] == 2)
        #expect(output.tierCounts[.fresh] == 13)
    }

    @Test("QuickPick 不套三层配额")
    func composerQuickPickSkipsQuota() {
        let candidates = distinctCandidates(count: 30, tier: .fresh, idPrefix: "p")
        var input = PlaylistComposer.Input(candidates: candidates)
        input.tierQuotaEnabled = false

        let output = PlaylistComposer.compose(input)
        #expect(output.tracks.count == 25)
        #expect(output.tierCounts[.confident] == 25)
        #expect(output.tierCounts[.fresh] == nil)
        #expect(output.tierCounts[.bold] == nil)
    }
}

// MARK: - Dedup & Exclusion

@Suite("PlaylistComposer — 去重与排除")
struct ComposerDedupTests {

    @Test("先按 catalog ID 去重，再按归一化 key 去重")
    func composerDedupByIDThenKey() {
        let candidates = [
            makeCandidate(id: "id1", title: "晴天", artist: "周杰伦"),
            makeCandidate(id: "id1", title: "晴天", artist: "周杰伦"),        // 同 ID
            makeCandidate(id: "id2", title: "Hello", artist: "Adele"),
            makeCandidate(id: "id3", title: "hello", artist: "ADELE"),      // 同 key（大小写）
            makeCandidate(id: "id4", title: "Hello (Remastered)", artist: "Adele"), // 同 key（括号）
        ]
        let output = PlaylistComposer.compose(.init(candidates: candidates))

        #expect(output.tracks.count == 2)
        #expect(Set(output.tracks.map(\.info.id)) == ["id1", "id2"])
    }

    @Test("历史排除优先于配额")
    func composerExcludesHistoryBeforeQuota() {
        let all = (0..<30).map { index in
            makeCandidate(id: "c-\(index)", title: "曲目 \(index)", artist: "艺人 \(index)")
        }
        let inHistory = Array(all.prefix(10))

        var input = PlaylistComposer.Input(candidates: all)
        input.exclusions.keys = Set(inHistory.map(\.info.key))

        let output = PlaylistComposer.compose(input)
        #expect(output.tracks.count == 20)
        let excludedIDs = Set(inHistory.map(\.info.id))
        #expect(output.tracks.allSatisfy { !excludedIDs.contains($0.info.id) })
    }

    @Test("被内容类型拒掉的曲目不占配额名额")
    func composerContentFilterDoesNotConsumeQuota() {
        let normal = (0..<18).map { index in
            makeCandidate(id: "n-\(index)", title: "曲目 \(index)", artist: "艺人 \(index)")
        }
        let karaoke = (0..<4).map { index in
            makeCandidate(id: "k-\(index)", title: "曲目 \(index) (伴奏)", artist: "伴奏艺人 \(index)")
        }
        let output = PlaylistComposer.compose(.init(candidates: normal + karaoke))

        #expect(output.tierCounts[.confident] == 18)
        #expect(output.tracks.count == 18)
        #expect(output.tracks.allSatisfy { !$0.rawTitle.contains("伴奏") })
    }

    @Test("回填优先放开曲库，绝不放已推荐过的")
    func composerBackfillOrderIsLibraryFirst() {
        // 15 首在曲库里、15 首在历史里。放宽到「允许曲库重叠」就够了，
        // 不该为了凑够 20 首去重推刚推过的歌。
        let libraryOnly = (0..<15).map { index in
            makeCandidate(id: "lib-\(index)", title: "曲目 \(index)", artist: "图书馆艺人 \(index)")
        }
        let historyOnly = (0..<15).map { index in
            makeCandidate(id: "his-\(index)", title: "旧曲 \(index)", artist: "历史艺人 \(index)")
        }
        var input = PlaylistComposer.Input(candidates: libraryOnly + historyOnly)
        input.exclusions.libraryKeys = Set(libraryOnly.map(\.info.key))
        input.exclusions.keys = Set(historyOnly.map(\.info.key))

        let output = PlaylistComposer.compose(input)

        #expect(output.tracks.count == 15)
        #expect(output.tracks.allSatisfy { input.exclusions.libraryKeys.contains($0.info.key) })
        #expect(!output.tracks.contains { input.exclusions.keys.contains($0.info.key) })
    }
}

// MARK: - Determinism

@Suite("PlaylistComposer — 确定性")
struct ComposerDeterminismTests {

    @Test("同一种子下结果与输入顺序无关")
    func composerSeededNoiseIsDeterministic() {
        let candidates = distinctCandidates(count: 60, tier: .confident, idPrefix: "s")

        var forward = PlaylistComposer.Input(candidates: candidates)
        forward.randomSeed = 42
        var reversed = PlaylistComposer.Input(candidates: candidates.reversed())
        reversed.randomSeed = 42

        let a = PlaylistComposer.compose(forward)
        let b = PlaylistComposer.compose(reversed)
        #expect(a.tracks.map(\.info.id) == b.tracks.map(\.info.id))
    }

    @Test("稳定噪声跨调用一致，且不同输入不聚集")
    func stableNoiseIsStable() {
        #expect(stableNoise("hello", seed: 0) == stableNoise("hello", seed: 0))
        #expect(stableNoise("hello", seed: 0) != stableNoise("hello", seed: 1))
        #expect(stableNoise("a", seed: 7) != stableNoise("b", seed: 7))
    }
}

// MARK: - TierQuota

@Suite("TierQuota")
struct TierQuotaTests {

    @Test("任何总数下三层上限之和都等于总数")
    func quotaAlwaysSumsToTotal() {
        for total in 0...60 {
            let quota = TierQuota(total: total)
            let sum = quota.cap(for: .confident) + quota.cap(for: .fresh) + quota.cap(for: .bold)
            #expect(sum == total, "total = \(total)")
        }
    }

    @Test("25 → 18/5/2，20 → 14/4/2")
    func quotaMatchesExpectedBreakdown() {
        let large = TierQuota(total: 25)
        #expect(large.cap(for: .confident) == 18)
        #expect(large.cap(for: .fresh) == 5)
        #expect(large.cap(for: .bold) == 2)

        let small = TierQuota(total: 20)
        #expect(small.cap(for: .confident) == 14)
        #expect(small.cap(for: .fresh) == 4)
        #expect(small.cap(for: .bold) == 2)
    }
}

// MARK: - Artist Identity

@Suite("primaryArtistKey")
struct PrimaryArtistKeyTests {

    @Test("feat. / ft. / featuring / 、都折叠到主艺人")
    func primaryArtistCollapsesFeaturedArtists() {
        #expect(primaryArtistKey("周杰伦 feat. 方文山") == "周杰伦")
        #expect(primaryArtistKey("A ft. B") == "a")
        #expect(primaryArtistKey("A featuring B") == "a")
        #expect(primaryArtistKey("A、B") == "a")
    }

    @Test("`&` 与 `x` 不折叠 —— 它们是乐队名的一部分")
    func primaryArtistKeepsBandsWithAmpersand() {
        #expect(primaryArtistKey("Simon & Garfunkel") == "simon & garfunkel")
        #expect(primaryArtistKey("X Japan") == "x japan")
    }
}
