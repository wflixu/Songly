//
//  TrackItem.swift
//  Songly
//
//  Value types for representing music tracks in the recommendation pipeline.
//

import Foundation

// MARK: - TrackInfo (persisted, codable)

/// A matched track stored in RecommendationRecord as JSON.
struct TrackInfo: Codable, Equatable, Sendable {
    /// Apple Music MusicItemID string.
    let id: String
    /// Song title.
    let name: String
    /// Artist name.
    let artist: String
}

// MARK: - TrackItem (LLM response)

/// A track recommended by the LLM (before catalog matching).
struct TrackItem: Codable, Identifiable, Sendable {
    var id: String { "\(title)-\(artist)" }
    let title: String
    let artist: String
}
