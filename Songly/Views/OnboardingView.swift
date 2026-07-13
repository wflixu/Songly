//
//  OnboardingView.swift
//  Songly
//

import SwiftUI

struct OnboardingView: View {
    let onAuthorize: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(.tint)
            }

            Spacer().frame(height: 32)

            // Title
            Text("乐遇")
                .font(.system(size: 36, weight: .bold))
            Text("AI 驱动的个性化歌单推荐")
                .font(.title3)
                .foregroundStyle(.secondary)

            Spacer().frame(height: 48)

            // Feature list
            VStack(alignment: .leading, spacing: 20) {
                featureRow(icon: "music.note.list", text: "读取你的 Apple Music 收藏")
                featureRow(icon: "brain.head.profile", text: "AI 分析你的音乐品味")
                featureRow(icon: "sparkles", text: "每日自动创建推荐歌单")
            }
            .padding(.horizontal, 32)

            Spacer()

            // Authorize button
            Button(action: onAuthorize) {
                Text("允许访问 Apple Music")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .accessibilityLabel("允许访问 Apple Music")

            Spacer().frame(height: 12)

            // Privacy note
            Text("仅读取歌名和艺人名用于 AI 推荐，\n不会获取你的 Apple ID 或个人信息。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer().frame(height: 48)
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(text)
                .font(.body)
        }
    }
}

#Preview {
    OnboardingView {}
}
