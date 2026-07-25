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
    /// Create a new playlist in the user's Apple Music library with songs.
    func createPlaylist(
        name: String,
        description: String,
        songs: [Song]
    ) async throws -> Playlist

    /// Find a playlist by name (for same-day dedup).
    func findPlaylist(named name: String) async throws -> Playlist?
}

// MARK: - Implementation

final class PlaylistService: PlaylistServiceProtocol {
    func createPlaylist(
        name: String,
        description: String,
        songs: [Song]
    ) async throws -> Playlist {
        // Step 1: Create empty playlist
        let playlist = try await MusicLibrary.shared.createPlaylist(
            name: name,
            description: description
        )

        // Step 2: Add songs to playlist
        for song in songs {
            try await MusicLibrary.shared.add(song, to: playlist)
        }

        return playlist
    }

    func findPlaylist(named name: String) async throws -> Playlist? {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = 100
        let response = try await request.response()
        return response.items.first { $0.name == name }
    }
}
