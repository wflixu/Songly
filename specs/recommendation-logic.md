# 歌单生成逻辑分析

> 本文档基于当前代码实现（`RecommendationEngine` + `LLMService` + `MusicKitService` + `PromptBuilder` 等）梳理歌单生成的全流程，作为后续调优与重构的依据。

## 1. 概述

乐遇 Songly 的歌单生成是一条 **端到端流水线**：读取用户 Apple Music 收藏 → 交给 DeepSeek LLM 分析口味并推荐歌曲 → 在 Apple Music 曲库中逐个搜索匹配 → 落库 + 创建真实播放列表 → 本地通知。

整条流水线由 `RecommendationEngine`（一个 `actor`）串行编排，状态机通过回调 `RecommendationState` 推送给 `HomeViewModel` 驱动 UI。

```
授权 → 读收藏 → 构建 Prompt → LLM 推荐 → 曲库匹配 → 落库 → 建播放列表 → 完成 → 通知
```

## 2. 触发入口

共有两条触发路径，走的是**同一条**流水线，仅参数不同：

| 入口 | 来源 `source` | QuickPick 风格 | 触发方 |
|------|--------------|----------------|--------|
| `runDailyRecommendation` | `"daily"` | `nil` | 每日推荐 / 首页按钮 |
| `runQuickPickRecommendation` | `"quick_pick"` | 用户选中的 `QuickPickStyle` | 风格选择器 |

- `runDailyRecommendation` 同时被 `BackgroundTaskService` 用于后台每日自动生成。
- 引擎用 `isRunning` 标志防重入：正在运行时新的触发直接忽略。
- `cancel()` 取消当前任务并复位 `isRunning`。

## 3. 流水线分步详解

### Step 1 · Apple Music 授权

```swift
status = musicKitService.authorizationStatus()
```
- `authorized` → 直接继续
- `notDetermined` → 调 `MusicAuthorization.request()` 弹系统授权框，被拒则报错
- 其它（denied/restricted）→ 报"请在设置中开启 Apple Music 访问权限"，不可重试

### Step 2 · 读取收藏（增量）

```swift
lastSyncDate = fetchLastSyncDate()          // 读 UserPreferences
songs = fetchLibrarySongs(limit: 200, since: lastSyncDate)
```

- 读取上限 `AppConfig.maxLibrarySongs = 200`。
- 读完后把 `UserPreferences.lastSyncDate` 更新为当前时间。
- **注意（当前实现）**：`MusicLibraryRequest` 不支持真正的日期过滤，`since` 参数目前被忽略——每次都是全量拉 200 首。代码中留有 FIXME。

### Step 3 · 构建 Prompt

见第 5 节 `PromptBuilder` 详解。核心输入：采样后的收藏歌曲 + 历史推荐去重名单 + 策略/风格提示词。

### Step 4 · LLM 生成推荐

调用 `LLMService.recommend(prompt:)`，返回 `[TrackItem]`（`title + artist`）。见第 6 节。

- 最低数量校验：`recommendations.count >= AppConfig.minTrackCount (10)`，不足则报错。
- 错误分两类：API Key 未配置 → 不可重试；其它 → 可重试（并透出底层具体错误信息）。

### Step 5 · 曲库匹配（并发）

```swift
(matchedTracks, matchedSongs) = await searchCatalog(recommendations)
```

- 用 `TaskGroup` 并发搜索，并发上限 `AppConfig.searchConcurrency = 5`。
- 每首歌调 `searchTrack(title:artist:)`（三层匹配，见第 7 节）。
- 每完成一个结果就回调 `searchingCatalog(found:total:)` 更新进度条。
- 匹配率校验：
  - 完全无匹配 → 报错"未能匹配到歌曲"
  - 匹配率 `< AppConfig.matchRateThreshold (0.2)` → 报错"仅匹配到 X/Y 首"
  - 返回 `(TrackInfo[], Song[])` 两个数组：`TrackInfo` 用于落库，`Song` 用于真实加入播放列表。

### Step 6 · 持久化记录（先落库）

**顺序很关键：先落库、后建播放列表**。`RecommendationRecord` 作为"今日是否已生成"的唯一依据（`date` 带唯一约束）。

- 歌单命名规则：
  - 每日：`Sunny 每日推荐 · yyyyMMdd`
  - QuickPick：`<emoji> <风格>精选 · yyyyMMdd`
  - 同日多次生成时追加序号：`yyyyMMdd-NN`（`NN` 为该日第几个）。
