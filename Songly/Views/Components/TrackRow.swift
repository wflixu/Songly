//
//  TrackRow.swift
//  Songly
//
//  一行曲目：封面 + 歌名 + 艺人 +（仅新鲜/大胆）层级徽章。
//
//  这一行**是可点的**，点了跳到 Apple Music 播放这首歌。此前它带着一个
//  `minHeight: 44` 的触控尺寸却零交互 —— 那个尺寸是白给的。
//

import SwiftUI
import MusicKit
import UIKit

struct TrackRow: View {
    let track: TrackInfo

    var body: some View {
        // 有链接才可点。旧记录没有 `url`，那时保持不可点 —— 与其给一个按了
        // 没反应的按钮，不如不给。
        if let urlString = track.url, let url = URL(string: urlString) {
            Button { UIApplication.shared.open(url) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: Theme.Spacing.md) {
            ArtworkThumbnail(urlString: track.artworkURL)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.sm)

            if let tier = track.tier, tier.showsBadge {
                tierBadge(tier)
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        // 让整行（含左右 padding）都可点，而不只是文字。
        .contentShape(Rectangle())
    }

    private func tierBadge(_ tier: DiscoveryTier) -> some View {
        Text(tier.shortName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tier.badgeColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tier.badgeColor.opacity(0.12), in: Capsule())
    }
}

#Preview {
    List {
        TrackRow(track: TrackInfo(
            id: "1", name: "Yesterday", artist: "The Beatles", tier: .confident
        ))
        TrackRow(track: TrackInfo(
            id: "2", name: "Bohemian Rhapsody", artist: "Queen", tier: .fresh
        ))
        TrackRow(track: TrackInfo(
            id: "3", name: "夜空中最亮的星", artist: "逃跑计划", tier: .bold
        ))
    }
    .listStyle(.plain)
}
