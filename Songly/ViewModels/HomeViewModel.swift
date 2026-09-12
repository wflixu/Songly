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

    var canTrigger: Bool { !isOffline && !isLoading }

    init(
        engine: RecommendationEngine,
        networkMonitor: NetworkMonitor,
        modelContainer: ModelContainer,
        backgroundService: BackgroundTaskService,
        profileRefresher: TasteProfileRefresher
    ) {
        self.engine = engine
        self.networkMonitor = networkMonitor
        self.modelContainer = modelContainer
        self.backgroundService = backgroundService
        self.profileRefresher = profileRefresher
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
        backgroundService.schedule()

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
