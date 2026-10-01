//
//  PromptBuilderV3.swift
//  Songly
//
//  v3 的 prompt 构造。与旧版（`PromptBuilder`）的三处关键差别：
//
//  1. **模型第一次能看到真实小时**。旧版用 `timeStyle: .none` 格式化日期，
//     模型在结构上不可能知道"现在是周三晚上 22:15"—— 这是「歌单跟场景不搭」
//     最直接的原因。
//  2. **有了一份显式的口味画像**，而不是 200 首歌的裸列表（旧版那份列表
//     连标题都没有）。
//  3. **system / user 切分为缓存优化**：大而静态的画像放在 system 最前面、
//     跨轮跨天字节不变；日期 / 情境 / 抽样只放在 user 消息里。
//
//  纯函数，可完整单测。
//

import Foundation

// MARK: - Prompt Track

/// 送进 prompt 的曲目。刻意不直接用 `Song`，这样构造逻辑可以脱离 MusicKit 单测。
struct PromptTrack: Equatable, Sendable {
    let title: String
    let artist: String
    let playCount: Int?

    var line: String { "\(title) - \(artist)" }

    init(title: String, artist: String, playCount: Int? = nil) {
        self.title = title
        self.artist = artist
        self.playCount = playCount
    }

    init(_ info: TrackInfo) {
        self.init(title: info.name, artist: info.artist)
    }
}

// MARK: - Prompt Builder V3

enum PromptBuilderV3 {

    /// 收藏抽样的行数上限。
    static let librarySampleLines = 100
    /// 每位艺人在抽样里最多出现几次 —— 不加这条，抽样会被少数几位高产艺人占满。
    static let maxLinesPerArtist = 3
    static let recentlyPlayedLines = 30
    static let topPlayedLines = 20
    static let excludedHistoryLines = 40
    /// 被跨天艺人闸门挡掉的艺人名上限。超出的部分截掉 —— 这一节是**提示**，
    /// 真正的闸门在 composer 里，不需要把整份名单念给模型听。
    static let blockedArtistNames = 30

    // MARK: - System Prefix

