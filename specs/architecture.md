# 乐遇 Songly — 系统设计文档

> **版本**: v1.1 — MVP
> **最后更新**: 2026-07-13（专家评审修订版）
> **关联文档**: [PRD](./prd.md) | [开发计划](./dev-plan.md)

---

## 1. 架构总览

### 1.1 架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                        SwiftUI Layer                             │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐             │
│  │  HomeView    │ │ QuickPickView│ │ SettingsView │             │
│  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘             │
│         │                │                │                      │
├─────────┼────────────────┼────────────────┼──────────────────────┤
│         ▼                ▼                ▼          ViewModel   │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐   Layer     │
│  │HomeViewModel │ │QuickPickVM   │ │SettingsVM    │             │
│  │(@Observable) │ │(@Observable) │ │(@Observable) │             │
│  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘             │
│         │                │                │                      │
├─────────┼────────────────┼────────────────┼──────────────────────┤
│         │                │                │                      │
│         ▼                ▼                ▼          Service    │
│  ┌──────────────────────────────────────────────────┐  Layer     │
│  │         RecommendationEngine (actor)              │            │
│  │  ┌─────────────┐ ┌──────────┐ ┌──────────────┐  │            │
│  │  │MusicKitSvc  │ │ LLMSvc   │ │PlaylistSvc   │  │            │
│  │  └──────┬──────┘ └────┬─────┘ └──────┬───────┘  │            │
│  └─────────┼─────────────┼──────────────┼──────────┘            │
│            │             │              │                        │
├────────────┼─────────────┼──────────────┼────────────────────────┤
│            ▼             ▼              ▼            Data Layer  │
│  ┌──────────────────────────────────────────────────┐            │
│  │  SwiftData (ModelContainer)                       │            │
│  │  ┌────────────────────┐ ┌──────────────────────┐ │            │
│  │  │RecommendationRecord│ │   UserPreferences    │ │            │
│  │  └────────────────────┘ └──────────────────────┘ │            │
│  └──────────────────────────────────────────────────┘            │
│                                                                   │
├───────────────────────────────────────────────────────────────────┤
│                     External Services                             │
│  ┌──────────┐  ┌──────────────┐  ┌──────────────────┐            │
│  │ MusicKit │  │ DeepSeek API │  │  APNs (推送)     │            │
│  │(Apple)   │  │ (LLM)        │  │  (Apple)         │            │
│  └──────────┘  └──────────────┘  └──────────────────┘            │
└───────────────────────────────────────────────────────────────────┘
```

**职责分离原则：**
- `HomeViewModel`、`QuickPickViewModel`、`SettingsVM` 是唯一的 `@Observable`/`@MainActor` 类，拥有 UI 状态
- `RecommendationEngine` 是纯 `actor`，作为编排器不直接暴露给 SwiftUI，通过 ViewModel 桥接状态
- Service 层各组件通过 Protocol 抽象，可独立测试和替换

### 1.2 架构决策记录 (ADR)

| ID | 决策 | 理由 | 替代方案 |
|----|------|------|----------|
| ADR-1 | **纯客户端架构，无后端** | MVP 阶段数据量小，LLM API 可直接从客户端调用；零服务器成本 | 自建后端代理 API（Phase 2 必须引入） |
| ADR-2 | **MVVM + `@Observable` (iOS 17+)** | SwiftUI 原生 `@Observable` 宏（非旧版 `@ObservableObject`），`@State` 管所有权，`@Environment` 管注入，`@Bindable` 管双向绑定 | MVC, TCA, 旧版 `@Published`/`ObservableObject` |
| ADR-3 | **SwiftData 持久化** | Apple 官方推荐，原生 Swift 宏支持，与 SwiftUI 深度集成 | Core Data, Realm, UserDefaults |
| ADR-4 | **DeepSeek API 直连** | 国内可用、延迟低、成本极低（¥0.001/1K tokens） | 通义千问、月之暗面 |
| ADR-5 | **直接管理 Xcode 项目** | 简单直接，单人项目无需额外工具，避免 XcodeGen 配置同步问题 | XcodeGen, Tuist |
| ADR-6 | **API Key 通过 .xcconfig 注入** | 防止 git 误提交（开发卫生措施，非安全措施——Key 仍可被 IPA 二进制提取，MVP 接受此风险） | 环境变量, Keychain 读取 |
| ADR-7 | **纯 `actor` 编排引擎** | Swift 6 并发安全，天然序列化管线执行，防止并发触发 | `@Observable` 引擎（职责不清）, `OSAllocatedUnfairLock` |

---

## 2. 模块设计

### 2.1 文件结构

```
Songly/
├── SonglyApp.swift                  # @main 入口，注入依赖
├── App/
│   ├── AppConfig.swift              # 全局配置常量
│   └── AppEnvironment.swift         # 环境值（API Key 等，使用 INFOPLIST_KEY_ 前缀）
│
├── Models/
│   ├── RecommendationRecord.swift   # SwiftData: 推荐记录
│   ├── UserPreferences.swift        # SwiftData: 用户偏好
│   ├── TrackItem.swift              # 歌曲模型（解析 LLM 输出）
│   └── RecommendationStrategy.swift # 推荐策略枚举
│
├── Services/
│   ├── MusicKitService.swift        # MusicKit 授权、读取、搜索
│   ├── LLMService.swift             # DeepSeek API 调用
│   ├── PlaylistService.swift        # 播放列表 CRUD
│   ├── RecommendationEngine.swift   # 推荐编排器（actor，核心管线）
│   ├── NotificationService.swift    # 推送通知管理
│   ├── BackgroundTaskService.swift  # 后台任务注册
│   └── NetworkMonitor.swift         # 网络状态监控 (NWPathMonitor)
│
├── ViewModels/
│   ├── HomeViewModel.swift          # 首页视图模型 (@Observable, @MainActor)
│   ├── QuickPickViewModel.swift     # "想听"快捷选择 (@Observable, @MainActor)
│   └── SettingsViewModel.swift      # 设置页 (@Observable, @MainActor)
│
├── Views/
│   ├── HomeView.swift               # 首页：推荐状态 + 快捷入口
│   ├── OnboardingView.swift         # 首启引导页
│   ├── QuickPickView.swift          # "想听"风格选择页
│   ├── RecommendationResultView.swift # 推荐结果展示
│   ├── SettingsView.swift           # 设置页
│   └── Components/
│       ├── StyleButton.swift        # 风格选择按钮
│       └── TrackRow.swift           # 歌曲行组件
│
├── Utils/
│   ├── PromptBuilder.swift          # LLM Prompt 构造器（含 token 管理）
│   └── DateFormatter+Extensions.swift
│
├── Localization/
│   └── Localizable.xcstrings        # 字符串目录（中文为主，预留英文）
│
└── Assets.xcassets/                 # 资源文件
```

### 2.2 模块职责矩阵

| 模块 | 职责 | 依赖 |
|------|------|------|
| **SonglyApp** | App 入口，注入 `ModelContainer`，注册后台任务，注册 `NWPathMonitor` | SwiftData, Network |
| **MusicKitService** | 授权请求、增量读取收藏列表、并发曲库搜索 | MusicKit |
| **LLMService** | 构建 HTTP 请求、调用 DeepSeek API、解析响应 | URLSession |
| **PlaylistService** | 创建/更新/查找 Apple Music 播放列表 | MusicKit |
| **RecommendationEngine** | actor：序列化编排推荐管线（读收藏→LLM→搜索→创建歌单→持久化），提供 `cancel()` | MusicKitService, LLMService, PlaylistService |
| **PromptBuilder** | 根据策略+收藏列表+历史记录+token 预算构建 LLM prompt | — |
| **NotificationService** | 请求推送权限、发送本地通知 | UserNotifications |
| **BackgroundTaskService** | 注册 `BGAppRefreshTask`，拆分管线（后台只调 LLM，前台补齐） | BackgroundTasks, RecommendationEngine |
| **NetworkMonitor** | `NWPathMonitor` 实时跟踪网络状态 | Network |
| **HomeViewModel** | `@Observable` `@MainActor`：持有推荐状态、进度、触发推荐 | RecommendationEngine |
| **QuickPickViewModel** | `@Observable` `@MainActor`：风格选择、即时推荐触发 | RecommendationEngine |

---

## 3. 核心数据流

### 3.1 每日推荐完整链路

```
                    ┌─────────────────────┐
                    │  BGAppRefreshTask    │  后台：仅调 LLM，存原始结果
                    │  或 App 前台检查      │  前台：补跑搜索+创建歌单
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │  检查今日是否已生成    │  查询 SwiftData
                    │  RecommendationRecord │  date 字段有 @Attribute(.unique)
                    └─────────┬───────────┘
                              │ (未生成)
                              ▼
              ┌───────────────────────────────┐
              │  Step 1: 增量读取用户收藏       │
              │  MusicLibraryRequest<Song>()   │
              │  首次全量(≤200) / 后续按        │
              │  lastSyncDate 增量拉取          │
              └───────────────┬───────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │  Step 2: 构建 Prompt            │
              │  PromptBuilder.build(          │
              │    songs: [Song],              │
              │    strategy: .styleExploration, │
              │    history: [历史推荐歌名],      │
              │    maxTokens: 2000             │
              │  )                             │
              │  200首 → 采样+去重 → 适配token  │
              └───────────────┬───────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │  Step 3: 调用 LLM               │
              │  LLMService.recommend(prompt)  │
              │  → [TrackItem] (25首)           │
              │  超时: 10s, 重试: 3次            │
              └───────────────┬───────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │  Step 4: 并发曲库匹配             │
              │  TaskGroup (maxConcurrent: 5)  │
              │  精确匹配 → 模糊匹配 → 艺人比对   │
              │  → [MusicItemID] (目标 >80%)    │
              └───────────────┬───────────────┘
                              │ (匹配率检查: < 20% → error)
                              │ (空列表 → error, 不创建空歌单)
                              ▼
              ┌───────────────────────────────┐
              │  Step 5: 持久化记录（先于歌单）   │
              │  modelContext.insert(record)   │
              │  try modelContext.save()       │
              │  失败则中止，不创建歌单           │
              └───────────────┬───────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │  Step 6: 创建播放列表            │
              │  PlaylistService.create(       │
              │    name: "🎵 每日推荐 · 7月13日", │
              │    tracks: [MusicItemID],       │
              │    description: 策略说明         │
              │  )                             │
              └───────────────┬───────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │  Step 7: 推送通知               │
              │  UNUserNotificationCenter      │
              │  .add(request)                 │
              └───────────────────────────────┘
