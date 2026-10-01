# 乐遇 Songly 改版计划

> 日期：2026-09-30
> 状态：**进行中** —— 需求仍在收集中（用户分多轮补充），本文档持续追加。
>
> 本文档记录「为什么这么改」的完整推理，不只是「改什么」。凡是标注「已查证」的事实，
> 均来自 `iPhoneOS27.0.sdk` 的 `MusicKit.swiftinterface` 或本仓库源码，逐条核对过，不是推测。

## Context（背景）

推荐质量经过两轮迭代（v2 去重与信号强化 → v3「情境 + 三层配比」）已明显提升。用户评价：

> 现在这个推荐质量已经很好了……基本上都可以，有我喜欢听的，有一些惊喜，还有一些跟我风格不同、
> 可以探索的。我觉得这个歌单已经挺好了，达到了一个可用的状态。

所以本次改版的基调**不是**「质量不行」，而是：**质量已经可用，但支撑它继续变好的几个结构性
条件还没建立起来。** 具体分三类：

1. **反馈回路是断的** —— 用户的真实偏好动作全发生在 Apple Music 里，App 看不见（第 1 项）。
2. **几个已知的体感问题没有机制去治** —— 艺人重复、旧歌单堆积、设置页形态（第 2/3/4 项）。
3. **数据不足以支撑迭代** —— 用户明确提出「以后每个版本要不断迭代算法，迭代会越来越好」，
   但当前没有任何版本标识，每迭代一次历史数据就贬值一次（第 5 项）。

用户还明确提出一条贯穿第 4 项的原则：

> 功能决定样式。首先这块它到底有什么功能？没有功能就不要。第二，它应该符合人们操作
> 以及苹果的设计风格。

行文中未展开但用户已提及的观察，记在文末「未决」，以免被误当成抱怨处理。

---

# 第 1 项：隐式反馈闭环（从 Apple Music 回读用户行为）

> 状态：**阶段 1–3 已实施（2026-10-01）**；**阶段 0 的探测代码已写好但尚未在真机跑过**。
> 评分读取整条挂在 `AppConfig.readAppleMusicRatings = false` 后面，**默认关闭** ——
> 关掉时「入库 / 播放 / 歌单被改」三路照跑，它们用的都是已验证的 MusicKit API。
>
> **实施记录**
>
> 新增 `ImplicitSignalDetector.swift`（`ImplicitCandidate` / `ImplicitObservation` /
> `ImplicitSignals` / `ImplicitSignalClassifier` 纯函数 / `ImplicitSignalDetector` I/O）、
> `MusicLibraryService.readRatings(songIDs:)` + 三个探测、`FeedbackStore` 的
> `implicitRemovedIDs` 出口与 `markLibrarySynced` / `markImplicitRemoved`、
> 引擎的 Step 3.5 与三个出口的接线、`PromptBuilderV3` 的隐式信号区块、
> 设置页 DEBUG 的三个探测按钮。新增 **25 条单测**，真机全绿（累计 185 条）。
>
> **两处对计划本身的修正（都是计划写错了）**
>
> 1. **阶段 0c 的修法是错的，已改成删参数。** 计划说「`since:` 那个 no-op 的 FIXME
>    可以真正实现了」——**真那么做会把管线打穿**：Step 2 用 `fetchLibrarySongs`
>    做**全量**收藏读取，排除集合、画像统计、收藏抽样全建立在「他有什么」之上；
>    一旦 `since:` 变成真过滤，那一次调用只会拿到「最近新增的几首」。所以删掉了
>    这个参数（连同那条已经过时的 FIXME —— 它声称 `Song` 不暴露 dateAdded，而
>    `Song.libraryAddedDate` 从 iOS 16 就有）。
> 2. **不能复用全量收藏读取，改用定向查询。** 计划说「复用既有的 `fetchLibrarySongs`，
>    一次取回后客户端比对」—— 但那个方法有 `limit` 上限（200），曲库大的用户会漏，
>    而漏掉的恰好可能是**他刚加进来的那几首**。改为新增
>    `fetchLibrarySongs(ids:)`：`MusicLibraryRequest<Song>` +
>    `filter(matching: \.id, memberOf:)`，按推荐过的 ID 定向查。
>
> **一处计划没定的、已拍板的**：一首歌既被 ⭐ 又被从歌单里删掉时取哪个？
> **取 ⭐。** ⭐ 是对这首歌**明确**的正面表态，而「从歌单里消失」至少有一种无害读法
> （「这首我早就有」）。把用户亲手标过的歌永久排除，是这两个错误里更坏的那个。
> 有一条单测钉住它（`starredOutranksRemoval`）。
>
> **`librarySyncedAt` 只在 `.added` 时写。** `addToLibrary` 的返回值正好能区分
> 「我们加的」与「本来就有」（`.added` / `.alreadyOwned`）—— 后者的情况交给
> `libraryAddedDate` 的时间比对去挡：本来就在库里的歌，入库时间远早于这次推荐，
> 天然不满足「推荐之后」。这正好回应了 `PlaylistDetailView` 里那条
> 「我们无法区分这两种情况」的旧注释。
>
> **首次实测（2026-10-01 13:15，v4 构建）** —— 第 5 项刚落地的诊断块第一次报数：
>
> ```
> implicit: { candidates: 75, starred: 0, adopted: 0, listened: 0,
>             playlist_removed: 8, weighted_artists: 7,
>             notes: ["playlist_diff_suspect", "ratings_read_disabled"] }
> ```
>
> - `starred: 0` —— `readAppleMusicRatings` 关着，符合预期。
> - `adopted: 0` / `listened: 0` —— **也是符合预期的**：管线刻意排除收藏库里的歌，
>   所以候选（我们推荐过的歌）本来就不在库里，定向查回空。这两个信号要等用户
>   **后来把某首歌加进资料库**才会亮。
> - `playlist_removed: 8` —— **歌单 diff 在真机上确实有效**。用户确认
>   「删过，差不多就是这个量」，所以那 8 首是真实信号、不是比对误判。
>   同一份 notes 里的 `playlist_diff_suspect` 来自**另一份**歌单（存活率 < 30%），
>   说明安全闸门也在正常工作。
>
> **由此产生的两个改动**：
>
> 1. `treatPlaylistRemovalAsPermanent` 改为 **false**（`pipelineVersion` 4 → 5）。
>    ⚠️ 这是**审慎**而非**怀疑** —— 用户已经确认那 8 首是真的，等于把「准不准」这个
>    探测本来要回答的问题回答了一半。降级的代价是真实的：他主动从歌单里删掉的歌
>    可能又被推回来，也就是计划里称作「最伤信任」的那个失败。等「探测：歌单条目」
>    报出匹配率 ≥ 90%，改回 `true` 即可。
> 2. 修掉一个**实现 bug**：`treatPlaylistRemovalAsPermanent` 此前是**半失效**的 ——
>    `derive()` 判了它，但 `makeExclusions` 把当轮实时发现的那批无条件并进硬排除，
>    于是开关关了照样拦。现在判断收拢到 `makeExclusions` 这**唯一消费点**，
>    同时管住「落盘的历史」与「本轮刚发现的」两个来源。
>    顺带：`derive()` 只回答「观察到了什么」，不再做取舍 —— 这让它的两条单测
>    继续有意义（否则会因为开关关着而"通过"，而不是因为逻辑对）。
>
> **诊断与导出的两处补强**（因为上面这个信号会永久影响结果，必须可核对）：
> `diagnostics` 增加 `playlist_removed_names`（歌名本身，此前只有计数）；
> 导出的曲目增加 `implicit_removed_at` / `library_synced_at`。
>
> **仍未验证**：阶段 0 的三项探测、以及 `readAppleMusicRatings` 打开后的真实效果。

## 问题

App 生成歌单 → 跳转 Apple Music 播放。用户的大部分动作发生在 Apple Music 里，而 App 只能收到
**在 App 内**主动点的反馈（`PlaylistDetailView` 的超赞 / 删除 / 歌单「准不准」三档）。用户自述：

> 我平时主要是在 Apple Music 里操作，很少回到这个 APP。如果我想添加反馈，必须返回来操作。

也就是说：**最真实的偏好信号（他到底收下了哪些歌）全部丢在 Apple Music 里，App 看不见。**
用户收藏一首推荐歌，等于直接告诉系统「这个方向对了」，而下一轮系统还会把同样的方向当陌生方向试探。

