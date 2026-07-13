//
//  TrackRow.swift
//  Songly
//
//  Reusable component for displaying a single track recommendation.
//

import SwiftUI

struct TrackRow: View {
    let track: TrackInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.name)
                    .font(.body)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44) // Minimum touch target
    }
}

#Preview {
    List {
        TrackRow(track: TrackInfo(id: "1", name: "Yesterday", artist: "The Beatles"))
        TrackRow(track: TrackInfo(id: "2", name: "Bohemian Rhapsody", artist: "Queen"))
    }
}