```

**关键修复（v1.1）：**
- Step 4 改为 `TaskGroup` 并发（非串行 `for` 循环）
- Step 5 与 Step 6 对调——先持久化记录，再创建歌单。持久化失败则不再创建歌单，避免"Apple Music 有歌单但本地无记录"的不一致状态
- 匹配率为 0 时中止（`guard !matchedIDs.isEmpty`），不创建空歌单
- 匹配率 < 20% 时触发 `error(matchRateTooLow)`，询问用户是否仍创建

### 3.2 "想听"快捷推荐链路

与每日推荐链路基本相同，区别在于:
- **触发方式**: 用户手动点击风格按钮
- **策略来源**: 用户选择的预设风格（而非默认策略）
- **无后台限制**: 前台执行，无需 BGAppRefreshTask
- **UI 反馈**: 实时展示 loading → 结果预览

### 3.3 状态机设计

```
         ┌──────────────┐
         │  onboarding   │ ───── 首启：未授权状态
         └──────┬───────┘
                │ 授权成功
                ▼
         ┌──────────────┐
         │   idle        │ ◄──── 初始状态 / 完成 / 从 error 恢复
         └──────┬───────┘
                │ triggerRecommendation()
                │ (actor 序列化，并发触发排队)
                ▼
         ┌──────────────┐
         │  reading      │ ───── 增量读取收藏中
         │  Library      │
         └──────┬───────┘
                │
                ▼
         ┌──────────────┐
         │  generating   │ ───── LLM 请求中
         │  LLM          │
         └──────┬───────┘
                │ (失败 → 重试 ≤3次 → error)
                │ (成功)
                ▼
         ┌──────────────┐
         │  searching    │ ───── 并发曲库匹配中
         │  Catalog      │
         └──────┬───────┘
                │ (匹配率 < 20% → error.matchRateTooLow)
                │ (匹配 0 首 → error)
                │ (成功)
                ▼
         ┌──────────────┐
         │  persisting   │ ───── 写入 SwiftData
         │  Record       │       (失败 → error，不创建歌单)
         └──────┬───────┘
                │
                ▼
         ┌──────────────┐
         │  creating     │ ───── 创建播放列表中
         │  Playlist     │       (失败 → 删除刚写入的记录 → error)
         └──────┬───────┘
                │
                ▼
         ┌──────────────┐
         │  completed    │ ───── 歌单已创建
         └──────────────┘
