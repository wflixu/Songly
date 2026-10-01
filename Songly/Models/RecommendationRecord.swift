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
    /// 运行失败。**保留记录**，好让「今天为什么没出歌单」事后有据可查。
    ///
    /// ⚠️ 这类记录的曲目**从未出现在任何歌单里**，所以所有展示与去重路径都必须
    /// 把它排除掉 —— 否则会把用户从没见过的歌排除掉、或让首页显示一份并不存在的歌单。
    /// `loadTodayRecord` 与 `PlaylistHistoryView` 本来就按 `completed` 过滤；
    /// `loadRecentRecords` / `fetchRecentRecords` / `countTodayRecommendations`
    /// 是随本次改动一起补上的（顺带修掉一个既有隐患：进程若在「落库」与
    /// 「建歌单」之间被杀，那条 `pending` 记录同样会污染这两处）。
    static let statusFailed = "failed"

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
    /// 用户对这份歌单的判断（`PlaylistRating.rawValue`：很准 / 一般 / 不准）。
    /// 旧记录为 nil。与 `scene` 同一套路：存字符串 + 计算属性解析，
    /// 不让 SwiftData 直接持有枚举。
    var rating: String? = nil
    /// 被用户删掉的曲目数。
    ///
    /// `songCount` 的语义是**当前**曲目数（删除时递减），所以这个字段保留
    /// 差值，供详情页那行「N 首已移除（Apple Music 中的歌单不变）」使用。
    /// 旧记录为 0。
    var removedCount: Int = 0

    // MARK: - 版本标识（数据批次的可比性）
    //
    // 没有这几个字段，「这份歌单是哪一版算法产的」就无从得知 —— 算法一改，
    // 新旧数据混在同一张表里无法区分批次。全部是 `var` + 默认值，
    // 与 `scene` / `rating` 同一套路，**不需要 SwiftData 迁移**。

    /// 产物版本，见 `AppConfig.pipelineVersion`。**0 = 未标记的旧记录。**
    var pipelineVersion: Int = 0
    /// prompt 结构版本，见 `AppConfig.promptVersion`。
    var promptVersion: Int = 0
    /// 生成时用的模型 ID。模型名会变（`AppConfig` 的注释记录过旧模型被退役的先例），
    /// 不留痕就无法解释「同一版算法为什么前后表现不一样」。
    var modelID: String? = nil

    /// 该次运行的完整诊断 —— 与 `logDiagnostics` 打的是**同一份 payload**。
    ///
    /// ⚠️ **刻意不放在 `#if DEBUG` 里。** 02:00 的后台任务跑的是 Release 构建，
    /// 而它恰恰是歌单的主要产出路径；跟着 DEBUG 走的话，数据在 Release 下
    /// **永远是空的**，而且这个错法不报错、只静默产出零数据。
    var diagnosticsJSON: String? = nil

    /// 失败原因（仅 `status == "failed"` 时有值）。
    var failureReason: String? = nil

    /// 用户最近一次给出歌单评价的时间。`nil` = 从未评价，或评价已被撤销。
    var ratedAt: Date? = nil

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

    // MARK: - Computed: 反馈

    /// 用户删掉的曲目**不在**这里面。
    ///
    /// **所有展示路径都必须走它** —— 封面拼贴、层级配比、曲目列表、歌单行封面。
    /// 漏掉任何一处，就会出现「拼贴里还有那首歌、列表里却没有」的错位。
    var visibleTracks: [TrackInfo] {
        tracks.filter { $0.verdict != .removed }
    }

    var ratingValue: PlaylistRating? {
        rating.flatMap(PlaylistRating.init(rawValue:))
    }

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
        // 读 visibleTracks：删掉一首「新鲜」之后，配比本来就该跟着变。
        for track in visibleTracks {
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
        scene: String? = nil,
        rating: String? = nil,
        removedCount: Int = 0,
        pipelineVersion: Int = 0,
        promptVersion: Int = 0,
        modelID: String? = nil,
        diagnosticsJSON: String? = nil,
        failureReason: String? = nil,
        ratedAt: Date? = nil
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
        self.rating = rating
        self.removedCount = removedCount
        self.pipelineVersion = pipelineVersion
        self.promptVersion = promptVersion
        self.modelID = modelID
        self.diagnosticsJSON = diagnosticsJSON
        self.failureReason = failureReason
        self.ratedAt = ratedAt
    }
}
