//
//  PlaylistDetailView.swift
//  Songly
//
//  一份歌单的详情：封面拼贴 + 元信息 + 反馈 + 完整曲目列表。
//
//  反馈分两种粒度：
//    · 歌单级 —— 顶部「准不准」三档，回灌下一次生成的方向
//    · 单曲级 —— 每行尾部两个按钮：❤️ 超赞 / 🗑 删除
//
//  注意所有展示路径都读 `record.visibleTracks`（已滤掉删除的曲目）。漏掉任何
//  一处就会出现「拼贴里还有那首歌、列表里却没有」的错位。
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
    /// 「超赞」在 Apple Music 侧的副作用失败时的提示。
    /// **本地标记永远先写、永远成功** —— 这里报的只是同步失败。
    @State private var syncErrorMessage: String?

    private let libraryService = MusicLibraryService()

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
        .alert(
            "已记录，但没能同步到 Apple Music",
            isPresented: Binding(
                get: { syncErrorMessage != nil },
                set: { if !$0 { syncErrorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { syncErrorMessage = nil }
        } message: {
            Text(syncErrorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ArtworkMosaic(tracks: record.visibleTracks, side: 148, gap: 4)

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

                // 删除只在本地生效，Apple Music 里那份仍然是原数。
                // 不说清楚，用户以后会觉得哪里对不上。
                if record.removedCount > 0 {
                    Text("\(record.removedCount) 首已移除（Apple Music 中的歌单不变）")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            ratingControl
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.md)
    }

    /// 「准不准」三档。再点一次已选中的档位可以取消选择。
    ///
    /// 措辞刻意是「准不准」而不是「喜不喜欢」：我们想优化的是**推荐质量**，
    /// 不是这份歌单好不好听。
    private var ratingControl: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text("这份歌单准不准？")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: Theme.Spacing.sm) {
                ForEach(PlaylistRating.allCases, id: \.self) { rating in
                    let isSelected = record.ratingValue == rating
                    Button {
                        rate(rating)
                    } label: {
                        Text(rating.displayName)
                            .font(.subheadline.weight(isSelected ? .medium : .regular))
                            .foregroundStyle(isSelected ? Theme.onBrand : Color.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background {
                                if isSelected {
                                    Capsule().fill(Theme.brand)
                                } else {
                                    Capsule().strokeBorder(.secondary.opacity(0.2))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("评价：\(rating.displayName)")
                }
            }
        }
        .padding(.top, Theme.Spacing.xs)
    }

    /// 「夜晚 · 24 首 · 今天 22:04」。场景只在每日推荐上存在，缺失时自动省略。
    private var metaLine: String {
        var parts: [String] = []
        if let scene = record.sceneValue {
            parts.append(scene.displayName)
        }
        parts.append("\(record.visibleTracks.count) 首")
        parts.append(record.createdAt.relativeDayString)
        return parts.joined(separator: " · ")
    }

    // MARK: - Tracks

    private var trackList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if record.visibleTracks.isEmpty {
                ContentUnavailableView(
                    "暂无歌曲",
                    systemImage: "music.note.list",
                    description: Text("这首歌单里的曲目都被移除了")
                )
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(record.visibleTracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(
                            track: track,
                            isLoved: track.verdict == .loved,
                            onLove: { love(track) },
                            onDelete: { remove(track) }
                        )

                        if index < record.visibleTracks.count - 1 {
                            Divider().padding(.leading, Theme.Size.trackArtwork + Theme.Spacing.md)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .cardSurface()

                // 既解决发现性，也让用户**在按之前**就知道删除是永久的。
                Text("❤️ 是他会多推这个方向；🗑 会让这首歌**永远不再出现**。删除可在「设置 → 我的反馈」里撤销。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
        }
    }

    // MARK: - Actions

    /// 超赞 / 取消超赞。
    ///
    /// 顺序是有讲究的：**本地标记先写，它永远成功**；Apple Music 的两步是次级的，
    /// 失败不回滚本地标记，但也不静默吞掉。
    private func love(_ track: TrackInfo) {
        let next: TrackVerdict? = (track.verdict == .loved) ? nil : .loved
        FeedbackStore(context: modelContext).setVerdict(next, forSongID: track.id, in: record)

        // 取消超赞只动本地，不去 Apple Music 里做任何"撤销"——
        // 我们无法区分"这首歌本来就在他资料库里"和"是我们刚加进去的"。
        guard next == .loved else { return }

        Task { await syncLovedToAppleMusic(songID: track.id) }
    }

    private func syncLovedToAppleMusic(songID: String) async {
        var problems: [String] = []

        do {
            let outcome = try await libraryService.addToLibrary(songID: songID)
            if outcome == .added {
                // 记下「**我们**把这首歌放进了他的资料库」。
                //
                // 隐式信号会把「这首歌在他库里 + 入库时间落在推荐之后」读成
                // 「他自己收的」—— 没有这个标记，**我们自己的写入会凭空造出一个
                // 正向信号**，而且它还会顺势给这个艺人加权。
                //
                // 只在 `.added` 时记。`.alreadyOwned` 说明它本来就在库里
                // （或者是我们上一轮加的，两者无法区分）—— 那种情况交给
                // `libraryAddedDate` 的时间比对去挡：本来就在库里的歌，入库时间远早于
                // 这次推荐，天然不满足「推荐之后」。这也正是第 214 行那条注释
                // 所担心的歧义，现在它有了一个精确的出口。
                FeedbackStore(context: modelContext).markLibrarySynced(songID: songID, in: record)
            } else {
                #if DEBUG
                print("[Songly] 这首歌本来就在资料库里，跳过添加")
                #endif
            }
        } catch {
            problems.append("加入资料库：\(error.localizedDescription)")
        }

        if AppConfig.writeBackLovedRating {
            do {
                try await libraryService.setLovedRating(songID: songID)
            } catch {
                problems.append("写回喜欢：\(error.localizedDescription)")
            }
        }

        if !problems.isEmpty {
            syncErrorMessage = problems.joined(separator: "\n")
        }
    }

    /// 从这份歌单里删掉。本地永久排除 + 该艺人降权。
    private func remove(_ track: TrackInfo) {
        FeedbackStore(context: modelContext).setVerdict(.removed, forSongID: track.id, in: record)
    }

    private func rate(_ rating: PlaylistRating) {
        let next: PlaylistRating? = (record.ratingValue == rating) ? nil : rating
        FeedbackStore(context: modelContext).setRating(next, on: record)
    }

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
                TrackInfo(id: "1", name: "Yesterday", artist: "The Beatles",
                          tier: .confident, verdict: .loved),
                TrackInfo(id: "2", name: "Bohemian Rhapsody", artist: "Queen", tier: .fresh),
                TrackInfo(id: "3", name: "Hotel California", artist: "Eagles", tier: .bold),
            ],
            source: "daily",
            playlistName: "🌙 Songly 每日推荐 · 20260912",
            scene: ListeningScene.night.rawValue,
            rating: PlaylistRating.accurate.rawValue
        ))
    }
    .modelContainer(for: RecommendationRecord.self, inMemory: true)
}