```

---

## 4. 数据模型设计

### 4.1 SwiftData 模型

```swift
// MARK: - 歌曲信息（JSON 存储，避免并行数组）
struct TrackInfo: Codable, Equatable {
    let id: String      // Apple Music MusicItemID
    let name: String    // 歌名
    let artist: String  // 艺人名
}

// MARK: - 推荐记录
@Model
final class RecommendationRecord {
    @Attribute(.unique) var date: Date  // 推荐日期（唯一索引，用于"今日是否已生成"判断）
    var strategy: String               // 推荐策略标识
    var songCount: Int                 // 实际匹配成功的歌曲数
    var tracksJSON: String             // JSON([TrackInfo]) — 避免三数组索引对应
    var createdAt: Date                // 推荐生成时间戳
    var source: String                 // "daily" | "quick_pick"
    var quickPickStyle: String?        // "想听"的风格标签（仅 quick_pick）

    // 计算属性：反序列化
    var tracks: [TrackInfo] {
        get {
            guard let data = tracksJSON.data(using: .utf8),
                  let result = try? JSONDecoder().decode([TrackInfo].self, from: data)
            else { return [] }
            return result
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                tracksJSON = json
            }
        }
    }

    // 便捷属性
    var trackNames: [String] { tracks.map(\.name) }
    var trackIDs: [String] { tracks.map(\.id) }
    var artistNames: [String] { tracks.map(\.artist) }

    init(
        date: Date,
        strategy: String,
        songCount: Int,
        tracks: [TrackInfo],
        source: String,
        quickPickStyle: String? = nil
    ) {
        self.date = date
        self.strategy = strategy
        self.songCount = songCount
        self.tracksJSON = (try? JSONEncoder().encode(tracks))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        self.createdAt = Date()
        self.source = source
        self.quickPickStyle = quickPickStyle
    }
}

// MARK: - 用户偏好（单例实体）
@Model
final class UserPreferences {
    var id: UUID
    var favoriteGenres: [String]       // 用户偏好风格（Phase 2 启用，MVP 预留）
    var lastSyncDate: Date?            // 上次同步收藏的时间（增量更新依据）
    var totalRecommendations: Int      // 累计推荐次数

    init() {
        self.id = UUID()
        self.favoriteGenres = []
        self.lastSyncDate = nil
        self.totalRecommendations = 0
    }
}
```

**数据模型改进（v1.1）：**
- **并行数组 → JSON**：`trackIDs`/`trackNames`/`artistNames` 三数组改为单个 `tracksJSON: String`，序列化 `[TrackInfo]`，消除索引不一致风险
- **`@Attribute(.unique)` on `date`**：天然保证一天一份推荐，同时作为查询索引
- **移除 `musicAuthorizationStatus`**：不应缓存到数据库——授权状态应以 `MusicAuthorization.currentStatus` 实时查询为准，缓存会造成过期误判
- **`favoriteGenres` 明确标注为 Phase 2 预留**，MVP 不填充

### 4.2 内存模型（非持久化）

```swift
// LLM 返回的推荐曲目
struct TrackItem: Codable, Identifiable, Sendable {
    var id: String { "\(title)-\(artist)" }
    let title: String
    let artist: String
}

// 推荐策略
enum RecommendationStrategy: String, CaseIterable, Sendable {
    case styleExploration = "风格探索"
    case eraRetrospective = "年代回溯"
    case artistAssociation = "艺人关联"
    case genreMix = "混搭实验"
    case randomDiscovery = "随机发现"
    case moodMatch = "情绪匹配"

    var emoji: String {
        switch self {
        case .styleExploration: return "🎸"
        case .eraRetrospective: return "📻"
        case .artistAssociation: return "🎭"
        case .genreMix: return "🔀"
        case .randomDiscovery: return "🎲"
        case .moodMatch: return "🌙"
        }
    }

    // MVP 阶段仅启用此策略
    static var mvpStrategies: [RecommendationStrategy] {
        [.styleExploration]
    }
}

// QuickPick 预设风格
enum QuickPickStyle: String, CaseIterable, Sendable {
    case rock = "摇滚"
    case instrumental = "纯音乐"
    case jazz = "爵士"
    case surprise = "来点不一样的"
    case sleep = "睡前放松"

    var emoji: String {
        switch self {
        case .rock: return "🎸"
        case .instrumental: return "🎹"
        case .jazz: return "🎷"
        case .surprise: return "🔀"
        case .sleep: return "🌙"
        }
    }
}

// 推荐管线状态（由 HomeViewModel 持有）
enum RecommendationState: Equatable {
    case onboarding             // 首启未授权
    case idle                   // 空闲
    case readingLibrary         // 增量读取收藏
    case generating(progress: String)  // LLM 生成中
    case searchingCatalog(found: Int, total: Int)  // 并发曲库匹配
    case persistingRecord       // 写入本地记录
    case creatingPlaylist       // 创建播放列表
    case completed(trackCount: Int)  // 完成
    case error(message: String, retryable: Bool)
}
```

---

## 5. 服务层设计

### 5.1 MusicKitService

```swift
protocol MusicKitServiceProtocol {
    /// 检查当前授权状态（实时查询，不使用缓存）
    func authorizationStatus() -> MusicAuthorization.Status

    /// 请求 MusicKit 授权（仅在 .notDetermined 时调用）
    func requestAuthorization() async -> MusicAuthorization.Status

    /// 增量读取用户收藏歌曲
    /// - Parameter limit: 全量读取时的上限
    /// - 首次：全量读取 ≤ limit 首
    /// - 后续：仅读取 lastSyncDate 之后新增的收藏
    func fetchLibrarySongs(limit: Int, since lastSync: Date?) async throws -> [Song]