- `saveRecommendation` 失败 → 报错终止（不建播放列表）。

### Step 7 · 创建播放列表

`PlaylistService.createPlaylist(name:description:songs:)`：

1. 先 `MusicLibrary.shared.createPlaylist` 建空列表
2. 再逐首 `MusicLibrary.shared.add(song, to: playlist)`

失败时**回滚**：删除当天已落库的 `RecommendationRecord`，并报错"播放列表创建失败"（可重试）。

### Step 8 · 完成

回调 `.completed(trackCount:playlistName:)`，`HomeViewModel` 收到后刷新今日记录、累计次数与最近记录列表。

### Step 9 · 本地通知

`NotificationService.shared.sendRecommendationReady(count:)` 发送"今日推荐已生成"通知。

## 4. 关键配置参数（AppConfig）

| 参数 | 值 | 作用 |
|------|----|------|
| `deepseekBaseURL` | `https://api.deepseek.com/anthropic/v1/messages` | DeepSeek 的 Anthropic 兼容端点 |
| `deepseekModel` | `deepseek-v4-flash` | 模型 |
| `requestTimeout` | 10s | 单请求超时 |
| `maxRetries` / `retryDelays` | 3 / `[1, 2, 4]s` | 指数退避重试（仅 5xx/网络错误） |
| `maxPromptTokens` | 2000 | 用户消息 token 预算 |
| `targetTrackCount` | 25 | 每首歌单推荐目标数量 |
| `minTrackCount` | 10 | LLM 输出/最终推荐的最低数量 |
| `maxLibrarySongs` | 200 | 读收藏上限 |
| `searchConcurrency` | 5 | 曲库搜索并发数 |
| `matchRateThreshold` | 0.2 | 最低匹配率阈值 |

## 5. Prompt 构造（PromptBuilder）

### 5.1 歌曲采样（Token 预算控制）

`sampleSongs` 按"每字符 ≈ 1.5 token"的保守估算，从收藏列表**顺序累积**直到超出 `maxPromptTokens`：
- 正常情况：塞满预算即停；
- 兜底：若结果 `< 20` 首且收藏本身 ≥ 20，则直接取前 50 首。

采样歌曲以编号列表格式化：`1. 歌名 - 艺人名`。

### 5.2 历史去重名单

取最近 30 条 `RecommendationRecord` 的所有 `trackNames` 平铺，截取前 75 条，生成"不要推荐以下歌曲（近期已推荐过）"区块；历史为空则不生成该区块。

### 5.3 策略提示词

- 有 `quickPickStyle` → 用风格的 `promptHint`（如"推荐钢琴曲/钢琴独奏/钢琴伴奏的优美曲目"）。
- 否则 → 用 `RecommendationStrategy` 的 `promptHint`（MVP 阶段仅 `styleExploration` = "基于用户的听歌品味，推荐相近风格但用户可能没听过的冷门好歌"）。

### 5.4 固定要求模板

```text
推荐 N(25) 首 Apple Music 曲库中存在的歌曲
1. 每行格式：歌名 - 艺人名
2. 不要推荐用户已经收藏的歌曲
3. (可选)排除近期已推荐
4. 语言/类型比例：中文 6/10、纯音乐 2/10、非英文外语 1/10、英文 1/10
5. 优先推荐冷门好歌，而非热门金曲大杂烩
6. 确保歌在 Apple Music 曲库存在（主流歌手正式发行）
7. 输出仅包含歌曲列表，不要额外说明
```

## 6. LLM 调用与响应解析（LLMService）

### 6.1 请求体

- 走 **Anthropic 兼容协议**（`/v1/messages`），header 带 `x-api-key` + `anthropic-version: 2023-06-01`。
- body 关键字段：`model`、`max_tokens: 1000`、`thinking.disabled`，`system` 固定为"你是一个专业音乐推荐专家……每行格式「歌名 - 艺人名」，不输出任何额外说明"。
- 重试策略：网络错误/5xx 按 `[1,2,4]s` 指数退避最多 3 次；4xx 客户端错误直接抛出不重试。

### 6.2 响应解析（兼容三种格式）

1. **Anthropic 格式**：`{"content": [{"type":"text","text":"..."}]}` —— 遍历 content 块跳过 `thinking` 块，取 text。
2. **OpenAI/DeepSeek 原生格式**：`{"choices":[{"message":{"content":"..."}}]}`。
3. 以上都不匹配 → `parseError`。

任一格式解析出的条数 `< minTrackCount` 都抛 `tooFewRecommendations`。

