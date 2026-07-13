//
//  HomeView.swift
//  Songly
//

import SwiftUI
import MusicKit

private enum AuthStatus {
    case notDetermined, authorized, denied
}

struct HomeView: View {
    @Environment(HomeViewModel.self) private var vm
    @State private var auth: AuthStatus = .notDetermined

    var body: some View {
        Group {
            switch auth {
            case .notDetermined:
                OnboardingView(onAuthorize: requestAuth)
            case .denied:
                DeniedView()
            case .authorized:
                ScrollView {
                    VStack(spacing: 24) {
                        heroBanner
                        todayCard
                        quickPickSection
                        statsRow
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .background(Color(.systemGroupedBackground))
        .task { checkAuth() }
    }

    // MARK: - Hero

    private var heroBanner: some View {
        LinearGradient(
            colors: [.pink.opacity(0.85), .purple.opacity(0.6), .blue.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .leading) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Date().chineseDateString) · \(Date().chineseWeekdayString)")
                    .font(.title3)
                    .foregroundStyle(.white)
                Text("AI 驱动的个性化歌单")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(20)
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Today

    @ViewBuilder
    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日推荐").font(.headline).padding(.leading, 4)
            switch vm.state {
            case .idle, .onboarding:
                stateCard(icon: "wand.and.stars", color: .blue,
                    title: "等待推荐", desc: "AI 正在为你准备今日专属歌单") {
                        Button {
                            vm.triggerDailyRecommendation()
                        } label: {
                            Label("立即生成推荐", systemImage: "wand.and.stars")
                                .font(.headline).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(.blue, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(!vm.canTrigger)
                    }
            case .completed:
                stateCard(icon: "checkmark.circle.fill", color: .green,
                    title: "歌单已就绪", desc: "已为你生成今日专属推荐") {
                        Button {
                            if let u = URL(string: "music://") { UIApplication.shared.open(u) }
                        } label: {
                            Label("在 Apple Music 中打开", systemImage: "play.circle.fill")
                                .font(.headline).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(.green, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
            case .readingLibrary, .generating, .searchingCatalog, .persistingRecord, .creatingPlaylist:
                VStack(spacing: 20) {
                    ProgressView().scaleEffect(1.3).tint(.blue)
                    Text(statusText).font(.body).foregroundStyle(.secondary)
                    if case .searchingCatalog(let f, let t) = vm.state {
                        ProgressView(value: Double(f), total: Double(t)).tint(.blue)
                        Text("\(f) / \(t) 首已匹配").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(32).frame(maxWidth: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
            case .error(let msg, let retry):
                stateCard(icon: "exclamationmark.triangle.fill", color: .orange,
                    title: msg, desc: "") {
                        if retry { Button("重试") { vm.triggerDailyRecommendation() }.buttonStyle(.bordered) }
                    }
            }
        }
    }

    private func stateCard(icon: String, color: Color, title: String, desc: String,
        @ViewBuilder action: () -> some View) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(color.opacity(0.1)).frame(width: 72, height: 72)
                Image(systemName: icon).font(.system(size: 30)).foregroundStyle(color)
            }
            VStack(spacing: 4) {
                Text(title).font(.title3).fontWeight(.semibold)
                if !desc.isEmpty { Text(desc).font(.subheadline).foregroundStyle(.secondary) }
            }
            action()
        }
        .padding(24).frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    // MARK: - QuickPick

    private var quickPickSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("想听点什么？").font(.headline).padding(.leading, 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(QuickPickStyle.mvpStyles, id: \.self) { s in
                    Button {} label: {
                        HStack(spacing: 10) {
                            Text(s.emoji).font(.title2)
                            Text(s.rawValue).font(.subheadline).fontWeight(.medium)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("\(s.rawValue)歌单")
                }
            }
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 12) {
            stat("music.note.list", "\(vm.totalRecommendations)", "份歌单")
            stat("sparkles", "每日", "自动更新")
            stat("brain.head.profile", "AI", "个性化")
        }
    }

    private func stat(_ icon: String, _ val: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint)
            Text(val).font(.headline)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Helpers

    private var statusText: String {
        switch vm.state {
        case .readingLibrary:    return "正在读取你的收藏…"
        case .generating(let p): return p
        case .searchingCatalog:  return "正在曲库中匹配歌曲…"
        case .persistingRecord:  return "正在保存…"
        case .creatingPlaylist:  return "正在创建播放列表…"
        default:                 return "请稍候…"
        }
    }

    private func requestAuth() {
        Task {
            let s = await MusicAuthorization.request()
            await MainActor.run { auth = (s == .authorized) ? .authorized : .denied }
        }
    }
    private func checkAuth() {
        switch MusicAuthorization.currentStatus {
        case .authorized:          auth = .authorized
        case .denied, .restricted: auth = .denied
        default:                   auth = .notDetermined
        }
    }
}

// MARK: - Denied View

private struct DeniedView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Circle().fill(.secondary.opacity(0.12)).frame(width: 100, height: 100)
                .overlay { Image(systemName: "lock.shield.fill").font(.system(size: 40)).foregroundStyle(.secondary) }
            Text("需要 Apple Music 访问权限").font(.title3).fontWeight(.semibold)
            Text("请在设置中开启权限，乐遇才能为你生成个性化推荐。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("打开设置") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }.buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }
}