    /// 在 Apple Music 曲库搜索歌曲
    func searchTrack(title: String, artist: String) async throws -> MusicItemID?
}
```

**关键设计决策：**
- **授权状态实时查询**：每次需要时调用 `MusicAuthorization.currentStatus`，不缓存到 SwiftData
- **增量更新策略**：首次全量读取后缓存 `lastSyncDate`，后续按 `DateAdded` 过滤，减少 API 调用量
- **搜索匹配策略（三层降级）**：
  1. 精确匹配：`"{title} {artist}"` 完整搜索词
  2. 歌名优先：仅 `{title}` 搜索，取第一个结果
  3. 艺人比对：`{title}` 取前 3 个结果，用 Levenshtein 距离比对艺人名
- **并发搜索**：使用 `TaskGroup`（`maxConcurrentTasks: 5`），避免串行等待和 MusicKit 系统限流

**Info.plist 必须项：**
```
NSAppleMusicUsageDescription = "乐遇需要访问你的 Apple Music 收藏，以便 AI 为你生成个性化推荐歌单。"
```
缺少此 key 将导致授权弹窗不显示，且 App Store 审核被拒。

### 5.2 LLMService

```swift
protocol LLMServiceProtocol {
    /// 调用 LLM 生成推荐歌单
    func recommend(prompt: String) async throws -> [TrackItem]

    /// 检查 API 可用性
    func healthCheck() async -> Bool
}
```

**DeepSeek API 集成细节：**

```
Endpoint: POST https://api.deepseek.com/v1/chat/completions
Headers:
  - Authorization: Bearer {API_KEY}
  - Content-Type: application/json
Body:
{
  "model": "deepseek-chat",
  "messages": [
    { "role": "system", "content": "你是一个专业的音乐推荐专家..." },
    { "role": "user", "content": "{prompt}" }
  ],
  "temperature": 0.9,
  "max_tokens": 1000,
  "stream": false
}
```

**容错策略：**
| 场景 | 处理方式 |
|------|----------|
| 网络超时 (10s) | 重试，最多 3 次，指数退避 (1s, 2s, 4s) |
| HTTP 4xx | 不重试，检查 API Key 有效性，提示用户 |
| HTTP 5xx | 重试 3 次 |
| 响应解析失败 | 尝试宽松解析（容错非标准格式），仍失败则返回空列表 |
| 推荐歌曲数 < 10 | 视为失败，不创建播放列表 |
| 空响应 / 非列表格式（如纯文本建议） | 返回空列表 → engine 收到后报 error |
| CJK 歌曲名 Unicode/同形字问题 | 标准化（NFKC）后再匹配 |

**响应解析（容错）：**
LLM 返回格式约定为每行 `歌名 - 艺人名`，解析器需容错多种实际格式：
```
// 标准格式
"Yesterday - The Beatles"

// 需容错格式（来自真实 LLM 输出）
"Yesterday / The Beatles"
"Yesterday - The Beatles (Remastered 2009)"
"Yesterday — The Beatles"          // em-dash
"1. Yesterday - The Beatles"       // 带序号
""Yesterday" by The Beatles"       // 英文引号格式
```

使用正则表达式提取歌名和艺人名，支持多种分隔符。**关键**：先用真实 DeepSeek API 跑 5 次请求，收集实际响应格式后再最终确定解析器——避免仅依赖假想的格式。

### 5.3 PlaylistService

```swift
protocol PlaylistServiceProtocol {
    /// 创建新的每日推荐播放列表
    func createDailyPlaylist(
        name: String,
        description: String,
        trackIDs: [MusicItemID]
    ) async throws -> Playlist

    /// 更新已有的播放列表（同日歌单去重）
    func updatePlaylist(
        _ playlist: Playlist,
        trackIDs: [MusicItemID]
    ) async throws

