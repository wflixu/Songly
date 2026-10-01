//
//  PromptTests.swift
//  SonglyTests
//
//  prompt 构造与专辑挑曲。两者都是纯函数，而且各自守住一条关键性质：
//  - `PromptBuilderV3`：**真实小时必须出现在模型看得到的地方**，
//    而 **system 前缀必须字节稳定**（否则 DeepSeek 的前缀缓存全部失效）。
//  - `AlbumTrackPicker`：**优先挖非主打**，这是治「都是听过的老歌」的地方。
//

import Foundation
import Testing
@testable import Songly

// MARK: - Fixtures

private let shanghaiCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}()

private func instant(hour: Int, minute: Int = 0, day: Int = 11) -> Date {
    shanghaiCalendar.date(from: DateComponents(
        year: 2026, month: 9, day: day, hour: hour, minute: minute
    ))!
}

private func candidate(
    id: String,
    title: String,
    artist: String = "某艺人",
    album: String = "某专辑",
    trackNumber: Int? = nil,
    albumTrackCount: Int? = nil,
    duration: TimeInterval = 200,
    isCompilation: Bool = false,
    tier: DiscoveryTier = .confident
) -> ResolvedCandidate {
    ResolvedCandidate(
        info: TrackInfo(id: id, name: title, artist: artist),
        tier: tier,
        seedKind: .album,
        rawTitle: title,
        albumTitle: album,
        duration: duration,
        genreNames: [],
        isCompilation: isCompilation,
        releaseDate: nil,
        trackNumber: trackNumber,
        albumTrackCount: albumTrackCount
    )
}

private let payload = TasteProfilePayload(
    coreGenres: ["华语民谣"],
    representativeArtists: ["陈粒"],
    eraPreference: "2010s",
    moodSignature: "偏低能量",
    vocalPreference: "以人声为主",
    languageDistribution: "中文为主",
    tiredOf: ["抖音热歌"],
    summary: "偏好叙事性强的中文独立音乐。"
)

// MARK: - Album Track Picker

@Suite("AlbumTrackPicker")
struct AlbumTrackPickerTests {

    /// 一张 10 首歌的专辑，第 1、2 轨是主打。
    ///
    /// 闭包参数必须显式标注成 `Int`：`trackNumber` 是 `Int?`，而 `Optional` 在
    /// `Wrapped: Comparable` 时也满足 `Comparable`，于是 `1...10` 会被推断成
    /// `ClosedRange<Int?>`，插值出 `Optional(3)` 这种 id。
    private func albumTracks() -> [ResolvedCandidate] {
        (1...10).map { (index: Int) -> ResolvedCandidate in
            candidate(
                id: "t\(index)", title: "第 \(index) 首",
                trackNumber: index, albumTrackCount: 10
            )
        }
    }

    @Test("优先挖非主打 —— 前两轨排到最后")
    func prefersDeepCuts() {
        // 要 2 首，专辑有 10 首。如果按轨号顺序取，拿到的永远是主打。
        let picked = AlbumTrackPicker.pick(
            from: albumTracks(), wants: 2, exclusions: .init()
        )

        #expect(picked.count == 2)
        #expect(picked.allSatisfy { ($0.trackNumber ?? 0) > 2 })
        #expect(picked.map(\.trackNumber) == [3, 4])
    }

    @Test("迷你专辑不套深挖偏置")
    func skipsDeepCutBiasOnShortAlbums() {
        // 5 首歌的 EP 里，前三轨未必是主打，硬套会挑到奇怪的位置。
        let tracks = (1...5).map { (index: Int) -> ResolvedCandidate in
            candidate(id: "e\(index)", title: "第 \(index) 首", trackNumber: index, albumTrackCount: 5)
        }
        let picked = AlbumTrackPicker.pick(from: tracks, wants: 2, exclusions: .init())
        #expect(picked.map(\.trackNumber) == [1, 2])
    }

    @Test("排除集合里的曲目会被剔掉")
    func dropsExcludedTracks() {
        let all = albumTracks()
        var exclusions = PlaylistComposer.ExclusionSet()
        exclusions.songIDs = ["t3", "t4", "t5"]

        let picked = AlbumTrackPicker.pick(from: all, wants: 2, exclusions: exclusions)
        #expect(picked.map(\.info.id) == ["t6", "t7"])
    }

    @Test("整张专辑都在曲库里时，退回允许重叠而不是空手而归")
    func fallsBackWhenEverythingIsExcluded() {
        // 一条 seed 能解析出东西总比失败强；真正的硬排除（已推荐过、最近播放）
        // 仍然生效，只是"已在曲库"这一条被放开。
        let all = albumTracks()
        var exclusions = PlaylistComposer.ExclusionSet()
        exclusions.libraryKeys = Set(all.map(\.info.key))

        let picked = AlbumTrackPicker.pick(from: all, wants: 2, exclusions: exclusions)
        #expect(picked.count == 2)
    }

