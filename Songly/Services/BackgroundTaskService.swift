//
//  BackgroundTaskService.swift
//  Songly
//
//  Registers and schedules a BGProcessingTask for overnight daily recommendation.
//  Note: background tasks are best-effort — `earliestBeginDate` is a floor, the
//  OS decides the actual run time. The manual button is the fallback path.
//

import Foundation
import MusicKit
@preconcurrency import BackgroundTasks

final class BackgroundTaskService {
    private let engine: RecommendationEngine

    init(engine: RecommendationEngine) {
        self.engine = engine
    }

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppConfig.bgTaskIdentifier,
            using: nil
        ) { [weak self] task in
            // Must match the request type (BGProcessingTask), else the
            // force-cast below traps when the task actually launches.
            self?.handleDailyTask(task as! BGProcessingTask)
        }
    }

    func schedule() {
        // Can't prompt for Music authorization from a background context, so only
        // schedule once the user is already authorized.
        guard MusicAuthorization.currentStatus == .authorized else { return }

        // Overnight slot: earliest 2:00 AM (best-effort, OS decides actual time).
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        var components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        components.hour = 2
        components.minute = 0

        let request = BGProcessingTaskRequest(identifier: AppConfig.bgTaskIdentifier)
        request.earliestBeginDate = calendar.date(from: components)
        request.requiresNetworkConnectivity = true
        // Setting requiresExternalPower would maximize the chance the system runs
        // it overnight (charging) at the cost of not running when unplugged.
        // request.requiresExternalPower = true

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected on simulator; log on device.
            print("[Songly] BGTask schedule failed: \(error.localizedDescription)")
        }
    }

    private func handleDailyTask(_ task: BGProcessingTask) {
        schedule()

        let engine = self.engine

        task.expirationHandler = {
            Task { await engine.cancel() }
        }

        Task {
            await engine.runDailyRecommendation { state in
                if case .completed = state {
                    // Let the foreground UI refresh even if the app was open.
                    NotificationCenter.default.post(name: .recommendationDidComplete, object: nil)
                    task.setTaskCompleted(success: true)
                } else if case .error = state {
                    task.setTaskCompleted(success: false)
                }
            }
        }
    }
}
