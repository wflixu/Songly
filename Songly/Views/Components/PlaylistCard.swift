//
//  PlaylistCard.swift
//  Songly
//
//  Reusable compact card for displaying a playlist summary.
//  Used in home recent preview and playlist history list.
//

import SwiftUI

struct PlaylistCard: View {
    let record: RecommendationRecord

    private var emoji: String {
        if let style = record.quickPickStyle,
           let qs = QuickPickStyle(rawValue: style) {
            return qs.emoji
        }
        return "🎵"
    }

    private var relativeDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(record.date) {
            return "今天"
        } else if calendar.isDateInYesterday(record.date) {
            return "昨天"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日"
            return formatter.string(from: record.date)
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Emoji icon
            Text(emoji)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(record.playlistName ?? "歌单")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(record.songCount) 首")
                    Text("·")
                    Text(record.strategy)
                    Text("·")
                    Text(relativeDate)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.03), radius: 4, y: 1)
    }
}

#Preview {
    VStack(spacing: 8) {
        PlaylistCard(record: RecommendationRecord(
            date: Date(),
            strategy: "风格探索",
            songCount: 25,
            tracks: [
                TrackInfo(id: "1", name: "Yesterday", artist: "The Beatles"),
                TrackInfo(id: "2", name: "Bohemian Rhapsody", artist: "Queen"),
            ],
            source: "daily",
            playlistName: "🎵 每日推荐 · 7月26日"
        ))
        PlaylistCard(record: RecommendationRecord(
            date: Calendar.current.date(byAdding: .day, value: -1, to: Date())!,
            strategy: "风格探索",
            songCount: 20,
            tracks: [],
            source: "quick_pick",
            quickPickStyle: "摇滚",
            playlistName: "🎸 摇滚精选 · 7月25日"
        ))
    }
    .padding()
}