    @Test("已推荐过 / 最近播放过的即使在放宽路径下也不放行")
    func hardExclusionsSurviveRelaxation() {
        let all = albumTracks()
        var exclusions = PlaylistComposer.ExclusionSet()
        exclusions.libraryKeys = Set(all.map(\.info.key))
        exclusions.songIDs = Set(all.map(\.info.id))

        let picked = AlbumTrackPicker.pick(from: all, wants: 2, exclusions: exclusions)
        #expect(picked.isEmpty)
    }

    @Test("取数被 wants 与专辑上限双重夹紧")
    func clampsToWantsAndAlbumLimit() {
        let all = albumTracks()

        #expect(AlbumTrackPicker.pick(from: all, wants: 1, exclusions: .init()).count == 1)
        // wants 很大也不能超过单专辑上限。
        let many = AlbumTrackPicker.pick(from: all, wants: 99, exclusions: .init())
        #expect(many.count == AppConfig.maxTracksPerAlbum)
    }

    @Test("伴奏 / 现场版在挑曲阶段就被挡掉")
    func rejectsBadContentTypes() {
        let tracks = [
            candidate(id: "k", title: "某曲 (伴奏)", trackNumber: 3, albumTrackCount: 10),
            candidate(id: "l", title: "某曲 (Live)", trackNumber: 4, albumTrackCount: 10),
            candidate(id: "ok", title: "正经曲目", trackNumber: 5, albumTrackCount: 10),
        ]
        let picked = AlbumTrackPicker.pick(from: tracks, wants: 3, exclusions: .init())
        #expect(picked.map(\.info.id) == ["ok"])
    }

    @Test("同样的输入挑出同样的结果")
    func deterministic() {
        let all = albumTracks()
        let first = AlbumTrackPicker.pick(from: all, wants: 3, exclusions: .init())
        let second = AlbumTrackPicker.pick(from: all.reversed(), wants: 3, exclusions: .init())
        #expect(first.map(\.info.id) == second.map(\.info.id))
    }
}

// MARK: - Prompt Builder

@Suite("PromptBuilderV3")
struct PromptBuilderV3Tests {

