//
//  TrackItem.swift
//  Songly
//
//  Value types for representing music tracks in the recommendation pipeline.
//

import Foundation
import MusicKit

// MARK: - TrackInfo (persisted, codable)

/// A matched track stored in RecommendationRecord as JSON.
struct TrackInfo: Codable, Equatable, Sendable {
    /// Apple Music MusicItemID string.
    let id: String
    /// Song title.
    let name: String
    /// Artist name.
    let artist: String

    /// 专辑封面直链（160×160）。可选 —— 旧记录里没有，缺图时由
    /// `ArtworkThumbnail` 用品牌渐变占位。
    ///
    /// **必须是 `var` + 默认值，不能写成 `let artworkURL: String?`** ——
    /// `let` 带默认值会被排除出合成的 memberwise init，`CatalogResolver`
    /// 就永远设不进去；`var` 则保留为「带默认值的参数」，既能传，又让已有的
    /// `TrackInfo(id:name:artist:)` 调用点（含测试与 #Preview）全部继续编译。
    var artworkURL: String? = nil

    /// 这首歌是在哪一层被选中的（大概率喜欢 / 新鲜尝试 / 大胆探索）。
    /// 同样必须是 `var` + 默认值。旧记录解码后为 nil，不显示徽章。
    var tier: DiscoveryTier? = nil

    /// 这首歌在 Apple Music 里的规范链接（`Song.url`）。点一行跳过去要用它 ——
    /// 没有它，曲目行要么不可点、要么只能退化成打开 Music App 首页。
    var url: String? = nil
}

// MARK: - TrackItem (LLM response)

/// A track recommended by the LLM (before catalog matching).
struct TrackItem: Codable, Identifiable, Sendable {
    var id: String { "\(title)-\(artist)" }
    let title: String
    let artist: String
}

// MARK: - Dedup Matching (normalized title + artist)

/// Normalized key for dedup. Operates on freeform text on both sides, so it is
/// a *pre-filter* — the authoritative dedup happens on catalog `MusicItemID`
/// after matching.
struct TrackKey: Hashable, Sendable {
    let title: String
    let artist: String
}

/// Normalize a title/artist for fuzzy matching: trim, lowercase, strip
/// parenthetical notes, collapse whitespace.
func normalizedKey(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s*（[^）]*）"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}

extension TrackInfo {
    var key: TrackKey { TrackKey(title: normalizedKey(name), artist: normalizedKey(artist)) }
}

extension TrackItem {
    var key: TrackKey { TrackKey(title: normalizedKey(title), artist: normalizedKey(artist)) }
}

extension Song {
    var key: TrackKey { TrackKey(title: normalizedKey(title), artist: normalizedKey(artistName)) }
}
