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

    /// 用户对这首歌的判定（`.loved` / `.removed`）。`nil` = 未表态。
    ///
    /// 同样必须是 `var` + 默认值，理由见上面 `artworkURL` 的注释。
    /// 判定刻意存在 `tracksJSON` 里而**不是**另建一张表：不用碰 SwiftData
    /// schema（迁移风险直接消失），而且「撤销删除」天然可行 —— 把这个字段
    /// 清掉，歌就回到列表里，不必记住它原本属于哪份歌单。
    var verdict: TrackVerdict? = nil

    /// 判定写下的时刻。`nil` = 未表态，或表态已被撤销。
    ///
    /// 为什么需要它：在此之前，一个判定的先后只能靠「它在哪份记录里」间接推断
    /// （见 `FeedbackStore.derive()` 的「已按 date 降序 → 新的判定先到先得」）。
    /// 同一份歌单**之内**的先后则完全不可知 —— 而那正是「推荐后第几天才被收藏」
    /// 这类时间序列分析所依赖的东西。同样是 `var` + 默认值，零迁移。
    var verdictUpdatedAt: Date? = nil

    /// **我们**把这首歌加进用户资料库的时刻。`nil` = 我们没加过。
    ///
    /// 存在的理由是一个真实的漏洞：`love(_:)` 是 toggle，用户把三周前的「超赞」取消后
    /// `verdict` 变回 `nil`，但那首歌还在资料库里 —— 是**我们**放进去的。
    /// 没有这个字段，「他在资料库里」就会被误读成「他自己收藏的」，白送一个正向信号。
    ///
    /// 与 `verdict` 同一套路：`var` + 默认值，写在 `tracksJSON` 里，零 SwiftData 迁移。
    var librarySyncedAt: Date? = nil

    /// 他被发现从我们建的歌单里**自己删掉**了这首歌的时刻（隐式负面信号）。
    ///
    /// 必须持久化：不落盘的话，这条排除会在记录滚出回看窗口时蒸发 ——
    /// 那正是「删除应当永久生效」这条设计存在的意义。
    var implicitRemovedAt: Date? = nil
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
