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
                // 没配 Key 时整个推荐管线都跑不起来（引擎第 1 轮就抛
                // `apiKeyNotConfigured`），所以这里换掉 hero 槽位，而不是等用户
                // 点了生成再看一张错误卡。
                //
                // 用 `Group` 包住分支才能把 `.padding` 施加在分支结果上 ——
                // 直接给 if/else 挂修饰符不编译。
                //
                // 只换这一处、不动 `body` 里那个 `authStatus` switch：授权与 Key
                // 是两个正交的先决条件，挤进同一个 switch 就必须回答「Music 被拒
                // + 没 Key 该显示哪个」，而任何答案都会让用户白跑一趟。
                Group {
                    if vm.isAPIKeyConfigured {
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
                    } else {
                        APIKeySetupCard { vm.showSettings = true }
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)

                // `styleSection` / `recentSection` 都保留：历史上生成的歌单不该
                // 因为换了个 Key 就消失，而 `StyleChips(isEnabled: vm.canTrigger)`
                // 会因为 `canTrigger` 多了一个条件自动置灰，零改动。
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

// MARK: - 未配置 API Key

/// 「还没填 Key」的 hero 卡。
///
/// 视觉上照抄 `TodayCard.idleCard` 的骨架（同一块 `Theme.brandGradient`、
/// 同一个圆角、同一颗胶囊按钮）—— 它们是同一张 hero 卡的两个面孔，
/// 读起来应该是「这张卡还没有内容」，而不是「换了一个 App」。
private struct APIKeySetupCard: View {
    let onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label("先配置 DeepSeek API Key", systemImage: "key.fill")
                    .font(.title3.weight(.semibold))

                Text("乐遇用你自己的 API Key 生成推荐。Key 只保存在这台设备的钥匙串里，不会上传。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.onBrandSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onConfigure) {
                Label("去设置", systemImage: "gearshape")
                    .font(.headline)
                    .foregroundStyle(Theme.brand)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Size.primaryButton)
                    .background(Theme.onBrand, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Theme.onBrand)
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.brandGradient)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
