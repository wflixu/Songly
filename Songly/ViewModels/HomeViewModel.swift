//
//  HomeViewModel.swift
//  Songly
//
//  @Observable @MainActor: bridges RecommendationEngine → the UI.
//  单屏重构后它也是**唯一**的授权状态持有者 —— 首页与设置页都读它这一份。
//

import Foundation
import SwiftUI
import Observation
import SwiftData
import MusicKit
import UserNotifications

// MARK: - Auth

/// Apple Music 授权状态。
///
/// 从 `HomeView` 的文件私有枚举搬过来：它现在同时被首页和设置页读取，两处
/// 各持一份快照必然会漂移（设置页显示「已授权」而首页还停在 Onboarding）。
enum AuthStatus: Equatable {
    case notDetermined, authorized, denied
}

// MARK: - View Model

@MainActor
@Observable
final class HomeViewModel {
    private(set) var state: RecommendationState = .idle
    private(set) var todayRecord: RecommendationRecord?
    private(set) var recentRecords: [RecommendationRecord] = []
    private(set) var authStatus: AuthStatus
    private(set) var notificationAuthorized = false

    /// 设置 sheet 的呈现开关。
    var showSettings = false

    private let engine: RecommendationEngine
    private let networkMonitor: NetworkMonitor
    private let modelContainer: ModelContainer
    private let backgroundService: BackgroundTaskService
    private let profileRefresher: TasteProfileRefresher
    private var observers: [NSObjectProtocol] = []

    // MARK: - API Key

    /// **private**：设置页不直接碰凭据，所有读写都走下面的方法。
    /// 这样「谁写的 Key」和「谁读的 Key」在同一段代码里，且明文 Key 永不进入视图层。
    private let keyStore: any APIKeyStoring
    private let llmService: LLMServiceProtocol

    /// 首页据此决定 hero 槽位放 `TodayCard` 还是「去配置 Key」。
    /// 与 `authStatus` 一样是 `private(set)` 单一真相源 —— 设置页不持有副本，
    /// 否则两个快照必然会漂移（本文件头部记过这个坑）。
    private(set) var isAPIKeyConfigured: Bool

    /// 口味画像最近的失败原因。未配置 Key 时**不记录** —— 那不是新闻，
    /// 设置页同一屏已经在显示「未配置」了，再叠一条失败原因只是噪音。
    private(set) var profileRefreshError: String?

    var isLoading: Bool {
        switch state {
        case .idle, .completed, .error, .onboarding:
            return false
        default:
            return true
        }
    }

    /// 直接从 `NetworkMonitor` 派生，而不是各存一份。
    ///
    /// 原来 `isOffline` 是个声明了却**从未被赋值**的存储属性，两处 `guard`
    /// 因此永远不触发，`NetworkMonitor` 注入了但没人读。
    var isOffline: Bool { !networkMonitor.isConnected }

    /// 没配 Key 时点「生成」必然失败（引擎第 1 轮就抛 `apiKeyNotConfigured`），
    /// 所以在这里就拦住 —— 让按钮变灰，而不是让用户等 40 秒再看一张错误卡。
    ///
    /// 因为这是所有入口的公共闸门，改这一行会连带把 `StyleChips` 也置灰。
    var canTrigger: Bool { !isOffline && !isLoading && isAPIKeyConfigured }