    /// 通过命名规则查找指定日期的已有歌单
    func findPlaylist(named name: String) async throws -> Playlist?
}
```

**播放列表命名规范：**
- 每日推荐: `🎵 每日推荐 · 7月13日`
- 想听(摇滚): `🎸 摇滚精选 · 7月13日`
- 想听(纯音乐): `🎹 纯音乐时光 · 7月13日`

**同名处理：** 如果用户手动创建了同名歌单，`findPlaylist(named:)` 会匹配到它——此时应 `updatePlaylist` 覆盖内容，而非创建第二个。

### 5.4 PromptBuilder

```swift
struct PromptBuilder {
    /// 构建 LLM prompt
    /// - Parameters:
    ///   - strategy: 推荐策略
    ///   - songs: 用户收藏歌曲列表（可能超过 token 限制）
    ///   - history: 历史推荐歌名（去重用）
    ///   - maxTokens: LLM 输入 token 预算
    /// - Returns: 优化后的 prompt 字符串
    static func build(
        strategy: RecommendationStrategy,
        songs: [Song],
        history: [String],
        maxTokens: Int = 2000
    ) -> String
}
```

**Token 管理策略：**
- 200 首歌全部塞入 prompt 可能超过上下文窗口
- 策略：按 `DateAdded` 倒序取最近收藏（信号最强），估算 token 占用，控制在 `maxTokens` 以内
- 粗略估算：中文歌名+艺人平均 ~15 tokens/行 → 200 首 ≈ 3000 tokens。实际取最近的 ~130 首即可控制在 2000 tokens 内
- 历史去重列表同理：最多取最近 30 天的推荐歌名

**系统 Prompt（参考）：**
```
你是一个专业音乐推荐专家，擅长根据用户的音乐品味推荐冷门好歌。
你的推荐原则：
1. 不要推荐大众热门金曲大杂烩——推荐用户可能没听过但品质高的歌
2. 风格上可以适度跨界（如果用户听独立摇滚，可以尝试 shoegaze、post-rock）
3. 优先推荐有代表性的冷门佳作，而非榜单热门
4. 只推荐在 Apple Music 曲库中实际存在的歌曲（主流厂牌正式发行曲目）
```

### 5.5 RecommendationEngine（核心编排器 — actor）

```swift
actor RecommendationEngine {
    // 依赖注入
    private let musicKitService: MusicKitServiceProtocol
    private let llmService: LLMServiceProtocol
    private let playlistService: PlaylistServiceProtocol
    private let modelContainer: ModelContainer

    // 管线互斥：actor 天然保证同一时间只有一个执行
    private var isRunning = false
    private var currentTask: Task<Void, Never>?

    /// 检查今日是否已生成（读 SwiftData）
    func hasTodayRecommendation() -> Bool { ... }

    /// 每日推荐
    func runDailyRecommendation(
        onStateChange: @Sendable (RecommendationState) -> Void
    ) async { ... }

    /// 想听推荐
    func runQuickPickRecommendation(
        style: QuickPickStyle,
        onStateChange: @Sendable (RecommendationState) -> Void
    ) async { ... }

    /// 取消当前执行（后台超时或用户手动取消）
    func cancel() {
        currentTask?.cancel()
        isRunning = false
    }
}
```

**编排流程（v1.1 修复版）：**

```swift
func runDailyRecommendation(
    onStateChange: @Sendable (RecommendationState) -> Void
) async {
    // actor 序列化 — 如果已在运行，等待或直接返回
    guard !isRunning else { return }
    isRunning = true
    defer { isRunning = false }

    let task = Task { @MainActor in
        // 1. 检查授权状态（实时查询，不用缓存）
        let authStatus = MusicAuthorization.currentStatus
        guard authStatus == .authorized else {
            if authStatus == .notDetermined {
                let status = await MusicAuthorization.request()
                guard status == .authorized else {
                    onStateChange(.error(message: "需要 Music 访问权限", retryable: false))
                    return
                }
            } else {
                onStateChange(.error(message: "请在设置中开启 Apple Music 访问权限", retryable: false))
                return
            }
        }

        // 2. 增量读取收藏
        onStateChange(.readingLibrary)
        let prefs = fetchPreferences()
        let songs = try? await musicKitService.fetchLibrarySongs(
            limit: 200,
            since: prefs?.lastSyncDate
        )
        guard let songs, !songs.isEmpty else {
            onStateChange(.error(message: "收藏列表为空", retryable: false))
            return
        }

        // 更新 lastSyncDate
        await updateLastSyncDate(Date())

        // 3. 构建 prompt
        let history = fetchHistoryTrackNames(limit: 30)
        let prompt = PromptBuilder.build(
            strategy: .styleExploration,
            songs: songs,
            history: history
        )

        // 4. 调用 LLM（带重试）
        onStateChange(.generating(progress: "正在分析你的音乐品味..."))
        let recommendations: [TrackItem]
        do {
            recommendations = try await llmService.recommend(prompt: prompt)
        } catch {
            onStateChange(.error(message: "推荐生成失败，请稍后重试", retryable: true))
            return
        }

        guard recommendations.count >= 10 else {
            onStateChange(.error(message: "推荐结果不足，请稍后重试", retryable: true))
            return
        }

        // 5. 并发曲库匹配 (TaskGroup, max 5 concurrent)
        onStateChange(.searchingCatalog(found: 0, total: recommendations.count))
        var matchedTracks: [TrackInfo] = []

        await withTaskGroup(of: TrackInfo?.self) { group in
            var index = 0
            for track in recommendations {
                if index >= 5 { _ = await group.next() }  // throttle
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    if let id = try? await self.musicKitService.searchTrack(
                        title: track.title, artist: track.artist
                    ) {
                        return TrackInfo(id: id.rawValue, name: track.title, artist: track.artist)
                    }
                    return nil
                }
                index += 1
            }
            for await result in group {
                if let track = result { matchedTracks.append(track) }
                await MainActor.run {
                    onStateChange(.searchingCatalog(found: matchedTracks.count, total: recommendations.count))
                }
            }
        }

        // 匹配率检查
        let matchRate = Double(matchedTracks.count) / Double(recommendations.count)
        guard !matchedTracks.isEmpty else {
            onStateChange(.error(message: "未能匹配到歌曲，请稍后重试", retryable: true))
            return
        }
        if matchRate < 0.2 {
            onStateChange(.error(message: "仅匹配到 \(matchedTracks.count)/\(recommendations.count) 首，是否仍创建？", retryable: true))
            return
        }

        // 6. 持久化记录（先于歌单创建）
        onStateChange(.persistingRecord)
        let record = RecommendationRecord(
            date: Date(),
            strategy: "styleExploration",
            songCount: matchedTracks.count,
            tracks: matchedTracks,
            source: "daily"
        )

        let context = modelContainer.mainContext
        context.insert(record)
        do {
            try context.save()
        } catch {
            onStateChange(.error(message: "数据保存失败，请稍后重试", retryable: true))
            return  // 不创建歌单！
        }

        // 7. 创建播放列表
        onStateChange(.creatingPlaylist)
        let dateString = formatDate(Date())
        let description = generatePlaylistDescription(strategy: .styleExploration)
        do {
            _ = try await playlistService.createDailyPlaylist(
                name: "🎵 每日推荐 · \(dateString)",
                description: description,
                trackIDs: matchedTracks.map { MusicItemID($0.id) }
            )
        } catch {
            // 歌单创建失败 → 删除刚写入的记录
            context.delete(record)
            try? context.save()
            onStateChange(.error(message: "播放列表创建失败，请稍后重试", retryable: true))
            return
        }

        // 8. 完成
        onStateChange(.completed(trackCount: matchedTracks.count))

        // 9. 发送通知
        await NotificationService.shared.sendRecommendationReady(count: matchedTracks.count)
    }

    currentTask = task
    await task.value
}
```

**v1.1 关键修复总结：**
| 问题 | 修复 |
|------|------|
| 搜索串行 `for` 循环 | 改为 `TaskGroup`，`maxConcurrent: 5` |
| 并行数组 | 改为 `[TrackInfo]` JSON 存储 |
| `modelContext.save()` `try?` 吞错 | `do-catch` + 失败不创建歌单 |
| 先建歌单再持久化 | 对调：先持久化，失败则中止 |
| 歌单创建失败无回滚 | 失败时 `context.delete(record)` |
| 空匹配列表穿透 | `guard !matchedTracks.isEmpty` |
| 匹配率阈值未实现 | `matchRate < 0.2` → error |
| `engine.cancel()` 未定义 | 通过 `currentTask?.cancel()` 实现 |
| 授权状态缓存 | 实时查询 `MusicAuthorization.currentStatus` |
| 并发无防护 | `actor` 天然序列化 + `isRunning` 守卫 |

### 5.6 后台任务设计

```swift
import BackgroundTasks

