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
                    VStack(spacing: 20) {
                        heroBanner
                        todayCard
                        recentPlaylistsSection
                        statsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .background(Color(.systemGroupedBackground))
        .task { checkAuth() }
        .sheet(isPresented: Binding(
            get: { vm.showStylePicker },
            set: { vm.showStylePicker = $0 }
        )) {
            StylePickerView { style in
                vm.triggerStyledRecommendation(style: style)
            }
        }
    }

    // MARK: - Hero Header

    private var heroBanner: some View {
        LinearGradient(
            colors: [.pink.opacity(0.85), .purple.opacity(0.6), .blue.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .leading) {
            VStack(alignment: .leading, spacing: 2) {
                Text("乐遇")
                    .font(.title2)
                    .fontWeight(.bold)
                    .fontDesign(.rounded)
                    .foregroundStyle(.white)
                Text("\(Date().chineseDateString) · \(Date().chineseWeekdayString)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                Text("AI 驱动的个性化歌单")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(20)
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Today Card

    @ViewBuilder
    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch vm.state {
            case .idle, .onboarding:
                idleCard
            case .completed(let count, let name):
                completedCard(trackCount: count, playlistName: name)
            case .readingLibrary, .generating, .searchingCatalog, .persistingRecord, .creatingPlaylist:
                ImmersiveProgressView(state: vm.state, onCancel: {})
            case .error(let msg, let retry):
                errorCard(message: msg, retryable: retry)
            }
        }
    }

    // MARK: Idle State

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日推荐")
                .font(.headline)
                .padding(.leading, 4)

            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("✨ 准备好发现新音乐了吗？")
                        .font(.body)
                        .fontWeight(.medium)
                    Text("基于你的收藏品味，AI 为你推荐专属好歌")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                // Direct generate button
                Button {
                    vm.triggerDailyRecommendation()
                } label: {
                    Label("直接生成歌单", systemImage: "wand.and.stars")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [.blue, .purple.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                }
                .disabled(!vm.canTrigger)

                // Style picker button
                Button {
                    vm.showStylePicker = true
                } label: {
                    Label("选择风格生成", systemImage: "paintpalette")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .disabled(!vm.canTrigger)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        }
    }

    // MARK: Completed State

    private func completedCard(trackCount: Int, playlistName: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日推荐")
                .font(.headline)
                .padding(.leading, 4)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(.green.opacity(0.1))
                        .frame(width: 64, height: 64)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.green)
                }

                VStack(spacing: 4) {
                    Text("歌单已就绪")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("「\(playlistName)」")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("共 \(trackCount) 首歌曲")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    Button {
                        if let url = URL(string: "music://") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("在 Apple Music 中查看", systemImage: "play.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.green, in: RoundedRectangle(cornerRadius: 14))
                    }

                    Button {
                        vm.forceRegenerate()
                    } label: {
                        Label("重新生成", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        }
    }

    // MARK: Error State

    private func errorCard(message: String, retryable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日推荐")
                .font(.headline)
                .padding(.leading, 4)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(.orange.opacity(0.1))
                        .frame(width: 64, height: 64)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.orange)
                }

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if retryable {
                    Button("重试") {
                        vm.triggerDailyRecommendation()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        }
    }

    // MARK: - Recent Playlists

    private var recentPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近歌单")
                    .font(.headline)
                Spacer()
                if !vm.recentRecords.isEmpty {
                    NavigationLink("查看全部") {
                        PlaylistHistoryView()
                    }
                    .font(.subheadline)
                }
            }
            .padding(.leading, 4)

            if vm.recentRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("生成第一份歌单后，它会出现在这里")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(spacing: 8) {
                    ForEach(vm.recentRecords) { record in
                        NavigationLink {
                            PlaylistDetailView(record: record)
                        } label: {
                            PlaylistCard(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 12) {
            statCard(
                icon: "music.note.list",
                value: "\(vm.totalRecommendations)",
                label: "份歌单"
            )
            statCard(
                icon: "clock",
                value: "每日 6:00",
                label: "自动推荐"
            )
        }
    }

    private func statCard(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Helpers

    private func requestAuth() {
        Task {
            let status = await MusicAuthorization.request()
            await MainActor.run {
                auth = (status == .authorized) ? .authorized : .denied
            }
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
            Circle()
                .fill(.secondary.opacity(0.12))
                .frame(width: 100, height: 100)
                .overlay {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
            Text("需要 Apple Music 访问权限")
                .font(.title3)
                .fontWeight(.semibold)
            Text("请在设置中开启权限，乐遇才能为你生成个性化推荐。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }
}