## 关键澄清：用户的「收藏」是 ⭐，不是「加入资料库」

用户的回答推翻了最初的假设：

> Apple Music 里面没有"喜欢"，只有一个叫做五角星的东西，你点击之后就收藏了。

这颗 ⭐ 是 iOS 17.1 引入的 **Favorites（收藏）**，替换掉了旧的 ♥「喜欢」，在 API 里就是
`rating` 值 `1`。它和「加入资料库」（`+`）是**两个独立动作**。

结论：只做资料库检测等于什么都没做。主信号必须走 REST，而它**尚未验证** —— 这就是本方案
存在「阶段 0」的原因。

## 已确认的技术事实（逐条 grep 过，非推测）

| 事实 | 结论 |
|---|---|
| `Song.libraryAddedDate: Date?`（iOS 16+） | **存在**。`MusicKitService.fetchLibrarySongs` 里那句 `FIXME: Song doesn't expose dateAdded` 是**过时的**，顺手删掉 |
| `Song.playCount` / `Song.lastPlayedDate` | 存在 |
| `MusicLibraryRequest<Song>.filter(matching: \.id, memberOf: [MusicItemID])` | 可用，能按 ID 批量定向查 |
| `LibrarySongFilter` | **只暴露 `id/title/artistName/albumTitle/…`**，`libraryAddedDate`/`playCount` 不可 **filter**，只能 **sort** → 「查某天之后入库的」不是服务端查询，只能取回客户端比 |
| `Playlist.entries` | `MusicRelationshipProperty<Playlist, Playlist.Entry>`，须 `playlist.with([.entries])` 取；`MusicLibraryRequest` 本身没有 `with(_:)` |
| `Playlist.Entry` | 有 `title` / `artistName` / `position` / `item`，**`id` 是另一套 ID 域**（≠ 我们存的目录 ID） |
| `MusicItemCollection.hasNextBatch` / `nextBatch(limit:)` | 存在 → 分页抓取可检测，这是安全闸门的支点 |
| MusicKit Swift 的 `rating` / `love` / `favorite` | **零命中**。评分只能手写 REST；`MusicDataRequest` 自动带 developer + user token，`MusicLibraryService.putRating` 已是先例 |

两个最容易踩的坑，先写在这里：

1. **歌单 diff 绝不能按 `id` 比对**。`Playlist.Entry.id` 与 `TrackInfo.id` 不同域，直接比对会
   静默地把整份歌单判成「全被删了」，把 25 首歌永久打进排除集。必须按 `TrackKey`
   （归一化 歌名+艺人）比对。
2. **`MusicLibrary.add` 会被我们自己的代码污染**。`PlaylistDetailView.syncLovedToAppleMusic`
   在用户点 App 内「超赞」时会调 `addToLibrary` —— 所以「在资料库里」不等于「他自己收的」。

## 已确认的产品决策

1. ★收藏为主信号；入库 / 播放为辅助信号。
2. **完全后台**：不加任何 UI（无角标、无「系统推断」页）。唯一可观测性是既有的 DEBUG
   `logDiagnostics` 单行 JSON —— 与该用户「靠真机诊断字段排查」的既有习惯一致。
3. 用户在 Apple Music 里从我们建的歌单删掉的曲目，要回读并当作强负面。

## 预期结果

每轮生成前，系统能回答「我前几轮推的歌里，哪些他后来自己收下了？哪些他删了？」并把答案喂进
既有的三个出口（prompt / 艺人权重 / 排除集），下一轮更准 —— 而用户零操作。

---

## 阶段 0：真机探测（门禁，必须先做）

三条路都**不能靠猜**。沿用既有 `probeRatingWrite` 的形状（`MusicLibraryService.swift:142-178`
+ `SettingsView.swift:429` 的 DEBUG 按钮 + `probeSheet`），新增三个探测，都只在 DEBUG 可见。

**0a. `probeRatingRead(songID:)`** —— 回答「⭐ 到底读不读得到、用哪条路」

| 探测 | 端点 | 判读 |
|---|---|---|
| A（主推） | `GET /v1/me/ratings/songs?ids=<id,…>` | `data[].attributes.value`；**id 不在 data 里 = 没标过** |
| B | `GET /v1/me/ratings/songs/<catalogID>` | `200` + value；**`404` = 没标过，不是错误** |
| C | `GET /v1/me/ratings/library-songs/<libraryID>` | 兜底；但需先做 catalog→library id 映射，多一跳 |

⚠️ **必须同时跑两首歌：一首他标过 ⭐ 的、一首没标过的。** 没有阴性对照，就无法区分
「404 = 没标过」和「404 = 端点根本不通」—— 这正是 Write 探测当年卡住的原因。

**0b. `probePlaylistEntries(playlistID:)`** —— 回答「歌单 diff 到底能不能做」

1. `MusicLibraryRequest<Playlist>()` + `filter(matching: \.id, equalTo:)` 能不能查回我们建的歌单
2. `playlist.with([.entries])` 对**资料库歌单**是否可用（类型上成立，运行时未验证）
3. `entries.hasNextBatch` 是否为 false（有没有分页）
4. **把 `entry.title | entry.artistName | entry.id` 与本地 `TrackInfo` 并排打印，肉眼算匹配率**

判据：**匹配率 < 90% 就不做歌单 diff**（不是降级为可放宽，是整个关掉）。

**0c. 顺手修掉** `MusicKitService.fetchLibrarySongs` 里那段 `since:` 的 no-op `FIXME`
—— `libraryAddedDate` 可以真正做增量过滤了。不是本项必需，但同一处、同一次真机验证。

探测结论回来之前，阶段 1/2/3 可以照常写完并合入，只是被 `readAppleMusicRatings` 开关挡住。

---

## 阶段 1：检测器（★收藏 / 入库 / 播放）

### 新文件 `Songly/Services/ImplicitSignalDetector.swift`

按代码库既有的「纯函数 vs I/O」缝切开（对照 `PlaylistComposer` 纯 / `CatalogResolver` I/O）：

```swift
/// 输入：全来自本地记录，不含任何网络状态。由引擎在主线程组装。
struct ImplicitCandidate: Sendable, Equatable {
    let songID: String
    let key: TrackKey
    let displayName: String        // "歌名 - 艺人"
    let artist: String             // primaryArtistKey(...)
    let firstRecommendedAt: Date   // 窗口内**最早**一次推荐它的记录日期
    let playlistID: String?
    let hasExplicitVerdict: Bool
    let librarySyncedAt: Date?     // 我们自己 add 进资料库的时间（见下）
}

/// 网络的**原始事实**，不含任何权重判断 —— 可用 fixture 直接构造，单测不需要网络。
struct ImplicitObservation: Sendable, Equatable {
    var starredSongIDs: Set<String> = []
    var dislikedSongIDs: Set<String> = []
    var adoptedSongIDs: Set<String> = []
    var listenedSongIDs: Set<String> = []
    var removedFromPlaylistKeys: Set<TrackKey> = []
    var degraded: Bool = false
    var notes: [String] = []       // 失败原因，进 logDiagnostics
    static let empty = ImplicitObservation(degraded: true)
}

/// 纯分类器的产物。prompt 与 composer 直接可用。
struct ImplicitSignals: Sendable, Equatable {
    var artistWeights: [String: Int] = [:]
    var starred: [String] = []
    var adopted: [String] = []
    var listened: [String] = []
    var removedSongs: [String] = []
    var removedIDs: Set<String> = []
    var removedKeys: Set<TrackKey> = []
    static let empty = ImplicitSignals()
}

protocol ImplicitSignalDetecting: Sendable {
    /// **永不抛错、永不失败整条管线**：任何子步骤失败只让对应字段为空并记 note。
    func observe(_ candidates: [ImplicitCandidate]) async -> ImplicitObservation
}

enum ImplicitSignalClassifier {   // 纯函数，可完整单测
    static func classify(_ candidates: [ImplicitCandidate],
                         observation: ImplicitObservation) -> ImplicitSignals
}

final class ImplicitSignalDetector: ImplicitSignalDetecting { /* 只有网络 I/O */ }
```

**类型选择：普通 `final class: Sendable`** —— 不是 actor（无共享可变状态，引擎本身已是 actor 会串行化），
不是 `@MainActor`（2–4 次串行网络往返会卡主线程）。它也**不碰 SwiftData**：读记录照旧归
`FeedbackStore` / 引擎，符合 `FeedbackStore` 头部注释定下的归属规则。

