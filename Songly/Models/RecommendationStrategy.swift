//
//  RecommendationStrategy.swift
//  Songly
//
//  Enums defining recommendation strategies and QuickPick preset styles.
//

import Foundation

// MARK: - Recommendation Strategy

enum RecommendationStrategy: String, CaseIterable, Sendable {
    case styleExploration = "风格探索"
    case eraRetrospective = "年代回溯"
    case artistAssociation = "艺人关联"
    case genreMix = "混搭实验"
    case randomDiscovery = "随机发现"
    case moodMatch = "情绪匹配"

    var emoji: String {
        switch self {
        case .styleExploration: return "🎸"
        case .eraRetrospective: return "📻"
        case .artistAssociation: return "🎭"
        case .genreMix: return "🔀"
        case .randomDiscovery: return "🎲"
        case .moodMatch: return "🌙"
        }
    }

    /// MVP 阶段仅启用此策略。
    static var mvpStrategies: [RecommendationStrategy] {
        [.styleExploration]
    }

    /// Prompt 中使用的策略描述。
    var promptHint: String {
        switch self {
        case .styleExploration:
            return "基于用户的听歌品味，推荐相近风格但用户可能没听过的冷门好歌"
        case .eraRetrospective:
            return "翻出用户收藏的经典歌曲，推荐同时代风格相近的遗珠"
        case .artistAssociation:
            return "基于用户收藏的艺人，推荐关联艺人/合作项目的好歌"
        case .genreMix:
            return "将不同风格的歌曲混搭在一起，创造新鲜听感"
        case .randomDiscovery:
            return "随机探索冷门佳作，排除用户已收藏的歌曲"
        case .moodMatch:
            return "根据情绪/场景推荐合适的歌曲"
        }
    }
}

// MARK: - QuickPick Style

enum QuickPickStyle: String, CaseIterable, Sendable {
    case rock = "摇滚"
    case instrumental = "纯音乐"
    case jazz = "爵士"
    case surprise = "来点不一样的"
    case sleep = "睡前放松"

    var emoji: String {
        switch self {
        case .rock: return "🎸"
        case .instrumental: return "🎹"
        case .jazz: return "🎷"
        case .surprise: return "🔀"
        case .sleep: return "🌙"
        }
    }

    /// MVP 阶段展示的风格（精简为 3 种）。
    static var mvpStyles: [QuickPickStyle] {
        [.rock, .jazz, .surprise]
    }

    /// 风格对应的 prompt 提示词。
    var promptHint: String {
        switch self {
        case .rock: return "推荐摇滚/另类摇滚/独立摇滚风格的好歌，注重吉他编排和能量感"
        case .instrumental: return "推荐纯音乐/器乐演奏，适合专注或放松时聆听"
        case .jazz: return "推荐爵士/融合爵士/冷爵士风格，注重旋律和即兴"
        case .surprise: return "来点不一样的——跨风格随机推荐，跳出用户的舒适区"
        case .sleep: return "推荐舒缓放松的音乐，适合睡前聆听"
        }
    }
}

// MARK: - Recommendation State

/// Pipeline state — emitted by RecommendationEngine, observed by HomeViewModel.
enum RecommendationState: Equatable {
    case onboarding
    case idle
    case readingLibrary
    case generating(progress: String)
    case searchingCatalog(found: Int, total: Int)
    case persistingRecord
    case creatingPlaylist
    case completed(trackCount: Int)
    case error(message: String, retryable: Bool)
}