    init(
        engine: RecommendationEngine,
        networkMonitor: NetworkMonitor,
        modelContainer: ModelContainer,
        backgroundService: BackgroundTaskService,
        profileRefresher: TasteProfileRefresher,
        llmService: LLMServiceProtocol,
        keyStore: any APIKeyStoring
    ) {
        self.engine = engine
        self.networkMonitor = networkMonitor
        self.modelContainer = modelContainer
        self.backgroundService = backgroundService
        self.profileRefresher = profileRefresher
        self.llmService = llmService
        self.keyStore = keyStore
        // 与 `authStatus` 同理：`load()` 是同步的，在这里播种，别让首页先闪一下
        // 「未配置」再跳到正确状态。
        self.isAPIKeyConfigured = APIKeyPolicy.isUsable(keyStore.load() ?? "")
        // `MusicAuthorization.currentStatus` 是同步的，所以在这里直接播种。
        // 原先 HomeView 是 `@State = .notDetermined` 加一个 `.task` 去补，结果
        // 已授权的用户每次冷启动都会先闪一下 Onboarding 再跳到首页。
        self.authStatus = Self.mapStatus(MusicAuthorization.currentStatus)

        observers.append(NotificationCenter.default.addObserver(
            forName: .recommendationDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reloadAfterBackgroundCompletion() }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .recommendationRecordDeleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.loadRecentRecords() }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .tasteProfileRefreshFailed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                // 未配置 Key 时画像**必然**失败，那不是需要展示的异常。
                guard let self, self.isAPIKeyConfigured else { return }
                self.profileRefreshError = note.userInfo?["message"] as? String
            }
        })

        Task {
            await restoreTodayState()
            await loadRecentRecords()
            await refreshNotificationStatus()
        }
    }

    // MARK: - Permissions

    static func mapStatus(_ status: MusicAuthorization.Status) -> AuthStatus {
        switch status {
        case .authorized:  return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default:  return .denied
        }
    }

    /// **只读，不请求**，所以可以安全地每次回到前台都调。
    ///
    /// 触发点只有一个：`ContentView` 上那个 `.onChange(of: scenePhase)`。
    /// 不要在设置 sheet 里再挂一个 —— 两个快照就会漂移。
    func refreshPermissionState() async {
        authStatus = Self.mapStatus(MusicAuthorization.currentStatus)
        await refreshNotificationStatus()
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthorized = settings.authorizationStatus == .authorized
    }

    func requestMusicAuthorization() async {
        authStatus = Self.mapStatus(await MusicAuthorization.request())
        guard authStatus == .authorized else { return }

        // 通知授权放到这里，而不是 App 启动时 —— 否则会在用户还没授权
        // Music 的时候就弹出第二个系统弹窗。
        _ = await NotificationService.shared.requestPermission()
        await refreshNotificationStatus()

        // 后台调度的入口。**不能**挪到 App 启动时：`schedule()` 内部会静默
        // 检查授权，启动那一刻用户还没授权，整个后台功能会静默失效。
        //
        // 同时要求已配置 Key：没有它，每日唤醒会跑一遍管线、第 1 轮就失败，
        // 而那个错误没有任何监听者 —— 纯粹的空转。
        // 反过来的顺序（先填 Key 后授权）由 `saveAPIKey` 补挂。
        if isAPIKeyConfigured {
            backgroundService.schedule()
        }

        // 首启时画像是在未授权状态下尝试的、直接返回了。授权成功后必须补一次，
        // 否则画像永远建不起来。
        await refreshTasteProfile()
    }

    /// 口味画像的刷新入口。
    ///
    /// **只在两处调用**：App 启动后一次，以及授权刚变成 authorized 时一次。
    /// 不要挂到 `scenePhase` 上 —— `TasteProfileRefresher.refreshIfNeeded()`
    /// 会**先拉 200 首曲库**再做指纹判断，挂到前台切换等于每次回前台拉一次全库。
    func refreshTasteProfile() async {
        await profileRefresher.refreshIfNeeded()
    }

    // MARK: - API Key

    /// 写入 Key 并立刻刷新首页状态。
    ///
    /// **先落盘、后联网**：连通性校验（`verifyAPIKey`）是调用方独立的一步，
    /// 离线时 Key 也必须存得下来。
    ///
    /// 空输入**等价于清除**，省掉一个「字段清空了但没点清除」的歧义状态。
    func saveAPIKey(_ raw: String) throws {
        let normalized = APIKeyPolicy.normalize(raw)
        guard !normalized.isEmpty else { return try clearAPIKey() }

        try keyStore.save(APIKeyPolicy.validate(normalized))
        isAPIKeyConfigured = true
        profileRefreshError = nil

        // 之前因为没 Key 而被跳过的后台调度，现在补上 —— 覆盖「先授权、
        // 很久以后才填 Key」这个顺序。反向顺序在 `requestMusicAuthorization` 里。
        if authStatus == .authorized {
            backgroundService.schedule()
        }
    }

    func clearAPIKey() throws {
        try keyStore.clear()
        isAPIKeyConfigured = false
        profileRefreshError = nil
    }

    /// 保存后的连通性探测。**只负责给用户一句结论**，不参与任何业务判断。
    ///
    /// 抛出的错误由调用方区分「Key 有问题」（`LLMServiceError.httpError` 4xx）与
    /// 「网线有问题」（URLError）—— 这两件事对用户的含义完全不同。
    func verifyAPIKey() async throws {
        try await llmService.verifyCredentials()
    }

    // MARK: - Generation

    func triggerDailyRecommendation() {
        guard canTrigger else { return }
        startRecommendation(source: "daily", quickPickStyle: nil)
    }

    func triggerStyledRecommendation(style: QuickPickStyle) {
        guard canTrigger else { return }
        startRecommendation(source: "quick_pick", quickPickStyle: style)
    }

    func forceRegenerate() {
        guard canTrigger else { return }
        if let record = loadTodayRecord() {
            modelContainer.mainContext.delete(record)
            try? modelContainer.mainContext.save()
        }
        startRecommendation(source: "daily", quickPickStyle: nil)
    }

    /// 取消正在跑的生成。
    ///
    /// `RecommendationEngine.cancel()` 早就存在，管线里也埋好了协作式的
    /// `Task.isCancelled` 检查 —— 只是 UI 从来没接过它，于是「取消生成」
    /// 那个按钮在整个生成过程中可见却什么都做不了。
    func cancelGeneration() {
        Task { await engine.cancel() }
    }

    // MARK: - Data

    /// 重新载入首页的「最近」列表。删除记录后由通知触发。
    func loadRecentRecords() async {
        let context = modelContainer.mainContext
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var descriptor = FetchDescriptor<RecommendationRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 10

        if let all = try? context.fetch(descriptor) {
            recentRecords = all
                .filter { !calendar.isDate($0.date, inSameDayAs: today) }
                .prefix(3)
                .map { $0 }
        }
    }

    // MARK: - Private

    private func reloadAfterBackgroundCompletion() async {
        todayRecord = loadTodayRecord()
        if let record = todayRecord {
            state = .completed(trackCount: record.songCount, playlistName: record.playlistName ?? "今日推荐")
        }
        await loadRecentRecords()
    }

    /// 如果今天已经生成过，恢复 UI 状态；没有则清干净。
    private func restoreTodayState() async {
        guard let record = loadTodayRecord() else {
            // 不能只是 return —— 重新生成时旧记录已被删除，留着 `todayRecord`
            // 会让它指向一个已经不存在的对象。
            todayRecord = nil
            return
        }
        todayRecord = record
        state = .completed(trackCount: record.songCount, playlistName: record.playlistName ?? "今日推荐")
    }

    private func startRecommendation(source: String, quickPickStyle: QuickPickStyle?) {
        Task {
            let started: Bool
            if let style = quickPickStyle {
                started = await engine.runQuickPickRecommendation(style: style) { [weak self] nextState in
                    Task { @MainActor in self?.applyState(nextState) }
                }
            } else {
                started = await engine.runDailyRecommendation { [weak self] nextState in
                    Task { @MainActor in self?.applyState(nextState) }
                }
            }
            if !started {
                // 引擎正忙（例如后台任务已经在跑）。别把这次点击吞掉。
                state = .generating(progress: "正在后台生成，请稍候…")
            }
        }
    }

    private func applyState(_ nextState: RecommendationState) {
        state = nextState
        switch nextState {
        case .completed:
            todayRecord = loadTodayRecord()
            Task { await loadRecentRecords() }

        case .idle:
            // 取消生成后引擎回到 idle。此刻数据库里**可能本来就有一份**今天
            // 已完成的歌单（取消的是一次 QuickPick，或一次重新生成），所以
            // 据实恢复，而不是硬把界面摁成「今天还没有歌单」。
            Task { await restoreTodayState() }

        default:
            break
        }
    }

    /// 今天已完成的最新一份歌单。
    ///
    /// 谓词**刻意不再限制 `source == "daily"`**。原先那样写，QuickPick 生成的
    /// 歌单会导致：`state` 变成 `.completed`（歌单名是对的）但 `todayRecord`
    /// 仍是 nil ——「在 Apple Music 中打开」于是静默退化成打开 Music App 首页，
    /// 重启后更是直接回到 idle，那份歌单从首页消失。
    ///
    /// 只取 `completed`：`pending` 记录（已落库、播放列表尚未建成）不该
    /// 让首页显示一个并不存在的完成态。
    private func loadTodayRecord() -> RecommendationRecord? {
        let context = modelContainer.mainContext
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let predicate = #Predicate<RecommendationRecord> { record in
            record.date >= today && record.date < tomorrow
                && record.status == "completed"
        }
        var descriptor = FetchDescriptor<RecommendationRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
