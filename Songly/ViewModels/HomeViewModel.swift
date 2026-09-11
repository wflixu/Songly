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
    private(set) var recentRecords: [RecommendationRecord] = []

    /// Controls the style picker sheet presentation.
    var showStylePicker = false

    private let engine: RecommendationEngine
    private let networkMonitor: NetworkMonitor
    private let modelContainer: ModelContainer
    private var completionObserver: NSObjectProtocol?

    var isLoading: Bool {
        switch state {
        case .idle, .completed, .error, .onboarding:
            return false
        default:
            return true
        }
    }

    var canTrigger: Bool {
        guard !isOffline else { return false }
        return !isLoading
    }

    /// Expose engine for external access.
    nonisolated var engineRef: RecommendationEngine { engine }

    init(engine: RecommendationEngine, networkMonitor: NetworkMonitor, modelContainer: ModelContainer) {
        self.engine = engine
        self.networkMonitor = networkMonitor
        self.modelContainer = modelContainer

        // Refresh the foreground UI if a background recommendation completes
        // while the app is open (e.g. left open overnight).
        completionObserver = NotificationCenter.default.addObserver(
            forName: .recommendationDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reloadAfterBackgroundCompletion() }
        }

        Task {
            await restoreTodayState()
            await loadRecentRecords()
        }
    }

    /// Reload today's record + recent list after a background completion.
    private func reloadAfterBackgroundCompletion() async {
        todayRecord = loadTodayRecord()
        totalRecommendations = (try? modelContainer.mainContext.fetchCount(
            FetchDescriptor<RecommendationRecord>()
        )) ?? 0
        if let record = todayRecord {
            state = .completed(trackCount: record.songCount, playlistName: record.playlistName ?? "今日推荐")
        }
        await loadRecentRecords()
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

    /// Load recent records excluding today's for the preview section.
    func loadRecentRecords() async {
        let context = modelContainer.mainContext
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var descriptor = FetchDescriptor<RecommendationRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 10

        if let all = try? context.fetch(descriptor) {
            recentRecords = all.filter { !calendar.isDate($0.date, inSameDayAs: today) }.prefix(3).map { $0 }
        }
        totalRecommendations = (try? context.fetchCount(FetchDescriptor<RecommendationRecord>())) ?? 0
    }

    // MARK: - Daily (Direct) Recommendation

    func triggerDailyRecommendation() {
        guard canTrigger else { return }
        startRecommendation(source: "daily", quickPickStyle: nil)
    }

    // MARK: - Styled Recommendation

    func triggerStyledRecommendation(style: QuickPickStyle) {
        guard canTrigger else { return }
        startRecommendation(source: "quick_pick", quickPickStyle: style)
    }

    func forceRegenerate() {
        guard !isOffline else { return }
        if let record = loadTodayRecord() {
            modelContainer.mainContext.delete(record)
            try? modelContainer.mainContext.save()
        }
        startRecommendation(source: "daily", quickPickStyle: nil)
    }

    // MARK: - Private

    private func startRecommendation(source: String, quickPickStyle: QuickPickStyle?) {
        Task {
            let started: Bool
            if let style = quickPickStyle {
                started = await engine.runQuickPickRecommendation(style: style) { [weak self] nextState in
                    Task { @MainActor in self?.applyState(nextState) }
                }
            } else {
                started = await engine.runDailyRecommendation { [weak self] nextState in
                    Task { @MainActor in self?.applyState(nextState) }
                }
            }
            if !started {
                // The engine is busy (e.g. a background task is already running).
                // Don't silently swallow the tap — surface an in-progress state.
                state = .generating(progress: "正在后台生成，请稍候…")
            }
        }
    }

    private func applyState(_ nextState: RecommendationState) {
        state = nextState
        if case .completed = nextState {
            todayRecord = loadTodayRecord()
            totalRecommendations += 1
            Task { await loadRecentRecords() }
        }
    }

    private func loadTodayRecord() -> RecommendationRecord? {
        let context = modelContainer.mainContext
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        // Only a fully-completed `daily` record counts as "today done".
        // A `pending` record (persisted but playlist not yet created) must not
        // surface a phantom completed state.
        let predicate = #Predicate<RecommendationRecord> { record in
            record.date >= today && record.date < tomorrow
                && record.source == "daily"
                && record.status == "completed"
        }
        var descriptor = FetchDescriptor<RecommendationRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
