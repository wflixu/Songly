//
//  TrackItem.swift
//  Songly
//
//  Value types for representing music tracks in the recommendation pipeline.
//

import Foundation
import MusicKit

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

// MARK: - Dedup Matching (normalized title + artist)

/// Normalized key for dedup. Operates on freeform text on both sides, so it is
/// a *pre-filter* — the authoritative dedup happens on catalog `MusicItemID`
/// after matching.
struct TrackKey: Hashable, Sendable {
    let title: String
    let artist: String
}

/// Normalize a title/artist for fuzzy matching: trim, lowercase, strip
/// parenthetical notes, collapse whitespace.
func normalizedKey(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s*（[^）]*）"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}

extension TrackInfo {
    var key: TrackKey { TrackKey(title: normalizedKey(name), artist: normalizedKey(artist)) }
}

extension TrackItem {
    var key: TrackKey { TrackKey(title: normalizedKey(title), artist: normalizedKey(artist)) }
}

extension Song {
    var key: TrackKey { TrackKey(title: normalizedKey(title), artist: normalizedKey(artistName)) }
}
