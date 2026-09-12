//
//  FeedbackHistoryView.swift
//  Songly
//
//  「我的反馈」—— 系统到底记住了什么，以及撤销。
//
//  这个页面存在的理由是**知情**，不只是撤销：
//    · 用户按了 🗑 之后，那首歌会**永远**不再出现。没有地方能看到"我删过哪些"，
//      这个机制就是不可审计的。
//    · 「超赞」不只是一个标记，它还会把歌加进 Apple Music 资料库 —— 用户应当
//      能看到自己触发过哪些副作用。
//

import SwiftUI
import SwiftData

struct FeedbackHistoryView: View {

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \RecommendationRecord.date, order: .reverse)
    private var records: [RecommendationRecord]

    /// 一条反馈。同一首歌可能在多份歌单里出现，取**最新**的那条（与
    /// `FeedbackStore.derive()` 同一套规则）。
    private struct Entry: Identifiable {
        let id: String
        let record: RecommendationRecord
        let track: TrackInfo
        let verdict: TrackVerdict
    }

    private var entries: [Entry] {
        var seen = Set<String>()
        var result: [Entry] = []
        for record in records {
            for track in record.tracks {
                guard let verdict = track.verdict else { continue }
                guard seen.insert(track.id).inserted else { continue }
                result.append(Entry(id: track.id, record: record, track: track, verdict: verdict))
            }
        }
        return result
    }

    private var loved: [Entry] { entries.filter { $0.verdict == .loved } }
    private var removed: [Entry] { entries.filter { $0.verdict == .removed } }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "还没有反馈",
                    systemImage: "hand.thumbsup",
                    description: Text("在歌单详情页给歌单评价、\n或对单曲点 ❤️ / 🗑，都会出现在这里。")
                )
            } else {
                List {
                    if !loved.isEmpty {
                        Section {
                            ForEach(loved) { row($0, systemImage: "heart.fill", tint: .pink) }
                        } header: {
                            Text("超赞（\(loved.count)）")
                        } footer: {
                            Text("这些方向会被更多地推荐。收藏也已加入你的 Apple Music 资料库。")
                        }
                    }

                    if !removed.isEmpty {
                        Section {
                            ForEach(removed) { row($0, systemImage: "trash", tint: .secondary) }
                        } header: {
                            Text("已删除（\(removed.count)）")
                        } footer: {
                            Text("这些歌**不会再被推荐**。撤销后它们会回到原来所在歌单的列表里，并解除永久排除。")
                        }
                    }
                }
            }
        }
        .navigationTitle("我的反馈")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ entry: Entry, systemImage: String, tint: Color) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.track.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(entry.track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.sm)

            Button("撤销") { undo(entry) }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func undo(_ entry: Entry) {
        FeedbackStore(context: modelContext)
            .setVerdict(nil, forSongID: entry.id, in: entry.record)
    }
}

#Preview {
    NavigationStack {
        FeedbackHistoryView()
    }
    .modelContainer(for: RecommendationRecord.self, inMemory: true)
}
