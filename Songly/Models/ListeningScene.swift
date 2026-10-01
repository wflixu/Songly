//
//  ListeningScene.swift
//  Songly
//
//  情境感知：从本地信号（时段 / 星期 / 季节）推导出「此刻该听什么」。
//
//  这是治「推荐跟场景不搭」的核心。改造前 prompt 用 `timeStyle: .none` 格式化
//  日期（`PromptBuilder.swift:64`），模型**在结构上就看不到几点** —— 所以它
//  永远不可能知道"现在是周三晚上 22:15，用户刚下班走在天桥上"。
//
//  纯函数、零 IO，全部可单测。
//

import Foundation

// MARK: - ListeningScene

/// 一天里的九个时段。刻意用中性的时段名而不是"早通勤/晚通勤"之类 ——
/// 同一个 8 点在工作日和周末是两回事，那层差别交给 `SceneBrief.rationale` 去说。
enum ListeningScene: String, CaseIterable, Codable, Sendable {
    case earlyMorning   // 05–06
    case morning        // 07–08
    case forenoon       // 09–11
    case midday         // 12–13
    case afternoon      // 14–16
    case earlyEvening   // 17–18
    case evening        // 19–20
    case night          // 21–22
    case lateNight      // 23–04

    var displayName: String {
        switch self {
        case .earlyMorning: return "清晨"
        case .morning: return "早上"
        case .forenoon: return "上午"
        case .midday: return "午间"
        case .afternoon: return "下午"
        case .earlyEvening: return "傍晚"
        case .evening: return "晚间"
        case .night: return "夜晚"
        case .lateNight: return "深夜"
        }
    }

    var emoji: String {
        switch self {
        case .earlyMorning: return "🌅"
        case .morning: return "☕️"
        case .forenoon: return "💻"
        case .midday: return "🍜"
        case .afternoon: return "🌤"
        case .earlyEvening: return "🌆"
        case .evening: return "🏠"
        case .night: return "🌙"
        case .lateNight: return "🌌"
        }
    }

    /// 该时段覆盖的小时区间（用于展示）。
    var hourRange: String {
        switch self {
        case .earlyMorning: return "05:00–07:00"
        case .morning: return "07:00–09:00"
        case .forenoon: return "09:00–12:00"
        case .midday: return "12:00–14:00"
        case .afternoon: return "14:00–17:00"
        case .earlyEvening: return "17:00–19:00"
        case .evening: return "19:00–21:00"
        case .night: return "21:00–23:00"
        case .lateNight: return "23:00–05:00"
        }
    }

    /// 由时间推导情境。纯函数。
    static func current(for date: Date, calendar: Calendar = .current) -> ListeningScene {
        switch calendar.component(.hour, from: date) {
        case 5...6: return .earlyMorning
        case 7...8: return .morning
        case 9...11: return .forenoon
        case 12...13: return .midday
        case 14...16: return .afternoon
        case 17...18: return .earlyEvening
        case 19...20: return .evening
        case 21...22: return .night
        default: return .lateNight   // 23 点与 0–4 点
        }
    }
}

// MARK: - SceneBrief

/// 一个场景对应的音乐方向，直接喂给 LLM。
struct SceneBrief: Equatable, Sendable {
    /// 建议能量：低 / 中低 / 中 / 中高。
    let energy: String
    /// 建议速度。
    let tempo: String
    /// 编曲密度。
    let density: String
    let moodKeywords: [String]
    /// 本场景**建议避开**的方向。没有这一条，模型很容易在深夜推高能量的歌。
    let avoid: [String]
    /// 给 LLM 的一句话中文说明。
    let rationale: String

    /// 按场景 + 是否周末取方向。
    ///
    /// `isWeekend` 只影响展示给模型的措辞，不改变音乐方向 ——
    /// 早上八点在工作日和周末的能量需求其实差不多，差别在于"为什么"。
    static func brief(for scene: ListeningScene, isWeekend: Bool) -> SceneBrief {
        let base = scene.brief
        guard isWeekend else { return base }
        return SceneBrief(
            energy: base.energy,
            tempo: base.tempo,
            density: base.density,
            moodKeywords: base.moodKeywords,
            avoid: base.avoid,
            rationale: "\(base.rationale)（今天是周末，时间感比工作日松弛。）"
        )
    }
}

private extension ListeningScene {

