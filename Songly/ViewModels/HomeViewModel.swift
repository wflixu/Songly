//
//  HomeViewModel.swift
//  Songly
//
//  @Observable @MainActor: bridges RecommendationEngine → HomeView.
//

import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class HomeViewModel {
    private(set) var state: RecommendationState = .idle
    private(set) var todayRecord: RecommendationRecord?
    private(set) var totalRecommendations: Int = 0
    private(set) var isOffline: Bool = false

    private let engine: RecommendationEngine
    private let networkMonitor: NetworkMonitor

    var isLoading: Bool {
        switch state {
        case .idle, .completed, .error, .onboarding:
            return false
        default:
            return true
        }
    }

    var canTrigger: Bool {
        if case .idle = state { return true }
        if case .completed = state { return true }
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

    init(engine: RecommendationEngine, networkMonitor: NetworkMonitor) {
        self.engine = engine
        self.networkMonitor = networkMonitor

        Task {
            await checkToday()
        }
    }

    func checkToday() async {
        let has = await engine.hasTodayRecommendation()
        if has {
            todayRecord = loadTodayRecord()
        }
    }

    func triggerDailyRecommendation() {
        guard canTrigger, !isOffline else { return }
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
        // Query from SwiftData — simplest approach
        return nil
    }
}