### 6.3 文本 → TrackItem 解析

`parseTrackList` 逐行处理：
1. 去空白、去行首序号（`1.`/`2、`/`•` 等）。
2. 归一化破折号（`—`/`–` → `-`），剔除括号注释如 `(Remastered 2009)`。
3. 按分隔符优先级拆分 `[" - ", " / ", " — ", "\" by ", ": "]`，拆出 `歌名 + 艺人名`；拆不开的行丢弃。

## 7. 曲库搜索匹配（MusicKitService.searchTrack）

对每首 LLM 推荐，执行**三层匹配**，命中即返回 `Song`：

| 层级 | 查询方式 | 说明 |
|------|---------|------|
| 1 精确 | `"{title} {artist}"` 取第 1 个结果 | 歌名 + 艺人联合搜索 |
| 2 仅歌名 | `title` 取第 1 个结果 | 忽略艺人 |
| 3 模糊艺人 | `title` 取前 3 个，逐个算艺人名距离 | 自定义 `artistDistance < 0.3` 才接受 |

`artistDistance` 是简化的字符集 Jaccard 距离：全等=0，互相包含=0.1，否则 `1 - 交集/并集`。

## 8. 数据模型（持久化）

| 实体 | 关键字段 | 作用 |
|------|---------|------|
| `RecommendationRecord` | `date`(唯一)、`strategy`、`songCount`、`tracksJSON`、`createdAt`、`source`、`quickPickStyle?`、`playlistName?` | 每次成功推荐的一条记录；`date` 唯一约束保证"今日只算一次" |
| `UserPreferences` | `lastSyncDate`、`favoriteGenres`、`totalRecommendations` | 增量同步游标（预留）等 |
| `TrackInfo` | `id`、`name`、`artist` | 匹配成功歌曲，JSON 存入 `tracksJSON` |
| `TrackItem` | `title`、`artist` | LLM 原始输出（未匹配前） |

**今日去重逻辑**：`countTodayRecommendations()` 统计今日已有记录数，决定歌单名是否加 `-NN` 后缀；`hasTodayRecommendation()` 用于 UI 判断"今日是否已生成"。同日多次生成不会互相覆盖，而是产生 `-02`、`-03` 等序号歌单。

## 9. 错误处理与回滚汇总

| 失败点 | 表现 | 可重试 | 是否回滚 |
|--------|------|--------|----------|
| 授权被拒 | `.error` 提示去设置 | 否 | - |
| 读收藏失败 | "读取收藏失败" | 是 | - |
| 收藏为空 | "收藏列表为空" | 否 | - |
| LLM：Key 未配置 | 具体错误信息 | 否 | - |
| LLM：其它错误 | 具体错误信息 | 是 | - |
| 推荐数量不足 | "推荐结果不足" | 是 | - |
| 无匹配 / 匹配率低 | "仅匹配到 X/Y 首" | 是 | - |
| 落库失败 | "数据保存失败" | 是 | - |
| 建播放列表失败 | "播放列表创建失败" | 是 | **删除已落库记录** |

## 10. 并发与状态

- `RecommendationEngine` 是 `actor`，串行执行，`isRunning` 防重入。
- 曲库搜索用 `TaskGroup` 并发（上限 5），其余步骤串行。
- UI 状态由 `RecommendationState` 枚举驱动：`idle → readingLibrary → generating → searchingCatalog(found/total) → persistingRecord → creatingPlaylist → completed / error`，`HomeViewModel` 据此展示进度与 `stageIdentifier` 动画。

## 11. 已知限制 / 待办（来自代码）

1. **增量同步未真正实现**：`since lastSync` 被忽略，每次全量拉 200 首（`MusicKitService` 有 FIXME）。
2. **语言比例写死**：Prompt 中固定"中文 6 / 纯音乐 2 / 非英文外语 1 / 英文 1"，非用户偏好驱动。
3. **采样无随机性**：总是从收藏开头顺序截取，可能偏向早期收藏。
4. **策略单一**：`RecommendationStrategy` 定义了 6 种策略，MVP 仅启用 `styleExploration`。
5. **`favoriteGenres` 未使用**：用户偏好风格字段预留但未接入 Prompt。
6. **`totalRecommendations` 未自增于持久化层**：由 `HomeViewModel` 在前端累加，重启后依赖 `fetchCount` 重新计算。
7. **建列表逐首 add**：`PlaylistService` 逐首调用 `MusicLibrary.shared.add`，歌曲较多时较慢。