// Info.plist: BGTaskSchedulerPermittedIdentifiers = ["cn.wflixu.Songly.dailyRecommendation"]

final class BackgroundTaskService {
    static let dailyTaskIdentifier = "cn.wflixu.Songly.dailyRecommendation"
    private let engine: RecommendationEngine

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.dailyTaskIdentifier,
            using: nil
        ) { task in
            self.handleDailyTask(task as! BGAppRefreshTask)
        }
    }

    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.dailyTaskIdentifier)

        // 修复：计算明天早上 6:00（而非今天——今天6AM已过会调度失败）
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 6
        components.minute = 0
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        components.year = Calendar.current.component(.year, from: tomorrow)
        components.month = Calendar.current.component(.month, from: tomorrow)
        components.day = Calendar.current.component(.day, from: tomorrow)
        request.earliestBeginDate = Calendar.current.date(from: components)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Logger().warning("BGTask submit failed: \(error.localizedDescription)")
            // 常见错误：模拟器（unsupported）、重复提交（tooManyPending）
        }
    }

    private func handleDailyTask(_ task: BGAppRefreshTask) {
        schedule()  // 安排下一次

        task.expirationHandler = {
            // 超时：取消引擎的所有操作
            Task { await self.engine.cancel() }
        }

        // 拆分策略：后台只调 LLM + 存原始结果
        // 完整的搜索+歌单创建留给用户打开 App 时的前台补充检查
        Task {
            await engine.runDailyRecommendation { state in
                if case .completed = state {
                    task.setTaskCompleted(success: true)
                }
                if case .error = state {
                    // 后台任务失败是预期的，前台会补上
                    task.setTaskCompleted(success: false)
                }
            }
        }
    }
}
```

**后台任务策略（v1.1 修订）：**

| 现实 | 应对 |
|------|------|
| 执行窗口通常 5-15 秒，极少达 30 秒 | 后台尝试完整管线，但 `expirationHandler` 随时中止 |
| 完整管线最坏情况 ~40 秒（含 LLM 重试） | 后台管线会频繁被系统 kill —— 这是**预期的**，不是 bug |
| 前台补充检查是**主要路径** | 用户打开 App 时：检查今日是否已生成 → 未生成则补跑 |
| 模拟器不支持 BGAppRefreshTask | 后台任务仅在真机上测试 |
| 低电量模式完全禁止后台任务 | 无解，依赖前台补充 |
| 设备重启后任务不触发直到首次打开 App | 同样依赖前台补充 |
| 系统批量调度，`earliestBeginDate` 是建议非保证 | 可能延迟数小时甚至跳过 |

**结论：MVP 阶段，后台任务是"尽力而为的辅助路径"。推荐质量验证不依赖后台任务的可靠性。**

---

## 6. UI 设计

### 6.1 页面结构

```
┌─────────────────────────────────┐
│  TabView                         │
│  ┌──────────┐  ┌──────────┐     │
│  │  首页     │  │  设置     │     │
│  └──────────┘  └──────────┘     │
└─────────────────────────────────┘

首启引导 (OnboardingView, 仅首次):
┌─────────────────────────────────┐
│                                  │
│         🎵 乐遇                   │
│    AI 驱动的个性化歌单推荐         │
│                                  │
│  ┌──────────────────────────┐   │
│  │    允许访问 Apple Music    │   │
│  └──────────────────────────┘   │
│                                  │
│  乐遇需要访问你的收藏，才能让      │
│  AI 为你生成个性化推荐            │
│                                  │
└─────────────────────────────────┘

首页 (HomeView):
┌─────────────────────────────────┐
│  🎵 乐遇                            │
│  2026年7月13日 星期一                │
├─────────────────────────────────┤
│                                  │
│  ┌  ─  ─  ─  ─  ─  ─  ─  ─  ┐  │
│    🎵 今日推荐已就绪！              │
│    25 首新歌等你来听                │
│    ┌──────────────────────┐      │
│    │ 在 Apple Music 中打开 │      │
│    └──────────────────────┘      │
│  └  ─  ─  ─  ─  ─  ─  ─  ─  ┘  │
│                                  │
│  ── 想听点什么？ ──               │
│                                  │
│  ┌──────────┐ ┌──────────┐      │
│  │ 🎸 摇滚   │ │ 🎹 纯音乐 │      │
│  └──────────┘ └──────────┘      │
│  ┌──────────┐ ┌──────────┐      │
│  │ 🎷 爵士   │ │ 🔀 惊喜   │      │
│  └──────────┘ └──────────┘      │
│  ┌──────────┐                   │
│  │ 🌙 睡前放松│                   │
│  └──────────┘                   │
│                                  │
├─────────────────────────────────┤
│  上次推荐: 🎵 每日推荐 · 7月12日    │
│  已为你生成 12 份歌单               │
└─────────────────────────────────┘

