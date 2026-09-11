//
//  CatalogResolver.swift
//  Songly
//
//  把 LLM 给出的「选曲线索」变成 Apple Music 曲库里真实存在的曲目。
//
//  这是 v3 相比旧流程最根本的一处倒置：
//    旧：LLM 凭记忆报歌名 → 拿去搜 → 搜到多少算多少（数量因此完全不可控）
//    新：LLM 指出方向 → 我们从曲库拉出**真实候选池** → 由确定性算法收敛
//
//  注意 Apple 在这条链路里只贡献**目录元数据**，不贡献任何推荐算法结果。
//

import Foundation
import MusicKit

// MARK: - Result

struct CatalogResolution: Sendable {
    var candidates: [ResolvedCandidate]
    /// 没能解析出来的 seed —— 会被回传给模型让它换方向，而不是静默丢弃。
    var failures: [FailedSeed]
    /// catalog ID → `Song`。建歌单需要真实的 `Song` 对象，而
    /// `ResolvedCandidate` 刻意不背着它 —— 那样 composer 就没法脱离 MusicKit 单测了。
    var songsByID: [String: Song]
    /// 实际走了多少条专辑扩展（用于诊断延迟）。
    var albumExpansions: Int
    /// 成功解析出**至少一首**曲目的 seed 数。
    ///
    /// 用它而不是"候选数"来算解析率：专辑扩展一条 seed 可以产出 2 首，
    /// 拿候选数当分子会得出大于 1 的比率，是个会误导人的指标。
    var seedsSucceeded: Int

    static let empty = CatalogResolution(
        candidates: [], failures: [], songsByID: [:],
        albumExpansions: 0, seedsSucceeded: 0
    )
}

protocol CatalogResolving: Sendable {
    func resolve(
        seeds: [RecommendationSeed],
        exclusions: PlaylistComposer.ExclusionSet,
        albumBudget: Int
    ) async -> CatalogResolution
}

// MARK: - Resolver

final class CatalogResolver: CatalogResolving {

    /// 一条 seed 的解析方式。
    enum Plan: Equatable, Sendable {
        case track
        /// 从专辑里挑 —— 这是唯一能主动挖到非主打歌的路径。
        case album
        /// 按艺人取曲目 —— 专辑路径失败或超出预算时的降级。
        case artist
    }

    private struct Outcome: Sendable {
        var candidates: [ResolvedCandidate] = []
        var songs: [String: Song] = [:]
        var failure: FailedSeed?
        var expandedAlbum = false
    }

    private let musicKit: MusicKitServiceProtocol
    private let concurrency: Int

    init(musicKit: MusicKitServiceProtocol, concurrency: Int = AppConfig.searchConcurrency) {
        self.musicKit = musicKit
        self.concurrency = max(1, concurrency)
    }

    func resolve(
        seeds: [RecommendationSeed],
        exclusions: PlaylistComposer.ExclusionSet,
        albumBudget: Int
    ) async -> CatalogResolution {
        let planned = plan(seeds, albumBudget: albumBudget)
        guard !planned.isEmpty else { return .empty }

        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(planned.count)

        await withTaskGroup(of: Outcome.self) { group in
            var running = 0
            for (seed, plan) in planned {
                if Task.isCancelled { break }
                if running >= concurrency, let outcome = await group.next() {
                    outcomes.append(outcome)
                }
                group.addTask { [musicKit] in
                    if Task.isCancelled {
                        return Outcome(failure: FailedSeed(
                            artist: seed.artist, title: seed.title,
                            album: seed.album, reason: "cancelled"
                        ))
                    }
                    return await Self.resolveOne(
                        seed, plan: plan, musicKit: musicKit, exclusions: exclusions
                    )
                }
                running += 1
            }

            for await outcome in group {
                outcomes.append(outcome)
            }
        }

        var candidates: [ResolvedCandidate] = []
        var songsByID: [String: Song] = [:]
        var failures: [FailedSeed] = []
        var albumExpansions = 0

        for outcome in outcomes {
            candidates.append(contentsOf: outcome.candidates)
            songsByID.merge(outcome.songs) { existing, _ in existing }
            if let failure = outcome.failure { failures.append(failure) }
            if outcome.expandedAlbum { albumExpansions += 1 }
        }

        return CatalogResolution(
            candidates: candidates,
            failures: failures,
            songsByID: songsByID,
            albumExpansions: albumExpansions,
            seedsSucceeded: outcomes.count - failures.count
        )
    }

    // MARK: - Planning

    /// 决定每条 seed 走哪条路径，并在这里就把专辑扩展的预算分完。
    ///
    /// 预算**先到先得**而不是靠运行时共享计数器 —— 后者要在并发里协调可变状态，
    /// 换来的只是"哪条 seed 抢到预算"的不确定性。
    func plan(_ seeds: [RecommendationSeed], albumBudget: Int) -> [(RecommendationSeed, Plan)] {
        var remaining = max(0, albumBudget)
        var seen = Set<String>()
        var planned: [(RecommendationSeed, Plan)] = []

        for seed in seeds {
            // 同一位艺人 + 同一张专辑被提两次是常见的，没必要解析两遍。
            let identity = "\(seed.primaryArtist)|\(seed.album ?? "")|\(seed.title ?? "")"
            guard seen.insert(identity).inserted else { continue }

            if seed.kind == .track, let title = seed.title, !title.isEmpty {
                planned.append((seed, .track))
            } else if let album = seed.album, !album.isEmpty, remaining > 0 {
                remaining -= 1
                planned.append((seed, .album))
            } else {
                planned.append((seed, .artist))
            }
        }

        return planned
    }