    @Test("system 前缀字节稳定 —— 缓存能不能命中全看这一条")
    func systemPrefixIsByteStable() {
        let profile = TasteProfile(
            version: 1, generatedAt: Date(), libraryFingerprint: "x", payload: payload
        )
        #expect(
            PromptBuilderV3.systemPrefix(profile: profile)
                == PromptBuilderV3.systemPrefix(profile: profile)
        )
    }

    @Test("system 前缀里不含时间戳")
    func systemPrefixHasNoTimestamp() {
        // 前缀缓存逐字节比对，任何随时间变化的东西都会让它每天都失效。
        let system = PromptBuilderV3.systemPrefix(profile: nil)
        #expect(!system.contains("2026"))
        #expect(!system.contains("现在："))
        // 生成时间不同的两份同内容画像，前缀必须一模一样。
        let a = TasteProfile(version: 1, generatedAt: Date(timeIntervalSince1970: 0),
                             libraryFingerprint: "x", payload: payload)
        let b = TasteProfile(version: 1, generatedAt: Date(timeIntervalSince1970: 9_999_999),
                             libraryFingerprint: "x", payload: payload)
        #expect(PromptBuilderV3.systemPrefix(profile: a) == PromptBuilderV3.systemPrefix(profile: b))
    }

    @Test("用户消息里出现真实小时 —— 这是「歌单不懂场景」的直接修复")
    func userMessageCarriesRealHour() {
        // 改造前 prompt 用 `timeStyle: .none` 格式化日期，模型在结构上
        // 不可能知道几点。这条断言就是钉住那个修复。
        let scene = SceneContext.sensed(at: instant(hour: 22, minute: 15), calendar: shanghaiCalendar)
        let message = PromptBuilderV3.firstUserMessage(
            scene: scene, now: instant(hour: 22, minute: 15),
            librarySample: [], stats: nil,
            recentlyPlayed: [], topPlayed: [], recentlyRecommended: [],
            seedTargets: PromptBuilderV3.seedTargets(for: 25),
            calendar: shanghaiCalendar
        )

        #expect(message.contains("22:15"))
        #expect(message.contains("夜晚"))
    }

    @Test("被跨天闸门挡掉的艺人写进用户消息 —— 省得模型把 seed 浪费在注定被拒的方向")
    func blockedArtistsAreAnnounced() {
        let scene = SceneContext.sensed(at: instant(hour: 9), calendar: shanghaiCalendar)
        let message = PromptBuilderV3.firstUserMessage(
            scene: scene, now: instant(hour: 9),
            librarySample: [], stats: nil,
            recentlyPlayed: [], topPlayed: [], recentlyRecommended: [],
            blockedArtists: ["周杰伦", "陈奕迅"],
            seedTargets: PromptBuilderV3.seedTargets(for: 25),
            calendar: shanghaiCalendar
        )

        #expect(message.contains("周杰伦"))
        #expect(message.contains("陈奕迅"))
        #expect(message.contains("本轮不会再选"))
    }

    @Test("没有近期艺人时这一节整块省略 —— 无信号的消息与改造前逐字节相同")
    func noBlockedArtistsNoSection() {
        let scene = SceneContext.sensed(at: instant(hour: 9), calendar: shanghaiCalendar)
        let message = PromptBuilderV3.firstUserMessage(
            scene: scene, now: instant(hour: 9),
            librarySample: [], stats: nil,
            recentlyPlayed: [], topPlayed: [], recentlyRecommended: [],
            seedTargets: PromptBuilderV3.seedTargets(for: 25),
            calendar: shanghaiCalendar
        )

        #expect(!message.contains("不会再选"))
    }

    @Test("情境区块给出能量、速度与要避开的雷")
    func sceneBlockCarriesDirection() {
        let scene = SceneContext.sensed(at: instant(hour: 23), calendar: shanghaiCalendar)
        let block = PromptBuilderV3.sceneBlock(
            scene: scene, now: instant(hour: 23), calendar: shanghaiCalendar
        )
        #expect(block.contains("建议能量"))
        #expect(block.contains("建议避开"))
        #expect(block.contains("深夜"))
    }

    @Test("手动指定场景时明确告诉模型不要按时间推测")
    func overrideIsAnnounced() {
        let scene = SceneContext.overridden(to: .lateNight, at: instant(hour: 10), calendar: shanghaiCalendar)
        let block = PromptBuilderV3.sceneBlock(
            scene: scene, now: instant(hour: 10), calendar: shanghaiCalendar
        )
        #expect(block.contains("手动指定"))
    }

    @Test("收藏抽样：每位艺人最多 3 首，按播放次数降序")
    func samplesLibraryByPlayCountAndArtist() {
        var tracks: [PromptTrack] = []
        for index in 0..<10 {
            tracks.append(PromptTrack(title: "高产艺人曲 \(index)", artist: "高产", playCount: 100 - index))
        }
        tracks.append(PromptTrack(title: "别人的歌", artist: "另一位", playCount: 1))

        let sampled = PromptBuilderV3.sampleLibrary(tracks, limit: 20)

        let prolific = sampled.filter { $0.artist == "高产" }
        #expect(prolific.count == PromptBuilderV3.maxLinesPerArtist)
        // 最高播放的排最前。
        #expect(sampled.first?.title == "高产艺人曲 0")
        // 限额没被占满时，别的艺人也进得来（旧实现按输入顺序取，会永远是同一批）。
        #expect(sampled.contains { $0.artist == "另一位" })
    }

    @Test("seed 目标按 70/20/10 超额分配")
    func seedTargetsFollowQuota() {
        let targets = PromptBuilderV3.seedTargets(for: 25)
        // 25 × 1.8 = 45 → 32 / 9 / 4
        #expect(targets[.confident] == 32)
        #expect(targets[.fresh] == 9)
        #expect(targets[.bold] == 4)
        #expect(targets.values.reduce(0, +) == 45)
    }

    @Test("任务区块的数字与 seed 目标一致")
    func taskBlockMatchesTargets() {
        let targets = PromptBuilderV3.seedTargets(for: 25)
        let block = PromptBuilderV3.taskBlock(seedTargets: targets)
        #expect(block.contains("45"))
        #expect(block.contains("32"))
        #expect(block.contains("大概率喜欢"))
    }

    @Test("QuickPick 时不套三层分布，改为风格要求")
    func quickPickOverridesTiers() {
        let targets = PromptBuilderV3.seedTargets(for: 25)
        let message = PromptBuilderV3.firstUserMessage(
            scene: SceneContext.sensed(at: instant(hour: 10), calendar: shanghaiCalendar),
            now: instant(hour: 10),
            librarySample: [], stats: nil,
            recentlyPlayed: [], topPlayed: [], recentlyRecommended: [],
            seedTargets: targets,
            quickPickStyle: .piano,
            calendar: shanghaiCalendar
        )
        #expect(message.contains("钢琴"))
        #expect(message.contains("优先级高于上面的场景"))
        #expect(!message.contains("fresh"))
    }

    @Test("system 前缀要求模型优先用专辑形式提 seed")
    func systemPrefixAsksForAlbumSeeds() {
        // 这是挖到非主打的关键指令，不能丢。
        let system = PromptBuilderV3.systemPrefix(profile: nil)
        #expect(system.contains("album"))
        #expect(system.contains("最多 2 首"))
    }

    @Test("没有画像时给出可用的兜底提示，而不是留空")
    func handlesMissingProfile() {
        let system = PromptBuilderV3.systemPrefix(profile: nil)
        #expect(system.contains("暂无画像"))
    }
}
