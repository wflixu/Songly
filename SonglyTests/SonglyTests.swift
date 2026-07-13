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

    // MARK: - RecommendationStrategy

    @Test func recommendationStrategyEmoji() async throws {
        #expect(RecommendationStrategy.styleExploration.emoji == "🎸")
        #expect(RecommendationStrategy.moodMatch.emoji == "🌙")
    }

    @Test func quickPickStyleMVPCount() async throws {
        #expect(QuickPickStyle.mvpStyles.count == 3)
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
        #expect(AppConfig.minTrackCount == 10)
        #expect(AppConfig.maxRetries == 3)
        #expect(AppConfig.searchConcurrency == 5)
    }
}
