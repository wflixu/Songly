//
//  AppConfig.swift
//  Songly
//
//  Global configuration constants.
//

import Foundation

enum AppConfig {
    // MARK: - DeepSeek API

    static let deepseekBaseURL = "https://api.deepseek.com/anthropic/v1/messages"
    /// 计费模型 ID。旧的 `deepseek-v4-flash` 已被官方退役（仍能路由，但那是
    /// 未文档化的兜底行为，随时可能静默失效）。
    /// ⚠️ 绝不要发 `claude-*` 模型名 —— 服务端会把 `claude-opus*` 映射到
    /// `deepseek-v4-pro` 并按 Pro 价计费。
    static let deepseekModel = "deepseek-flash"
    static let requestTimeout: TimeInterval = 60
    static let maxRetries = 3
    static let retryDelays: [TimeInterval] = [1, 2, 4]

    // MARK: - API Key 校验（设置页）

    /// 校验 Key 的单次超时。**刻意远短于 `requestTimeout`** —— 用户在设置页
    /// 点「保存」后等的是一个「行/不行」的结论，不是一次生成。让他为这个答案
    /// 盯 60 秒转圈，还不如不给这个反馈。
    static let keyProbeTimeout: TimeInterval = 10

    /// 探测请求的输出上限。只需要服务端回一个状态码，回复内容丢不丢都无所谓。
    static let keyProbeMaxTokens = 16

    /// 单次响应上限。旧值 1000 是「歌单长度不稳定」的直接原因之一 ——
    /// 它天然只够 25–40 行歌名。上限实际是 384K，非思考模式默认 8K。
    static let llmMaxOutputTokens = 8000
    /// 单轮最多接受多少条 seed（解析器按此 clamp，不依赖服务端校验）。
    static let maxSeedsPerRound = 60

    // MARK: - Prompt

    /// 歌单目标上限：超过即硬截断。
    static let targetTrackCount = 25

    // MARK: - MusicKit

    static let maxLibrarySongs = 200
    static let searchConcurrency = 5

    // MARK: - Recommendation Dedup & Signals

    /// 去重窗口（天）：窗口内 `daily` 推荐过的歌曲硬性不再推荐。
    static let dedupWindowDays = 14
    /// 最近播放取数上限。
    static let recentlyPlayedLimit = 30
    /// 高播放收藏取数上限。
    static let topPlayedLimit = 20
    /// 上下文信号（最近播放 / 高播放）单次取数超时（秒）。
    static let contextTimeout: TimeInterval = 3

    // MARK: - Recommendation v3 (PlaylistComposer)

    /// 低于此数就触发补位轮，向 25 补齐。
    static let minAcceptableTrackCount = 20
    /// 低于此数直接判定失败、不建歌单。
    static let publishableTrackCount = 15
    /// 同一艺人在一份歌单里的上限。
    /// **任何放宽 / 回填路径都不得触碰这个值。**
    static let maxTracksPerArtist = 2
    /// 单张专辑最多取几首。
    static let maxTracksPerAlbum = 2
    /// 是否拒掉明显的现场版。做成开关是因为 Live 专辑对某些流派是正常形态。
    static let rejectLiveTitles = true

    // MARK: - Recommendation v3 (补位轮)

    /// seed 的超额产出倍数。要的比目标多，才能覆盖"解析不出来"的损耗。
    static let seedOverGeneration = 1.8
    /// 补位轮上限。再多轮也不会更好，只是更慢。
    static let maxGapRounds = 3
    /// 整条管线的时间预算（秒）。超过就用手上已有的结果建歌单。
    static let pipelineDeadline: TimeInterval = 210
    /// 单轮补位最少要几条 seed（低于这个数说明缺口太小，不值得单独跑一轮）。
    static let minSeedsPerGapRound = 8
    /// 单轮补位最多要几条 seed。
    static let maxSeedsPerGapRound = 30

