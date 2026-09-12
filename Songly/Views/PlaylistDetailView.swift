//
//  PlaylistDetailView.swift
//  Songly
//
//  一份歌单的详情：封面拼贴 + 元信息 + 完整曲目列表。
//

import SwiftUI
import SwiftData
import MusicKit
import UIKit

struct PlaylistDetailView: View {
    let record: RecommendationRecord

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                header
                trackList
            }
            .padding(Theme.Spacing.page)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(record.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // `ToolbarItemGroup` 而不是「一个 ToolbarItem 里塞 HStack」——
            // 工具栏项由 bar 决定尺寸，在单个 item 内部用 `maxWidth: .infinity`
            // 撑开是不可靠的。
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    openInMusic()
                } label: {
                    Label("在 Apple Music 中打开", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
            Button("删除", role: .destructive) { deleteRecord() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(record.displayTitle)」将从本地记录中删除。\nApple Music 中的播放列表不受影响。")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ArtworkMosaic(tracks: record.tracks, side: 148, gap: 4)

            VStack(spacing: Theme.Spacing.xs) {
                Text(record.displayTitle)
                    .font(.title3.weight(.semibold))

                Text(metaLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let tierSummary = record.tierSummary {
                    Text(tierSummary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.md)
    }

    /// 「夜晚 · 24 首 · 今天 22:04」。场景只在每日推荐上存在，缺失时自动省略。
    private var metaLine: String {
        var parts: [String] = []
        if let scene = record.sceneValue {
            parts.append(scene.displayName)
        }
        parts.append("\(record.songCount) 首")
        parts.append(record.createdAt.relativeDayString)
        return parts.joined(separator: " · ")
    }

    // MARK: - Tracks

    private var trackList: some View {
        Group {
            if record.tracks.isEmpty {
                ContentUnavailableView(
                    "暂无歌曲数据",
                    systemImage: "music.note.list",
                    description: Text("推荐生成时未获取到歌曲信息")
                )
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(record.tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track)

                        if index < record.tracks.count - 1 {
                            Divider().padding(.leading, Theme.Size.trackArtwork + Theme.Spacing.md)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .cardSurface()
            }
        }
    }

    // MARK: - Actions

    /// 用记录里存着的深链。
    ///
    /// 原来这里硬编码 `music://`，**无视了 `record.playlistURL`** —— 于是无论
    /// 从哪份歌单进来，都只会打开 Music App 首页。
    private func openInMusic() {
        let url = record.playlistURL ?? URL(string: "music://")
        guard let url else { return }
        UIApplication.shared.open(url)
    }

    private func deleteRecord() {
        modelContext.delete(record)
        try? modelContext.save()
        // 首页的「最近」是手动 fetch 的，靠这声通知刷新。
        NotificationCenter.default.post(name: .recommendationRecordDeleted, object: nil)
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
                TrackInfo(id: "1", name: "Yesterday", artist: "The Beatles", tier: .confident),
                TrackInfo(id: "2", name: "Bohemian Rhapsody", artist: "Queen", tier: .fresh),
                TrackInfo(id: "3", name: "Hotel California", artist: "Eagles", tier: .bold),
            ],
            source: "daily",
            playlistName: "🌙 Songly 每日推荐 · 20260912",
            scene: ListeningScene.night.rawValue
        ))
    }
    .modelContainer(for: RecommendationRecord.self, inMemory: true)
}
