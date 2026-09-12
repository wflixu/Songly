//
//  Feedback.swift
//  Songly
//
//  用户反馈的两种粒度。
//
//  ⚠️ 名字陷阱：这里的「超赞」是**本 App 自己**的标记，存在本地库的
//  `tracksJSON` 里。它和 Apple Music 账号里那个 Love/Dislike 评分是**两套
//  互不相干的系统** —— MusicKit 根本不提供读写后者评分的 API。
//  写回 Apple Music 是另一条独立的、可失败的 REST 路径（见 MusicLibraryService）。
//

import Foundation

// MARK: - 单曲

/// 用户对**一首歌**的判定。
///
/// 只存在于本地记录里。`nil` 表示没表态 —— 绝大多数歌都是这个状态。
enum TrackVerdict: String, Codable, CaseIterable, Sendable {
    /// 超赞。表示「非常惊喜」，会让这个艺人在后续推荐里上浮。
    case loved
    /// 删除。从这份歌单的本地记录里去掉，并且**永久**不再推荐这首歌。
    case removed
}

// MARK: - 歌单

/// 用户对**一份歌单**的判断。
///
/// 刻意用「准不准」而不是「喜欢不喜欢」：我们真正想优化的是**推荐质量**，
/// 而不是这份歌单好不好听 —— 后者会诱导用户评价音乐本身，前者才对应
/// 「下次该不该换个方向」。
enum PlaylistRating: String, Codable, CaseIterable, Sendable {
    case accurate
    case mixed
    case off

    var displayName: String {
        switch self {
        case .accurate: return "很准"
        case .mixed:    return "一般"
        case .off:      return "不准"
        }
    }
}
