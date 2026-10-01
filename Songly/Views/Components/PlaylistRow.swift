//
//  PlaylistRow.swift
//  Songly
//
//  一份歌单的紧凑行。用于首页「最近」和歌单历史列表。
//
//  刻意**不含任何导航装饰**：`chevron` 由调用方决定要不要。旧 `PlaylistCard`
//  把 chevron 焊死在组件内部，一旦在非导航场景复用它，那个箭头就在说谎。
//

import SwiftUI

struct PlaylistRow: View {
    let record: RecommendationRecord
    /// 是否显示右侧的 `›`。由把它包进 `NavigationLink` 的调用方置 true。
    var showsDisclosure: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ArtworkThumbnail(
                urlString: record.visibleTracks.first?.artworkURL,
                side: Theme.Size.playlistArtwork,
                radius: Theme.Radius.tile
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.sm)

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Spacing.md)
        .cardSurface(radius: Theme.Radius.control)
        // 让整行（含卡片内边距）都可点，而不只是文字。
        .contentShape(Rectangle())
    }

    /// 「夜晚 · 24 首 · 今天 22:04」。场景在旧记录上缺失，自动省略。
    private var subtitle: String {
        var parts: [String] = []
        if let scene = record.sceneValue {
            parts.append(scene.displayName)
        }
        parts.append("\(record.songCount) 首")
        parts.append(record.date.relativeDayString)
        return parts.joined(separator: " · ")
    }
}

#Preview {
    VStack(spacing: 8) {
        PlaylistRow(
            record: RecommendationRecord(
                date: Date(),
                strategy: "风格探索",
                songCount: 25,
                tracks: [
                    TrackInfo(id: "1", name: "Yesterday", artist: "The Beatles"),
                ],
                source: "daily",
                playlistName: "🌙 Songly 每日推荐 · 20260912",
                scene: ListeningScene.night.rawValue
            ),
            showsDisclosure: true
        )
        PlaylistRow(
            record: RecommendationRecord(
                date: Calendar.current.date(byAdding: .day, value: -1, to: Date())!,
                strategy: "风格探索",
                songCount: 20,
                tracks: [],
                source: "quick_pick",
                quickPickStyle: QuickPickStyle.rock.rawValue,
                playlistName: "🎸 摇滚精选 · 20260911"
            ),
            showsDisclosure: true
        )
    }
    .padding()
}
