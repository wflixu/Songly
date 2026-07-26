//
//  RecommendationEngine.swift
//  Songly
//
//  Actor that orchestrates the full recommendation pipeline:
//  Auth → Library → Prompt → LLM → Search → Persist → Playlist → Notify
//

import Foundation
import SwiftData
import MusicKit

// MARK: - Errors

enum EngineError: LocalizedError {
    case notAuthorized
    case emptyLibrary
    case tooFewRecommendations(count: Int)
    case noMatches

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "需要 Apple Music 访问权限"
        case .emptyLibrary: return "收藏列表为空"
        case .tooFewRecommendations(let c): return "推荐结果不足 (仅 \(c) 首)"
        case .noMatches: return "未能匹配到歌曲"
        }
    }
}

// MARK: - Engine

actor RecommendationEngine {
    private let musicKitService: MusicKitServiceProtocol
    private let llmService: LLMService
    private let playlistService: PlaylistServiceProtocol
    private let modelContainer: ModelContainer

    private var isRunning = false
    private var currentTask: Task<Void, Never>?

    init(
        musicKitService: MusicKitServiceProtocol,
        llmService: LLMService,
        playlistService: PlaylistServiceProtocol,
        modelContainer: ModelContainer
    ) {
        self.musicKitService = musicKitService
        self.llmService = llmService
        self.playlistService = playlistService
        self.modelContainer = modelContainer
    }

    // MARK: - Public

    func hasTodayRecommendation() async -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let predicate = #Predicate<RecommendationRecord> { record in
            record.date >= today && record.date < tomorrow
        }

        let descriptor = FetchDescriptor<RecommendationRecord>(predicate: predicate)
        return await MainActor.run {
            let context = modelContainer.mainContext
            return (try? context.fetchCount(descriptor)) ?? 0 > 0
        }
    }

    func runDailyRecommendation(
        onStateChange: @escaping @Sendable (RecommendationState) -> Void
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let task = Task {
            await _runPipeline(
                strategy: .styleExploration,
                quickPickStyle: nil,
                source: "daily",
                onStateChange: onStateChange
            )
        }
        currentTask = task
        await task.value
    }

    func runQuickPickRecommendation(
        style: QuickPickStyle,
        onStateChange: @escaping @Sendable (RecommendationState) -> Void
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let task = Task {
            await _runPipeline(
                strategy: .styleExploration,
                quickPickStyle: style,
                source: "quick_pick",
                onStateChange: onStateChange
            )
        }
        currentTask = task
        await task.value
    }

    func cancel() {
        currentTask?.cancel()
        isRunning = false
    }

    // MARK: - Private Pipeline

    private func _runPipeline(
        strategy: RecommendationStrategy,
        quickPickStyle: QuickPickStyle?,
        source: String,
        onStateChange: @escaping @Sendable (RecommendationState) -> Void
    ) async {
        let reportState = { @MainActor @Sendable state in
            onStateChange(state)
        }

        // Step 1: Authorization
        let currentStatus = musicKitService.authorizationStatus()
        if currentStatus == .authorized {
            // Proceed
        } else if currentStatus == .notDetermined {
            let status = await musicKitService.requestAuthorization()
            if status != .authorized {
                await reportState(.error(message: "需要 Music 访问权限", retryable: false))
                return
            }
        } else {
            await reportState(.error(message: "请在设置中开启 Apple Music 访问权限", retryable: false))
            return
        }

        // Step 2: Fetch library (incremental)
        await reportState(.readingLibrary)
        let lastSyncDate = await fetchLastSyncDate()
        let songs: [Song]
        do {
            songs = try await musicKitService.fetchLibrarySongs(
                limit: AppConfig.maxLibrarySongs,
                since: lastSyncDate
            )
        } catch {
            await reportState(.error(message: "读取收藏失败", retryable: true))
            return
        }

        guard !songs.isEmpty else {
            await reportState(.error(message: "收藏列表为空", retryable: false))
            return
        }

        // Update lastSyncDate
        await updateLastSyncDate()

        // Step 3: Build prompt
        let history = await fetchHistoryTrackNames()
        let prompt = PromptBuilder.build(
            strategy: strategy,
            songs: songs,
            history: history,
            quickPickStyle: quickPickStyle
        )

        // Step 4: LLM
        await reportState(.generating(progress: "正在分析你的音乐品味..."))
        let recommendations: [TrackItem]
        do {
            recommendations = try await llmService.recommend(prompt: prompt)
        } catch {
            let isKeyError = (error as? LLMServiceError).map {
                if case .apiKeyNotConfigured = $0 { return true }
                return false
            } ?? false
            await reportState(.error(
                message: error.localizedDescription,
                retryable: !isKeyError
            ))
            return
        }

        guard recommendations.count >= AppConfig.minTrackCount else {
            await reportState(.error(message: "推荐结果不足，请稍后重试", retryable: true))
            return
        }

        // Step 5: Concurrent catalog search
        await reportState(.searchingCatalog(found: 0, total: recommendations.count))
        let (matchedTracks, matchedSongs) = await searchCatalog(recommendations, reportState: reportState)

        let matchRate = Double(matchedTracks.count) / Double(recommendations.count)
        guard !matchedTracks.isEmpty else {
            await reportState(.error(message: "未能匹配到歌曲，请稍后重试", retryable: true))
            return
        }
        if matchRate < AppConfig.matchRateThreshold {
            await reportState(.error(
                message: "仅匹配到 \(matchedTracks.count)/\(recommendations.count) 首",
                retryable: true
            ))
            return
        }

        // Step 6: Persist record FIRST (via MainActor)
        await reportState(.persistingRecord)
        let dateString = Date().chineseDateString

        let playlistName: String
        let playlistDesc: String
        if let style = quickPickStyle {
            playlistName = "\(style.emoji) \(style.rawValue)精选 · \(dateString)"
            playlistDesc = "基于你的收藏，AI 为你生成的 \(style.rawValue)歌单"
        } else {
            playlistName = "🎵 每日推荐 · \(dateString)"
            playlistDesc = "基于你的收藏，AI 为你生成的今日个性化歌单"
        }

        let saveSuccess = await saveRecommendation(
            date: Date(),
            strategy: strategy.rawValue,
            songCount: matchedTracks.count,
            tracks: matchedTracks,
            source: source,
            quickPickStyle: quickPickStyle?.rawValue,
            playlistName: playlistName
        )
        guard saveSuccess else {
            await reportState(.error(message: "数据保存失败，请稍后重试", retryable: true))
            return
        }

        // Step 7: Create playlist
        await reportState(.creatingPlaylist)
        let playlist: Playlist
        do {
            playlist = try await playlistService.createPlaylist(
                name: playlistName,
                description: playlistDesc,
                songs: matchedSongs
            )
        } catch {
            // Rollback: delete persisted record
            _ = await deleteRecommendation(date: Date())
            await reportState(.error(message: "播放列表创建失败", retryable: true))
            return
        }

        // Step 8: Done
        await reportState(.completed(trackCount: matchedTracks.count, playlistName: playlist.name))

        // Step 9: Notify
        await NotificationService.shared.sendRecommendationReady(count: matchedTracks.count)
    }

    // MARK: - Catalog Search (TaskGroup)

    private struct CatalogMatch {
        let info: TrackInfo
        let song: Song
    }

    private func searchCatalog(
        _ tracks: [TrackItem],
        reportState: @escaping @Sendable @MainActor (RecommendationState) -> Void
    ) async -> (infos: [TrackInfo], songs: [Song]) {
        var infos: [TrackInfo] = []
        var songs: [Song] = []
        let total = tracks.count

        await withTaskGroup(of: CatalogMatch?.self) { group in
            var running = 0

            for track in tracks {
                if running >= AppConfig.searchConcurrency {
                    if let result = await group.next(), let match = result {
                        infos.append(match.info)
                        songs.append(match.song)
                        await reportState(.searchingCatalog(found: infos.count, total: total))
                    }
                }

                group.addTask { [musicKitService] in
                    if let song = try? await musicKitService.searchTrack(
                        title: track.title,
                        artist: track.artist
                    ) {
                        return CatalogMatch(
                            info: TrackInfo(id: song.id.rawValue, name: track.title, artist: track.artist),
                            song: song
                        )
                    }
                    return nil
                }
                running += 1
            }

            for await result in group {
                if let match = result {
                    infos.append(match.info)
                    songs.append(match.song)
                    await reportState(.searchingCatalog(found: infos.count, total: total))
                }
            }
        }

        return (infos, songs)
    }

    // MARK: - SwiftData Helpers (MainActor-isolated, Sendable-only params)

    @MainActor
    private func fetchLastSyncDate() -> Date? {
        let context = modelContainer.mainContext
        let results = try? context.fetch(FetchDescriptor<UserPreferences>())
        return results?.first?.lastSyncDate
    }

    @MainActor
    private func updateLastSyncDate() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<UserPreferences>()
        if let prefs = try? context.fetch(descriptor).first {
            prefs.lastSyncDate = Date()
        } else {
            let newPrefs = UserPreferences()
            newPrefs.lastSyncDate = Date()
            context.insert(newPrefs)
        }
        try? context.save()
    }

    @MainActor
    private func fetchHistoryTrackNames() -> [String] {
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<RecommendationRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 30
        let records = (try? context.fetch(descriptor)) ?? []
        return records.flatMap(\.trackNames)
    }

    @MainActor
    private func saveRecommendation(
        date: Date,
        strategy: String,
        songCount: Int,
        tracks: [TrackInfo],
        source: String,
        quickPickStyle: String?,
        playlistName: String?
    ) -> Bool {
        let context = modelContainer.mainContext
        let record = RecommendationRecord(
            date: date,
            strategy: strategy,
            songCount: songCount,
            tracks: tracks,
            source: source,
            quickPickStyle: quickPickStyle,
            playlistName: playlistName
        )
        context.insert(record)
        do {
            try context.save()
            return true
        } catch {
            return false
        }
    }

    @MainActor
    private func deleteRecommendation(date: Date) -> Bool {
        let context = modelContainer.mainContext
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!

        let predicate = #Predicate<RecommendationRecord> { record in
            record.date >= start && record.date < end
        }
        let descriptor = FetchDescriptor<RecommendationRecord>(predicate: predicate)
        if let record = try? context.fetch(descriptor).first {
            context.delete(record)
            try? context.save()
            return true
        }
        return false
    }
}
