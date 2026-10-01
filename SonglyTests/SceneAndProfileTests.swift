//
//  SceneAndProfileTests.swift
//  SonglyTests
//
//  情境推导是纯本地的（时段 + 星期 + 季节），所以可以完整单测。
//  改造前模型在结构上根本看不到小时，这些用例就是防止那个问题回潮。
//

import Foundation
import Testing
@testable import Songly

// MARK: - Fixtures

private let shanghai: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}()

/// 2026-09-11 是星期五，所以 `day: 11` 是工作日、`day: 12` 是周六。
private func instant(hour: Int, day: Int = 11) -> Date {
    shanghai.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
}

// MARK: - Scene Derivation

@Suite("ListeningScene")
struct ListeningSceneTests {

    @Test("24 小时全部映射到正确的时段")
    func coversEveryHour() {
        let expected: [Int: ListeningScene] = [
            0: .lateNight, 1: .lateNight, 2: .lateNight, 3: .lateNight, 4: .lateNight,
            5: .earlyMorning, 6: .earlyMorning,
            7: .morning, 8: .morning,
            9: .forenoon, 10: .forenoon, 11: .forenoon,
            12: .midday, 13: .midday,
            14: .afternoon, 15: .afternoon, 16: .afternoon,
            17: .earlyEvening, 18: .earlyEvening,
            19: .evening, 20: .evening,
            21: .night, 22: .night,
            23: .lateNight,
        ]
        #expect(expected.count == 24)

        for hour in 0...23 {
            let actual = ListeningScene.current(for: instant(hour: hour), calendar: shanghai)
            #expect(actual == expected[hour], "hour=\(hour) 得到 \(actual.rawValue)")
        }
    }

    @Test("九个时段都能被取到，没有死档位")
    func allScenesReachable() {
        let reached = Set((0...23).map {
            ListeningScene.current(for: instant(hour: $0), calendar: shanghai)
        })
        #expect(reached.count == ListeningScene.allCases.count)
    }

    @Test("跨越午夜的边界归属正确")
    func hourBoundaries() {
        // 深夜档横跨 23:00–04:59，是最容易写错的一段。
        #expect(ListeningScene.current(for: instant(hour: 23), calendar: shanghai) == .lateNight)
        #expect(ListeningScene.current(for: instant(hour: 0), calendar: shanghai) == .lateNight)
        #expect(ListeningScene.current(for: instant(hour: 4), calendar: shanghai) == .lateNight)
        #expect(ListeningScene.current(for: instant(hour: 5), calendar: shanghai) == .earlyMorning)
        #expect(ListeningScene.current(for: instant(hour: 6), calendar: shanghai) == .earlyMorning)
        #expect(ListeningScene.current(for: instant(hour: 7), calendar: shanghai) == .morning)
        #expect(ListeningScene.current(for: instant(hour: 9), calendar: shanghai) == .forenoon)
        #expect(ListeningScene.current(for: instant(hour: 12), calendar: shanghai) == .midday)
        #expect(ListeningScene.current(for: instant(hour: 14), calendar: shanghai) == .afternoon)
        #expect(ListeningScene.current(for: instant(hour: 17), calendar: shanghai) == .earlyEvening)
        #expect(ListeningScene.current(for: instant(hour: 19), calendar: shanghai) == .evening)
        #expect(ListeningScene.current(for: instant(hour: 21), calendar: shanghai) == .night)
    }
}

// MARK: - Scene Brief

@Suite("SceneBrief")
struct SceneBriefTests {

    @Test("每个场景都给出完整的方向说明")
    func everySceneHasCompleteBrief() {
        for scene in ListeningScene.allCases {
            let brief = SceneBrief.brief(for: scene, isWeekend: false)
            #expect(!brief.energy.isEmpty, "\(scene.rawValue) 缺能量")
            #expect(!brief.tempo.isEmpty, "\(scene.rawValue) 缺速度")
            #expect(!brief.density.isEmpty, "\(scene.rawValue) 缺密度")
            #expect(!brief.rationale.isEmpty, "\(scene.rawValue) 缺说明")
            #expect(!brief.moodKeywords.isEmpty, "\(scene.rawValue) 缺情绪词")
        }
    }

