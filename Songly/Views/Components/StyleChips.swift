//
//  StyleChips.swift
//  Songly
//
//  首页常驻的风格快选。替代原来的 `StylePickerView` sheet —— 那里要多两跳
//  （点按钮 → 等 sheet 弹出 → 挑），而这是一个一步就能做完的动作。
//

import SwiftUI

struct StyleChips: View {
    var isEnabled: Bool = true
    let onSelect: (QuickPickStyle) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            // `HStack` 而不是 `LazyHStack`：只有 8 项且几乎全部可见，
            // 惰性不省任何东西，反而多一层需要在外部滚动时重新测量的容器。
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(QuickPickStyle.allStyles, id: \.self) { style in
                    chip(style)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
        }
        .scrollIndicators(.hidden)
        // 只在内层开：开在外层纵向 ScrollView 上会让内容画到导航栏和
        // 安全区上去。
        .scrollClipDisabled()
    }

    private func chip(_ style: QuickPickStyle) -> some View {
        Button {
            onSelect(style)
        } label: {
            HStack(spacing: 6) {
                Text(style.emoji)
                    .accessibilityHidden(true)
                Text(style.rawValue)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.background, in: Capsule())
            .overlay { Capsule().strokeBorder(.secondary.opacity(0.15)) }
        }
        // `.plain` 在这里是**必须的，不是审美选择**：横向 ScrollView 里用
        // 默认样式时，按钮的手势会和滚动手势打架，表现为「只有从 chip 之间的
        // 缝隙起手才能横向拖动」。旧的 StylePickerView 也是为此用的 `.plain`。
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("\(style.rawValue)歌单")
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        StyleChips { _ in }
        StyleChips(isEnabled: false) { _ in }
    }
    .padding(.vertical)
}
