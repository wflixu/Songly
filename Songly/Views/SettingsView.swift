//
//  SettingsView.swift
//  Songly
//
//  从底部 Tab 改为 sheet。它自带 `NavigationStack` —— 否则既没有标题也没有
//  关闭按钮（sheet 不在呈现者的导航栈里），只剩下拉手势一条退路。
//
//  权限状态**全部来自 `HomeViewModel`**，这里不持有任何副本。原先设置页自己
//  存了一份 `@State authOk`，和首页那份是独立快照，必然漂移；而且只在 `.task`
//  里读一次，从系统设置授权回来不会更新。
//

import SwiftUI
import SwiftData
import MusicKit
import UIKit

struct SettingsView: View {
    @Environment(HomeViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    /// 画像存在 UserDefaults 里，读一次很便宜，不需要走依赖注入。
    private let profileStore = TasteProfileStore()

    /// 仅探测用：拿最近一份歌单里的第一首歌当样本。
    @Query(sort: \RecommendationRecord.date, order: .reverse)
    private var records: [RecommendationRecord]

    @State private var probeReport: String?

    var body: some View {
        NavigationStack {
            List {
                tasteSection
                feedbackSection
                permissionSection
                aboutSection
                #if DEBUG
                debugSection
                #endif
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        // 必须挂在 sheet 的**根**上；挂在 List 上不生效。
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: Binding(
            get: { probeReport != nil },
            set: { if !$0 { probeReport = nil } }
        )) {
            probeSheet
        }
    }

    // MARK: - 我的反馈

    private var feedbackSection: some View {
        Section {
            NavigationLink {
                FeedbackHistoryView()
            } label: {
                Label("我的反馈", systemImage: "hand.thumbsup")
            }
        } footer: {
            Text("查看并撤销你对歌单和单曲的评价。删除过的歌不会再被推荐。")
        }
    }

    // MARK: - AI 眼中的你

    @ViewBuilder
    private var tasteSection: some View {
        Section {
            if let profile = profileStore.load() {
                let payload = profile.payload

                if !payload.coreGenres.isEmpty {
                    chipRow("核心风格", payload.coreGenres)
                }
                if !payload.representativeArtists.isEmpty {
                    chipRow("代表艺人", payload.representativeArtists)
                }
                infoRow("年代偏好", payload.eraPreference)
                infoRow("情绪特征", payload.moodSignature)
                infoRow("人声偏好", payload.vocalPreference)
                infoRow("语言分布", payload.languageDistribution)

                // 「已经听腻的方向」是画像里最有价值的一条 —— 它直接解释了
                // 为什么推荐会绕开某些东西。之前它只喂给了 prompt，用户看不到。
                if !payload.tiredOf.isEmpty {
                    chipRow("已经听腻", payload.tiredOf, tint: .orange)
                }
                if !payload.summary.isEmpty {
                    Text(payload.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                }

                Text("更新于 \(profile.generatedAt.relativeDayString)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("还没有建立口味画像。生成第一份歌单后就会有。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI 眼中的你")
        } footer: {
            Text("这是 AI 对你的音乐口味的理解，每次推荐都基于它。")
        }
    }

    private func chipRow(_ title: String, _ items: [String], tint: Color = Theme.brand) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(.caption)
                            .foregroundStyle(tint)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.12), in: Capsule())
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func infoRow(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 权限

    private var permissionSection: some View {
        Section {
            permissionRow(
                icon: "music.note", tint: .red, title: "Apple Music",
                ok: vm.authStatus == .authorized
            )
            permissionRow(
                icon: "bell.fill", tint: .orange, title: "通知",
                ok: vm.notificationAuthorized
            )
        } header: {
            Text("权限")
        }
    }

    private func permissionRow(icon: String, tint: Color, title: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(title)
            Spacer()
            if ok {
                Text("已开启")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Button("去设置") { openSettings() }
                    .font(.subheadline)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: Self.appVersion)
        } header: {
            Text("关于")
        }
    }

    /// 读 bundle，而不是写死。原先这里硬编码着 "1.0.0"。
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String, build != short else {
            return short
        }
        return "\(short) (\(build))"
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - 调试（仅 DEBUG）

    #if DEBUG
    private var debugSection: some View {
        Section {
            Button("探测：写回评分") { runProbe() }
        } header: {
            Text("调试")
        } footer: {
            Text("验证三件事：MusicDataRequest 能否带 body 发 PUT、写端点用目录 ID 还是资料库 ID、请求体形状。结论决定 AppConfig.writeBackLovedRating 能不能打开。")
        }
    }

    private var probeSheet: some View {
        NavigationStack {
            ScrollView {
                Text(probeReport ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("评分写回探测")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { probeReport = nil }
                }
            }
        }
    }

    private func runProbe() {
        guard let songID = records.first?.tracks.first?.id else {
            probeReport = "没有可用的曲目 ID —— 先在首页生成一份歌单。"
            return
        }
        probeReport = "探测中…"
        Task {
            let report = await MusicLibraryService().probeRatingWrite(songID: songID)
            probeReport = report
            print(report)
        }
    }
    #endif
}
