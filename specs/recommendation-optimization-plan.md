# 推荐逻辑优化方案（v2 — 已合并专家审核修正）

> 日期：2026-08-16
> 状态：**已实施（2026-08-16）**，Phase 0→4 全部落地，构建通过、15 个单元测试通过。
>
> v2 变更：并入两位专家审核（苹果生态专家 / 软件架构师）的全部修正——修复 2 处编译错误 + 1 处上架风险，按依赖重排实施阶段。实施顺序**必须**按本版的 Phase 0→4，不再按旧版"三部分独立"划分。
>
> 实施备注：天气（WeatherKit）按计划延后，`RecommendationContext.weather` 保留为 nil；`requiresExternalPower` 作为选项注释保留；后台任务需真机验证（模拟器不触发 BGTask）。

## Context（背景）

用户反馈四类问题：

1. **喂给 LLM 的信号太单一** — 只有收藏库（采样 ≤200 首），看不到"最近在听/反复听什么、当下情境"。
2. **去重太弱** — 现为最近 30 条记录的裸歌名前 75 个，只塞进 Prompt 软排除；无日期窗口、无艺人、无硬过滤。已确认 **14 天硬去重**。
3. **推荐感觉都听过** — 最近播放的歌从不排除，LLM 易推荐用户刚听过的。
4. **生成耗时较长** — 点击生成要等；希望早上 6 点前歌单就绪。

已确认的实现选择：

| 决策点 | 选择 |
|--------|------|
| 去重窗口 | **14 天**（跨 `daily` 记录；quick_pick 用短窗口） |
| 口味信号范围 | **最近播放 + 高播放收藏**（不加 Apple 个性化推荐） |
| 天气 | **MVP 延后不做**（字段保留 nil-able；详见 Phase 3） |
| 热点事件 | **MVP 不做**，用榜单代表"最近流行"（仅作情境，不进硬过滤） |

## 审核结论摘要（本版已据此修正）

- **2 处编译错误已改**：`Song.playHistory`/`isLoved`/`rating` 在统一 `Song` 上不存在（只有 `playCount: Int?` / `lastPlayedDate: Date?`）；`MusicLibrary.edit(_:items:)` 不是合法调用（批量建列表改用单调用 `createPlaylist(name:description:authorDisplayName:items:)`）。
- **1 处上架风险已补**：WeatherKit 必须显示 Apple Weather 版权归属（mark + 法律链接）。
- **架构重排**：引擎生命周期（Phase 0）是其它一切的前置；"幽灵完成态"（先落库后建列表、进程被杀即骗用户）必须用记录 `status` 修复；Prompt 需要真实的总 token 预算（旧版超预算 2-3 倍）；去重主键改用 catalog `id`；降级链删掉"缩窗口重跑 LLM"；`source` 感知去重与"今日完成"判断。
- 详见各 Phase 与"关键文件"。

## 已调研的 API（修正版）

| API | 用途 | 备注（含修正） |
|-----|------|------|
| `MusicRecentlyPlayedRequest<Song>`（iOS16+） | 最近播放歌曲（曲目级），limit≈30 | Song 确实 conform；运行时可能为空/nil，须按空降级 |
| `MusicLibraryRequest<Song>` + **服务端** `sort(by: \.playCount, ascending: false)` | 高播放收藏 | 服务端排序 limit 在排序后生效；`playCount` 可能 nil，客户端用 `playCount ?? 0` 兜底 |
| `MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Song.self])` → `response.songCharts` | 最近流行榜单 | 服务端会连 playlist charts 一起返回，**只取 songCharts** |
| `MusicLibrary.shared.createPlaylist(name:description:authorDisplayName:items:)` | **单调用**建列表并写入全部歌曲 | 替代"建空列表+25 次 add"；`Song` conform `MusicPlaylistAddable` |
| `Song.playCount: Int?` / `Song.lastPlayedDate: Date?` | 播放次数/最近播放 | **没有** `playHistory`/`isLoved`/`rating` |
| WeatherKit（**MVP 延后**） | 天气 → 简短描述 | entitlement `com.apple.developer.weatherkit` + **强制版权归属**（`WeatherService.shared.attribution` 的 mark + `legalPageURL`） |
| `BGProcessingTask` / `BGProcessingTaskRequest` | 后台预生成 | 执行窗口分钟级（vs refresh ~30s），仍 best-effort；支持 `requiresNetworkConnectivity`/`requiresExternalPower` |

最低部署 iOS 26.5，以上均可用。

---

## Phase 0 — 引擎生命周期修复（前置，必做）

