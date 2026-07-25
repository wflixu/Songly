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

    // MARK: - Init

    init(
        date: Date,
        strategy: String,
        songCount: Int,
        tracks: [TrackInfo],
        source: String,
        quickPickStyle: String? = nil,
        playlistName: String? = nil
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
    }
}