    var brief: SceneBrief {
        switch self {
        case .earlyMorning:
            return SceneBrief(
                energy: "低",
                tempo: "慢速",
                density: "稀疏",
                moodKeywords: ["清醒", "安静", "微光", "新的一天"],
                avoid: ["高能量", "密集鼓点", "嘶吼", "明亮的大调舞曲"],
                rationale: "清晨刚醒，耳朵还没准备好，需要留白和温度，不要一上来就冲击。"
            )

        case .morning:
            return SceneBrief(
                energy: "中高",
                tempo: "中速偏快",
                density: "中等",
                moodKeywords: ["出发", "推进感", "提神但不吵"],
                avoid: ["过度忧伤", "冗长的叙事慢歌", "纯氛围无节奏"],
                rationale: "工作日多半在通勤路上，需要在嘈杂环境里抓住注意力；周末则是慢启动的早晨，节奏可以稍缓但别太沉。"
            )

        case .forenoon:
            return SceneBrief(
                energy: "中",
                tempo: "中速",
                density: "低到中等",
                moodKeywords: ["专注", "稳定", "不抢注意力"],
                avoid: ["强人声主导", "情绪起伏大", "突然的高潮"],
                rationale: "工作时段，音乐应该退到背景里，不抢注意力，但也不至于让人犯困。"
            )

        case .midday:
            return SceneBrief(
                energy: "中",
                tempo: "中速",
                density: "中等",
                moodKeywords: ["放松", "透气", "小憩"],
                avoid: ["沉重", "压抑", "需要费力理解的复杂编排"],
                rationale: "午间休整，需要一点透气感，把上午的紧绷放下来。"
            )

        case .afternoon:
            return SceneBrief(
                energy: "中",
                tempo: "中速",
                density: "中等",
                moodKeywords: ["续航", "温和的推动", "别让我困"],
                avoid: ["过于舒缓的助眠向", "长时间的低音铺底"],
                rationale: "下午容易困，需要温和的推进力撑住后半程。"
            )

        case .earlyEvening:
            return SceneBrief(
                energy: "中",
                tempo: "中速",
                density: "中等",
                moodKeywords: ["收工", "卸力", "城市黄昏"],
                avoid: ["加班感", "紧张", "高攻击性"],
                rationale: "工作日是下班路上，需要从工作状态里退出来；周末则是傍晚出门前的过渡，都是转换而不是刺激。"
            )

        case .evening:
            return SceneBrief(
                energy: "中低",
                tempo: "中速偏慢",
                density: "中等",
                moodKeywords: ["生活感", "松弛", "陪伴"],
                avoid: ["攻击性", "密度过高", "需要绷着听的东西"],
                rationale: "回到自己的时间，音乐可以有点生活气，陪着你做别的事。"
            )

        case .night:
            return SceneBrief(
                energy: "低",
                tempo: "慢速",
                density: "低到中等",
                moodKeywords: ["独处", "回望", "温度", "不必振作"],
                avoid: ["亢奋", "快节奏", "喧闹的编曲"],
                rationale: "夜里一个人，需要的是陪伴感而不是刺激 —— 就像下班后走在天桥上，不想被鼓舞，只想被理解。"
            )

        case .lateNight:
            return SceneBrief(
                energy: "很低",
                tempo: "慢速",
                density: "稀疏",
                moodKeywords: ["极安静", "私人", "不必解释"],
                avoid: ["任何高能量", "明亮的大调舞曲", "强节奏"],
                rationale: "深夜了，不需要被鼓励，只需要被理解。宁可过分安静，也不要吵。"
            )
        }
    }
}

// MARK: - Scene Context

/// 情境快照。会被持久化到 `RecommendationRecord`，用于事后回答
/// "这份歌单是在什么情境下生成的"。
struct SceneContext: Equatable, Sendable {
    let scene: ListeningScene
    let isWeekend: Bool
    let season: String
    /// 用户手动指定，而非自动感知。
    let isOverridden: Bool

    /// 自动感知。
    static func sensed(at date: Date = Date(), calendar: Calendar = .current) -> SceneContext {
        SceneContext(
            scene: ListeningScene.current(for: date, calendar: calendar),
            isWeekend: calendar.isDateInWeekend(date),
            season: Self.currentSeason(for: date, calendar: calendar),
            isOverridden: false
        )
    }

    /// 用户手动指定场景。
    static func overridden(
        to scene: ListeningScene,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> SceneContext {
        SceneContext(
            scene: scene,
            isWeekend: calendar.isDateInWeekend(date),
            season: Self.currentSeason(for: date, calendar: calendar),
            isOverridden: true
        )
    }

    var brief: SceneBrief { SceneBrief.brief(for: scene, isWeekend: isWeekend) }

    /// 气象学季节（3–5 春 / 6–8 夏 / 9–11 秋 / 12–2 冬）。
    static func currentSeason(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.month, from: date) {
        case 3...5: return "春"
        case 6...8: return "夏"
        case 9...11: return "秋"
        default: return "冬"
        }
    }
}