    @Test("每个场景都明确该避开什么")
    func everySceneListsWhatToAvoid() {
        // 没有这一条，模型很容易在深夜推高能量的歌 —— 这正是「歌单不懂我」的来源之一。
        for scene in ListeningScene.allCases {
            #expect(!SceneBrief.brief(for: scene, isWeekend: false).avoid.isEmpty, "\(scene.rawValue)")
        }
    }

    @Test("周末只改措辞，不改音乐方向")
    func weekendOnlyChangesWording() {
        // 早上八点在工作日和周末的能量需求其实差不多，差别只在"为什么"。
        let weekday = SceneBrief.brief(for: .morning, isWeekend: false)
        let weekend = SceneBrief.brief(for: .morning, isWeekend: true)

        #expect(weekend.energy == weekday.energy)
        #expect(weekend.tempo == weekday.tempo)
        #expect(weekend.density == weekday.density)
        #expect(weekend.avoid == weekday.avoid)
        #expect(weekend.moodKeywords == weekday.moodKeywords)

        #expect(weekend.rationale != weekday.rationale)
        #expect(weekend.rationale.contains("周末"))
    }

    @Test("深夜的建议能量低于早上 —— 防止场景说明退化成同一份")
    func lateNightIsCalmerThanMorning() {
        let lateNight = SceneBrief.brief(for: .lateNight, isWeekend: false)
        let morning = SceneBrief.brief(for: .morning, isWeekend: false)
        #expect(lateNight.energy != morning.energy)
        #expect(lateNight.tempo != morning.tempo)
    }
}

// MARK: - Scene Context

@Suite("SceneContext")
struct SceneContextTests {

    @Test("自动感知：周五晚上是夜晚、工作日、秋天")
    func sensesWeekdayEvening() {
        let context = SceneContext.sensed(at: instant(hour: 22), calendar: shanghai)
        #expect(context.scene == .night)
        #expect(!context.isWeekend)
        #expect(!context.isOverridden)
        #expect(context.season == "秋")
    }

    @Test("自动感知：周六上午算周末")
    func sensesWeekend() {
        let context = SceneContext.sensed(at: instant(hour: 10, day: 12), calendar: shanghai)
        #expect(context.isWeekend)
        #expect(context.brief.rationale.contains("周末"))
    }

    @Test("手动指定场景优先，并标记为已覆盖")
    func overrideWins() {
        // 上午 10 点自动感知是 forenoon，用户手动切到深夜。
        let sensed = SceneContext.sensed(at: instant(hour: 10), calendar: shanghai)
        #expect(sensed.scene == .forenoon)

        let overridden = SceneContext.overridden(to: .lateNight, at: instant(hour: 10), calendar: shanghai)
        #expect(overridden.scene == .lateNight)
        #expect(overridden.isOverridden)
        #expect(overridden.brief == SceneBrief.brief(for: .lateNight, isWeekend: false))
    }

    @Test("季节边界")
    func seasonBoundaries() {
        func season(month: Int) -> String {
            let date = shanghai.date(from: DateComponents(year: 2026, month: month, day: 15))!
            return SceneContext.currentSeason(for: date, calendar: shanghai)
        }
        #expect(season(month: 3) == "春")
        #expect(season(month: 5) == "春")
        #expect(season(month: 6) == "夏")
        #expect(season(month: 8) == "夏")
        #expect(season(month: 9) == "秋")
        #expect(season(month: 11) == "秋")
        #expect(season(month: 12) == "冬")
        #expect(season(month: 1) == "冬")
        #expect(season(month: 2) == "冬")
    }
}

// MARK: - Library Stats

private func track(
    _ title: String,
    artist: String = "某艺人",
    genres: [String] = [],
    year: Int? = nil
) -> LibraryTrackSnapshot {
    LibraryTrackSnapshot(
        title: title, artist: artist, genreNames: genres,
        releaseYear: year, playCount: nil
    )
}

@Suite("LibraryStats")
struct LibraryStatsTests {

