//
//  MusicKitService.swift
//  Songly
//
//  MusicKit integration — authorization, library reading, catalog search.
//

import Foundation
import MusicKit

// MARK: - Protocol

protocol MusicKitServiceProtocol: Sendable {
    /// Get current authorization status (live query, no caching).
    func authorizationStatus() -> MusicAuthorization.Status

    /// Request authorization. Only shows system dialog when .notDetermined.
    func requestAuthorization() async -> MusicAuthorization.Status

    /// Fetch user's library songs with incremental sync support.
    /// - Parameters:
    ///   - limit: Maximum songs for full fetch.
    ///   - lastSync: If non-nil, only fetch songs added after this date.
    func fetchLibrarySongs(limit: Int, since lastSync: Date?) async throws -> [Song]

    /// Fetch the user's recently played songs (track-level).
    /// - Note: Runtime may return empty for non-subscribers / fresh accounts;
    ///   callers must degrade gracefully (treat as empty).
    func fetchRecentlyPlayedSongs(limit: Int) async throws -> [Song]

    /// Fetch the user's most-played library songs.
    /// - Note: Returns `[]` when no play-count data is available (never inject noise).
    func fetchTopPlayedSongs(limit: Int) async throws -> [Song]

    // MARK: - Catalog Resolution (v3)

    /// 解析一首**具体的**曲目。歌名与艺人**都要**通过校验才会返回。
    ///
    /// 这是对旧 `searchTrack` 实现的修正：它前两层直接取 Apple 返回的第一条、
    /// 不做任何校验，于是一个错误的猜测会静默匹配到一首完全不相干的歌 ——
    /// 而且用户无从察觉，因为歌单里显示的本来就是它猜错的名字。
    func resolveTrack(title: String, artist: String, album: String?) async throws -> Song?

    /// 取一张专辑的曲目列表。
    func albumSongs(artist: String, album: String, limit: Int) async throws -> [Song]

    /// 按艺人取曲目 —— 专辑扩展失败时的降级路径。
    ///
    /// 这条路径是改造前就在用、确定可用的（`MusicCatalogSearchRequest` + 艺人校验），
    /// 所以专辑扩展是**增强**而不是单点依赖。
    func searchArtistSongs(artist: String, limit: Int) async throws -> [Song]
}

// MARK: - Implementation

final class MusicKitService: MusicKitServiceProtocol {
    func authorizationStatus() -> MusicAuthorization.Status {
        MusicAuthorization.currentStatus
    }

    func requestAuthorization() async -> MusicAuthorization.Status {
        let current = MusicAuthorization.currentStatus
        if current == .notDetermined {
            return await MusicAuthorization.request()
        }
        return current
    }

    func fetchLibrarySongs(limit: Int, since lastSync: Date?) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.limit = limit

        // Sort by date added (newest first) and filter incrementally
        let response = try await request.response()
        var songs = Array(response.items)

        // Apply incremental filter if we have a last sync date
        if let lastSync {
            // MusicLibraryRequest doesn't support date filtering natively,
            // so we fetch all and filter client-side. For MVP volumes this is fine.
            songs = songs.filter { song in
                // Note: Song doesn't expose a 'dateAdded' property directly in
                // the modern MusicKit API. We do a full fetch for MVP and rely
                // on the caller to handle dedup via lastSyncDate.
                return true
            }
            // FIXME: When MusicKit API stabilizes, add proper incremental filtering.
        }