    // MARK: - Resolution

    private static func resolveOne(
        _ seed: RecommendationSeed,
        plan: Plan,
        musicKit: MusicKitServiceProtocol,
        exclusions: PlaylistComposer.ExclusionSet
    ) async -> Outcome {
        do {
            switch plan {
            case .track:
                guard let title = seed.title else {
                    return Outcome(failure: failure(seed, reason: "missing_title"))
                }
                guard let song = try await musicKit.resolveTrack(
                    title: title, artist: seed.artist, album: seed.album
                ) else {
                    return Outcome(failure: failure(seed, reason: "catalog_miss"))
                }
                return outcome(from: [song], seed: seed, albumTrackCount: nil, expandedAlbum: false)

            case .album:
                let songs = try await musicKit.albumSongs(
                    artist: seed.artist, album: seed.album ?? "", limit: 25
                )
                guard !songs.isEmpty else {
                    return Outcome(failure: failure(seed, reason: "album_not_found"))
                }
                let picked = AlbumTrackPicker.pick(
                    from: songs.map { candidate(from: $0, seed: seed, albumTrackCount: songs.count) },
                    wants: seed.resolvedWants,
                    exclusions: exclusions
                )
                guard !picked.isEmpty else {
                    return Outcome(failure: failure(seed, reason: "album_all_excluded"))
                }
                let ids = Set(picked.map(\.info.id))
                let kept = songs.filter { ids.contains($0.id.rawValue) }
                return outcome(
                    from: kept, seed: seed, albumTrackCount: songs.count, expandedAlbum: true
                )

            case .artist:
                let songs = try await musicKit.searchArtistSongs(artist: seed.artist, limit: 25)
                guard !songs.isEmpty else {
                    return Outcome(failure: failure(seed, reason: "artist_not_found"))
                }
                let picked = AlbumTrackPicker.pick(
                    from: songs.map { candidate(from: $0, seed: seed, albumTrackCount: nil) },
                    wants: seed.resolvedWants,
                    exclusions: exclusions,
                    maxPerAlbum: 25   // 艺人级扩展不是一张专辑，不该套专辑的取数上限
                )
                guard !picked.isEmpty else {
                    return Outcome(failure: failure(seed, reason: "artist_all_excluded"))
                }
                let ids = Set(picked.map(\.info.id))
                let kept = songs.filter { ids.contains($0.id.rawValue) }
                return outcome(from: kept, seed: seed, albumTrackCount: nil, expandedAlbum: false)
            }
        } catch {
            return Outcome(failure: failure(seed, reason: "request_failed"))
        }
    }

    /// 从已经过 `AlbumTrackPicker` 筛选的 `Song` 列表构造结果。
    private static func outcome(
        from songs: [Song],
        seed: RecommendationSeed,
        albumTrackCount: Int?,
        expandedAlbum: Bool
    ) -> Outcome {
        var candidates: [ResolvedCandidate] = []
        var songsByID: [String: Song] = [:]
        var emptyIDCount = 0

        for song in songs {
            let id = song.id.rawValue
            guard !id.isEmpty else {
                // 空 catalog ID 的 Song 既无法可靠地加进歌单，又会在去重时
                // **互相碰撞** —— 整个候选池被静默压缩成一条，表现为解析率极低
                // 却看不出任何报错。真机日志里成百上千条 `MPIdentifierSet EMPTY`
                // 警告就是这个信号，所以这里单独计一档。
                emptyIDCount += 1
                continue
            }
            candidates.append(candidate(from: song, seed: seed, albumTrackCount: albumTrackCount))
            songsByID[id] = song
        }

        let failure: FailedSeed? = candidates.isEmpty
            ? failure(seed, reason: emptyIDCount > 0 ? "empty_catalog_id" : "no_usable_track")
            : nil

        return Outcome(
            candidates: candidates, songs: songsByID,
            failure: failure, expandedAlbum: expandedAlbum
        )
    }

    private static func failure(_ seed: RecommendationSeed, reason: String) -> FailedSeed {
        FailedSeed(artist: seed.artist, title: seed.title, album: seed.album, reason: reason)
    }

    private static func candidate(
        from song: Song,
        seed: RecommendationSeed,
        albumTrackCount: Int?
    ) -> ResolvedCandidate {
        ResolvedCandidate(
            info: TrackInfo(id: song.id.rawValue, name: song.title, artist: song.artistName),
            tier: seed.tier,
            seedKind: seed.kind,
            rawTitle: song.title,
            albumTitle: song.albumTitle,
            duration: song.duration ?? 0,
            genreNames: song.genreNames,
            // `Album.isCompilation` 需要额外一次请求才能拿到，这里不取。
            // 合辑主要靠 ContentTypeFilter 的专辑名规则识别（「合辑 / tribute /
            // Various Artists」），那条规则不需要这个字段。
            isCompilation: false,
            releaseDate: song.releaseDate,
            trackNumber: song.trackNumber,
            albumTrackCount: albumTrackCount
        )
    }
}