    // MARK: - Recommendation v3 (目录解析)

    /// 跨天艺人热度回看窗口（天）。
    static let artistRecencyWindowDays = 7
    /// 每轮最多解析多少张专辑 —— 这是把一轮控制在延迟预算内的闸门。
    static let maxAlbumResolutionsPerRound = 30
    /// quick_pick 的去重窗口（天）。比 daily 短：用户主动要的风格不该被长期阻断。
    static let dedupWindowDaysQuickPick = 7

    // MARK: - Background Task

    static let bgTaskIdentifier = "cn.wflixu.Songly.dailyRecommendation"

    // MARK: - 反馈

    /// 「超赞」是否把**喜欢评分**写回 Apple Music。
    ///
    /// 默认 **false**，因为这条路还没被证实：MusicKit 的 Swift API 完全不提供
    /// 评分读写（`rating`/`favorite`/`love` 零命中），写回只能手写 REST，而且
    /// 端点用目录 ID 还是资料库 ID 尚未在真机上探测过。
    ///
    /// 先在真机跑 `MusicLibraryService.probeRatingWrite(songID:)`，拿到结论再决定
    /// 要不要打开 —— 而不是留一个假装在工作、实际一直失败的功能。
    /// 「收藏进资料库」那一步不在此开关之下，它已经确认可用。
    static let writeBackLovedRating = false

    // MARK: - 跨天艺人闸门

    /// 艺人最近一次出现在这么多天以内（含）时，本轮**一首都不给**。
    ///
    /// 用户的原话是「昨天听了这个歌手的歌，今天还有，明天还有，重复的概率也比较大」。
    /// 在此之前跨天只做**层内排序**（`artistHeat`），而排序挡不住任何东西 ——
    /// `takeNext` 会把整条队列走完，排在后面的照样被选中。这里把它变成真正的闸门。
    ///
    /// ⚠️ **可放宽**（`Relaxation.recentArtistOverlap`）：池子荒时宁可牺牲一点多样性，
    /// 也不能让当天出不来歌单。这与 `removedSongIDs` 的「永不放宽」是两回事 ——
    /// 那条是刚性的用户意志，这条只是择优偏好。
    static let artistBlockedWithinDays = 3

    /// 上一条之外、这么多天以内（含）时，这位艺人本轮最多 1 首。
    ///
    /// 取 14 与 `dedupWindowDays` 对齐 —— 两个窗口一套口径，不引入第三个数。
    /// 更早出现 / 从未出现的艺人不受限，仍可取 `maxTracksPerArtist` 首：
    /// 那是「专辑深挖非主打」这个设计的前提，压到 1 首等于把它关掉。
    static let artistCooldownDays = 14

    // MARK: - 隐式信号（回读 Apple Music 里的实际行为）

    /// 总开关。关掉后管线一行都不跑，行为与引入它之前**逐字节一致**。
    static let implicitSignalsEnabled = true

    /// 是否回读评分（⭐ 收藏 / 不喜欢）。
    ///
    /// 默认 **false** —— 与 `writeBackLovedRating` 同一理由：MusicKit 的 Swift API
    /// 完全不提供评分读写，这条只能手写 REST，而 `GET /v1/me/ratings/*` **尚未在真机
    /// 上验证过**。先在设置页跑 `MusicLibraryService.probeRatingRead(songIDs:)`
    /// 拿到结论，再决定要不要打开 —— 而不是留一个假装在工作、实际一直失败的功能。
    ///
    /// 关掉时**其余信号照跑**（入库 / 播放 / 歌单被改），它们用的都是已验证的 MusicKit API。
    static let readAppleMusicRatings = false

