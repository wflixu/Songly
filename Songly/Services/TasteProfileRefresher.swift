//
//  TasteProfileRefresher.swift
//  Songly
//
//  口味画像的**生成**入口。
//
//  刻意挂在 App 进前台时而不是推荐流程里：画像重算是一次完整的 LLM 调用，
//  塞进推荐流程会让"刷新日"的总耗时冲到 100–165 秒 —— 那是用户唯一会察觉到的
//  一天。放在前台做，推荐流程永远只用已经算好的画像。
//

import Foundation
import MusicKit

@MainActor
final class TasteProfileRefresher {
    private let musicKit: MusicKitServiceProtocol
    private let llm: LLMServiceProtocol
    private let store: TasteProfileStore

    /// 同一进程内不重复触发。
    private var isRunning = false

    init(
        musicKit: MusicKitServiceProtocol,
        llm: LLMServiceProtocol,
        store: TasteProfileStore = TasteProfileStore()
    ) {
        self.musicKit = musicKit
        self.llm = llm
        self.store = store
    }

    /// 需要的话重算一次画像。任何失败都静默略过 ——
    /// 画像只是让推荐更好，不值得为它打断用户。
    func refreshIfNeeded() async {
        guard !isRunning else { return }
        guard musicKit.authorizationStatus() == .authorized else { return }

        isRunning = true
        defer { isRunning = false }

        guard let songs = try? await musicKit.fetchLibrarySongs(
            limit: AppConfig.maxLibrarySongs, since: nil
        ), !songs.isEmpty else { return }

        let fingerprint = LibraryFingerprint.make(from: songs.map { $0.id.rawValue })
        let existing = store.load()

        guard TasteProfileStore.shouldRefresh(
            existing: existing, libraryFingerprint: fingerprint
        ) else { return }

        let recentlyPlayed = (try? await musicKit.fetchRecentlyPlayedSongs(
            limit: AppConfig.recentlyPlayedLimit
        )) ?? []
        let topPlayed = (try? await musicKit.fetchTopPlayedSongs(
            limit: AppConfig.topPlayedLimit
        )) ?? []

        let payload: TasteProfilePayload
        do {
            payload = try await llm.requestTasteProfile(
                system: PromptBuilderV3.tasteProfileSystem,
                userMessage: PromptBuilderV3.tasteProfileUserMessage(
                    stats: LibraryStats(snapshot: songs.map(Self.snapshot)),
                    librarySample: PromptBuilderV3.sampleLibrary(
                        songs.map { PromptTrack(title: $0.title, artist: $0.artistName, playCount: $0.playCount) }
                    ),
                    recentlyPlayed: recentlyPlayed.map { PromptTrack(title: $0.title, artist: $0.artistName) },
                    topPlayed: topPlayed.map { PromptTrack(title: $0.title, artist: $0.artistName) }
                )
            )
        } catch {
            // 画像失败本身不该打断用户（这是本文件顶部立下的取舍，保持不变），
            // 但**必须让设置页能如实说一句**。这里的 print 不加 `#if DEBUG`：
            // 本仓库已有 Release 下无条件打印的先例（`SonglyApp.swift` 的
            // BGTaskScheduler 那几处），而这是一次性的失败信号，与
            // `RecommendationEngine.logDiagnostics` 那种每轮都打的诊断性质不同。
            print("[Songly] 画像生成失败：\(error.localizedDescription)")
            NotificationCenter.default.post(
                name: .tasteProfileRefreshFailed,
                object: nil,
                userInfo: ["message": error.localizedDescription]
            )
            return
        }

        store.save(store.makeProfile(
            payload: payload,
            libraryFingerprint: fingerprint,
            previous: existing
        ))

        #if DEBUG
        print("[Songly] 口味画像已更新到 v\((existing?.version ?? 0) + 1)")
        #endif
    }

    private static func snapshot(_ song: Song) -> LibraryTrackSnapshot {
        LibraryTrackSnapshot(
            title: song.title,
            artist: song.artistName,
            genreNames: song.genreNames,
            releaseYear: song.releaseDate.map { Calendar.current.component(.year, from: $0) },
            playCount: song.playCount
        )
    }
}
