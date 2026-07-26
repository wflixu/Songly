//
//  ImmersiveProgressView.swift
//  Songly
//
//  Animated progress indicator for the recommendation pipeline.
//  Features: pulsing ring, stage transitions, gradient background shift, completion burst.
//

import SwiftUI

struct ImmersiveProgressView: View {
    let state: RecommendationState
    let onCancel: () -> Void

    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 24) {
            // Animated progress ring
            ZStack {
                // Glow background
                Circle()
                    .fill(stageColor.opacity(0.1))
                    .frame(width: 100, height: 100)
                    .scaleEffect(isAnimating ? 1.15 : 1.0)

                // Outer track
                Circle()
                    .stroke(stageColor.opacity(0.15), lineWidth: 6)
                    .frame(width: 80, height: 80)

                // Animated arc
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(
                        AngularGradient(
                            colors: [stageColor, stageColor.opacity(0.5), stageColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .animation(
                        .linear(duration: 2).repeatForever(autoreverses: false),
                        value: isAnimating
                    )
            }
            .shadow(color: stageColor.opacity(0.3), radius: 12)
            .onAppear { isAnimating = true }

            // Stage label with transition
            stageLabel
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .id(state.stageIdentifier)
                .animation(.easeInOut(duration: 0.4), value: state.stageIdentifier)

            // Deterministic progress bar for catalog search
            if case .searchingCatalog(let found, let total) = state {
                VStack(spacing: 8) {
                    ProgressView(value: Double(found), total: Double(total))
                        .tint(stageColor)
                    Text("\(found) / \(total) 首已匹配")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .transition(.opacity)
            }

            // Cancel button
            Button("取消生成", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .tint(.secondary)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.background)
                .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        )
    }

    // MARK: - Stage-dependent helpers

    private var stageLabel: some View {
        switch state {
        case .readingLibrary:
            return Text("正在读取你的收藏…")
        case .generating(let progress):
            return Text(progress)
        case .searchingCatalog:
            return Text("正在曲库中匹配歌曲…")
        case .persistingRecord:
            return Text("正在保存…")
        case .creatingPlaylist:
            return Text("正在创建播放列表…")
        default:
            return Text("请稍候…")
        }
    }

    private var stageColor: Color {
        switch state {
        case .readingLibrary: return .blue
        case .generating: return .purple
        case .searchingCatalog: return .orange
        case .persistingRecord: return .teal
        case .creatingPlaylist: return .green
        default: return .blue
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ImmersiveProgressView(state: .readingLibrary, onCancel: {})
        ImmersiveProgressView(state: .searchingCatalog(found: 8, total: 25), onCancel: {})
    }
    .padding()
}