> 背景：现有 `isRunning` 是标量 flag，存在两个缺陷——后台任务运行中手动点击会**永久转圈**（引擎 `guard !isRunning` 直接 return、永不回调，而 ViewModel 已把 state 置为 readingLibrary）；`cancel()` 立即复位 `isRunning` 但被取消的 Task 仍跑（无 `Task.checkCancellation`），导致**双生成/并发写 SwiftData**。Phase 4 的后台+手动并发会让这两个缺陷必现。

- `RecommendationEngine.runDailyRecommendation` / `runQuickPickRecommendation` **返回结果/抛 `.busy`**；`HomeViewModel.startRecommendation` 只在**获得运行许可后**才把 state 置为 `.readingLibrary`（失败时给出"正在后台生成…"而不是静默）。
- `cancel()` 改**协作式**：取消 Task，`isRunning` 在管线真正退出（`defer`）时才复位；管线每步加 `Task.checkCancellation()`。
- `searchCatalog` 尊重取消：不要用 `try?` 把取消吞掉；任务组在取消时及时退出。

**文件**：`Songly/Services/RecommendationEngine.swift`、`Songly/ViewModels/HomeViewModel.swift`
**验证**：后台运行中手动触发 → 不转圈、不双生成；调用 `cancel()` 后管线真正停止、可安全重跑。

## Phase 1 — 建列表提速 + 完成态可信（低风险，独立）

- **批量建列表**（`Songly/Services/PlaylistService.swift`）：用 `MusicLibrary.shared.createPlaylist(name:description:authorDisplayName:items: matchedSongs)` **单调用**建列表并写入全部歌曲。删除 25 次串行 `add`。（注：`preferredSource` 不是 `Song` 属性，只是 `.with(_:preferredSource:)` 的参数；matchedSongs 来自 catalog search，本就是 catalog 曲目，天然规避 edit 崩溃路径。）
- **LLM 超时** 10s → **45-60s**（`AppConfig.requestTimeout`）：消除慢响应无效超时重试。
- **完成态可信**（`Songly/Models/RecommendationRecord.swift` + `RecommendationEngine.swift` + `HomeViewModel.swift`）：
  - `RecommendationRecord` 新增 `status: String`（`pending`/`completed`）和 `playlistID`/`playlistURL`（可空）。
  - 落库写 `pending`；**建列表成功后**翻 `completed` 并写 playlistID/URL。
  - `hasTodayRecommendation()` / `restoreTodayState()` 仅把 `completed` 的记录视为"今日已生成"——杜绝"歌单不存在却显示已生成"的**幽灵完成态**。
  - "打开歌单"按钮深链到 `playlistURL`（替代泛 `music://`）。
- **source 门控**：`source == "daily"` 才算"今日已生成"（quick_pick 不挡当日每日按钮）。
- **回滚修正**：`deleteRecommendation` 改为按刚插入那条记录的 `persistentModelID` 删除（现按天删第一条，可能误删其它 source 的记录）。

**文件**：`Songly/Services/PlaylistService.swift`、`Songly/Services/RecommendationEngine.swift`、`Songly/Models/RecommendationRecord.swift`、`Songly/App/AppConfig.swift`、`Songly/ViewModels/HomeViewModel.swift`、`Songly/Views/HomeView.swift`
**验证**：改造前后对比"点击到完成"秒数（重点看建列表段）；杀掉进程模拟落库后中断 → 重启后不显示"已生成"；每日按钮在 quick_pick 生成后仍可点。

## Phase 2 — 去重做对 + 最近播放（核心价值，就是原始诉求）

- **最近播放取数**（`MusicKitService.fetchRecentlyPlayedSongs(limit: 30)`）：`MusicRecentlyPlayedRequest<Song>`；编译不过回退 `MusicDataRequest` 打 `/v1/me/recent/played/tracks`。**运行时视为 UNCERTAIN**：为空/失败一律返回 `[]`，绝不把"避免刚听过"当成硬承诺。
- **双层去重**（`Songly/Models/TrackItem.swift` + `RecommendationEngine.swift`）：
  - 前置粗过滤：归一化 `TrackKey`（trim/lowercase/去括号/折叠空白）过滤 LLM 输出——省钱，避免浪费 catalog 搜索；
  - **权威去重（匹配后）**：对 catalog 搜索到的 `Song.id`，与最近 14 天 `daily` 记录的 `trackIDs` 做**集合级硬去重**。歌名归一对 `feat.`/`Live`/繁简/全半角都漏，`MusicItemID` 才是权威稳定键。
