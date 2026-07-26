//
//  PlaylistHistoryView.swift
//  Songly
//
//  Full playlist history list with @Query, swipe-to-delete, and tap-to-detail.
//

import SwiftUI
import SwiftData

struct PlaylistHistoryView: View {
    @Query(sort: \RecommendationRecord.date, order: .reverse)
    private var records: [RecommendationRecord]

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if records.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(records) { record in
                        NavigationLink {
                            PlaylistDetailView(record: record)
                        } label: {
                            PlaylistCard(record: record)
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                    .onDelete(perform: deleteRecords)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("歌单历史")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "还没有生成过歌单",
            systemImage: "music.note.list",
            description: Text("在首页生成第一份歌单后，\n它会出现在这里。")
        )
    }

    private func deleteRecords(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(records[index])
        }
        try? modelContext.save()
    }
}

#Preview {
    NavigationStack {
        PlaylistHistoryView()
    }
}
