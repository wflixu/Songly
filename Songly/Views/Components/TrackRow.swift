//
//  TrackRow.swift
//  Songly
//
//  一行曲目：封面 + 歌名 + 艺人 +（仅新鲜/大胆）层级徽章 +（可选）反馈按钮。
//
//  结构上有一处是**必须**的：点击区只包「封面 + 文字」，不能包整行。否则行尾的
//  两个图标按钮会被外层大按钮的命中区域吞掉 —— 点了没反应，还查不出原因。
//

import SwiftUI
import MusicKit
import UIKit

struct TrackRow: View {
    let track: TrackInfo
    /// 是否已被标为「超赞」。实心 ❤️ 表示标过。
    var isLoved: Bool = false
    /// 传 `nil` 表示不显示该按钮（预览、只读场景）。
    var onLove: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            tappableIdentity

            if let onLove {
                actionButton(
                    systemName: isLoved ? "heart.fill" : "heart",
                    tint: isLoved ? .pink : .secondary,
                    label: isLoved ? "取消超赞" : "超赞",
                    action: onLove
                )
            }

            if let onDelete {
                actionButton(
                    systemName: "trash",
                    // 破坏性动作用次要色而不是红色：每一行都挂一个红色垃圾桶
                    // 会显得很吵，而这个操作是可撤销的（设置 → 我的反馈）。
                    tint: .secondary,
                    label: "删除",
                    action: onDelete
                )
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 56)
    }

    // MARK: - 主体（可点开 Apple Music）

    @ViewBuilder
    private var tappableIdentity: some View {
        // 有链接才可点。旧记录没有 `url`，那时保持不可点 —— 与其给一个按了
        // 没反应的按钮，不如不给。
        if let urlString = track.url, let url = URL(string: urlString) {
            Button { UIApplication.shared.open(url) } label: { identity }
                .buttonStyle(.plain)
        } else {
            identity
        }
    }

    private var identity: some View {
        HStack(spacing: Theme.Spacing.md) {
            ArtworkThumbnail(urlString: track.artworkURL)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    // 徽章放在艺人**后面**而不是行尾：行尾要留给反馈按钮，
                    // 而且徽章本来就属于"这首歌是什么"，与操作不是一类。
                    if let tier = track.tier, tier.showsBadge {
                        tierBadge(tier)
                    }
                }
            }

            // 吃掉剩余宽度，把行尾的按钮自然推到右边。
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    // MARK: - 组件

    private func actionButton(
        systemName: String,
        tint: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func tierBadge(_ tier: DiscoveryTier) -> some View {
        Text(tier.shortName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tier.badgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tier.badgeColor.opacity(0.12), in: Capsule())
    }
}

#Preview("只读") {
    List {
        TrackRow(track: TrackInfo(
            id: "1", name: "Yesterday", artist: "The Beatles", tier: .confident
        ))
        TrackRow(track: TrackInfo(
            id: "2", name: "Bohemian Rhapsody", artist: "Queen", tier: .fresh
        ))
    }
    .listStyle(.plain)
}

#Preview("带反馈按钮") {
    List {
        TrackRow(
            track: TrackInfo(id: "1", name: "夜空中最亮的星", artist: "逃跑计划", tier: .fresh),
            isLoved: true, onLove: {}, onDelete: {}
        )
        TrackRow(
            track: TrackInfo(id: "2", name: "Bohemian Rhapsody", artist: "Queen", tier: .bold),
            isLoved: false, onLove: {}, onDelete: {}
        )
        TrackRow(
            track: TrackInfo(id: "3", name: "很长的歌名会怎样被截断掉呢我们来看看效果", artist: "某位名字也很长的艺人"),
            isLoved: false, onLove: {}, onDelete: {}
        )
    }
    .listStyle(.plain)
}