    /// 回看窗口（天）。比 `dedupWindowDays`(14) 长 —— 「他三周后才收藏」也是有效信号。
    static let implicitLookbackDays = 30
    /// 单次最多回看几条记录（新的优先）。
    static let maxImplicitLookbackRecords = 10
    /// 单次最多探测多少个曲目 ID（批量评分的 URL 长度与限流双重约束）。
    static let maxImplicitCandidateIDs = 75
    /// 批量评分请求的分片大小。
    static let ratingBatchChunkSize = 50
    /// 单次最多 diff 几份歌单。每份一跳网络，3 份足够覆盖最近行为。
    static let maxPlaylistDiffsPerRun = 3
    /// 歌单 diff 的存活率下限：低于它一律判为抓取异常，**不做任何删除归因**。
    ///
    /// 这是整套隐式信号里最危险的一环：`Playlist.Entry.id` 与我们的目录 ID 不同域，
    /// 一旦比对方式或分页出错，整份歌单会被判成「全被删了」，25 首歌永久进排除集。
    /// 启用前用真实数据校一下这个值。
    static let implicitRemovalMinSurvivorRatio = 0.3
    /// 隐式回读的整体超时（秒）。长于 `contextTimeout`(3) —— 它是多次序列请求；
    /// 但仍远短于 `pipelineDeadline`(210)，且与 Step 3 并发执行。
    static let implicitSignalTimeout: TimeInterval = 8
    /// 隐式信号对艺人权重的贡献上限，合并前先夹取。
    ///
    /// 比显式的 `-5...5` 窄：显式超赞是用户在**本 App 里**对**这一次推荐**的明确表态，
    /// 隐式信号是我们从他行为里推断的副产品。3 次「好奇点开」不能压过一次慎重的超赞。
    static let implicitArtistWeightRange = -3...3
    /// 单曲的隐式正向 / 负向强度。
    static let implicitPositiveArtistWeight = 1
    static let implicitNegativeArtistWeight = -1
    /// 用户从我们建的歌单里删掉的曲目，是否进「永不放宽」的硬排除。
    ///
    /// 默认 true：那个动作的语义与 App 内的 `remove(_:)` 完全一致，代码库已经判定
    /// 后者是刚性意志。探测显示 diff 不可靠时改 false 降级为「只降权、不排除」。
    static let treatPlaylistRemovalAsPermanent = true

    // MARK: - 版本标识（数据批次的可比性）

    /// 推荐管线的版本号。**改了算法就手工 +1**，没有任何机制会自动改它。
    ///
    /// 为什么值得单开一节：在引入它之前，`RecommendationRecord` 里**没有任何字段**
    /// 能说明「这份歌单是哪一版算法产的」。于是算法一改，新旧数据混在同一张表里
    /// 无法区分批次 —— 「v4 是不是比 v3 好」这个问题在数据上就不可回答，
    /// **每迭代一次，此前积累的数据就贬值一次**。
    ///
    /// **`0` 表示「未标记」**，留给先于本机制存在的旧记录 —— 它不是一个真实版本。
    ///
    /// 变更记录（每次改算法都要在这里留一行，否则这条版本号就白加了）：
    /// - `3` —— 推荐 v3：情境 + 三层配比。
    /// - `4` —— 跨天艺人闸门（`artistBlockedWithinDays` / `artistCooldownDays`
    ///   三档上限）与 prompt 里的「近 3 天出现过的艺人」区块。
    ///
    /// ⚠️ 实测教训：4 是在第 2 项**已经上真机验证完之后**才补上的。中间有一次
    /// 真机生成的记录带着 `3`，但它跑的是**不带闸门**的代码 —— 那条记录在版本上
    /// 是错的，会让后续的跨版本统计把「闸门前后的数据」混成一批。**先改版本号，
    /// 再改算法**，不要反过来。
    static let pipelineVersion = 4

    /// prompt 结构的版本号。**改动 `PromptBuilderV3` 里任何一个块的措辞、顺序或增删
    /// 都要 +1** —— 它直接改变模型看到的东西，与算法版本是两件事，混在一起就分不清
    /// 「是算法变了还是措辞变了」。
    static let promptVersion = 3
}
