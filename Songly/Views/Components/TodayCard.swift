//
//  TodayCard.swift
//  Songly
//
//  首页唯一的主角：今天这份歌单。
//
//  品牌渐变在这里**是有功能的，不是装饰** —— 它是「今天这份歌单」的封套，
//  四个状态是同一块颜色的连续演变：
//
//    idle        整块渐变，里面还没有内容
//    generating  同一块渐变承载**真实阶段**进度（不是伪进度）
//    completed   内容填进来了，渐变让位，只在顶部保留一条作为身份
//    error       不出现 —— 错误不配好看，也免得渐变承载负面状态
//
//  所以 idle → completed 读起来是「卡片被内容填满了」，而不是两块不相干的设计。
//

import SwiftUI
import MusicKit

struct TodayCard: View {

    struct Actions {
        var generate: () -> Void
        var regenerate: () -> Void
        var openInMusic: () -> Void
        var cancel: () -> Void
    }

    let state: RecommendationState
    /// 今天已完成的记录。旧记录没有 `scene` / `tier` / 封面，卡片自动降级显示。
    let record: RecommendationRecord?
    let canTrigger: Bool
    let isOffline: Bool
    let actions: Actions

    var body: some View {
        switch state {
        case .completed:
            completedCard
        case .error(let message, let retryable):
            errorCard(message: message, retryable: retryable)
        case .idle, .onboarding:
            idleCard
        default:
            progressCard
        }
    }

    // MARK: - idle

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("今天还没有歌单")
                    .font(.title3.weight(.semibold))

                Text("从你的收藏出发，挑 \(AppConfig.targetTrackCount) 首你大概率喜欢、还没听过的好歌。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.onBrandSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: actions.generate) {
                Label("生成今天的歌单", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Theme.brand)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Size.primaryButton)
                    .background(Theme.onBrand, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canTrigger)
            .opacity(canTrigger ? 1 : 0.5)