        return songs
    }

    func fetchRecentlyPlayedSongs(limit: Int) async throws -> [Song] {
        var request = MusicRecentlyPlayedRequest<Song>()
        request.limit = limit
        let response = try await request.response()
        return Array(response.items)
    }

    func fetchTopPlayedSongs(limit: Int) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.limit = AppConfig.maxLibrarySongs
        // Server-side sort by play count — the limit is applied after sorting.
        request.sort(by: \.playCount, ascending: false)
        let response = try await request.response()
        let items = Array(response.items)
        // Degrade to [] when no play-count data at all, rather than injecting
        // arbitrary songs labeled as "most played".
        guard items.contains(where: { $0.playCount != nil }) else { return [] }
        // Client-side tie-break for deterministic ordering of nil playCounts.
        let sorted = items.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        return Array(sorted.prefix(limit))
    }

    // MARK: - Catalog Resolution (v3)

    /// 艺名匹配阈值。用字符集 Jaccard 距离，0 = 完全相同。
    static let artistMatchThreshold = 0.5

    /// 歌名 / 专辑名**完全相等**时用的宽松阈值。
    ///
    /// 字符集 Jaccard 对中文的写法差异极其敏感：「周杰倫」和「周杰伦」就有 0.5 的
    /// 距离，「G.E.M. 邓紫棋」和「邓紫棋」有 0.7 —— 这些全是**同一个人**，却会被
    /// 上一档阈值当成错误匹配拒掉。而如果作品名一模一样，几乎不可能是别的作品，
    /// 此时艺人的写法差异不该成为否决理由。
    static let artistMatchRelaxed = 0.85

    func resolveTrack(title: String, artist: String, album: String?) async throws -> Song? {
        var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [Song.self])
        request.limit = 10
        let response = try await request.response()

        let titleKey = normalizedKey(title)
        let candidates = response.songs.filter { song in
            let songTitle = normalizedKey(song.title)
            guard Self.fuzzyEqual(songTitle, titleKey) else { return false }
            let distance = artistDistance(song.artistName, artist)
            // 作品名完全一致 → 艺人写法差异不否决。
            if songTitle == titleKey, distance < Self.artistMatchRelaxed { return true }
            return distance < Self.artistMatchThreshold
        }
        guard !candidates.isEmpty else { return nil }

        // 有专辑名时用它消歧 —— 同名的现场版 / 精选版靠这一层区分。
        if let album {
            let albumKey = normalizedKey(album)
            if let matched = candidates.first(where: {
                guard let songAlbum = $0.albumTitle else { return false }
                return Self.fuzzyEqual(normalizedKey(songAlbum), albumKey)
            }) {
                return matched
            }
        }

        return candidates.first
    }

    func albumSongs(artist: String, album: String, limit: Int) async throws -> [Song] {
        var request = MusicCatalogSearchRequest(term: "\(artist) \(album)", types: [Song.self])
        request.limit = min(max(limit, 1), 25)
        let response = try await request.response()
        let songs = Array(response.songs)
        guard !songs.isEmpty else { return [] }

        // 逐级放宽，**绝不在校验失败时丢掉整批** —— 丢一批的代价是一条 seed
        // 白白失败，而失败会让歌单凑不够数。

        // 1. 专辑名对得上就用（艺人不再否决，只影响不排序）。
        let albumKey = normalizedKey(album)
        let onAlbum = songs.filter { song in
            guard let songAlbum = song.albumTitle else { return false }
            return Self.fuzzyEqual(normalizedKey(songAlbum), albumKey)
        }
        if !onAlbum.isEmpty { return onAlbum }

        // 2. 专辑名都没对上，退到"艺人名对得上"。
        let byArtist = songs.filter {
            artistDistance($0.artistName, artist) < Self.artistMatchRelaxed
        }
        if !byArtist.isEmpty { return byArtist }

        // 3. 最后兜底：搜索词本身就是「艺人 + 专辑」，直接信任搜索结果。
        //    真机实测发现前两层叠加会把解析率打到 10% —— 一条 seed 的成本
        //    远高于偶尔混进一首不完全对口的曲目。
        return songs
    }

    func searchArtistSongs(artist: String, limit: Int) async throws -> [Song] {
        var request = MusicCatalogSearchRequest(term: artist, types: [Song.self])
        request.limit = min(max(limit, 1), 25)
        let response = try await request.response()
        let songs = Array(response.songs)

        let byArtist = songs.filter {
            artistDistance($0.artistName, artist) < Self.artistMatchRelaxed
        }
        // 同样兜底：搜索词就是艺人名，不必因为写法差异把整批丢掉。
        return byArtist.isEmpty ? songs : byArtist
    }

    // MARK: - Private Helpers

    /// 归一化后相等，或一方包含另一方（处理「歌名 (Remastered)」这类后缀）。
    static func fuzzyEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs)
    }

    /// Simple Levenshtein-like distance normalized to [0, 1].
    private func artistDistance(_ a: String, _ b: String) -> Double {
        let aLower = a.lowercased().trimmingCharacters(in: .whitespaces)
        let bLower = b.lowercased().trimmingCharacters(in: .whitespaces)
        if aLower == bLower { return 0 }
        if aLower.contains(bLower) || bLower.contains(aLower) { return 0.1 }
        // Simplified: character set overlap ratio
        let setA = Set(aLower)
        let setB = Set(bLower)
        let intersection = setA.intersection(setB)
        let union = setA.union(setB)
        guard !union.isEmpty else { return 1.0 }
        return 1.0 - Double(intersection.count) / Double(union.count)
    }
}
