//
//  SonglyApp.swift
//  Songly
//

import SwiftUI
import SwiftData

@main
struct SonglyApp: App {
    let modelContainer: ModelContainer
    let engine: RecommendationEngine
    let homeVM: HomeViewModel

    init() {
        let schema = Schema([RecommendationRecord.self, UserPreferences.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container = try! ModelContainer(for: schema, configurations: [config])
        self.modelContainer = container

        // 同一个 MusicKitService 实例同时供取数和目录解析使用。
        let musicKit = MusicKitService()
        let eng = RecommendationEngine(
            musicKitService: musicKit,
            llmService: LLMService(),
            playlistService: PlaylistService(),
            catalogResolver: CatalogResolver(musicKit: musicKit),
            modelContainer: container
        )
        self.engine = eng
        self.homeVM = HomeViewModel(engine: eng, networkMonitor: NetworkMonitor(), modelContainer: container)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                ContentView(homeVM: homeVM, engine: engine)
                    .modelContainer(modelContainer)
            }
        }
    }
}

struct ContentView: View {
    let homeVM: HomeViewModel
    let engine: RecommendationEngine

    @State private var selectedTab = 0
    /// 必须由视图持有。原先它是 `onAppear` 里的局部变量：出了作用域就被释放，
    /// 而 `BGTaskScheduler` 的回调闭包捕获的是 `[weak self]` —— 等于任务真正
    /// 被系统唤醒时没有任何东西活着，后台预生成静默失效。
    /// 同时它也是"重复注册同一个标识符"的守卫。
    @State private var backgroundService: BackgroundTaskService?
    /// 口味画像的生成入口。放在前台做，推荐流程永远只用算好的画像。
    @State private var profileRefresher: TasteProfileRefresher?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView()
                    .environment(homeVM)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("首页", systemImage: "music.note.house.fill") }
            .tag(0)

            NavigationStack {
                SettingsView()
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("设置", systemImage: "gear") }
            .tag(1)
        }
        .onAppear {
            let bar = UITabBarAppearance()
            bar.configureWithDefaultBackground()
            UITabBar.appearance().standardAppearance = bar
            UITabBar.appearance().scrollEdgeAppearance = bar

            if backgroundService == nil {
                let bg = BackgroundTaskService(engine: engine)
                bg.register()
                bg.schedule()
                backgroundService = bg
            }

            if profileRefresher == nil {
                let refresher = TasteProfileRefresher(
                    musicKit: MusicKitService(),
                    llm: LLMService()
                )
                profileRefresher = refresher
                Task { await refresher.refreshIfNeeded() }
            }

            Task { _ = await NotificationService.shared.requestPermission() }
        }
    }
}
