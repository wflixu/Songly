//
//  RecommendationRecord.swift
//  Songly
//
//  SwiftData model for persisting recommendation results.
//  Track data stored as JSON to avoid parallel-array consistency issues.
//

import Foundation
import SwiftData

@Model
final class RecommendationRecord {
    static let statusPending = "pending"
    static let statusCompleted = "completed"

    /// 推荐日期（唯一约束，用于"今日是否已生成"判断）。
    @Attribute(.unique) var date: Date
    /// 推荐策略标识。
    var strategy: String
    /// 实际匹配成功的歌曲数。
    var songCount: Int
    /// JSON 编码的 [TrackInfo] 数组。
    var tracksJSON: String
    /// 推荐生成时间戳。
    var createdAt: Date
    /// 来源: "daily" | "quick_pick"。
    var source: String
    /// "想听"的风格标签（仅 quick_pick）。
    var quickPickStyle: String?
    /// 创建的播放列表名称。
    var playlistName: String?
    /// 生成状态: "pending"（已落库、播放列表未建成）| "completed"。
    /// 旧记录迁移默认视为 completed（历史上都建成了列表）。
    var status: String = RecommendationRecord.statusCompleted
    /// 已创建的 Apple Music 播放列表 ID（完成后写入）。
    var playlistID: String?
    /// 已创建的播放列表打开 URL（完成后写入）。
    var playlistURL: URL?
    /// 生成时所属的听力场景（`ListeningScene.rawValue`）。
    ///
    /// 场景是**这份歌单的属性**，不是「现在几点」—— 卡片上显示它，回答的是
    /// 「这份歌单是在什么情境下生成的」。理由文案刻意不落库：它由
    /// `SceneBrief.brief(for:isWeekend:)` 从 scene + 日期纯函数派生，
    /// 存一份副本只会多一处可能不一致的地方。旧记录为 nil。
    var scene: String? = nil

    // MARK: - Computed: TrackInfo

    /// 反序列化歌曲列表。
    var tracks: [TrackInfo] {
        get {
            guard let data = tracksJSON.data(using: .utf8),
                  let result = try? JSONDecoder().decode([TrackInfo].self, from: data)
            else { return [] }
            return result
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                tracksJSON = json
            }
        }
    }

    /// 便捷: 歌名列表。
    var trackNames: [String] { tracks.map(\.name) }
    /// 便捷: 歌曲 ID 列表。
    var trackIDs: [String] { tracks.map(\.id) }
    /// 便捷: 艺人名列表。
    var artistNames: [String] { tracks.map(\.artist) }

    // MARK: - Computed: 展示

    /// 给人看的歌单标题。
    ///
    /// **不要直接用 `playlistName`** —— 那是 Apple Music 里的播放列表名，带着
    /// emoji 和 `20260912` 这样的日期后缀（同日第二份还有 `-02` 序号），在列表里
    /// 既难看、又和行尾的相对时间重复。
    var displayTitle: String {
        if let style = quickPickStyle, let parsed = QuickPickStyle(rawValue: style) {
            return "\(parsed.rawValue)精选"
        }
        return "每日推荐"
    }

    /// 已解析的听力场景。旧记录（本次改动之前生成的）为 nil。
    var sceneValue: ListeningScene? {
        scene.flatMap(ListeningScene.init(rawValue:))
    }

    /// 层级分布。旧记录里每首歌的 tier 都是 nil，因此返回空字典、
    /// 卡片相应地不显示这一行。
    var tierCounts: [DiscoveryTier: Int] {
        var counts: [DiscoveryTier: Int] = [:]
        for track in tracks {
            guard let tier = track.tier else { continue }
            counts[tier, default: 0] += 1
        }
        return counts
    }

    /// 「喜欢 18 · 新鲜 5 · 大胆 2」。三层的叙事在 UI 上的唯一呈现。
    /// 旧记录没有 tier，返回 nil，调用方就不显示这一行。
    var tierSummary: String? {
        let counts = tierCounts
        guard !counts.isEmpty else { return nil }
        return DiscoveryTier.allCases
            .compactMap { tier in
                guard let count = counts[tier], count > 0 else { return nil }
                return "\(tier.shortName) \(count)"
            }
            .joined(separator: " · ")
    }

    // MARK: - Init

    init(
        date: Date,
        strategy: String,
        songCount: Int,
        tracks: [TrackInfo],
        source: String,
        quickPickStyle: String? = nil,
        playlistName: String? = nil,
        status: String = RecommendationRecord.statusPending,
        playlistID: String? = nil,
        playlistURL: URL? = nil,
        scene: String? = nil
    ) {
        self.date = date
        self.strategy = strategy
        self.songCount = songCount

        let data = try? JSONEncoder().encode(tracks)
        self.tracksJSON = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        self.createdAt = Date()
        self.source = source
        self.quickPickStyle = quickPickStyle
        self.playlistName = playlistName
        self.status = status
        self.playlistID = playlistID
        self.playlistURL = playlistURL
        self.scene = scene
    }
}