    @Test("流派按数量降序，同数量按名称升序")
    func genresSortedByCountThenName() {
        let stats = LibraryStats(snapshot: [
            track("a", genres: ["民谣"]),
            track("b", genres: ["民谣"]),
            track("c", genres: ["摇滚"]),
            track("d", genres: ["摇滚"]),
            track("e", genres: ["电音"]),
        ])
        // 民谣与摇滚都是 2，靠名称升序打破平手，否则顺序会随输入漂移。
        #expect(stats.genres.map(\.name) == ["摇滚", "民谣", "电音"])
        #expect(stats.genres.map(\.count) == [2, 2, 1])
    }

    @Test("桶数被截断到 12")
    func bucketsAreTruncated() {
        let many = (0..<30).map { track("t\($0)", artist: "艺人\($0)", genres: ["流派\($0)"]) }
        let stats = LibraryStats(snapshot: many)

        #expect(stats.genres.count == LibraryStats.maxBuckets)
        #expect(stats.topArtists.count == LibraryStats.maxBuckets)
    }

    @Test("同样的输入产出同样的文本块 —— 这是缓存能命中的前提")
    func textBlockIsDeterministic() {
        let input = [
            track("曲一", artist: "A", genres: ["民谣", "独立"], year: 2015),
            track("曲二", artist: "B", genres: ["摇滚"], year: 2008),
            track("曲三", artist: "A", genres: ["民谣"], year: 2019),
        ]
        let first = LibraryStats(snapshot: input).compactBlock
        let second = LibraryStats(snapshot: input).compactBlock
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("输入顺序不影响结果")
    func orderIndependent() {
        let items = [
            track("曲一", artist: "A", genres: ["民谣"], year: 2015),
            track("曲二", artist: "B", genres: ["摇滚"], year: 2008),
            track("曲三", artist: "C", genres: ["民谣"], year: 2019),
        ]
        #expect(
            LibraryStats(snapshot: items).compactBlock
                == LibraryStats(snapshot: items.reversed()).compactBlock
        )
    }

    @Test("日文歌名不会被算成中文 —— 必须先判假名")
    func detectsJapaneseBeforeChinese() {
        // 日文歌名里同时有 kanji 和 kana，先判 kanji 就会全部误判成中文。
        #expect(LibraryStats.language(of: "君の名は") == "日文")
        #expect(LibraryStats.language(of: "残酷な天使のテーゼ") == "日文")
    }

    @Test("韩文与中英文的判定")
    func detectsLanguages() {
        #expect(LibraryStats.language(of: "晴天") == "中文")
        #expect(LibraryStats.language(of: "Hello World") == "英文")
        #expect(LibraryStats.language(of: "사랑해") == "韩文")
        #expect(LibraryStats.language(of: "❄︎❄︎❄︎") == "其他")
    }
}

// MARK: - TasteProfile

@Suite("TasteProfile")
struct TasteProfileTests {

    private let payload = TasteProfilePayload(
        coreGenres: ["华语民谣", "独立摇滚"],
        representativeArtists: ["陈粒", "万能青年旅店"],
        eraPreference: "以 2010s 为主",
        moodSignature: "偏低能量、偏内省",
        vocalPreference: "以人声为主",
        languageDistribution: "中文约七成",
        tiredOf: ["抖音热歌", "翻唱合辑"],
        summary: "你偏好叙事性强、编配克制的中文独立音乐。"
    )

    private func profile(version: Int = 1) -> TasteProfile {
        TasteProfile(
            version: version,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            libraryFingerprint: "abc",
            payload: payload
        )
    }

    @Test("profileBlock 字节稳定 —— 缓存能不能命中全看这一条")
    func blockIsByteStable() {
        // 前缀缓存是逐字节比对的，只要有一个字节漂移，输入价就差约 50 倍。
        #expect(profile().profileBlock == profile().profileBlock)
    }

