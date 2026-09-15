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

    // MARK: - API Key 输入状态

    /// 用户正在打、但还没保存的内容。
    ///
    /// **刻意不回填已存的 Key。** 回填意味着每次打开 sheet 都要把明文凭据读进
    /// 视图状态、一直活到 sheet 关闭 —— 截屏、内存里都是它；而且会制造一个歧义：
    /// 「字段里有内容」到底是「已配置的 Key」还是「用户刚改的草稿」？
    /// 留空字段 + 状态行是 iOS 上 token 字段的惯例：要换就输新的点保存，
    /// 要删就点清除。
    @State private var draftKey = ""
    @State private var keyCheck: KeyCheck = .idle
    @State private var showClearConfirm = false
    /// 「更换」是否已展开输入框。**已配置时默认收起** —— 见 `showsInput`。
    @State private var isChangingKey = false

    /// 保存后那次连通性探测的结果。
    ///
    /// `.failed` 承载的文案由调用方拼好 —— 「存不上」和「存上了但验不了」
    /// 是两件事，合并成一句会让用户误解自己该做什么。
    private enum KeyCheck: Equatable {
        case idle, checking, ok, invalid, noBalance, failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                // 放第一个：其余五个 section 都是**信息展示**，只有它是**可操作的**；
                // 而 `.medium` detent 下用户一进来就该看见它，不用滚动。
                apiKeySection
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
        // 必须与 `probeSheet` / `debugSection` 的 `#if DEBUG` 同步。
        // 原先这里没有包裹，于是 **Release 构建一直编译不过**（`cannot find
        // 'probeSheet' in scope`）—— 只跑 Debug 的话完全看不到。
        #if DEBUG
        .sheet(isPresented: Binding(
            get: { probeReport != nil },
            set: { if !$0 { probeReport = nil } }
        )) {
            probeSheet
        }
        #endif
    }

    // MARK: - DeepSeek API Key

    /// 要不要显示输入框。
    ///
    /// 没配过 → 必须显示（否则无从下手）；配过了 → 只在用户主动点「更换」时展开。
    private var showsInput: Bool { !vm.isAPIKeyConfigured || isChangingKey }

    private var statusBadge: some View {
        Group {
            if vm.isAPIKeyConfigured {
                Label("已保存", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("未配置")
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
    }

    private var apiKeySection: some View {
        Section {
            HStack {
                Image(systemName: "key.fill")
                    .foregroundStyle(Theme.brand)
                Text("DeepSeek API Key")
                Spacer()
                statusBadge
            }

            // **已配置且不在更换中时，整个输入区收起。**
            //
            // 原实现把 SecureField 一直摆在那儿（因为刻意不回填已存的 Key），
            // 结果每次进设置都像在说「请再输一遍」—— 用户会怀疑到底存没存上。
            // 收起之后，没有输入框本身就是「已经存好了」最直接的表达，
            // 而「更换」按钮保留了改 Key 的出路。
            if !showsInput {
                HStack {
                    Button("更换") { beginChanging() }
                    Spacer()
                    Button("清除", role: .destructive) { showClearConfirm = true }
                }
            } else {
                SecureField("sk-…", text: $draftKey)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    // 挡住密码自动填充往这里塞东西，也让这个字段参与截屏保护。
                    .textContentType(.password)
                    .privacySensitive()
                    .onSubmit(save)

                HStack {
                    Button("保存", action: save)
                        .disabled(!APIKeyPolicy.isUsable(draftKey) || keyCheck == .checking)

                    Spacer()

                    // 已经存过一把时，更换动作要能反悔 —— 否则点开「更换」
                    // 就只能一路填到底，连退出的路都没有。
                    if vm.isAPIKeyConfigured {
                        Button("取消") { cancelChanging() }
                    }
                }
            }
        } header: {
            Text("DeepSeek")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("乐遇用你自己的 DeepSeek API Key 生成推荐。Key 只保存在本机的钥匙串里，不会上传到任何服务器。")
                keyStatusLine
                if let error = vm.profileRefreshError {
                    Label("口味画像生成失败：\(error)", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .confirmationDialog("清除 API Key？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清除", role: .destructive, action: clear)
        } message: {
            Text("清除后需要重新填写才能生成歌单。")
        }
    }

    @ViewBuilder
    private var keyStatusLine: some View {
        switch keyCheck {
        case .idle:
            EmptyView()
        case .checking:
            Label("正在验证…", systemImage: "ellipsis.circle")
        case .ok:
            Label("Key 有效", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid:
            Label("这把 Key 无效或已过期", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .noBalance:
            Label("Key 有效，但账户余额不足", systemImage: "xmark.circle.fill")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        }
    }

    /// 保存 = **先落盘、后联网**。
    ///
    /// 顺序不能反：离线时 Key 也必须存得下来。校验只是**追加**一句结论，
    /// 它失败不影响保存已经成功这个事实。
    private func save() {
        do {
            try vm.saveAPIKey(draftKey)
        } catch {
            keyCheck = .failed("保存失败：\(error.localizedDescription)")
            return
        }
        draftKey = ""
        // 落盘成功就把输入区收起来 —— 用户看到的不再是「一个等着被填的空框」，
        // 而是「已保存」加一条验证结论。这正是「别再让我输一遍」的修法。
        isChangingKey = false
        keyCheck = .checking

        Task {
            do {
                try await vm.verifyAPIKey()
                keyCheck = .ok
            } catch let error as LLMServiceError {
                keyCheck = Self.map(error)
            } catch {
                // 网络异常不是 Key 的问题。用户在地铁里保存，Key 是好的，
                // 不能吓唬他 —— 所以文案明确说「已保存」。
                keyCheck = .failed("已保存，但暂时无法验证：\(error.localizedDescription)")
            }
        }
    }

    private func clear() {
        do {
            try vm.clearAPIKey()
            draftKey = ""
            keyCheck = .idle
            isChangingKey = false
        } catch {
            keyCheck = .failed("清除失败：\(error.localizedDescription)")
        }
    }

    private func beginChanging() {
        draftKey = ""
        keyCheck = .idle
        isChangingKey = true
    }

    private func cancelChanging() {
        draftKey = ""
        keyCheck = .idle
        isChangingKey = false
    }

    /// 状态码映射是这次校验的全部价值所在 —— 只说「失败」等于没说。
    private static func map(_ error: LLMServiceError) -> KeyCheck {
        guard case .httpError(let code, _) = error else {
            return .failed("已保存，但验证失败：\(error.localizedDescription)")
        }
        switch code {
        case 401: return .invalid
        case 402: return .noBalance
        default: return .failed("已保存，但验证失败（HTTP \(code)）")
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
