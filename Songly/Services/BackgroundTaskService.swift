//
//  BackgroundTaskService.swift
//  Songly
//
//  Registers and schedules BGAppRefreshTask for daily recommendation.
//

import Foundation
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
            self?.handleDailyTask(task as! BGAppRefreshTask)
        }
    }

    func schedule() {
        // Calculate tomorrow 6:00 AM
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        components.year = Calendar.current.component(.year, from: tomorrow)
        components.month = Calendar.current.component(.month, from: tomorrow)
        components.day = Calendar.current.component(.day, from: tomorrow)
        components.hour = 6
        components.minute = 0

        let request = BGAppRefreshTaskRequest(identifier: AppConfig.bgTaskIdentifier)
        request.earliestBeginDate = Calendar.current.date(from: components)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected on simulator; log on device
            print("[Songly] BGTask schedule failed: \(error.localizedDescription)")
        }
    }

    private func handleDailyTask(_ task: BGAppRefreshTask) {
        schedule()

        let engine = self.engine

        task.expirationHandler = {
            Task { await engine.cancel() }
        }

        Task {
            await engine.runDailyRecommendation { state in
                if case .completed = state {
                    task.setTaskCompleted(success: true)
                } else if case .error = state {
                    task.setTaskCompleted(success: false)
                }
            }
        }
    }
}