设置 (SettingsView):
┌─────────────────────────────────┐
│  设置                             │
├─────────────────────────────────┤
│  Music 权限                       │
│  已授权 ✅ / 未授权 → 去设置        │
├─────────────────────────────────┤
│  通知权限                          │
│  已开启 ✅ / 未开启 → 去设置        │
├─────────────────────────────────┤
│  关于                             │
│  版本 1.0.0 (Build 1)             │
│  乐遇 Songly — AI 歌单推荐          │
└─────────────────────────────────┘
```

### 6.2 状态流转 UI 映射

| 状态 | UI 展示 |
|------|---------|
| `onboarding` | `OnboardingView`：欢迎 + Apple Music 授权按钮 |
| `idle` | 如已生成 → 展示推荐结果卡片；否则展示"等待今日推荐" |
| `readingLibrary` | 系统 `ProgressView` + "正在读取你的收藏..." |
| `generating` | 系统 `ProgressView` + "AI 正在为你挑选歌曲..." |
| `searchingCatalog` | 系统 `ProgressView` + 进度 "正在曲库匹配(18/25)..." |
| `persistingRecord` | 系统 `ProgressView` + "正在保存..." |
| `creatingPlaylist` | 系统 `ProgressView` + "正在创建播放列表..." |
| `completed(trackCount:)` | 成功卡片 + 歌单预览 + "在 Apple Music 中打开"按钮 |
| `error(retryable: true)` | 错误提示 + "重试"按钮 |
| `error(retryable: false)` | 错误提示 + 引导操作（如"去设置"按钮） |

**v1.1 改进：** Loading 状态统一使用系统 `ProgressView`（而非自定义动画），MVP 阶段不过度打磨 UI。

### 6.3 空状态与边缘情况

- **无收藏**: `ContentUnavailableView`（系统组件）— "收藏列表为空" + 引导去 Apple Music 收藏
- **无推荐记录**: `ContentUnavailableView` — "等待今日推荐"
- **无网络**: `ContentUnavailableView` — "网络不可用" + 显示上次推荐缓存
- **推送被拒**: 首页轻量 badge（数字角标），替代推送通知

---

## 7. 错误处理矩阵

| 错误场景 | 用户提示 | 操作 | 状态 |
|----------|----------|------|------|
| MusicKit 授权未确定 | 引导弹窗（OnboardingView） | "允许访问 Apple Music"按钮 | `onboarding` |
| MusicKit 授权被拒 | "需要访问 Apple Music 来读取你的收藏。请在设置中开启。" | "去设置"按钮 | `error(retryable: false)` |
| MusicKit 订阅未激活 | "需要 Apple Music 订阅才能使用推荐功能。" | 展示 Apple Music 注册引导 | `error(retryable: false)` |
| 收藏列表为空 | `ContentUnavailableView` + 引导文案 | 引导用户去 Apple Music 收藏歌曲 | `error(retryable: false)` |
| LLM API 超时 | "AI 服务响应超时，请检查网络后重试。" | "重试"按钮 | `error(retryable: true)` |
| LLM API 余额不足 | "推荐服务暂时不可用，请稍后再试。" | "联系开发者"（含 `mailto:` 链接） | `error(retryable: false)` |
| 推荐歌曲数 < 10 | "推荐结果不足，请稍后重试。" | "重试"按钮 | `error(retryable: true)` |
| MusicKit 搜索全面失败（匹配 0 首） | "未能匹配到歌曲，请稍后重试。" | "重试"按钮 | `error(retryable: true)` |
| 匹配率过低 (<20%) | "仅匹配到 {n}/{total} 首，是否仍创建歌单？" | "创建现有歌单"/"换一批" | `error(retryable: true)` |
| SwiftData 保存失败 | "数据保存失败，请稍后重试。" | "重试"按钮（不创建歌单） | `error(retryable: true)` |
| 播放列表创建失败 | "播放列表创建失败，请稍后重试。" | "重试"按钮（已回滚本地记录） | `error(retryable: true)` |
| 后台任务被系统取消 | 静默处理（前台补跑） | 用户打开 App 时自动触发 | — |
| 网络不可用 | `ContentUnavailableView` + "网络不可用" | 显示上次推荐缓存 + NWPathMonitor 监听恢复后自动触发 | — |
| 并发触发（用户快速点击两次） | Button 在 `state != .idle` 时 `disabled` | actor 序列化，第二次调用自动跳过 | — |

---

## 8. 安全与隐私设计

### 8.1 API Key 管理

```
# .xcconfig（gitignored — 仅防止 git 误提交）
DEEPSEEK_API_KEY = sk-xxxxxxxxxxxxxxxx

# 使用 INFOPLIST_KEY_ 前缀让 Xcode 自动注入 Info.plist
INFOPLIST_KEY_DEEPSEEK_API_KEY = $(DEEPSEEK_API_KEY)

# Swift 读取
enum AppEnvironment {
    static var deepseekAPIKey: String {
        Bundle.main.infoDictionary?["DEEPSEEK_API_KEY"] as? String ?? ""
    }
}
```

**⚠️ 已知风险（MVP 接受）：**
- API Key 通过 `INFOPLIST_KEY_` 前缀注入 Info.plist → 编译进 IPA 二进制包
- 任何人获取 IPA 文件后，可通过 `strings` 命令提取：
  ```
  strings Songly.app/Songly | grep "sk-"
  ```
- `.xcconfig` 仅防止 git 误提交，**不是安全措施**——它是开发卫生习惯
- **MVP 缓解措施：**
  1. DeepSeek 控制台设置消费限额（如 50 元/月），即使 Key 泄露损失可控
  2. 为 App 使用独立 API Key（不是开发者主 Key），泄露后可单独轮换
  3. 每用户年成本 ~¥0.5，攻击者刷 Key 的边际收益极低
- **Phase 2 根本解决：** 引入后端代理，Key 只存于服务端，客户端通过匿名认证访问

### 8.2 数据隐私

| 数据 | 存储位置 | 是否上传 |
|------|----------|----------|
| 收藏歌曲数据 | SwiftData（本地） | 仅构建 prompt 时发送给 LLM API（仅歌名+艺人名） |
| 推荐历史 | SwiftData（本地） | 不上传 |
| 用户 Apple ID | 不存储 | 不上传 |
| API Key | .xcconfig（本地）→ IPA 内嵌 | 仅作为 HTTP Authorization Header |

- MusicKit 返回的 `Song` 不含用户 Apple ID 或邮箱
- 发送给 LLM 的 prompt 仅含歌名+艺人名，不含任何用户标识
- 不集成任何第三方分析 SDK（MVP 阶段）
- 隐私清单 `PrivacyInfo.xcprivacy`：需声明向 `api.deepseek.com` 传输数据（歌曲名+艺人名用于推荐生成）

### 8.3 网络请求安全

- 所有请求使用 HTTPS
- ATS (App Transport Security) 保持默认开启
- API Key 仅通过 `Authorization: Bearer` header 传输

### 8.4 无障碍 (Accessibility)

MVP 阶段应满足基础无障碍要求（也是 App Store 审核关注点）：

| 要求 | 实现 |
|------|------|
| **Dynamic Type** | 使用 `.font(.body)` / `.font(.headline)` 等语义字体，而非固定字号 |
| **VoiceOver 标签** | 所有按钮有 `accessibilityLabel`；风格按钮的 emoji 需配合文本标签（"🎸 摇滚" → "摇滚风格歌单"） |
| **最小触摸区域** | 按钮 ≥ 44×44pt（Apple HIG 要求），`StyleButton` 需确保 |
| **减少动态效果** | 尊重 `accessibilityReduceMotion` 环境值，Loading 动画降级为静态指示器 |
| **高对比度** | 使用系统颜色（`.primary`, `.secondary`），自动适配深色模式和增加对比度 |

### 8.5 本地化

- 使用 `.xcstrings` String Catalog 管理所有用户可见字符串
- MVP 以中文为主，`.xcstrings` 结构预留英文翻译位置
- 代码中避免硬编码字符串：`Text("🎵 每日推荐")` → `Text(.dailyRecommendationTitle)`

---

## 9. 测试策略

### 9.1 测试金字塔

```
         ┌──────┐
         │  UI  │  关键流程验证（授权、推荐触发、结果展示）
         ├──────┤
         │ 集成  │  Service 层集成测试（MusicKit mock, LLM mock）
         ├──────┤
         │ 单元  │  ViewModel, PromptBuilder, 数据模型
         └──────┘
