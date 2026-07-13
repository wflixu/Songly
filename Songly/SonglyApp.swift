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

        let llm: LLMServiceProtocol = AppEnvironment.isAPIKeyConfigured
            ? LLMService() : MockLLMService()
        let eng = RecommendationEngine(
            musicKitService: MusicKitService(),
            llmService: llm,
            playlistService: PlaylistService(),
            modelContainer: container
        )
        self.engine = eng
        self.homeVM = HomeViewModel(engine: eng, networkMonitor: NetworkMonitor())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(homeVM: homeVM, engine: engine)
        }
        .modelContainer(modelContainer)
    }
}

struct ContentView: View {
    let homeVM: HomeViewModel
    let engine: RecommendationEngine

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView()
                    .environment(homeVM)
                    .navigationTitle("乐遇")
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

            let bg = BackgroundTaskService(engine: engine)
            bg.register()
            bg.schedule()
            Task { _ = await NotificationService.shared.requestPermission() }
        }
    }
}