### 检测实现要点

- 评分读取走**批量**（探测 A），按 `ratingBatchChunkSize` 分片、**串行**发，别并发打 Apple 的限流。
- 入库 / 播放的判定要**复用既有的 `fetchLibrarySongs`**（`MusicKitService.swift:70`），
  一次取回后客户端比对 —— 因为 `libraryAddedDate` 不可 filter。
- 超时由引擎侧 `withTimeout(AppConfig.implicitSignalTimeout)` 兜住；检测器内部在分片之间、
  歌单之间检查 `Task.isCancelled`，**返回部分结果而不是空**。
- 整条评分读取挂在 `AppConfig.readAppleMusicRatings`（默认 `false`）后面。关掉时，
  入库 / 播放 / 歌单 diff 照跑 —— 它们用的都是已验证的 MusicKit API。

### 分类规则（归因是全部难点）

先按 `hasExplicitVerdict == false` 过滤。**这一条就干净地解决了污染问题**：
`syncLovedToAppleMusic` 只在 `love(_:)` 且 `next == .loved` 时可达（`PlaylistDetailView.swift:210-246`），
所以**我们造成的每一次入库，其 `verdict` 当时必然是 `.loved`** —— 全部被这条过滤掉。

| 信号 | 判定 | 权重 |
|---|---|---|
| **★ 收藏** | `starredSongIDs` 含它 | 艺人 **+1** |
| **入库** | `libraryAddedDate != nil && >= firstRecommendedAt - 1天`，且 `librarySyncedAt == nil` | 艺人 **+1** |
| **听过** | `lastPlayedDate != nil && > firstRecommendedAt` | 艺人 **0**，仅进 prompt |
| **不喜欢** | `dislikedSongIDs` 含它 | 艺人 **−1**，**不进排除集** |

三条硬规则：

1. **归因锚点用窗口内「最早」一次推荐日期**，不是最近一次。他在第 2 次推荐后才收藏，
   用「最近一次」会漏判。
2. **一首歌只计一次，取最强档**（★ = 入库 > 听过），**绝不叠加**。★+入库+听过 = +1，不是 +3。
3. **`librarySyncedAt`**：`love(_:)` 是 toggle，用户把 3 周前的超赞取消后 `verdict` 变 `nil`，
   但那首歌还在资料库里、是**我们**加的 —— 残留漏洞。修法就是精确而非启发式：
   `TrackInfo` 加 `var librarySyncedAt: Date? = nil`（`var` + 默认值 = 零 SwiftData 迁移，
   与 `artworkURL`/`tier`/`verdict` 同一模式），入库成功后由 `FeedbackStore` 写入
   （写模型的动作留在 store，不放 view）。只对以后生效；老记录退化用启发式：
   `libraryAddedDate` 落在任何一次 `.loved` 判定 ±2 天内 → 不算入库。

⚠️ **评分没有时间戳**：六月前给的 ⭐ 和昨晚给的 ⭐ 无法区分。三重收敛 —— 30 天回看窗口、
只把正向归到**艺人**而非单曲、权重只有显式超赞的一半。残余误差是「偶尔高估一个他本来就爱的艺人」，
方向无害。

---

## 阶段 2：歌单被改的负面信号

选记录：`status == "completed"` 且 `playlistID != nil` 且 `date >= now - implicitLookbackDays`，
新的优先，上限 `maxPlaylistDiffsPerRun = 3`。

每份歌单：

1. `MusicLibraryRequest<Playlist>()` + `filter(matching: \.id, equalTo:)` → 空 = 歌单已不存在 →
   **记 `playlist_missing`，什么都不标**。删掉整份歌单绝不能翻译成 25 首永久排除
   （重装 / 重新同步资料库是同样的签名）。
2. `playlist.with([.entries])`，然后 `while entries.hasNextBatch { entries += nextBatch() }`。
3. **四道安全闸门，全过才允许归因**：
   - 闸 1：抓取 + 分页排空成功（无抛错、结束时 `!hasNextBatch`）
   - 闸 2：`entries.count > 0`
   - 闸 3：**存活率** `survivors / record.visibleTracks.count >= implicitRemovalMinSurvivorRatio(0.3)`
     —— 如果「我们推的全都缺了」，那是 ID 域或分页的 bug，不是用户在清理。**这道闸是防投毒的关键。**
   - 闸 4：按 `TrackKey(normalizedKey(entry.title), normalizedKey(entry.artistName))` 比对，
     **不是按 id**
   - 任一失败 → `notes.append("playlist_diff_suspect:<id>")`，零贡献，原因进日志。
4. 只有「记录里有、抓回来的集合里没有」的才算被删。

**持久化**：命中的 `TrackInfo` 写 `var implicitRemovedAt: Date? = nil`
（`FeedbackStore.markImplicitRemoved`）。不持久化的话，这条排除会在记录滚出 30 天窗口时
**蒸发** —— 那正是 `FeedbackTests` 里 `removalSurvivesEveryRelaxationRung` 存在的意义。

---

## 阶段 3：接线

### 出口一：排除集（永不放宽）

`makeExclusions`（`RecommendationEngine.swift:572-601`）新增 `implicitRemovedIDs: Set<String>` /
`implicitRemovedKeys: Set<TrackKey>`，union 进 `removedSongIDs` / `removedKeys`。

**为什么照搬「永不放宽」**（两边论证）：反方 —— 从歌单删歌可能只是「这首不配这次心情」，
而且 diff 是推断的、没有撤销按钮；正方 —— 用户动作的语义与 App 内 `remove(_:)` 完全一致，
代码库已经判定那个动作是刚性意志（`ExclusionSet` 的注释 + 那条测试）。做两套「他删掉了」的
语义而用户看不见，会在候选不足时把他主动删掉的歌又推回来。代价不对称：误排除只损失几百个
候选里的一个，误重推损失的是用户对「删掉」这个词的信任。**取永不放宽**，但留一行开关
`treatPlaylistRemovalAsPermanent`，探测显示 diff 不可靠就降级。

**不喜欢（−1）不进排除集**，只降艺人权重 —— 可能是误触，Apple 又不给时间戳，证据太薄。

### 出口二：艺人权重

隐式贡献先夹取到 `implicitArtistWeightRange = -3...3`，再与显式的 `feedback.artistWeights`
逐项相加，合并后再夹到既有的 `-5...5`。理由同 `FeedbackStore.weightRange` 的注释：
15 个显式超赞已经能顶到 ±5，隐式信号廉价易累积，3 次「好奇点开」不能压过一次慎重的超赞。
改 `RecommendationEngine.swift:271` 与 `:365` 两处传入即可。

### 出口三：prompt（放 `firstUserMessage`，不动 `systemPrefix`）

**不进 `systemPrefix`**。语义上：`systemPrefix` 是「这位用户是谁」的耐久事实
（`PromptBuilderV3.swift:101-103`），隐式信号是「他最近干了什么」，与 `## 最近在听` 同类，
属于 `firstUserMessage`。工程上：`systemPrefix` 一行不动，`FeedbackSummary.promptBlock`
照旧是它最后一块，既有的字节稳定性断言与测试全部继续成立。

（诚实说明：单看 DeepSeek 前缀缓存，两处**等价** —— `firstUserMessage` 里的 `now` 本来就每天
在变，跨天缓存从那里起注定失效；决定因素是语义分层，不是缓存。）

插在 `## 最近反复播放` 之后、`## 近 14 天已推荐过` 之前：

```
## 他的实际收听行为（弱信号）

以下不是他主动说的，是我们回读他在 Apple Music 里的动作推断出来的 ——
可信度**低于**上面的「用户明确反馈」，只当作方向参考，不要升级成硬性规则
（唯一例外见最后一句）：

他打了 ⭐ 收藏的推荐曲目：…
他后来加进资料库的推荐曲目：…
他后来又听过的推荐曲目：…

⭐ 与「加进资料库」说明这个方向对味，可以多挖一点；
「后来听过」只说明他点开过，**不代表喜欢**，不要因为这个方向加大配额。
```

`removedSongs` 非空时追加一句（与显式块结尾的硬规则对称）：

```
**他从前几期歌单里删掉的曲目：…。这些是硬性排除，绝不能再出现。**
```

渲染规则同显式块：复用 `FeedbackStore.ranked(_:limit:)` 的同一比较器排序、封顶
`maxImplicitShownPerCategory = 10`、空块整段省略 —— `ImplicitSignals.empty` 渲染出 `nil`，
无信号时消息与今天**逐字节相同**。