    /// 跨轮**且跨天**字节稳定的 system 前缀。
    ///
    /// ⚠️ 这里绝不能出现任何随时间变化的东西（时间戳、场景、日期）——
    /// DeepSeek 的前缀缓存是自动生效的，只要有一个字节漂移，整段缓存失效，
    /// 输入价差约 50 倍。
    ///
    /// 顺序也有讲究：规则放在最后，因为它是最常被改动的部分 ——
    /// 追加改动只会失效规则那几个字节，不会动到前面那份昂贵的画像。
    static func systemPrefix(
        profile: TasteProfile?,
        feedback: FeedbackSummary? = nil
    ) -> String {
        var sections: [String] = []

        sections.append("""
        你是「乐遇 Songly」的资深音乐策展人，为一位中国大陆的 Apple Music 用户选歌。
        你只通过 return_seeds 工具输出，不输出任何解释性文字。
        你推荐的是「这个人的此刻」，不是一份热门榜单。
        """)

        let profileText = profile?.profileBlock ?? "（暂无画像，请从下面的收藏抽样中自行判断这位用户是谁。）"
        sections.append("## 用户音乐画像\n" + profileText)

        sections.append("""
        ## 选曲硬性规则

        1. tier 的含义是「**我有多大概率喜欢它**」，不是「听过 / 没听过」，也不是单纯的风格距离：
           - confident（约 70%）：大概率会喜欢。可以来自他熟悉的艺人和风格，但**要挑非主打、非金曲的曲目**，而不是他已经收藏或听腻的那些。
           - fresh（约 20%）：可能喜欢，但**带一点新鲜感**。风格与画像相邻，艺人或作品他大概率没接触过。
           - bold（约 10%）：大胆探索。明显跳出舒适区（不同年代 / 语言 / 流派 / 编制），但仍要有理由相信他能接受 —— 不是随机撒网。
        2. 同一艺人在一份歌单里**最多 2 首**。
        3. 不要推荐画像里「已经听腻的方向」。
        4. 不要推荐用户已收藏的歌曲，也不要推荐他最近播放过的。
        5. **不确定歌名时请填 `album` 而不是 `title`** —— 系统会从这张专辑里挑曲目，这样反而更容易挖到非主打的好歌。
        6. 语言与年代的比例参考画像，不要机械套用固定配额。
        7. `reason` 用中文，一句话，说清「为什么是这一刻」。
        8. **艺人名与专辑名必须写字面准确的官方写法**（简体/繁体、中文名/英文名、
           有无空格都要对）。上面的收藏抽样里出现过的艺人，直接沿用那里的写法。
           写法不一致会导致曲库检索直接失败 —— 这是解析失败最常见的原因。
        """)

        // ## 用户明确反馈 —— 追加在**最后**。
        //
        // 位置是有讲究的：DeepSeek 缓存的是最长公共前缀。反馈变化时，缓存只
        // 在它这里断开，前面那份昂贵的画像和规则**仍然命中**。放到画像之前
        // 会让每次反馈变动都白烧一次全量输入。
        //
        // 它与画像同属「这位用户是谁」的耐久事实，而不是「此刻」的情境 ——
        // 所以进 system 而不是 messages[0]（后者内嵌 now 与 scene，跨天必冷）。
        if let block = feedback?.promptBlock {
            sections.append(block)
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - First User Message

    /// 第 1 轮的用户消息。**只构建一次**，后续补位轮靠追加对话完成，
    /// 这样这段内容就成了缓存前缀的一部分。
    static func firstUserMessage(
        scene: SceneContext,
        now: Date,
        librarySample: [PromptTrack],
        stats: LibraryStats?,
        recentlyPlayed: [PromptTrack],
        topPlayed: [PromptTrack],
        recentlyRecommended: [PromptTrack],
        /// 从 Apple Music 行为推断出来的弱信号。
        ///
        /// ⚠️ **刻意放在 `userMessage` 而不是 `systemPrefix`。** 语义上：`systemPrefix`
        /// 是「这位用户是谁」的耐久事实，而这是「他最近干了什么」—— 与 `## 最近在听`
        /// 同类。工程上：`systemPrefix` 一行不动，`FeedbackSummary.promptBlock` 照旧是
        /// 它最后一块，既有的字节稳定性断言全部继续成立。
        ///
        /// （单看 DeepSeek 前缀缓存，两处其实**等价** —— `userMessage` 里的 `now`
        /// 本来就每天在变，跨天缓存从那里起注定失效。决定因素是语义分层，不是缓存。）
        implicitSignals: ImplicitSignals = .empty,
        /// 近 `AppConfig.artistBlockedWithinDays` 天已经出现过的艺人。
        ///
        /// 不传也能跑（composer 那层照样挡得住），但模型会白白把 seed 浪费在
        /// 注定被拒的艺人身上 —— 45 条 seed 里浪费几条，解析率就掉几个点。
        blockedArtists: [String] = [],
        seedTargets: [DiscoveryTier: Int],
        quickPickStyle: QuickPickStyle? = nil,
        calendar: Calendar = .current
    ) -> String {
        var sections: [String] = []

        sections.append(sceneBlock(scene: scene, now: now, calendar: calendar))

        // QuickPick：用户已经点名了风格，优先于场景。
        if let style = quickPickStyle {
            sections.append(
                "## 本次风格要求（优先级高于上面的场景）\n"
                + "\(style.emoji) \(style.rawValue)：\(style.promptHint)\n"
                + "全部 seed 请标记为 confident，不要做三层分布。"
            )
        }

        if !librarySample.isEmpty {
            sections.append(
                "## 你的收藏抽样（按播放次数排序，每位艺人最多 \(maxLinesPerArtist) 首）\n"
                + numbered(librarySample)
            )
        }

        if let stats, stats.trackCount > 0 {
            sections.append("## 收藏画像统计\n" + stats.compactBlock)
        }

        if !recentlyPlayed.isEmpty {
            sections.append(
                "## 最近在听\n"
                + numbered(Array(recentlyPlayed.prefix(recentlyPlayedLines)))
                    + "\n（据此判断口味，但不要直接重复这些歌）"
            )
        }

        if !topPlayed.isEmpty {
            sections.append(
                "## 最近反复播放\n"
                + numbered(Array(topPlayed.prefix(topPlayedLines)))
            )
        }

        if let block = implicitSignals.promptBlock {
            sections.append(block)
        }

        if !blockedArtists.isEmpty {
            sections.append(
                "## 近 \(AppConfig.artistBlockedWithinDays) 天出现过的艺人（本轮不会再选，不要提）\n"
                + blockedArtists.prefix(blockedArtistNames).joined(separator: "、")
                + "\n（同一位艺人短期内连着出现会让歌单显得重复。请换别的方向。）"
            )
        }

        if !recentlyRecommended.isEmpty {
            sections.append(
                "## 近 14 天已推荐过（硬性排除，不要再提）\n"
                + Array(recentlyRecommended.prefix(excludedHistoryLines))
                    .map(\.line)
                    .joined(separator: "\n")
            )
        }

        sections.append(taskBlock(seedTargets: seedTargets, quickPickStyle: quickPickStyle))

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Scene Block

    /// 情境区块。**真实小时在这里**，而不是在 system 里。
    static func sceneBlock(scene: SceneContext, now: Date, calendar: Calendar = .current) -> String {
        let brief = scene.brief
        let weekday = scene.isWeekend ? "周末" : "工作日"

        // `dateFormat` 里的 `HH` 是这次改造的关键之一：
        // 旧版用 `timeStyle: .none`，模型看不到几点。
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd（EEEE）HH:mm"

        var lines = [
            "## 本次情境",
            "现在：\(formatter.string(from: now)) · \(scene.scene.displayName) · \(weekday) · \(scene.season)",
            "场景要点：\(brief.rationale)",
            "建议能量：\(brief.energy) · 建议速度：\(brief.tempo) · 编曲密度：\(brief.density)",
            "情绪关键词：\(brief.moodKeywords.joined(separator: "、"))",
            "本场景建议避开：\(brief.avoid.joined(separator: "、"))",
        ]

        if scene.isOverridden {
            lines.append("（用户手动指定了场景，请以此为准，不要按当前时间推测。）")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Task Block

    static func taskBlock(
        seedTargets: [DiscoveryTier: Int],
        quickPickStyle: QuickPickStyle? = nil
    ) -> String {
        let total = seedTargets.values.reduce(0, +)

        if let style = quickPickStyle {
            return """
            ## 本次任务

            请给出 \(total) 个 seed，全部围绕「\(style.rawValue)」这个方向。
            优先用专辑形式提 seed（填 `album` 而不是 `title`），以便挑到专辑里的非主打曲目。
            全部标记为 confident。
            """
        }

        let breakdown = DiscoveryTier.allCases
            .compactMap { tier -> String? in
                guard let count = seedTargets[tier], count > 0 else { return nil }
                return "\(tier.displayName)（\(tier.rawValue)）\(count) 个"
            }
            .joined(separator: "、")

        return """
        ## 本次任务

        请给出 \(total) 个 seed。分布：\(breakdown)。

        confident 那部分请**优先用专辑形式**提 seed（填 `album` 而不是 `title`），
        这样才能挑到专辑里的非主打曲目，而不是又一轮金曲大杂烩。
        """
    }

    // MARK: - Sampling

    /// 收藏抽样：每位艺人最多 `limit` 首，按播放次数降序、再按歌名升序。
    ///
    /// 旧版按输入顺序取前 N 首，于是抽样永远是"最早收藏的那些歌" ——
    /// 对判断当下口味几乎没有信息量。
    static func sampleLibrary(
        _ tracks: [PromptTrack],
        limit: Int = librarySampleLines,
        perArtist: Int = maxLinesPerArtist
    ) -> [PromptTrack] {
        var artistCounts: [String: Int] = [:]
        var result: [PromptTrack] = []

        let sorted = tracks.sorted { lhs, rhs in
            let leftPlays = lhs.playCount ?? 0
            let rightPlays = rhs.playCount ?? 0
            if leftPlays != rightPlays { return leftPlays > rightPlays }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.artist < rhs.artist
        }

        for track in sorted {
            guard result.count < limit else { break }
            let key = primaryArtistKey(track.artist)
            guard (artistCounts[key] ?? 0) < perArtist else { continue }
            artistCounts[key, default: 0] += 1
            result.append(track)
        }

        return result
    }

    // MARK: - Taste Profile

    /// 生成口味画像用的 system。频率很低（最多一周一次），不进每日路径。
    static let tasteProfileSystem = """
    你是一位资深音乐编辑，擅长从一个人的收藏与播放记录里读出他是谁。
    你只通过 return_taste_profile 工具输出，不输出任何解释性文字。
    描述要具体（「华语民谣」而不是「流行」），不要写放之四海皆准的空话。
    """

    static func tasteProfileUserMessage(
        stats: LibraryStats,
        librarySample: [PromptTrack],
        recentlyPlayed: [PromptTrack],
        topPlayed: [PromptTrack]
    ) -> String {
        var sections: [String] = []

        sections.append("## 收藏统计\n" + stats.compactBlock)

        if !librarySample.isEmpty {
            sections.append("## 收藏抽样（按播放次数排序）\n" + numbered(librarySample))
        }
        if !recentlyPlayed.isEmpty {
            sections.append(
                "## 最近在听\n" + numbered(Array(recentlyPlayed.prefix(recentlyPlayedLines)))
            )
        }
        if !topPlayed.isEmpty {
            sections.append(
                "## 反复播放\n" + numbered(Array(topPlayed.prefix(topPlayedLines)))
            )
        }

        sections.append("""
        ## 任务

        请归纳这位用户的音乐画像。

        其中 `tiredOf` 那一栏最要紧：列出他**大概率已经听腻、不要再推荐**的方向
        （比如"已经被短视频用烂的歌""他收藏里占比过高从而边际效用递减的风格"）。
        这一栏直接决定推荐能不能跳出「都是听过的老歌」。
        """)

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Seed Targets

    /// 本轮要多少 seed，按 70/20/10 分配到三层。
    ///
    /// 25 首 × 1.8 的超额 → 45 个 seed → 32 / 9 / 4。
    static func seedTargets(
        for total: Int,
        overGeneration: Double = AppConfig.seedOverGeneration
    ) -> [DiscoveryTier: Int] {
        let desired = max(1, Int((Double(total) * overGeneration).rounded()))
        let quota = TierQuota(total: desired)
        return Dictionary(
            uniqueKeysWithValues: DiscoveryTier.allCases.map { ($0, quota.cap(for: $0)) }
        )
    }

    // MARK: - Private

    private static func numbered(_ tracks: [PromptTrack]) -> String {
        tracks.enumerated()
            .map { "\($0.offset + 1). \($0.element.line)" }
            .joined(separator: "\n")
    }
}
