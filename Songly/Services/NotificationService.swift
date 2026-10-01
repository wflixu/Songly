//
//  NotificationService.swift
//  Songly
//
//  Local notification management for recommendation readiness.
//

import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted when a background daily recommendation completes, so the
    /// foreground UI (HomeViewModel) can reload today's record.
    static let recommendationDidComplete = Notification.Name("cn.wflixu.Songly.recommendationDidComplete")

    /// Posted when a record is deleted from the detail view.
    ///
    /// `PlaylistHistoryView` 用 `@Query` 驱动，会自动更新；而首页的
    /// `recentRecords` 是手动 fetch 的，需要这声通知才不会留下一行幽灵。
    static let recommendationRecordDeleted = Notification.Name("cn.wflixu.Songly.recommendationRecordDeleted")

    /// Posted when the taste-profile refresh fails, so the settings page can say
    /// why the profile stopped updating.
    ///
    /// 原先这条路径在 Release 下只剩下一个 `#if DEBUG` 的 print：一个 Key 失效的
    /// 用户只会发现「口味画像永远停在某一版」，而设置页显示的是「已配置」——
    /// 他没有任何线索能把这两件事联系起来。
    static let tasteProfileRefreshFailed = Notification.Name("cn.wflixu.Songly.tasteProfileRefreshFailed")
}

@MainActor
final class NotificationService: Sendable {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()

    private init() {}

    /// Request notification permission.
    func requestPermission() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Send a "recommendation ready" local notification.
    func sendRecommendationReady(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "🎵 今日推荐已就绪！"
        content.body = "\(count) 首新歌等你来听"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "cn.wflixu.Songly.daily-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )

        try? await center.add(request)
    }
}
