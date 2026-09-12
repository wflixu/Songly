//
//  OnboardingView.swift
//  Songly
//
//  首次启动的授权说明页。三条 feature 说明了权限**用途**，是这一页存在的
//  唯一理由 —— 所以保留，但字体改用语义尺寸（原来的 `size: 36` 不跟
//  Dynamic Type 缩放）。
//

import SwiftUI

struct OnboardingView: View {
    let onAuthorize: () -> Void

    /// 这里刻意**不用品牌渐变** —— 渐变在这个 App 里的规则是「今天这份歌单的
    /// 封套」，而这一页还没有歌单。品牌识别交给 App Icon 与系统 tint 就够了。
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "music.note.house.fill")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.tint)
                .padding(.bottom, Theme.Spacing.xl)

            Text("乐遇")
                .font(.largeTitle.bold())
                .padding(.bottom, Theme.Spacing.xs)

            Text("AI 驱动的个性化歌单推荐")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer().frame(height: 44)

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                featureRow(icon: "music.note.list", text: "读取你的 Apple Music 收藏")
                featureRow(icon: "brain.head.profile", text: "AI 分析你的音乐品味")
                featureRow(icon: "sparkles", text: "每日自动创建推荐歌单")
            }
            .padding(.horizontal, 32)

            Spacer()

            Button(action: onAuthorize) {
                Text("允许访问 Apple Music")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Size.primaryButton)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)

            Spacer().frame(height: Theme.Spacing.md)

            Text("仅读取歌名和艺人名用于 AI 推荐，\n不会获取你的 Apple ID 或个人信息。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer().frame(height: 44)
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    OnboardingView {}
}