- **source 感知窗口**：
  - 14 天硬去重**只跨 `source == "daily"`** 的记录；
  - `quick_pick` 记录用短窗口（如 3 天）或仅依赖最近播放排除——用户主动要的风格不应被 14 天阻断；
  - "今日已生成"只认 `daily`（见 Phase 1）。
- **自适应兜底（删除"缩窗口重跑 LLM"）**：过滤不足 `minTrackCount` 时**不重跑 LLM**，按顺序尝试：
  1. 放宽"收藏重叠"到约 20%，对**同一份输出**重新过滤；
  2. 用被排除的**最高置信 LLM 候补**补位；
  3. 仍不足才报可重试错误，并 `log` 各排除集命中数便于诊断。
- **Prompt 排除对子砍量**：Prompt 内近期推荐列表从 150 条砍到 **30-50 条**（LLM 无法有效消化 150 条排除；真正的去重由硬过滤兜住）。

**文件**：`Songly/Services/MusicKitService.swift`（+协议）、`Songly/Services/RecommendationEngine.swift`、`Songly/Models/TrackItem.swift`、`Songly/Utils/PromptBuilder.swift`、`Songly/App/AppConfig.swift`
**验证**：播放某歌后生成 → 不在结果；连续生成（或造两条窗口内记录）→ 无重复曲目；quick_pick 生成后每日仍可正常生成且不互斥；过滤不足时走自适应兜底、不重跑 LLM。

## Phase 3 — 口味/情境信号收尾（在 Prompt 预算修好之后）

- **Prompt 真实总预算**（`PromptBuilder.swift`）：按分区做 token 估算——有"最近在听/高播放/榜单"时，**把收藏采样从 2000 压到 ~1000**（收藏在有了这些信号后信息量最低）；修复 `sampleSongs` 的 `prefix(50)` 兜底绕过 maxTokens 的问题。
- **高播放收藏**：`MusicLibraryRequest.sort(by: \.playCount, ascending: false)` **服务端排序** + 客户端 `playCount ?? 0` 兜底；**若排序信号全无则返回 `[]`**，绝不注入任意歌曲冒充"反复播放的收藏"。
- **榜单**（`fetchTrendingSongs(limit: 15)`）：`MusicCatalogChartsRequest` 只取 `songCharts`；**仅作"情境"输入，不进硬过滤**；与"优先冷门好歌"措辞调和（明确榜单用于参考当下流行，不要求往榜单靠）。
- **上下文超时**：recentlyPlayed/topPlayed/trending（及后续 weather）每个包 **2-3s 超时**、并发执行；超时视为 nil/空。
- **天气（MVP 延后）**：`RecommendationContext.weather` 字段**保留为 nil-able**，本轮不实现。若后续要加：WeatherKit entitlement + **Apple Weather 版权归属（mark + `legalPageURL`，审核 5.2.5 强制）** + 后台路径用缓存的最后定位（`.whenInUse` 在后台拿不到新定位；WeatherKit 本身不要求定位权限，可传任意坐标）。先在 Phase 1/2 落地验证"天气是否真的影响推荐质量"再决定。
- `season` / `isWeekend` 为本地纯函数（`RecommendationContext.currentSeason(for:)` / `isWeekend(_:)`），无 IO、零风险。

**文件**：`Songly/Utils/PromptBuilder.swift`、`Songly/Models/RecommendationContext.swift`（新）、`Songly/Services/MusicKitService.swift`、`Songly/App/AppConfig.swift`、`Songly/Services/WeatherService.swift`（延后）
**验证**：抓 LLM 请求日志确认各区块存在且总 token 在预算内；高播放信号全 nil 时 Prompt 无"反复播放"区块；断网时上下文静默降级。

## Phase 4 — 后台预生成（最后上，且对用户讲清是 best-effort）

- **换 `BGProcessingTask`**（`Songly/Services/BackgroundTaskService.swift`）：
  - 必须同步改 `register()` 里的 `task as! BGAppRefreshTask` → `task as! BGProcessingTask`（**否则同 identifier 启动即崩溃**）；
  - `BGProcessingTaskRequest`：`earliestBeginDate` = 凌晨 **2:00**，`requiresNetworkConnectivity = true`，可考虑 `requiresExternalPower = true`（夜间充电时机最佳；代价是不充电不跑）；
  - 同一 identifier **不能同时排** refresh 和 processing 两种（submit 会覆盖）。
  - **调度前 gate**：`MusicAuthorization.currentStatus == .authorized` 才排——后台里 `request()` 弹不出授权框会挂死。