### 接入位置

- **新 Step 3.5**（`RecommendationEngine.swift` L225 之后，**与 Step 3 并发**）：
  8 秒超时必须与 3 秒的 context 取数重叠而不是叠加，且远在 `pipelineDeadline(210s)` 之内。
  ```
  let candidates = await collectImplicitCandidates()          // @MainActor 读记录
  async let implicitTask = withTimeout(AppConfig.implicitSignalTimeout) {
      await self.implicitDetector.observe(candidates)
  }
  ```
  取到后补 `if Task.isCancelled { return }`，与 L194/209/292 同一模式。
- **Step 4**（L227-245）：`ImplicitSignalClassifier.classify(...)` → 合并权重、并入排除集。
- **`SonglyApp.swift:38-44`**：构造并注入 detector；`RecommendationEngine.init` 给
  `implicitDetector: ImplicitSignalDetecting = ImplicitSignalDetector()` 默认值，测试与预览不改。
- **`logDiagnostics`**（L622）新增一个 key —— 这是唯一可观测性：
  ```swift
  "implicit": ["candidates": …, "starred": …, "adopted": …, "listened": …,
               "playlist_removed": …, "degraded": …, "notes": …]
  ```
- **`FeedbackStore.Derived`** 只加机读的 `implicitRemovedIDs` / `implicitRemovedKeys`
  （由 `track.implicitRemovedAt != nil && track.verdict == nil` 得到）。
  **`FeedbackSummary` 与 `promptBlock` 一个字都不改。**

## AppConfig 新增

```swift
// MARK: - 隐式信号（回读 Apple Music 里的实际行为）
static let implicitSignalsEnabled = true          // 总开关：关掉则行为与改动前完全一致
static let readAppleMusicRatings = false          // ⚠️ 探测通过前必须 false，理由同 writeBackLovedRating
static let implicitLookbackDays = 30              // 比 dedupWindowDays(14) 长：「三周后才收藏」也是信号
static let maxImplicitLookbackRecords = 10
static let maxImplicitCandidateIDs = 75           // URL 长度 + 限流双重约束
static let ratingBatchChunkSize = 50
static let maxPlaylistDiffsPerRun = 3
static let implicitRemovalMinSurvivorRatio = 0.3  // 低于它一律判为抓取异常
static let implicitSignalTimeout: TimeInterval = 8
static let implicitArtistWeightRange = -3...3
static let treatPlaylistRemovalAsPermanent = true // diff 不可靠时改 false 降级为可放宽
```

## 测试

新文件 `SonglyTests/ImplicitSignalTests.swift`（Swift Testing，命名即规格，照 `FeedbackTests.swift` 风格）：

**分类（纯，无网络）** —— `explicitVerdictDropsCandidate`（污染防护）、`ownLibraryWriteIsNotAdoption`、
`preexistingLibraryDateIsNotAdoption`、`adoptionRequiresDateAfterFirstRecommendation`、
`listenedRequiresPlayAfterRecommendation`、`oneSongCountsOnce`（★+入库+听过 = +1 不是 +3）、
`dislikeIsArtistOnlyNeverExclusion`、`implicitContributionClampedBeforeMerge`。

**歌单 diff 安全闸门（纯）** —— `partialFetchMarksNothing`（`hasNextBatch == true`）、
`allSongsMissingMarksNothing`（存活率 0 → 零删除 + note）、`strictSubsetIsAttributedExactly`、
`matchesByNormalizedKeyAcrossIdDomains`（条目 id 是资料库 id，仍能匹配上）、`emptyPlaylistMarksNothing`。

**prompt 块** —— `emptyRendersNothing`（无信号时逐字节等于今天）、`renderingIsOrderIndependent`、
`removalLineCarriesTheHardRule`、`systemPrefixContainsNoImplicitText`（守住第 3 阶段的决定）。

**`FeedbackStore` 隐式排除（@MainActor）** —— `implicitRemovalEntersDerivedButNotSummary`、
`explicitVerdictWinsOverImplicitRemoval`、`markImplicitRemovedIsIdempotent`、
**`implicitRemovalSurvivesEveryRelaxationRung`**（把既有那条测试对隐式来源再跑一遍 —— 这条必须有）。

**降级** —— `detectorFailureYieldsEmptyAndRunContinues`（stub 返回 `.empty`，管线仍产出可发布歌单）。

## 验证

1. `xcodebuild -project Songly.xcodeproj -scheme Songly -destination 'platform=iOS Simulator,name=iPhone 17' build`
2. `xcodebuild … test`（新增用例 + `FeedbackTests` 全绿，尤其字节稳定性那几条）
3. **真机**（用户自己跑，不由 AI 启动模拟器）：
   - 设置页 DEBUG 区点「探测：读回评分」→ 用**一首标过 ⭐ 的**和**一首没标过的**各跑一次。
     这是决定阶段 1 主信号能否启用的唯一依据。
   - 点「探测：歌单条目」→ 看 `entry.title | entry.artistName | entry.id` 与本地 `TrackInfo`
     并排的输出，据此判断匹配率够不够 90%。
4. 探测通过后打开 `readAppleMusicRatings`，生成一次推荐，从 DEBUG `logDiagnostics` 看
   `implicit` 那段：`starred/adopted/listened/playlist_removed` 计数是否与实际行为对得上。
   对不上就调整归因规则 —— 这一步的判据是用户自己认不认。

## 风险（按严重度）

1. **`GET /v1/me/ratings/*` 可能根本不通**（写入探测当年就卡在这里）。若 403/404，★ 不可用，
   功能退化为 入库 + 播放 + 歌单 diff。缓解：默认关闭、纯增量。
2. **`Playlist.Entry.id` 的 ID 域**。按 `TrackKey` 比对是正解，但它依赖 Apple 返回的
   `title`/`artistName` 文本能归一化成与我们持久化时相同的 key。匹配率 < 90% 就整个关掉歌单 diff。
3. **`playlist.with([.entries])` 对资料库歌单未在运行时验证过**。类型上成立。失败则退回
   `MusicDataRequest` 打 `/v1/me/library/playlists/{id}?include=tracks`（`putRating` 已有先例）。
4. **分页 / 部分抓取 → 误判大面积删除**。四道闸门挡着，`implicitRemovalMinSurvivorRatio = 0.3`
   是承重的那道，启用前要用真实数据校一下这个值。
5. **评分无时间戳**（残余误差，方向无害，见阶段 1）。
6. **后台预算**：8 秒与 Step 3 并发，净增最坏约 5 秒；检测器必须在分片间响应
   `Task.isCancelled`，否则 `expirationHandler → engine.cancel()`（`BackgroundTaskService:64-66`）
   不能及时返回。

---

# 第 2 项：艺人重复（单份 + 跨天）