    @Test("generatedAt 不出现在文本块里")
    func blockExcludesTimestamp() {
        let a = TasteProfile(
            version: 1, generatedAt: Date(timeIntervalSince1970: 0),
            libraryFingerprint: "abc", payload: payload
        )
        let b = TasteProfile(
            version: 1, generatedAt: Date(timeIntervalSince1970: 999_999_999),
            libraryFingerprint: "abc", payload: payload
        )
        // 生成时间不同、内容相同 → 文本块必须一致，否则每次重算都会打穿缓存。
        #expect(a.profileBlock == b.profileBlock)
    }

    @Test("版本号变化会体现在文本块里")
    func blockCarriesVersion() {
        // 画像真的变了的时候，本来就该让缓存失效。
        #expect(profile(version: 1).profileBlock != profile(version: 2).profileBlock)
    }

    @Test("画像包含了「听腻的方向」")
    func blockListsTiredOf() {
        #expect(profile().profileBlock.contains("抖音热歌"))
        #expect(profile().profileBlock.contains("听腻"))
    }

    @Test("空画像也能渲染，不崩")
    func emptyPayloadRenders() {
        let empty = TasteProfile(
            version: 1, generatedAt: Date(), libraryFingerprint: "x", payload: .empty
        )
        #expect(!empty.profileBlock.isEmpty)
    }
}

// MARK: - TasteProfileStore

@Suite("TasteProfileStore")
struct TasteProfileStoreTests {

    private func isolatedDefaults() -> UserDefaults {
        let suite = "songly.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func profile(
        version: Int = 1,
        ageDays: Double = 0,
        fingerprint: String = "fp-1"
    ) -> TasteProfile {
        TasteProfile(
            version: version,
            generatedAt: Date().addingTimeInterval(-ageDays * 24 * 60 * 60),
            libraryFingerprint: fingerprint,
            payload: .empty
        )
    }

    @Test("从来没有画像时要生成")
    func refreshesWhenMissing() {
        #expect(TasteProfileStore.shouldRefresh(existing: nil, libraryFingerprint: "fp-1"))
    }

    @Test("画像新鲜且曲库没变时不重算")
    func skipsWhenFresh() {
        #expect(!TasteProfileStore.shouldRefresh(
            existing: profile(ageDays: 1), libraryFingerprint: "fp-1"
        ))
    }

    @Test("超过有效期要重算")
    func refreshesWhenExpired() {
        #expect(TasteProfileStore.shouldRefresh(
            existing: profile(ageDays: 8), libraryFingerprint: "fp-1"
        ))
    }

    @Test("曲库变了、且已过最小间隔，就重算")
    func refreshesOnLibraryDrift() {
        #expect(TasteProfileStore.shouldRefresh(
            existing: profile(ageDays: 2, fingerprint: "fp-old"),
            libraryFingerprint: "fp-new"
        ))
    }

    @Test("曲库刚变但还在最小间隔内，先不重算")
    func doesNotRefreshWithinMinInterval() {
        // 用户每加一首歌就重算一次画像，等于每次收藏都烧一次 LLM 调用。
        #expect(!TasteProfileStore.shouldRefresh(
            existing: profile(ageDays: 0.5, fingerprint: "fp-old"),
            libraryFingerprint: "fp-new"
        ))
    }

    @Test("存读往返")
    func roundTrips() {
        let store = TasteProfileStore(defaults: isolatedDefaults())
        #expect(store.load() == nil)

        let saved = profile(version: 3)
        store.save(saved)
        #expect(store.load() == saved)

        store.clear()
        #expect(store.load() == nil)
    }

    @Test("版本号每次生成递增")
    func versionIncrements() {
        let store = TasteProfileStore(defaults: isolatedDefaults())
        let first = store.makeProfile(payload: .empty, libraryFingerprint: "f", previous: nil)
        let second = store.makeProfile(payload: .empty, libraryFingerprint: "f", previous: first)
        #expect(first.version == 1)
        #expect(second.version == 2)
    }

    @Test("曲库指纹与顺序无关")
    func fingerprintIgnoresOrder() {
        #expect(
            LibraryFingerprint.make(from: ["a", "b", "c"])
                == LibraryFingerprint.make(from: ["c", "a", "b"])
        )
        #expect(
            LibraryFingerprint.make(from: ["a", "b"])
                != LibraryFingerprint.make(from: ["a", "b", "c"])
        )
    }
}