            if isOffline {
                Label("网络不可用，暂时无法生成", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(Theme.onBrandSecondary)
            }
        }
        .foregroundStyle(Theme.onBrand)
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.brandGradient)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    // MARK: - generating

    private var progressCard: some View {
        VStack(spacing: Theme.Spacing.xl) {
            ProgressRing(progress: progressFraction)

            VStack(spacing: Theme.Spacing.xs) {
                Text(stageLabel)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .id(state.stageIdentifier)

                if case .searchingCatalog(let found, let total) = state {
                    Text("\(found) / \(total) 首已匹配")
                        .font(.caption)
                        .foregroundStyle(Theme.onBrandSecondary)
                }
            }
            .foregroundStyle(Theme.onBrand)
            .animation(.easeInOut(duration: 0.3), value: state.stageIdentifier)

            Button(action: actions.cancel) {
                Text("取消生成")
                    .font(.subheadline)
                    .foregroundStyle(Theme.onBrand)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .overlay { Capsule().strokeBorder(Theme.onBrand.opacity(0.5)) }
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
        .background(Theme.brandGradient)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// 真实阶段 → 0…1。
    ///
    /// 刻意**不是伪进度**：每一档都对应管线里一个真实发生过的阶段，而且
    /// `searchingCatalog` 那一档有精确的匹配计数可以细分。
    private var progressFraction: Double {
        switch state {
        case .readingLibrary:
            return 0.12
        case .generating:
            return 0.40
        case .searchingCatalog(let found, let total):
            guard total > 0 else { return 0.62 }
            return 0.55 + 0.30 * min(1, Double(found) / Double(total))
        case .persistingRecord:
            return 0.92
        case .creatingPlaylist:
            return 0.97
        default:
            return 0
        }
    }

    private var stageLabel: String {
        switch state {
        case .readingLibrary:            return "正在读取你的收藏…"
        case .generating(let progress):  return progress
        case .searchingCatalog:          return "正在曲库中匹配歌曲…"
        case .persistingRecord:          return "正在保存…"
        case .creatingPlaylist:          return "正在创建播放列表…"
        default:                         return "请稍候…"
        }
    }

    // MARK: - completed

    private var completedCard: some View {
        VStack(spacing: 0) {
            identityBand

            completedBody
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    private var identityBand: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(identity.emoji)
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(identity.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(identity.subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.onBrandSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.onBrand)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.brandGradient)
    }

    /// 顶部渐变态要说什么。
    ///
    /// 显示的是**这份歌单的属性**，不是「现在几点」—— 场景在生成时就定下了，
    /// 早上打开一份深夜生成的歌单，它仍然写「深夜」。这是刻意的：用户要的是
    /// 「这份歌单是什么」，而不是一个会随时间漂移的钟。
    private var identity: (emoji: String, title: String, subtitle: String) {
        if let record, let scene = record.sceneValue {
            let brief = SceneBrief.brief(
                for: scene,
                isWeekend: Calendar.current.isDateInWeekend(record.date)
            )
            return (scene.emoji, scene.displayName, brief.rationale)
        }
        if let record,
           let raw = record.quickPickStyle,
           let style = QuickPickStyle(rawValue: raw) {
            return (style.emoji, "\(style.rawValue)精选", "按你点名的风格挑的")
        }
        return ("🎵", record?.displayTitle ?? fallbackName, "已经准备好了")
    }

    private var completedBody: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.md) {
                ArtworkMosaic(tracks: record?.tracks ?? [])

                VStack(alignment: .leading, spacing: 4) {
                    Text(record?.displayTitle ?? fallbackName)
                        .font(.headline)
                        .lineLimit(2)

                    Text(subtitleLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let tierLine {
                        Text(tierLine)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 0)
            }

            VStack(spacing: Theme.Spacing.sm) {
                Button(action: actions.openInMusic) {
                    Label("在 Apple Music 中打开", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.onBrand)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Size.primaryButton)
                        .background(Theme.brandGradient, in: Capsule())
                }
                .buttonStyle(.plain)

                Button(action: actions.regenerate) {
                    Label("重新生成", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(.bordered)
                .disabled(!canTrigger)
            }
        }
    }

    private var subtitleLine: String {
        guard let record else { return "\(trackCount) 首" }
        return "\(record.songCount) 首 · \(record.date.relativeDayString)"
    }

    private var tierLine: String? { record?.tierSummary }

    private var trackCount: Int {
        if case .completed(let count, _) = state { return count }
        return 0
    }

    private var fallbackName: String {
        if case .completed(_, let name) = state { return name }
        return "今日推荐"
    }

    // MARK: - error

    private func errorCard(message: String, retryable: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label("生成失败", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if retryable {
                Button("重试", action: actions.generate)
                    .buttonStyle(.bordered)
                    .disabled(!canTrigger)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

// MARK: - Progress Ring

/// 确定进度环。取代原来那套蓝/紫/橙/青/绿的 stage 轮换 —— 那个颜色变化
/// 不承载任何信息，只是五秒钟换一个色。
private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.onBrand.opacity(0.25), lineWidth: 6)

            Circle()
                .trim(from: 0, to: max(0.03, min(1, progress)))
                .stroke(Theme.onBrand, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: progress)
        }
        .frame(width: 72, height: 72)
    }
}

#Preview("idle") {
    TodayCard(
        state: .idle,
        record: nil,
        canTrigger: true,
        isOffline: false,
        actions: .init(generate: {}, regenerate: {}, openInMusic: {}, cancel: {})
    )
    .padding()
}

#Preview("generating") {
    TodayCard(
        state: .searchingCatalog(found: 18, total: 25),
        record: nil,
        canTrigger: true,
        isOffline: false,
        actions: .init(generate: {}, regenerate: {}, openInMusic: {}, cancel: {})
    )
    .padding()
}

#Preview("completed") {
    TodayCard(
        state: .completed(trackCount: 24, playlistName: "🌙 Songly 每日推荐 · 20260912"),
        record: RecommendationRecord(
            date: Date(),
            strategy: "风格探索",
            songCount: 24,
            tracks: [
                TrackInfo(id: "1", name: "A", artist: "X", tier: .confident),
                TrackInfo(id: "2", name: "B", artist: "Y", tier: .fresh),
                TrackInfo(id: "3", name: "C", artist: "Z", tier: .bold),
            ],
            source: "daily",
            playlistName: "🌙 Songly 每日推荐 · 20260912",
            scene: ListeningScene.night.rawValue
        ),
        canTrigger: true,
        isOffline: false,
        actions: .init(generate: {}, regenerate: {}, openInMusic: {}, cancel: {})
    )
    .padding()
}

#Preview("error") {
    TodayCard(
        state: .error(message: "模型服务暂时不可用", retryable: true),
        record: nil,
        canTrigger: true,
        isOffline: false,
        actions: .init(generate: {}, regenerate: {}, openInMusic: {}, cancel: {})
    )
    .padding()
}