> 状态：**已实施（2026-10-01）**，但 `AlbumTrackPicker` 联动**刻意未做**（理由见下）。
> 用户原话：「歌单里经常出现同一个歌手两首歌的情况，概率蛮大的」
> 「昨天听了这个歌手的歌，今天还有，明天还有，重复的概率也比较大」。
>
> **实施记录**：三档闸门落地为 `AppConfig.artistBlockedWithinDays = 3` /
> `artistCooldownDays = 14`，由 `PlaylistComposer.Input.artistCap(for:allowingRecent:)`
> 计算、在 `runPass` 里预计算成 `artistCaps`，分别在**开池段**（判 0 首，归因
> `.recentArtist`）与 **`takeNext`**（判 1 / 2 首，归因 `.artistCapped`）执行。
> 新增放宽档 `Relaxation.recentArtistOverlap`，排在 `everything` **之前**。
> prompt 侧新增「近 3 天出现过的艺人」区块（`firstUserMessage` 的 `blockedArtists`）。
> 新增 9 条单测（`ComposerTests` 的「跨天艺人闸门」suite + `PromptTests` 两条），
> 真机全部通过。
>
> **两处顺带修正**：
> 1. `recentArtistCounts` 的注释自称是「每天都是同几个艺人的**真正解药**」——
>    **那句话是错的**，它只是层内排序，`takeNext` 会把整条队列走完。已改成明确指出
>    真正的闸门在哪，免得下一个人又信它。
> 2. `Engine.artistsAtCap` 原先用全局 `maxTracksPerArtist` 判定「这位艺人用满了没」。
>    上限分档后这会把「只用满 1 首额度」的艺人漏报，于是模型继续往那个方向提 seed。
>    已改为按同一份 `composerInput` 计算。
>
> **归因顺序是刻意选的**：新闸门排在 `already_recommended` / `recently_played` /
> `in_library` **之后**。那三个是既有指标，它们的计数要能与历史数据（算法版本 3 及之前）
> 横向对比；新闸门挤到前面会把归因抢走，让版本对比失真 —— 这正是第 5 项刚落地的
> 版本可比性在起作用。有一条单测钉住它（`userRemovedOutranksRecentArtist`）。
>
> **基线数据（2026-10-01，闸门上线之前的那一版）** —— 由第 5 项刚做完的导出功能
> 实测得到，这是闸门上线后要对比的「before」：
>
> | 指标 | 值 |
> |---|---|
> | 新歌单 25 首里的艺人数 | 23 |
> | **近 3 天内出现过的艺人** | **7 位（占 30%）**，其中 3 位是**前一天**刚推过 |
> | 单份歌单里出现 2 首的艺人 | 2 位 |
> | `rejection_reasons` | `artist_capped` 8 · `duplicate_key` 3 · `quota_full` 4 |
> | `rounds` / `stop_reason` | 1 / `targetReached` |
> | `seeds_requested` → `resolved` | 27 → 26（resolve_rate 0.96）|
> | `candidates_total` | 40 |
>
> 用户的原话「昨天听了这个歌手的歌，今天还有，明天还有」在数据上是 **30%**。
>
> **实测结果（2026-10-01 13:15，v4 构建）—— 闸门有效，且没牺牲歌单完整性：**
>
> | | 闸门前（v3） | 闸门后（v4） |
> |---|---|---|
> | 近 3 天内出现过的艺人 | **7 位 / 23（30%）** | **0 位** |
> | 4–14 天内出现过的艺人 | — | 11 位，**全部 ≤1 首**（合规）|
> | 单份里出现 2 首的艺人 | 2 位 | 1 位（14 天以上没出现过，按设计允许）|
> | 歌单完整度 | 25 首 | **25 首** |
> | `rejection_reasons` | `artist_capped` 8 | **`recent_artist` 21** · `artist_capped` 2 |
> | `rounds` / `stop_reason` / `resolve_rate` | 1 / targetReached / 0.96 | 1 / targetReached / **1.0** |
> | `failures` | `catalog_miss` 1 | **无** |
>
> `recent_artist` 打出 21 次说明闸门在真干活；而 `final` 仍是 25、`resolve_rate` 还升到
> 1.0 —— **多样性不是靠变短换来的**，这是这个改动唯一需要证明的事。
>
> ⚠️ **踩过的坑**：闸门改完忘了把 `AppConfig.pipelineVersion` 从 3 加到 4，
> 于是真机上出现过一条「版本号是 3、但跑的其实是闸门前后不一致的代码」的记录。
> 已经改成 4，并把闸门的两档阈值加进了 `diagnosticsJSON` 的 `config` 快照
> —— 只靠版本号说不清「这一版用的是 3 天还是 5 天」。
> **先改版本号，再改算法。**

## 根因（已定位，非猜测）

两个独立机制在犯同一个错：

1. **单份内**：v3 刻意让模型**优先用专辑形式提 seed**（`PromptBuilderV3` 硬规则第 5 条
   「不确定歌名时请填 `album`」），而 `AlbumTrackPicker` 从该专辑取**最多 `maxTracksPerAlbum = 2` 首**。
   专辑 ≈ 艺人，所以**这套设计本身在批量制造「同一歌手两首」**。
   → 只调 `maxTracksPerArtist` 没用，必须同时动 `maxTracksPerAlbum`。
2. **跨天**：`recentArtistCounts(windowDays: 7)` 喂给 `PlaylistComposer.Input.recentArtistCounts`，
   只进 `orderingKey` 的第 4 位。代码注释自己写明：「⚠️ 这**只是层内排序**，挡不住任何东西：
   `takeNext` 会把整条队列走完」。所以它现在是**软劝阻**，不是闸门。

## 已定决策

**三档上限**（用户选了「近期出现过的降为 1 首」+「3 天内不再出现」，合起来正是三档）：

| 该艺人上次出现于 | 本次上限 |
|---|---|
| 0–3 天内 | **0 首**（硬门槛） |
| 4–14 天内 | **1 首** |
| 从未 / 15 天以上 | **2 首**（保住专辑深挖） |

窗口取 14 天，与 `dedupWindowDays = 14` 对齐，两个窗口一套口径。

## 实现要点

- 需要一个**新的放宽档**：艺人闸门必须能被放宽，否则池子荒时会直接跌破
  `publishableTrackCount = 15` 判定失败、**当天不出歌单**。现有 `Relaxation.ladder` 只有
  library / recentlyPlayed / alreadyRecommended 三档，要加 `allowRecentArtist`，
  且只在结果低于 `minAcceptableTrackCount` 时启用（与既有阶梯同构）。
- 闸门位置：`PlaylistComposer` 的 S3/S4 候选过滤段（与 `userRemoved` 同一层，
  但**可放宽**，这是它与 `removedSongIDs` 的本质区别）。
- prompt 侧：把「近 N 天已出现过的艺人」渲染进 `firstUserMessage`，让模型别浪费 seed
  在会被闸门挡掉的艺人上 ~~数据现成 —— `recentArtistCounts` 已经在算~~
  **（修正：数据并不现成。）** `recentArtistCounts` 记的是**次数**，而三档规则需要的是
  **「最近一次是几天前」**——次数区分不了「3 天前 1 次」和「6 天前 1 次」，而这两档
  一个禁、一个限 1 首。所以新增了 `ArtistRecencySignals`（key → 最近日期 + 展示名）
  与 `Engine.fetchArtistRecency()`。顺带一个好处：它另存了**未经小写化**的艺人名，
  直接喂 prompt 不会出现 `taylor swift` 这种写法。
- ~~`AlbumTrackPicker` 的 `maxTracksPerAlbum` 跟随艺人档位联动~~ **刻意未做。**
  原计划说「必须同时动 `maxTracksPerAlbum`」，那是针对**旧方案**（全局压到 1 首）的论证。
  三档方案下，未近期出现过的艺人本来就允许 2 首，`maxTracksPerAlbum = 2` 与它一致。
  联动只会省下一点浪费（被 composer 以 `.artistCapped` 拒掉的候选），**不改变输出**，
  却要把 `CatalogResolver` 耦合到闸门规则上。收益不值这个耦合。

---

# 第 3 项：旧歌单堆积

> 状态：**已决定不做（2026-10-01）—— 保持手动删除。**
>
> 曾经按「保留最近 N 份、其余自动删」实现过一版（见提交 `fd88473`），
> 后来**整段撤掉**了：用户确认手动删可以接受，而那段代码永远不会有打开的那一天。
>
> **为什么不做**：MusicKit 的 Swift API **根本没有删除能力** —— `MusicLibrary`
> 的全部成员只有 `add` / `add(to:)` / `createPlaylist` / `edit`（逐行核对过
> iOS 27 SDK 的 `.swiftinterface`）。只能手写 REST 打
> `DELETE /v1/me/library/playlists/{id}`，而那个端点被开发者社区长期反馈返回 **403**。
> 为什么 Apple 关掉它，没人知道 —— 能确定的是它**不是**「只能删自己建的」那条规则，
> 因为那份歌单就是我们建的。
>
> **撤掉的是**：`AppConfig.autoDeleteOldPlaylists` / `keepRecentPlaylists`、
> `MusicLibraryServicing.deletePlaylist`、引擎的 `pruneOldPlaylists()` 与它的调用点、
> 以及引擎多出来的那个 `libraryService` 依赖。
> 一个默认关闭、且已被决定不再启用的开关，留在代码里就是死代码，还会给
> `MusicLibraryServicing` 加一条所有未来测试替身都得实现的协议要求。
>
> **保留的是设置页那个「探测：删除歌单」按钮**（DEBUG-only，十几行，零风险）。
> 它是唯一能回答「Apple 后来放开了没有」的东西 —— 而且**这个项目自己就是反例**：
> 社区同样说「playlist editing 仅限于 API 创建的列表」，而 `createPlaylist` 明明是通的。
> 那批 403 报告大多来自 2018–2024 年，旧结论不一定还成立。
>
> **如果哪天探测回来说通了**，退路有两条，但都要重做隐式信号的歌单 diff：
> ① 每天覆写同一份歌单；② 固定 7 份轮换（周一到周日）。两者都让「他昨天删了哪首」
> 失去比对对象。

