//
//  HomeView.swift
//  Songly
//
//  单屏首页。App 只有一件事 —— 每天给你一份歌单 —— 所以屏幕也只有一件事。
//
//  刻意**没有底部 Tab**：两个常驻页签（首页/设置）对「一件事」的 App 是多余的，
//  设置收进导航栏右上角。
//
//  横向 padding 由每个子视图各自承担，而不是套在最外层 VStack 上 —— 风格
//  chips 需要通铺到屏幕边缘才能横向滚动出血。
//

import SwiftUI
import MusicKit
import UIKit

struct HomeView: View {
    @Environment(HomeViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        Group {
            switch vm.authStatus {
            case .notDetermined:
                OnboardingView {
                    Task { await vm.requestMusicAuthorization() }
                }
            case .denied:
                DeniedView {
                    Task { await vm.refreshPermissionState() }
                }
            case .authorized:
                content
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("乐遇")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    vm.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
        .sheet(isPresented: $vm.showSettings) {
            SettingsView()
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                TodayCard(
                    state: vm.state,
                    record: vm.todayRecord,
                    canTrigger: vm.canTrigger,
                    isOffline: vm.isOffline,
                    actions: TodayCard.Actions(
                        generate: vm.triggerDailyRecommendation,
                        regenerate: vm.forceRegenerate,
                        openInMusic: openInMusic,
                        cancel: vm.cancelGeneration
                    )
                )
                .padding(.horizontal, Theme.Spacing.page)

                styleSection
                recentSection
            }
            .padding(.top, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xl)
        }
    }

    // MARK: - 换个心情

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("换个心情")
                .font(.headline)
                .padding(.horizontal, Theme.Spacing.page)

            StyleChips(isEnabled: vm.canTrigger) { style in
                vm.triggerStyledRecommendation(style: style)
            }
        }
    }

    // MARK: - 最近

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("最近")
                    .font(.headline)

                Spacer()

                if !vm.recentRecords.isEmpty {
                    NavigationLink("查看全部") { PlaylistHistoryView() }
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)

            if vm.recentRecords.isEmpty {
                Text("生成第一份歌单后，它会出现在这里")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .cardSurface(radius: Theme.Radius.control)
                    .padding(.horizontal, Theme.Spacing.page)
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(vm.recentRecords) { record in
                        NavigationLink {
                            PlaylistDetailView(record: record)
                        } label: {
                            PlaylistRow(record: record, showsDisclosure: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
            }
        }
    }

    // MARK: - Actions

    /// 打开今天那份歌单。
    ///
    /// 退到 `music://` 只在**引擎确实没拿到深链**时发生（`Playlist.url` 本身
    /// 是 Optional）。这和之前的 bug 不是一回事 —— 那时是因为 QuickPick 记录
    /// 根本没被 `todayRecord` 认出来，导致每一次都退化。
    private func openInMusic() {
        let url = vm.todayRecord?.playlistURL ?? URL(string: "music://")
        guard let url else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - 授权被拒

private struct DeniedView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)

            VStack(spacing: Theme.Spacing.sm) {
                Text("需要 Apple Music 访问权限")
                    .font(.title3.weight(.semibold))
                Text("请在设置中开启权限，乐遇才能为你生成个性化推荐。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: Theme.Spacing.sm) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("打开设置")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Size.primaryButton)
                }
                .buttonStyle(.borderedProminent)

                // 没有这个按钮，用户授权完回到 App 仍然停在这一页 ——
                // 授权状态只在进前台时刷新，而这一页本身不会自己重算。
                Button("我已授权，重试", action: onRetry)
                    .font(.subheadline)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .padding(Theme.Spacing.xl)
    }
}

// HomeView 没有 `#Preview`：它依赖整套服务图（engine / container / 后台服务），
// 在预览里搭一遍既啰嗦又脆弱，而且真实运行时要先过 MusicKit 授权、预览里只会
// 停在 Onboarding。各组件（TodayCard / StyleChips / PlaylistRow / TrackRow）
// 都有自己的 preview，那才是值得看的地方。
