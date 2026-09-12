//
//  SonglyApp.swift
//  Songly
//

import SwiftUI
import SwiftData

@main
struct SonglyApp: App {
    let modelContainer: ModelContainer

    /// 必须是 App 持有的 `let`，不能是视图里的 `@State`。
    ///
    /// 两个原因：① `BGTaskScheduler.register` 必须在启动完成之前调用，而原来
    /// 放在 `onAppear` 里已经晚于第一帧；② 它曾经是 `onAppear` 里的局部变量，
    /// 出了作用域就被释放，而调度回调捕获的是 `[weak self]` —— 任务真正被系统
    /// 唤醒时没有任何东西活着，后台预生成静默失效。
    let backgroundService: BackgroundTaskService
    let homeVM: HomeViewModel

    init() {
        let schema = Schema([RecommendationRecord.self, UserPreferences.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container = try! ModelContainer(for: schema, configurations: [config])
        self.modelContainer = container

        // 同一个 MusicKitService 实例同时供取数和目录解析使用。
        let musicKit = MusicKitService()
        let engine = RecommendationEngine(
            musicKitService: musicKit,
            llmService: LLMService(),
            playlistService: PlaylistService(),
            catalogResolver: CatalogResolver(musicKit: musicKit),
            modelContainer: container
        )

        let background = BackgroundTaskService(engine: engine)
        background.register()
        // **不在这里 schedule()** —— 它内部会静默检查 Music 授权，而启动这一刻
        // 用户还没授权，那样整个后台功能会静默失效。调度入口在
        // `HomeViewModel.requestMusicAuthorization()` 的授权成功分支里。
        self.backgroundService = background

        self.homeVM = HomeViewModel(
            engine: engine,
            networkMonitor: NetworkMonitor(),
            modelContainer: container,
            backgroundService: background,
            // 画像的生成放在前台，推荐流程永远只用算好的画像。
            profileRefresher: TasteProfileRefresher(musicKit: MusicKitService(), llm: LLMService())
        )
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                ContentView(homeVM: homeVM)
                    .modelContainer(modelContainer)
            }
        }
    }
}

// MARK: - Root

/// 单屏根视图。
///
/// 没有 `TabView` —— 这个 App 只有一件事（每天一份歌单），两个常驻页签
/// （首页/设置）纯属占位，设置收进首页导航栏右上角。
struct ContentView: View {
    let homeVM: HomeViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            HomeView()
        }
        // 必须排在 `.sheet` 之前。顺序反了不会编译报错，但点齿轮时
        // `@Environment(HomeViewModel.self)` 取不到值会直接 trap。
        // `.sheet` 挂在 HomeView 内部，位于这条链的下游，所以是安全的。
        .environment(homeVM)
        .task {
            // 每进程一次。不要挂到 scenePhase —— 见
            // `HomeViewModel.refreshTasteProfile()` 的说明。
            await homeVM.refreshTasteProfile()
        }
        .onChange(of: scenePhase) { _, phase in
            // 只认 `.active`：`.inactive` 在切出去、切回来、以及拉下控制中心
            // 时都会触发，在那里刷新只会白白抖动。用户从系统设置授权后返回
            // 走的是 background → inactive → active，`.active` 是可靠的。
            guard phase == .active else { return }
            Task { await homeVM.refreshPermissionState() }
        }
    }
}
