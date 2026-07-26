//
//  PlaylistDetailView.swift
//  Songly
//
//  Detail view for a single recommendation record.
//  Shows metadata, full track list, and management actions.
//

import SwiftUI
import SwiftData

struct PlaylistDetailView: View {
    let record: RecommendationRecord
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Metadata
                metadataSection

                Divider()

                // Track list
                trackListSection
            }
            .padding()
        }
        .navigationTitle(record.playlistName ?? "歌单详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 16) {
                    // Open in Apple Music
                    Button {
                        if let url = URL(string: "music://") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("在 Apple Music 中打开", systemImage: "arrow.up.forward.app")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    // Delete
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
            Button("删除", role: .destructive) { deleteRecord() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(record.playlistName ?? "歌单")」将从本地记录中删除。\nApple Music 中的播放列表不受影响。")
        }
    }

    // MARK: - Metadata

    private var emoji: String {
        if let style = record.quickPickStyle,
           let qs = QuickPickStyle(rawValue: style) {
            return qs.emoji
        }
        return "🎵"
    }

    private var metadataSection: some View {
        VStack(spacing: 12) {
            Text(emoji)
                .font(.system(size: 48))

            Text(record.playlistName ?? "歌单")
                .font(.title2)
                .fontWeight(.bold)

            HStack(spacing: 16) {
                metaItem(icon: "music.note.list", label: "\(record.songCount) 首")
                metaItem(icon: "sparkles", label: record.strategy)
                metaItem(icon: "clock", label: formattedDate)
            }
        }
        .padding(.vertical, 8)
    }

    private func metaItem(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: record.createdAt)
    }

    // MARK: - Track List

    private var trackListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("歌曲列表")
                .font(.headline)

            if record.tracks.isEmpty {
                ContentUnavailableView(
                    "暂无歌曲数据",
                    systemImage: "music.note.list",
                    description: Text("推荐生成时未获取到歌曲信息")
                )
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(record.tracks, id: \.id) { track in
                        TrackRow(track: track)
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Actions

    private func deleteRecord() {
        modelContext.delete(record)
        try? modelContext.save()
        dismiss()
    }
}

#Preview {
    NavigationStack {
        PlaylistDetailView(record: RecommendationRecord(
            date: Date(),
            strategy: "风格探索",
            songCount: 25,
            tracks: [
                TrackInfo(id: "1", name: "Yesterday", artist: "The Beatles"),
                TrackInfo(id: "2", name: "Bohemian Rhapsody", artist: "Queen"),
                TrackInfo(id: "3", name: "Hotel California", artist: "Eagles"),
            ],
            source: "daily",
            playlistName: "🎵 每日推荐 · 7月26日"
        ))
    }
}
