//
//  SonglyTests.swift
//  SonglyTests
//

import Foundation
import Testing
@testable import Songly

struct SonglyTests {

    // MARK: - TrackItem Parsing

    @Test func parseTrackItemStandard() async throws {
        let item = TrackItem(title: "Yesterday", artist: "The Beatles")
        #expect(item.title == "Yesterday")
        #expect(item.artist == "The Beatles")
        #expect(item.id == "Yesterday-The Beatles")
    }

    // MARK: - TrackInfo Codable

    @Test func trackInfoCodable() async throws {
        let info = TrackInfo(id: "12345", name: "Bohemian Rhapsody", artist: "Queen")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(TrackInfo.self, from: data)
        #expect(decoded == info)
    }

    // MARK: - RecommendationRecord

    @Test func recommendationRecordTrackSerialization() async throws {
        let tracks = [
            TrackInfo(id: "1", name: "Song A", artist: "Artist A"),
            TrackInfo(id: "2", name: "Song B", artist: "Artist B"),
        ]
        let record = RecommendationRecord(
            date: Date(),
            strategy: "styleExploration",
            songCount: 2,
            tracks: tracks,
            source: "daily"
        )
        #expect(record.tracks.count == 2)
        #expect(record.tracks[0].name == "Song A")
        #expect(record.trackNames == ["Song A", "Song B"])
    }

    @Test func recommendationRecordStatusDefaultsPending() async throws {
        let record = RecommendationRecord(
            date: Date(),
            strategy: "styleExploration",
            songCount: 1,
            tracks: [],
            source: "daily"
        )
        #expect(record.status == RecommendationRecord.statusPending)
    }

    // MARK: - RecommendationStrategy

    @Test func recommendationStrategyEmoji() async throws {
        #expect(RecommendationStrategy.styleExploration.emoji == "🎸")
        #expect(RecommendationStrategy.moodMatch.emoji == "🌙")
    }

    @Test func quickPickStyleAllStyles() async throws {
        #expect(QuickPickStyle.allStyles.count == 8)
    }

    // MARK: - Date Formatting

    @Test func chineseDateString() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.date(from: "2026-07-13")!
        #expect(date.chineseDateString == "7月13日")
    }

    // MARK: - AppConfig

    @Test func appConfigDefaults() async throws {
        #expect(AppConfig.targetTrackCount == 25)
        #expect(AppConfig.minAcceptableTrackCount == 20)
        #expect(AppConfig.publishableTrackCount == 15)
        #expect(AppConfig.maxTracksPerArtist == 2)
        #expect(AppConfig.maxRetries == 3)
        #expect(AppConfig.searchConcurrency == 5)
        #expect(AppConfig.dedupWindowDays == 14)
        #expect(AppConfig.maxGapRounds == 3)
    }

    // MARK: - Normalization & TrackKey

    @Test func normalizedKeyHandlesCaseParensWhitespace() async throws {
        #expect(normalizedKey("  Yesterday (Remastered 2009) ") == "yesterday")
        #expect(normalizedKey("  Shape of You  ") == "shape of you")
        #expect(normalizedKey("晴天（Live）") == "晴天")
        #expect(normalizedKey("ABC") == "abc")
    }

    @Test func trackKeyFromTrackItemAndInfo() async throws {
        let item = TrackItem(title: "Yesterday", artist: "The Beatles")
        #expect(item.key == TrackKey(title: "yesterday", artist: "the beatles"))

        let info = TrackInfo(id: "1", name: " 晴天 ", artist: " 周杰伦 ")
        #expect(info.key == TrackKey(title: "晴天", artist: "周杰伦"))
    }

    // MARK: - Hard Dedup Filter
    //
    // 原 `RecommendationEngine.filterRecommendations` 的四个用例随该函数一起删除了。
    // 硬去重与自适应放宽现在由 `PlaylistComposer` 负责，覆盖在 `ComposerTests` 里 ——
    // 而且换成了更强的不变量：数量上限与歌手上限在任何放宽路径下都不松动。

    // MARK: - RecommendationContext
    //
    // 原 `RecommendationContext` 已被 `SceneContext` 取代（情境推导 + 季节），
    // 季节边界用例移到了 `SceneAndProfileTests.seasonBoundaries`。
}
