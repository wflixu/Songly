//
//  NotificationService.swift
//  Songly
//
//  Local notification management for recommendation readiness.
//

import Foundation
import UserNotifications

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
