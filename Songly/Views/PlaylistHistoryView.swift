//
//  PlaylistHistoryView.swift
//  Songly
//
//  全部歌单历史。@Query 驱动，所以删除后自动更新。
//

import SwiftUI
import SwiftData

struct PlaylistHistoryView: View {
    /// 只看已完成的记录。
    ///
    /// `pending` 记录是「已落库、播放列表还没建成」的中间态。正常路径下它会被
    /// 收尾或回滚，但 App 在生成中途被杀就会留下一条孤儿 —— 不过滤的话它会
    /// 显示成一份 Apple Music 中并不存在的歌单。
    @Query(
        filter: #Predicate<RecommendationRecord> { record in
            record.status == "completed"
        },
        sort: \RecommendationRecord.date,
        order: .reverse
    )
    private var records: [RecommendationRecord]

    @Environment(\.modelContext) private var modelContext
    @State private var selectedRecord: RecommendationRecord?

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "还没有生成过歌单",
                    systemImage: "music.note.list",
                    description: Text("在首页生成第一份歌单后，\n它会出现在这里。")
                )
            } else {
                List {
                    ForEach(records) { record in
                        // 用 Button + `navigationDestination(item:)`，而不是
                        // `NavigationLink`：List 会给 NavigationLink 自动补一个
                        // **行尾**的箭头，位置落在卡片圆角之外，跟首页那张卡里
                        // 的箭头对不上（两处来源不同）。这里关掉系统的，改由
                        // `PlaylistRow` 在卡片内部自己画。
                        Button {
                            selectedRecord = record
                        } label: {
                            PlaylistRow(record: record, showsDisclosure: true)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(
                            top: Theme.Spacing.xs, leading: Theme.Spacing.page,
                            bottom: Theme.Spacing.xs, trailing: Theme.Spacing.page
                        ))
                    }
                    .onDelete(perform: deleteRecords)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
            }
        }
        // 挂在 `Group` 上而不是 `List` 上：条件分支里的 destination 会随分支
        // 出现/消失，而它应当在整个视图生命周期里稳定存在一次。
        .navigationDestination(item: $selectedRecord) { record in
            PlaylistDetailView(record: record)
        }
        .navigationTitle("歌单历史")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func deleteRecords(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(records[index])
        }
        try? modelContext.save()
        // 首页的「最近」是手动 fetch 的（@Query 管不到它），靠这声通知刷新。
        NotificationCenter.default.post(name: .recommendationRecordDeleted, object: nil)
    }
}

#Preview {
    NavigationStack {
        PlaylistHistoryView()
    }
    // 不带 container 时 @Query 会直接 trap。
    .modelContainer(for: RecommendationRecord.self, inMemory: true)
}