## 已查证的事实

- **MusicKit Swift 没有删除 API**。`MusicLibrary` 的全部成员只有
  `add` / `add(to:)` / `createPlaylist` / `edit`（`arm64e-apple-ios.swiftinterface:404-430`）。
- REST 有 `DELETE /v1/me/library/playlists/{id}`，但开发者社区长期反馈 **403**
  —— 与 PUT 同属「文档写了、实际不放行」。**但这不能直接下结论**：本项目的
  `createPlaylist` 是通的，旧结论不一定还成立。
- **不要 API 的退路**：复用同一份歌单，每天用 `MusicLibrary.shared.edit(_:items:)` 覆写。
  但 `specs/recommendation-optimization-plan.md:30-43` 已记录过「edit 换曲目这条路径
  不可靠，批量建单必须用 `createPlaylist(...items:)` 一次性建」—— 复用它有已知风险。

## 计划

1. 把 DELETE 加进阶段 0 的真机探测批次（与评分读取、歌单条目同一次跑完）。
2. 探测通过 → 自动清理，**保留最近 7 份**（约一周；用户每天 1–2 份）。
   判定用 `RecommendationRecord.date` 排序，只删我们自己建的（有 `playlistID` 的记录）。
3. 探测不通过 → 退回「复用同一份歌单」或「不处理」，并在设置页**明确告知**为什么
   （不留一个假装在工作、实际一直 403 的功能 —— 与 `writeBackLovedRating` 同一原则）。

## 与第 1 项的交叉影响（已核对，无冲突）

第 1 项要靠 `Playlist.entries` 回读「他在歌单里删了哪些歌」，比对对象是当初建的那份歌单。
**「保留最近 7 份」保住了比对对象** —— 只要 `maxPlaylistDiffsPerRun`（第 1 项定为 3）≤ 7 就安全。

但要注意**两个窗口不同源、长度不同**，别混为一谈：

| 信号 | 回看窗口 | 受什么限制 |
|---|---|---|
| ★收藏 / 入库 / 播放 | 30 天 | 本地记录 |
| 歌单被改 | 实际上只有约 3–7 天 | **被「保留 7 份」限住** |

超过 7 天的记录，其歌单已被清理 → `MusicLibraryRequest<Playlist>` 查回空 → 记 `playlist_missing`
并跳过。第 1 项里「查不到歌单 = 什么都不标」那条规则正好兜住这种情况，无需额外处理。

---

# 第 4 项：设置页重构

> 状态：**已实施（2026-10-01）**。用户原话三条：①「AI 眼中的你」篇幅过大，建议缩小 +
> 折叠；② 当前配置项是右上角触发的浮动弹框，是否有更优组织方式；③ 设置项前置，
> 「AI 眼中的你」作为可选查看内容。
>
> **实施记录**：sheet → push（`HomeView` 两处入口都改成 `NavigationLink`，
> 删掉 `HomeViewModel.showSettings`）；`SettingsView` 去掉自带的 `NavigationStack`、
> `@Environment(\.dismiss)`、右上角「关闭」按钮、`presentationDetents`；
> 「AI 眼中的你」改 `DisclosureGroup`（默认收起，收起态 = 核心风格前三项 +
> 听腻了 N 个方向 + 更新于）；权限行改 `LabeledContent`。
>
> **⚠️ 这是一次「先改一半」的中间态，值得记一笔。** 提交前它曾经是坏的：设置页已经改成
> push 进入，但页内那个自带的 `NavigationStack` 还在 —— 会渲染出**两层导航栏**。
> 半途提交会把一个肉眼可见的坏状态写进历史，所以是等它收尾之后才一起提交的。
>
> **未验证**：折叠态在真机上的实际观感（收起时占几行、摘要会不会太长）。
> 这部分只能真机看一眼，构建通过说明不了。

## 用户给的原则

> 「你应该遵循一个原则：功能决定样式。首先这块它到底有什么功能？没有功能就不要。
> 第二，它应该符合人们操作以及苹果的设计风格。」

## 功能审计（逐项过，这是本次重构的依据）

| 区块 | 实际功能 | 判断 |
|---|---|---|
| DeepSeek API Key | **真功能**。唯一必需配置，不填整个 App 跑不起来（引擎第 1 轮抛 `apiKeyNotConfigured`） | 保留，第一 |
| 「AI 眼中的你」 | **零功能**。8 个字段全是只读展示，没有任何可操作项 | 见下 |
| 我的反馈 | **真功能**。可撤销单曲判定，撤销后回灌推荐 | 保留 |
| 权限 · Apple Music | ⚠️ **冗余**。未授权时首页 `DeniedView` 已经拦住，并提供**同一个**跳转（都是 `UIApplication.openSettingsURLString`） | 保留（用户决定，见下） |
| 权限 · 通知 | **真功能**。**全 App 唯一**能看到通知开关的地方 —— 权限只在首启授权流程里请求一次（`HomeViewModel.swift:174`），用户拒绝后没有别的补救入口 | 保留 |
| 关于 · 版本 | 纯展示，但报 bug 时要用，1 行成本 | 保留 |
| 调试（DEBUG） | 开发工具 | 保留 |

两个关键发现：

1. **「AI 眼中的你」是全页唯一的「零功能」区块，却占了最大篇幅。** 问题不是「太大」，是
   **没有归宿** —— 它是*内容*，被塞进了一个放*配置*的容器里，只能靠篇幅撑着。
   补充事实：全 App **只有这一处**展示画像（`SettingsView.swift:284` 是 `TasteProfileStore`
   唯一的读取点）。
2. **Apple Music 权限行确实冗余**（与 `DeniedView` 的跳转完全相同）。

第二半条原则（符合人的操作 + 苹果风格）指向同一处：**苹果自己的设置页是纯操作列表**，
不放内容展示。

### 最终裁决

用户在两处保留了现状，审计结论按「保留」执行，但**降级为最弱的形式**：

- **「AI 眼中的你」留在设置页、折叠、挪到最后。**
- **权限两行都留**（形状对称，符合苹果常见的权限列表形式；接受那一行轻微冗余）。

## 现状（已核对，不是猜测）

- `HomeView.swift:41-53`：右上角齿轮 → `vm.showSettings = true` → `SettingsView()` 以
  **sheet** 打开，`.presentationDetents([.medium, .large])`（`SettingsView.swift:78`）→ **默认半屏**。
- `SettingsView.swift:54-91`：自带一个 `NavigationStack`（sheet 不在呈现者的导航栈里，
  没有它既没标题也没关闭按钮）；section 顺序
  `apiKey → taste → feedback → permission → about (+DEBUG)`。
- `SonglyApp.swift:149`：全 App **唯一**一个 `NavigationStack`，包着 HomeView。
- `vm.showSettings` 只有 3 处引用：`HomeViewModel.swift:38` 声明、`HomeView.swift:44`（齿轮）、
  `HomeView.swift:86`（`APIKeySetupCard` 的「去设置」）。

## 根因

「遮挡下方内容」**不是模块太大的问题**，是两件事叠加：半屏 detent + 一个能占满整屏的 section。
而且设置页里**没有任何需要「保存 / 取消」语义的流程**（Key 即时保存、开关即时生效）——
「模态浮层」这个形态在这里本来就没有存在理由：模态是用来打断当前任务、逼你完成一件事的。

顺带纠正一点：第 ③ 条其实**已经做了一半**。API Key 已经在最前面，代码注释还专门写了理由
（「其余五个 section 都是信息展示，只有它是可操作的」）。真正要做的是**把「AI 眼中的你」挪到
后面并折叠**，而不是「把设置项前置」。

## 已定决策

1. **改为 push 进页**，去掉 sheet。回到底部 Tab 已被明确否决 —— `HomeView.swift:7-8` 的注释
   写明理由：「两个常驻页签对『一件事』的 App 是多余的」。
2. **「AI 眼中的你」折叠**，收起态 = **一行摘要 + 关键项**：核心风格前三项 +「听腻了 N 个方向」
   +「更新于 X」。
