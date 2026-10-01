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
        // Single network round-trip: create the playlist and add all tracks at
        // once (instead of 25 serial `add` calls). `Song` conforms to
        // `MusicPlaylistAddable`, so `[Song]` works as `items`.
        return try await MusicLibrary.shared.createPlaylist(
            name: name,
            description: description,
            authorDisplayName: nil,
            items: songs
        )
    }

    func findPlaylist(named name: String) async throws -> Playlist? {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = 100
        let response = try await request.response()
        return response.items.first { $0.name == name }
    }
}
