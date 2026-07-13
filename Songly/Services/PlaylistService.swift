//
//  PlaylistService.swift
//  Songly
//
//  Apple Music playlist CRUD operations.
//

import Foundation
import MusicKit

// MARK: - Protocol

protocol PlaylistServiceProtocol: Sendable {
    /// Create a new playlist in the user's Apple Music library.
    func createPlaylist(
        name: String,
        description: String,
        trackIDs: [MusicItemID]
    ) async throws -> Playlist

    /// Find a playlist by name (for same-day dedup).
    func findPlaylist(named name: String) async throws -> Playlist?
}

// MARK: - Implementation

final class PlaylistService: PlaylistServiceProtocol {
    func createPlaylist(
        name: String,
        description: String,
        trackIDs: [MusicItemID]
    ) async throws -> Playlist {
        // Create playlist with metadata.
        // Note: Adding tracks requires Song objects (MusicPlaylistAddable),
        // not just MusicItemID. For MVP, tracks are described in the playlist
        // description; full track population is a Phase 2 enhancement.
        let trackList = trackIDs.isEmpty ? "" : "\n\n推荐曲目数: \(trackIDs.count) 首"
        let playlist = try await MusicLibrary.shared.createPlaylist(
            name: name,
            description: description + trackList
        )
        return playlist
    }

    func findPlaylist(named name: String) async throws -> Playlist? {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = 100
        let response = try await request.response()
        return response.items.first { $0.name == name }
    }
}