3. **最终 section 顺序**（可操作 → 状态 → 内容，与审计结论一致）：

   ```
   1. DeepSeek        ← 唯一的必需配置
   2. 我的反馈         ← 入口
   3. 权限            ← Apple Music + 通知（两行）
   4. AI 眼中的你      ← DisclosureGroup，默认收起，一行摘要
   5. 关于            ← 版本，1 行
   6. 调试            ← #if DEBUG
   ```
   （「AI 眼中的你」按要求挪到「底部」。`关于` 仍是最后一段 —— 它是 1 行元信息，
   苹果惯例就在末尾，不跟「折叠的内容块」争位置。）

## 实现要点

- `HomeView.swift:41-53`：齿轮按钮换成 `NavigationLink { SettingsView() }`；删掉 `.sheet`
  与 `vm.showSettings`。
- `APIKeySetupCard`（`HomeView.swift:178`）：`onConfigure` 闭包换成内嵌 `NavigationLink`，
  保持现有 `.buttonStyle(.plain)` + 自定义 label 的写法。
  ⚠️ 若 toolbar 里的 `NavigationLink` 表现异常，退路是 `.navigationDestination(for:)` +
  一个 `@State` 路由值。
- `SettingsView.swift`：**删掉它自己的 `NavigationStack`**（`:55`，push 后会嵌套）、
  `@Environment(\.dismiss)`、右上角「关闭」按钮、`.presentationDetents` /
  `.presentationDragIndicator`（`:78-79`）。
- `HomeViewModel.swift:38`：`showSettings` 整个删掉（删完就没有引用了）。
- `tasteSection` 改用 `DisclosureGroup` —— `List` 内原生，且展开态**默认不持久**，
  每次进来都是收起的，正是要的效果。收起态 label 做成一行摘要；展开态复用现有的
  `chipRow` / `infoRow`，不改渲染逻辑。
- `#if DEBUG` 的 `probeSheet` 仍然保留 sheet 形态（探测报告本来就适合模态）。注意
  `SettingsView.swift:80-90` 那条注释记录的坑：**它必须与 `#if DEBUG` 同步，否则 Release
  构建编译不过**（只跑 Debug 完全看不到）。改结构时保持。

## 苹果风格的落点（第二条原则的具体执行）

- 权限行现在是手写的 `HStack { icon; Text; Spacer; Text/Button }`（`SettingsView.swift:379-396`）。
  换成 **`LabeledContent`** —— `aboutSection`（`:402`）已经在用它，「状态右对齐」是系统标准形态，
  视觉上也与版本行统一。
- 破坏性操作保持 `confirmationDialog`（清除 Key，`SettingsView.swift:170-174`）。✅ 已符合
- 移除右上角「关闭」按钮与 `@Environment(\.dismiss)`：push 后系统自带返回，多一个关闭按钮
  反而是 sheet 时代的残留。
- `section` 的 header / footer 只承担解释，不承载内容。✅ 已是现有风格，保持。
- `DisclosureGroup` 是 `List` 内的原生展开容器，不自己造轮子。

## 验证

- **Debug 与 Release 双配置**都要构建 —— Release 那条是历史上踩过的坑。
- 真机：右上角齿轮 → push 出设置 → 返回；未配 Key 时首页卡片的「去设置」也能 push 到同一页；
  「AI 眼中的你」默认收起、点开展开；「我的反馈」→ 继续 push 子页 → 逐级返回。

---

# 第 5 项：让数据支撑迭代

> 状态：**已实施（2026-10-01）**，5.6 顺带清理未做（低优先，且删 `@Model` 属性要走迁移）。
> 用户提问：「现在存的数据是不是能支撑我们以后的迭代？」并说明前提
> ——「以后每个版本要不断迭代算法，迭代会越来越好」。这不是抱怨，是**可行性审计**。
>
> **实施记录**：5.1～5.5 全部落地。Debug 与 Release 双配置构建通过，测试目标编译通过。
> 实际改动比计划多出一处**必要的前置修复**：要让「失败留痕」不污染既有行为，必须先给
> `loadRecentRecords` / `fetchRecentRecords` / `countTodayRecommendations` 三个查询补上
> `status == "completed"` 过滤 —— 它们原本都没有，也就是说 `pending` 记录**本来就在**
> 污染去重窗口与「最近」列表（进程若在「落库」与「建歌单」之间被杀，那条记录永远收不了尾）。
> 这一处顺带把既有隐患一并修掉了。
>
> **测试首次真正执行**：本机只装了 iOS 26.5 的模拟器 runtime，而 App 的部署目标是 27.0，
> 所以模拟器跑不了测试。2026-10-01 接上真机（iPhone 17 / iOS 27.0）后改在真机上跑，
> `SonglyTests` **145 个断言全部通过**。`CLAUDE.md` 里那条
> `-destination 'platform=iOS Simulator,name=iPhone 17'` 的构建命令已过时；
> 模拟器构建可用 `-sdk iphonesimulator -destination 'generic/platform=iOS Simulator'`，
> 测试用 `-destination 'id=<真机 UDID>'`。
>
> ⚠️ **首次运行时发现并修复了一个既有测试 bug**（不是本次改动引入）：`FeedbackTests`
> 里写的是 `artistWeights = ["Z": 5]`，而 composer 查表用的 key 经 `primaryArtistKey`
> **小写化**为 `"z"` —— 查表永远 miss，那条断言从写下那天起就不可能成立。
> 之所以无人发现，正是因为测试长期没有执行过。修法是改用 `primaryArtistKey(...)`
> 构造 key（而不是写字面量），避免再次漂移。
>
> ✅ **顺带修好了一个既有的工具链问题：`xcodebuild test` 现在能通过了。**
> 此前它恒以 65 退出（运行器崩在 Apple 的 Swift Testing ↔ XCTest 互操作桥
> `Runner._applyScopingTraits`），**测试根本没法当 CI 门禁**。根因与修法见文末
> 「未决 / 已解决」。修完整套 **160 条全绿、exit 0**，其中包含 6 条此前
> 从未真正执行过的用例。

## 结论

**不够。** 缺的不是数据量，是三个结构性缺口 —— 其中最致命的一个会直接让「迭代越来越好」
这个前提落空。

## 现状（逐字段核对过）

| 位置 | 内容 |
|---|---|
| `RecommendationRecord`（每次运行一行） | `date` / `createdAt` / `source` / `quickPickStyle` / `strategy` / `scene` / `tracksJSON` / `songCount` / `playlistName·ID·URL` / `status` / `rating` / `removedCount` |
| `TrackInfo`（每首歌） | `id` / `name` / `artist` / `artworkURL` / `tier` / `url` / `verdict` |
| `UserPreferences`（单例） | `lastSyncDate` / `totalRecommendations` / `favoriteGenres` |
| UserDefaults | `TasteProfile` —— **只有最新一版**，每次刷新覆盖 |
| Keychain | API Key |

顺手发现的死重：**`UserPreferences` 四个字段里三个没在起作用** —— `favoriteGenres` 与
`totalRecommendations` 只有声明和 init 赋值、**零读取**；`lastSyncDate` 有写有读，但它服务的
「增量过滤」本身是个 no-op（`MusicKitService.swift:69-91` 的 `since:` 被 `FIXME` 挂起）。
这张表实际什么都没存。

## 缺口 1：没有版本标识（最致命）

`RecommendationRecord` 里**没有任何字段**说明「这份歌单是哪一版算法产的」。
`strategy` 存的是 `RecommendationStrategy.styleExploration.rawValue` —— 那是**策略**，不是版本。

后果：算法一改，新旧数据混在同一张表里**无法区分批次**，「v4 是否比 v3 好」在数据上不可回答。
**每迭代一次，此前积累的数据就贬值一次。** 这是「迭代会越来越好」这个前提的直接威胁 ——
没有它，迭代是盲的。

## 缺口 2：只留了输出，输入侧全丢

每次运行读过、算过、然后扔掉：图书馆那 200 首（只留匹配上的 25）、当时的画像全文、
30 首最近播放 + 20 首高频播放、**候选池与逐条拒绝原因**、**LLM 的 seeds 与解析失败原因**、
token 用量、缓存命中率。

而这些**恰好都在 `logDiagnostics` 里**（`RecommendationEngine.swift:622-685`）—— 字段设计得很好
（连 `cache_hit_rate`、`resolve_rate`、`raw_seed_input` 都有），但它 `#if DEBUG` + `print`，
**只进控制台、不落盘**。生成那一瞬间之后就没有了。

## 缺口 3：反馈无时间戳，数据出不了设备

