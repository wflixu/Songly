//
//  UserPreferences.swift
//  Songly
//
//  SwiftData model for user-level preferences (singleton entity).
//

import Foundation
import SwiftData

@Model
final class UserPreferences {
    var id: UUID
    /// 用户偏好风格（Phase 2 启用，MVP 预留）。
    var favoriteGenres: [String]
    /// 上次同步 Apple Music 收藏的时间（增量更新依据）。
    var lastSyncDate: Date?
    /// 累计推荐次数。
    var totalRecommendations: Int

    init() {
        self.id = UUID()
        self.favoriteGenres = []
        self.lastSyncDate = nil
        self.totalRecommendations = 0
    }
}
