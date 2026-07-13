//
//  RecommendationResultView.swift
//  Songly
//
//  Displays recommendation results with track list and "Open in Apple Music" button.
//

import SwiftUI

struct RecommendationResultView: View {
    let record: RecommendationRecord
    let onOpenInMusic: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(spacing: 4) {
                HStack {
                    Text("🎵 今日推荐已就绪！")
                        .font(.title3)
                        .fontWeight(.bold)
                    Spacer()
                    Text("\(record.tracks.count) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }

                Text(record.strategy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Track list
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(record.tracks, id: \.id) { track in
                        TrackRow(track: track)
                    }
                }
            }
            .frame(maxHeight: 300)

            Divider()

            // Open in Apple Music button
            Button(action: onOpenInMusic) {
                Label("在 Apple Music 中打开", systemImage: "arrow.up.forward.app")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("跳转到 Apple Music 播放歌单")
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    RecommendationResultView(
        record: RecommendationRecord(
            date: Date(),
            strategy: "风格探索",
            songCount: 3,
            tracks: [
                TrackInfo(id: "1", name: "Yesterday", artist: "The Beatles"),
                TrackInfo(id: "2", name: "Bohemian Rhapsody", artist: "Queen"),
                TrackInfo(id: "3", name: "Hotel California", artist: "Eagles"),
            ],
            source: "daily"
        ),
        onOpenInMusic: {}
    )
    .padding()
}