```

### 9.2 测试覆盖重点

| 层级 | 测试内容 | 工具 |
|------|----------|------|
| 单元测试 | `PromptBuilder` token 管理 / 去重逻辑 | Swift Testing |
| 单元测试 | LLM 响应解析器容错（真实 LLM 输出格式） | Swift Testing |
| 单元测试 | `RecommendationRecord` tracks JSON 序列化/反序列化 | Swift Testing |
| 单元测试 | 日期格式化/播放列表命名规范 | Swift Testing |
| 集成测试 | `RecommendationEngine` 状态机（mock services） | Swift Testing |
| 集成测试 | `LLMService` 超时/重试/指数退避 | Swift Testing |
| 集成测试 | SwiftData 读写一致性 | Swift Testing |
| UI 测试 | 授权流程完整走通 | XCTest |
| UI 测试 | "想听"按钮触发推荐 → 结果展示 | XCTest |
| 手动测试 | 后台任务触发（**仅真机**，模拟器不支持 BGTask） | 手动 |
| 手动测试 | 推送通知送达 | 手动 |

### 9.3 Mock 策略

为所有 Service Protocol 提供 Mock 实现：

```swift
final class MockMusicKitService: MusicKitServiceProtocol { ... }
final class MockLLMService: LLMServiceProtocol { ... }
final class MockPlaylistService: PlaylistServiceProtocol { ... }
```

---

## 10. 性能指标与监控

### 10.1 关键指标

| 指标 | 目标 | 监控方式 |
|------|------|----------|
| 整体推荐耗时 | < 30s | `os_signpost` (.recommendationPipeline 区间) |
| LLM API 响应 | < 10s | `os_signpost` (.llmRequest 区间) + URLSession metrics |
| MusicKit 搜索 (25首, 5并发) | < 15s | `os_signpost` (.catalogSearch 区间) |
| 匹配率 | > 80% | 每次推荐自动记录到 RecommendationRecord |
| App 冷启动 | < 2s | MetricKit `MXAppLaunchMetric` |

### 10.2 性能优化点

- MusicKit 搜索使用 `TaskGroup` 并发（5 并发），避免串行等待
- 收藏列表增量更新：`lastSyncDate` 过滤，仅拉取新增收藏
- LLM 响应本地缓存 keyed by (策略 + 日期)，同日重复触发复用
- 图片资源使用 SF Symbols，无需额外下载
- 网络监控：`NWPathMonitor` 实时跟踪网络状态，离线时跳过 LLM 调用直接报错而非等待超时；网络恢复后自动触发延迟推荐

---

## 11. 技术债务与后续演进

### 11.1 MVP 已知问题

| 问题 | 影响 | Phase 2 计划 |
|------|------|-------------|
| API Key 可被 IPA 提取 | 泄露后消费被盗（但金额极小） | 引入后端代理 API |
| 歌单累积无清理 | 30 天 = 30 份歌单，365 天 = 365 份 | 自动清理 30 天前的歌单 / 追加到滚动周歌单 |
| 后台管线频繁被系统 kill | 用户需打开 App 才能触发推荐 | 后台拆分：仅 LLM 调用 → 存结果 → 前台补搜索 |
| 并行数组已修复为 JSON 存储 | — | — |
| Swift 6 严格并发 | 部分 MusicKit 类型可能非 `Sendable`，需 `@unchecked Sendable` 包装 | 关注 Beta 更新，适配正式版 |

### 11.2 Phase 2 可能的架构演进

| 变更 | 理由 | 影响 |
|------|------|------|
| **引入后端代理 API** | 保护 API Key（根本解决），支持多 LLM Provider 热切换 | 新增服务端，客户端改 URL |
| 策略池扩展 | 更多推荐策略提升新鲜感 | 仅改 PromptBuilder |
| 反馈闭环 | 用户偏好影响下次推荐 | 新增 SwiftData 字段 + prompt 注入 |
| macOS 版本 | iPad 设计可直接适配 Mac Catalyst | 新增 target |
| Widget | 桌面小组件展示今日推荐 | 新增 Widget Extension target |
| 歌单清理策略 | 自动删除/合并旧歌单 | PlaylistService 新增清理逻辑 |

---

## 附录 A: 外部依赖

| 依赖 | 版本 | 用途 | 备注 |
|------|------|------|------|
| MusicKit | iOS 26.5+ (系统框架) | 音乐数据读写 | 需 `NSAppleMusicUsageDescription` |
| SwiftData | iOS 26.5+ (系统框架) | 本地持久化 | 不使用 CloudKit（无 `.unique` 冲突） |
| SwiftUI | iOS 26.5+ (系统框架) | UI 框架 | 使用 `@Observable` 宏（非旧版 `ObservableObject`） |
| BackgroundTasks | iOS 26.5+ (系统框架) | 后台任务 | 仅真机可用 |
| UserNotifications | iOS 26.5+ (系统框架) | 推送通知 | — |
| Network | iOS 26.5+ (系统框架) | `NWPathMonitor` 网络状态监控 | — |
| DeepSeek API | `deepseek-chat` model | LLM 推荐引擎 | HTTP API，非 SDK |

**无第三方依赖** — MVP 阶段仅使用 Apple 系统框架 + DeepSeek HTTP API。
