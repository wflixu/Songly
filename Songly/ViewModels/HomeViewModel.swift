//
//  HomeViewModel.swift
//  Songly
//
//  @Observable @MainActor: bridges RecommendationEngine → HomeView.
//

import Foundation
import SwiftUI
import Observation
import SwiftData

@MainActor
@Observable
final class HomeViewModel {
    private(set) var state: RecommendationState = .idle
    private(set) var todayRecord: RecommendationRecord?
    private(set) var totalRecommendations: Int = 0
    private(set) var isOffline: Bool = false

    private let engine: RecommendationEngine
    private let networkMonitor: NetworkMonitor
    private let modelContainer: ModelContainer

    var isLoading: Bool {
        switch state {
        case .idle, .completed, .error, .onboarding:
            return false
        default:
            return true
        }
    }

    var canTrigger: Bool {
        // Only allow when idle — never after completion.
        guard !isOffline else { return false }
        if case .idle = state { return true }
        return errorRetryable
    }

    var errorRetryable: Bool {
        if case .error(_, let retryable) = state {
            return retryable
        }
        return false
    }

    /// Expose engine for QuickPickViewModel injection.
    nonisolated var engineRef: RecommendationEngine { engine }

    init(engine: RecommendationEngine, networkMonitor: NetworkMonitor, modelContainer: ModelContainer) {
        self.engine = engine
        self.networkMonitor = networkMonitor
        self.modelContainer = modelContainer

        Task {
            await restoreTodayState()
        }
    }

    /// If a recommendation was already completed today, restore the UI state.
    private func restoreTodayState() async {
        guard let record = loadTodayRecord() else { return }
        todayRecord = record
        totalRecommendations = (try? modelContainer.mainContext.fetchCount(
            FetchDescriptor<RecommendationRecord>()
        )) ?? 0
        let name = record.playlistName ?? "今日推荐"
        state = .completed(trackCount: record.songCount, playlistName: name)
    }

    func triggerDailyRecommendation() {
        guard canTrigger, !isOffline else { return }
        startRecommendation()
    }

    func forceRegenerate() {
        guard !isOffline else { return }
        // Delete today's record so the new one replaces it
        if let record = loadTodayRecord() {
            modelContainer.mainContext.delete(record)
            try? modelContainer.mainContext.save()
        }
        startRecommendation()
    }

    private func startRecommendation() {
        state = .readingLibrary
        Task {
            await engine.runDailyRecommendation { [weak self] nextState in
                Task { @MainActor in
                    self?.state = nextState
                    if case .completed = nextState {
                        self?.todayRecord = self?.loadTodayRecord()
                        self?.totalRecommendations += 1
                    }
                }
            }
        }
    }

    private func loadTodayRecord() -> RecommendationRecord? {
        let context = modelContainer.mainContext
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let predicate = #Predicate<RecommendationRecord> { record in
            record.date >= today && record.date < tomorrow
        }
        var descriptor = FetchDescriptor<RecommendationRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
