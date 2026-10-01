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
    @Environment(\.modelContext) private var modelContext

    /// 画像存在 UserDefaults 里，读一次很便宜，不需要走依赖注入。
    private let profileStore = TasteProfileStore()

    /// 仅探测用：拿最近一份歌单里的第一首歌当样本。
    @Query(sort: \RecommendationRecord.date, order: .reverse)
    private var records: [RecommendationRecord]

    @State private var probeReport: String?

    // MARK: - 导出诊断数据

    /// 导出文件的 URL。非 nil 即呈现分享面板 —— 与上面的 `probeReport` 同一套路
    /// （可选值本身就是「有没有东西要展示」的状态，不必再单开一个 Bool）。
    @State private var exportURL: URL?
    @State private var exportError: String?

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
        List {
            // 顺序 = 「可操作 → 状态 → 内容」。依据是功能审计
            // （见 `specs/revamp-plan.md` 第 4 项）：只有前两段是用户能动手的，
            // 后面全是展示。原先「AI 眼中的你」排第二，把可操作的东西挤到了屏幕外。
            apiKeySection
            feedbackSection
            exportSection
            permissionSection
            tasteSection
            aboutSection
            #if DEBUG
            debugSection
            #endif
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        // ⚠️ 这里**没有** NavigationStack、没有「关闭」按钮、没有 presentationDetents。
        // 它是被 push 进来的，宿主已经提供返回按钮；再套一层 NavigationStack 会
        // 出现两层导航栏，而 detent 在推入式导航里根本没有意义。
        .sheet(isPresented: Binding(
            get: { exportURL != nil },
            set: { if !$0 { exportURL = nil } }
        )) {
            exportSheet
        }
        .alert(
            "导出失败",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("好", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
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

    // MARK: - 导出诊断数据

    private var exportSection: some View {
        Section {
            Button(action: exportDiagnostics) {
                Label("导出诊断数据", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("数据")
        } footer: {
            // 这件事必须说清楚：导出是**往外发**的动作，不是本地保存。
            Text("把推荐记录、算法版本和每次运行的诊断导成一份 JSON，用于离线分析。"
                 + "注意：文件会离开这台设备，它包含你的歌单、歌名、艺人，以及你对单曲和歌单的评价。")
        }
    }

    private var exportSheet: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.brand)

                VStack(spacing: Theme.Spacing.sm) {
                    Text("导出文件已生成")
                        .font(.headline)
                    Text("用系统分享把它存到「文件」，或直接发出去。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let url = exportURL {
                    // 用 `ShareLink` 而不是自绘分享面板 —— 它是苹果的标准入口，
                    // 自带「存储到文件 / 隔空投送 / 拷贝」等全部目标。
                    ShareLink(item: url) {
                        Label("分享 / 存储", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.Size.primaryButton)
                    }
                    .buttonStyle(.borderedProminent)

                    // 文件名里带着算法版本与时间戳，两个批次的导出不会认错。
                    Text(url.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(Theme.Spacing.xl)
            .navigationTitle("导出诊断数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { exportURL = nil }
                }
            }
        }
    }

    /// 生成导出文件。
    ///
    /// **先落盘、再给按钮**：分享面板要的是一个已经存在的 URL，
    /// 所以这里同步生成（记录数量是几十到几百条，耗时可以忽略）。
    private func exportDiagnostics() {
        do {
            exportURL = try DiagnosticsExporter.write(context: modelContext)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - AI 眼中的你

    /// 展开态。**`@State` 不持久化**，所以每次进设置都是收起的 —— 正是要的效果。
    @State private var isTasteExpanded = false

    /// 这一块原先占的篇幅最大，却**零功能**（八个字段全是只读展示）。
    ///
    /// 问题不是「太大」，是**没有归宿** —— 它是*内容*，被塞进了一个放*配置*的容器里，
    /// 只能靠篇幅撑着。按「功能决定样式」：只读内容拿最弱的形式 —— 收起时给一眼能
    /// 看完的线索，点开才出全部字段；位置也挪到可操作项之后。
    private var tasteSection: some View {
        Section {
            // `DisclosureGroup` 是 List 内的原生展开容器，不自己搭。
            DisclosureGroup(isExpanded: $isTasteExpanded) {
                if let profile = profileStore.load() {
                    tasteDetail(profile.payload)
                } else {
                    Text("还没有建立口味画像。生成第一份歌单后就会有。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } label: {
                tasteSummary
            }
        } header: {
            Text("AI 眼中的你")
        } footer: {
            Text("这是 AI 对你的音乐口味的理解，每次推荐都基于它。")
        }
    }

    /// 收起态：**一行摘要 + 关键项**。
    ///
    /// 「听腻了 N 个方向」被单独拎出来：它是画像里最有价值的一条 ——
    /// 直接解释了推荐为什么绕开某些东西，而在此之前它只喂给了 prompt，用户看不到。
    @ViewBuilder
    private var tasteSummary: some View {
        if let profile = profileStore.load() {
            let payload = profile.payload
            VStack(alignment: .leading, spacing: 3) {
                Text(coreGenresSummary(payload))
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                HStack(spacing: 10) {
                    if !payload.tiredOf.isEmpty {
                        Text("听腻了 \(payload.tiredOf.count) 个方向")
                            .foregroundStyle(.orange)
                    }
                    Text("更新于 \(profile.generatedAt.relativeDayString)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 1)
        } else {
            Text("还没有建立口味画像")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func coreGenresSummary(_ payload: TasteProfilePayload) -> String {
        let genres = payload.coreGenres.prefix(3)
        if !genres.isEmpty {
            return genres.joined(separator: " · ")
        }
        // 画像刚建好、核心风格还没攒够时，退回一句话摘要的**首句**，
        // 而不是直接显示「（暂无）」—— 那句摘要本身就有信息量。
        return payload.summary.isEmpty ? "（暂无摘要）" : String(payload.summary.prefix(24))
    }

    /// 展开态：原来的八个字段，一个没少，渲染逻辑也照旧。
    @ViewBuilder
    private func tasteDetail(_ payload: TasteProfilePayload) -> some View {
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

        if !payload.tiredOf.isEmpty {
            chipRow("已经听腻", payload.tiredOf, tint: .orange)
        }
        if !payload.summary.isEmpty {
            Text(payload.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
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

    /// 用 `LabeledContent` 而不是手写 `HStack { … Spacer() … }`。
    ///
    /// 它是苹果给「左标题 + 右状态」的标准容器：形状与同页的「关于 · 版本」一致，
    /// 也省掉一堆自己维护的对齐代码 —— 手写那版在 Dynamic Type 放大后会错位。
    private func permissionRow(icon: String, tint: Color, title: String, ok: Bool) -> some View {
        LabeledContent {
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
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(tint)
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
            Button("探测：读回评分") { runReadProbe() }
            Button("探测：歌单条目") { runEntriesProbe() }
            Button("探测：删除歌单") { runDeleteProbe() }
        } header: {
            Text("调试")
        } footer: {
            Text("写回探测：确认 PUT 端点与请求体形状，结论决定 writeBackLovedRating。\n"
                 + "读回探测：确认 ⭐ 收藏读不读得到，结论决定 readAppleMusicRatings。\n"
                 + "歌单条目探测：确认歌单 diff 能不能做（匹配率 < 90% 就得整个关掉）。\n"
                 + "删除探测：确认删歌单可不可用，决定第 3 项怎么做。")
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
            .navigationTitle("探测报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { probeReport = nil }
                }
            }
        }
    }

    private func runProbe() {
        guard let songID = newestCompletedRecord?.tracks.first?.id else {
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

    /// 最近一份**已完成**的歌单。
    ///
    /// `records` 是不带 status 过滤的裸查询，直接取 `first` 可能拿到 `pending`
    /// 或 `failed` 的记录 —— 那些没有歌单 ID，探测会白跑。
    private var newestCompletedRecord: RecommendationRecord? {
        records.first {
            $0.status == RecommendationRecord.statusCompleted && !$0.tracks.isEmpty
        }
    }

    /// 读回评分探测。
    ///
    /// 一次取 5 首而不是 1 首：判读需要**阴性对照**（至少一首标过 ⭐、至少一首没标过），
    /// 只取一首的话大概率两样都碰不上，跑完还是不知道端点通不通。
    private func runReadProbe() {
        let ids = Array((newestCompletedRecord?.tracks.prefix(5) ?? []).map(\.id))
        guard !ids.isEmpty else {
            probeReport = "没有可用的曲目 ID —— 先在首页生成一份歌单。"
            return
        }
        probeReport = "探测中…"
        Task {
            let report = await MusicLibraryService().probeRatingRead(songIDs: ids)
            probeReport = report
            print(report)
        }
    }

    private func runEntriesProbe() {
        guard let record = newestCompletedRecord,
              let playlistID = record.playlistID else {
            probeReport = "没有带歌单 ID 的记录 —— 先生成一份歌单。"
            return
        }
        let titles = record.tracks.map(\.name)
        probeReport = "探测中…"
        Task {
            let report = await MusicLibraryService()
                .probePlaylistEntries(playlistID: playlistID, expectedTitles: titles)
            probeReport = report
            print(report)
        }
    }

    private func runDeleteProbe() {
        probeReport = "探测中…（会新建一份一次性歌单再删它，不碰你已有的歌单）"
        Task {
            let report = await MusicLibraryService().probePlaylistDelete()
            probeReport = report
            print(report)
        }
    }
    #endif
}