- **完成态刷新前台 UI**：`.completed` 时发本地通知 + `NotificationCenter` 事件，`HomeViewModel` 据此重载今日记录（后台完成时前台不会停留在陈旧状态）。
- **手动按钮保留为降级**：配合 Phase 1 提速后点击也不慢；若被后台占用，显示"正在后台生成…"。
- **平台现实**：模拟器后台任务**永不真正启动**（只能冒烟测试注册；真机验证或用 LLDB `_simulateLaunchForTaskWithIdentifier`）。对用户传达"尽力而为"，不承诺"凌晨一定跑完、6 点 0 延迟"。

**文件**：`Songly/Services/BackgroundTaskService.swift`、`Songly/Services/NotificationService.swift`、`Songly/ViewModels/HomeViewModel.swift`
**验证**：真机不打开 App 观察能否完成并收到通知；确认 `register` 强转类型与调度条件正确；模拟器仅验证注册不崩溃。

---

## 工程配置

- （Phase 3 天气若启用）WeatherKit capability（entitlement）+ Info.plist `NSLocationWhenInUseUsageDescription` + Apple Weather 版权归属展示。

## 测试（`SonglyTests/SonglyTests.swift`）

- **先修损坏用例** `quickPickStyleMVPCount`（引用不存在的 `mvpStyles`，当前导致 `xcodebuild test` 编译失败）→ 改断言 `allStyles.count == 8`。
- 新增（Swift Testing）：
  - Phase 0：`busy` 返回/状态机——后台占用时手动触发不转圈；`cancel()` 后管线真停、可重跑。
  - Phase 1：`createPlaylist(items:)` 单调用路径；记录 `status` pending→completed 翻转；"今日已生成"只看 `daily` + `completed`；按 `persistentModelID` 回滚。
  - Phase 2：标题 key 前置过滤 + **catalog `id` 权威去重**（窗口内 id 剔除、窗口外保留）；source 感知窗口（quick_pick 不污染 daily）；自适应兜底（放宽收藏重叠、不用重跑 LLM）。
  - Phase 3：Prompt 各区块有无、总 token 在预算内；高播放全 nil → `[]`；`season`/`isWeekend` 边界。
  - Phase 4：调度条件（authorized gate、earliest、network）可单测的部分。

## 不改的部分

- 匹配三层（`searchTrack`）、授权流程、通知授权。
- `UserPreferences` 数据模型。

## 关键文件

- `Songly/Services/RecommendationEngine.swift`（Phase 0/1/2 核心）
- `Songly/Services/MusicKitService.swift`（+协议）、`Songly/Services/PlaylistService.swift`、`Songly/Services/BackgroundTaskService.swift`、`Songly/Services/NotificationService.swift`
- `Songly/Models/RecommendationRecord.swift`、`Songly/Models/TrackItem.swift`、`Songly/Models/RecommendationContext.swift`（新）
- `Songly/Utils/PromptBuilder.swift`、`Songly/App/AppConfig.swift`
- `Songly/ViewModels/HomeViewModel.swift`、`Songly/Views/HomeView.swift`
- `SonglyTests/SonglyTests.swift`
- （天气启用时）`Songly/Services/WeatherService.swift`（新）+ pbxproj/Info.plist

## 验证（整体）

1. `xcodebuild -project Songly.xcodeproj -scheme Songly -destination 'platform=iOS Simulator,name=iPhone 17' build`
2. `xcodebuild -project Songly.xcodeproj -scheme Songly test -destination 'platform=iOS Simulator,name=iPhone 17'`（先修损坏用例）
3. 真机（登录 Apple Music）按各 Phase 的"验证"逐项执行；重点：耗时对比、无重复、无幽灵完成态、后台完成刷新 UI。
4. 降级演练：断网/拒定位/非订阅者 → 各信号静默降级且不阻塞主流程；过滤不足走自适应兜底。

## 风险与回退

- `MusicRecentlyPlayedRequest<Song>` 编译不过 → `MusicDataRequest` + `/v1/me/recent/played/tracks`（Phase 2 已列预案）。
- `createPlaylist(items:)` 若个别账号报错 → 回退"建空列表 + 逐首 add"（接受耗时）。
- 后台任务本质 best-effort → 手动按钮兜底；`register` 强转类型必须同步改，否则首启即崩。
- 14 天硬排除（`daily`）削多 → 自适应兜底 + 可重试错误兜底，避免空推荐。
- 天气整体延后 → 若后启用，必须补 Apple Weather 版权归属，否则审核 5.2.5 拒。