`verdict` / `rating` 都没有 `updatedAt`，先后只能靠「哪份记录更新」推断
（`FeedbackStore.swift:120` 的注释写了这条规则）。→ 做不了「推荐后第几天才收藏」这类分析，
而第 1 项（隐式反馈）要的正是这类信号。另外**全 App 没有任何导出路径**，唯一出口是 DEBUG 日志。

---

## 已定方案

用户选择：**版本标识 + 运行指标落盘**，并**加导出入口**。

### 5.1 版本字段（加在 `RecommendationRecord` 上）

```swift
var pipelineVersion: Int = 0      // AppConfig.pipelineVersion，改算法手工 +1
var promptVersion: Int = 0        // 改动 PromptBuilderV3 的结构就 +1
var modelID: String? = nil        // AppConfig.deepseekModel —— 模型会变
var diagnosticsJSON: String? = nil
```

全部是 `var` + 默认值 → **零 SwiftData 迁移**，沿用 `scene` / `rating` 的既有模式
（`RecommendationRecord.swift:40-56` 有完整先例）。不新建表 —— 一次运行就是一行记录，
拆表只多一次 join。

`modelID` 不是凑数：`AppConfig.swift:14-17` 的注释记录了旧 `deepseek-v4-flash` 被官方退役的
先例，模型名会变，必须留痕。阈值快照（`targetTrackCount` / `maxTracksPerArtist` /
`maxTracksPerAlbum` / 各窗口天数）直接进 diagnostics payload，不单开字段。

### 5.2 运行指标落盘

把 `logDiagnostics` 拆成「构造 payload」+「输出」两步：payload 同时 ①`print`（DEBUG）
②写进 `record.diagnosticsJSON`。payload 已是稳定 JSON（`.sortedKeys`），形态现成。

⚠️ **两个必须避开的坑：**

1. **落盘绝不能留在 `#if DEBUG` 里。** 02:00 的 `BGProcessingTask` 跑的是 **Release** 构建 ——
   后台任务恰恰是主要产出路径。若落盘跟着 DEBUG 走，数据在 Release 下**永远是空的**，
   而且这个错法不会报错、只会静默产出零数据。
2. **落盘时机**：诊断在 Step 5 结束就算得出，而记录在 Step 7 才落库 → 需要把 payload
   传到 `saveRecommendation(...)`，而不是在 Step 5 就地写。

### 5.3 反馈时间戳（零迁移）

- `TrackInfo` 加 `var verdictUpdatedAt: Date? = nil`（JSON 内，零迁移）
- `RecommendationRecord` 加 `var ratedAt: Date? = nil`
- 由 `FeedbackStore.setVerdict` / `setRating` 写入（写模型的动作留在 store，不放 view）

### 5.4 导出

设置页新增一行**「导出诊断数据」**（放「我的反馈」附近）：

- 内容：所有 `RecommendationRecord`（含 tracks / tier / verdict / 版本字段）+ 运行诊断 + 反馈时间戳
- 形式：写临时文件 → 系统分享（`ShareLink`）
- 文件名带版本与日期，便于区分批次
- 文案要说明**这是往外发的动作**，数据含用户的收藏与收听

### 5.5 失败运行的留痕（已知缺口，建议一并做）

现在运行失败时**零留痕**（记录被删掉），而「为什么今天没出歌单」恰恰是最需要数据的场景。
廉价修法：复用已有的 `status` 字段加一个 `"failed"`，失败时保留记录而非删除。

⚠️ 前提是**先核对 `todayRecord` / `loadRecentRecords` 的过滤条件**，确认失败记录不会污染首页
（`PlaylistHistoryView` 已经按 `status == "completed"` 过滤，但首页的 `todayRecord` 未必）。
核对之前不要动。

### 5.6 顺带清理（低优先，可不做）

`UserPreferences` 的三个死/半死字段：`favoriteGenres` 与 `totalRecommendations` 可直接删；
`lastSyncDate` **保留** —— 第 1 项阶段 0c 会真正实现 `since:` 增量过滤，届时它才有意义。
删 `@Model` 属性要走迁移，收益只是洁癖，**若做就单独一次改动 + 真机验证**。

## 验证

- 构建 Debug **与 Release**（5.2 的坑 1 只在 Release 暴露）。
- 生成一次推荐 → 导出 → 检查 JSON 里 `pipelineVersion` / `diagnosticsJSON` 非空，
  且 `rejection_reasons` 里有真实的计数。
- **后台路径单独验**：确认 Release 构建下后台任务同样落盘（这是 5.2 坑 1 的回归测试）。
- 改一次 `AppConfig.pipelineVersion` → 新记录应带上新版本号，旧记录不变（批次可分）。

---

# 未决 / 待补充

用户表示会分多轮继续补充问题，以下是已提及但尚未决定的：

- ✅ **`xcodebuild test` 恒失败 —— 已解决（2026-10-01）**。
  首次在真机上执行测试时发现：运行器崩在 `Runner._applyScopingTraits(for:testCase:_:)`
  （Apple 的 Swift Testing ↔ XCTest 互操作桥），`xcodebuild` 因此恒以 65 退出，
  **测试根本没资格当 CI 门禁**。
  二分过程 —— 每一步都是真机实跑，**其中三个假设被自己的实验证伪**，
  记在这里是因为它们都很像是答案：
  1. ~~本次改动引入~~ → 证伪：改动前就复现。
  2. ~~并行执行的竞态~~ → 证伪：关掉 `-parallel-testing-enabled` 反而从 1 次重启变 6 次。
  3. ~~`@MainActor` 标在 `@Suite` 上~~ → 证伪：裸 `@MainActor @Test` 单独跑正常。
  4. ~~SwiftData `ModelContainer` 不能在测试进程里建~~ → 证伪：单独跑正常。
  5. ~~`FeedbackStore.derive()` 本身有问题~~ → 证伪：同样的调用换个 suite 跑正常。
  **结论**：触发条件是 `FeedbackStoreTests` **那个 struct 的具体形态** ——
  `@MainActor @Suite` + 两个 `private func` helper（其中一个是
  `throws -> (FeedbackStore, ModelContext)` 的元组返回）。没继续追到具体是哪个
  语法特征，收益不值那个时间。
  **修法**：改写成「不抽 private helper、每条用例自建 store」的形态，
  并在文件里写明**别"顺手整理"回去**。
  **结果**：整套 **160 条全绿、exit 0**。那 6 条从未执行过的用例现在真的跑起来了 ——
  它们覆盖的正是反馈派生逻辑，而这轮改动（第 5 项给 `setVerdict` 加时间戳）恰好
  碰的就是它。

- **情境判断几乎是噪音。** 用户原话：「这个场景我感觉不太清楚，不知道这场景有什么区别，
  好像区别不大」「关于场景判断工作时间，我觉得现在他对歌单的影响不是很大」。
  现状：`SceneContext.sensed()` 靠 时间 9 档 + 工作日 + 季节 推出场景，
  `SceneBrief` 再映射成 能量/速度/密度/情绪关键词，全部渲染进 `firstUserMessage` 的 `## 本次情境`。
  待定：保留 / 简化 / 强化。
- **与网易云的差距。** 用户认可「达到可用状态」，但觉得不如网易云惊艳，并自己判定这是
  迭代版本数量的问题（人家迭代了很多版，我们才两版）。**暂时不是待办项**，
  记在这里以免被当成抱怨处理。

## 实施顺序与进度

原计划的顺序是：第 5 项 → 第 1 项阶段 0 → 第 2 项 → 第 1 项 1→3 → 第 3 项 → 第 4 项。
实际按这个顺序走完了，只有一处调整：**第 1 项的探测代码先写了、但没跑**（用户要求
先写代码、暂不真机验证），所以阶段 0 从「门禁」变成了「待办」。

| 项 | 代码 | 真机验证 |
|---|---|---|
| 第 5 项 迭代数据底座 | ✅ | ✅ 导出已实测（见该节基线数据）|
| 第 2 项 跨天艺人闸门 | ✅ | ❌ 待验证（设备上还是旧构建）|
| 第 1 项 隐式反馈闭环 | ✅ | ❌ 三项探测待跑；评分读取默认关闭 |
| 第 3 项 旧歌单清理 | ➖ **已决定不做** | —（保持手动删；探测按钮保留）|
| 第 4 项 设置页重构 | ✅ | ❌ 折叠态观感待看 |

**累计**：`SonglyTests` 185 条全绿（新增 34 条），Debug / Release 双配置构建通过，
`xcodebuild test` 退出码 0（此前恒为 65，见文末）。
