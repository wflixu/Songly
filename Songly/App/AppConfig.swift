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
}
