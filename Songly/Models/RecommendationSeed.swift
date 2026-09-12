//
//  RecommendationSeed.swift
//  Songly
//
//  v3 推荐管线的值类型：LLM 给出的「选曲线索」、目录解析后的真实候选、三层配额。
//

import Foundation

// MARK: - DiscoveryTier

/// 三层配额。分界线是**「我有多大概率喜欢它」**，同时叠加一点新鲜度 ——
/// 不是"听过 / 没听过"，也不是单纯的风格距离。
enum DiscoveryTier: String, Codable, CaseIterable, Sendable {
    /// 大概率喜欢。可以来自熟悉的艺人与风格，但优先挑没听过或很少听的曲目。
    case confident
    /// 可能喜欢，但带一点新鲜感。风格与口味相邻，艺人或作品大概率没接触过。
    case fresh
    /// 大胆探索。明显跳出舒适区，但仍有理由相信能接受。
    case bold

    var displayName: String {
        switch self {
        case .confident: return "大概率喜欢"
        case .fresh: return "新鲜尝试"
        case .bold: return "大胆探索"
        }
    }

    /// 曲目行徽章上的短名。`displayName` 在行内太长。
    var shortName: String {
        switch self {
        case .confident: return "喜欢"
        case .fresh: return "新鲜"
        case .bold: return "大胆"
        }
    }

    /// 是否在曲目行上打徽章。
    ///
    /// `confident` **刻意不打** —— 它占 70%，是默认值，给默认值加标记只会
    /// 让每行都多一个元素却传达不了信息。只有真正"新"的两层值得被标出来。
    var showsBadge: Bool {
        self != .confident
    }
}

// MARK: - TierQuota

/// 70 / 20 / 10 配额。`sum(caps) == total` 恒成立。
struct TierQuota: Equatable, Sendable {
    /// 各层占比。
    static let ratios: [DiscoveryTier: Double] = [
        .confident: 0.70,
        .fresh: 0.20,
        .bold: 0.10,
    ]

    /// 消耗顺序。余数也按此顺序补齐。
    static let tierOrder: [DiscoveryTier] = [.confident, .fresh, .bold]

    let total: Int
    private(set) var caps: [DiscoveryTier: Int]

    init(total: Int) {
        let safeTotal = max(0, total)
        self.total = safeTotal

        var computed: [DiscoveryTier: Int] = [:]
        var assigned = 0
        for tier in Self.tierOrder {
            let cap = Int((Double(safeTotal) * (Self.ratios[tier] ?? 0)).rounded(.down))
            computed[tier] = cap
            assigned += cap
        }

        // 向下取整会留下余数，按层序补给，保证 sum(caps) == total。
        // 25 → 17/5/2 差 1 补到 confident → 18/5/2；20 → 14/4/2 正好整除。
        var remainder = safeTotal - assigned
        for tier in Self.tierOrder where remainder > 0 {
            computed[tier, default: 0] += 1
            remainder -= 1
        }

        for tier in Self.tierOrder where computed[tier] == nil {
            computed[tier] = 0
        }
        self.caps = computed
    }

    func cap(for tier: DiscoveryTier) -> Int { caps[tier] ?? 0 }

    /// 抬高某一层的上限（缺口补位用）。总上限不变 —— 这只是把"允许超出多少"变松。
    func raised(_ tier: DiscoveryTier, by delta: Int) -> TierQuota {
        var next = self
        next.caps[tier] = cap(for: tier) + max(0, delta)
        return next
    }
}

// MARK: - SeedKind

/// LLM 给的是一个明确的曲目、一张专辑，还是一个泛泛的艺人方向。
enum SeedKind: String, Codable, CaseIterable, Sendable {
    case track
    case album
    case artist

    /// 层内排序用。专辑扩展取到的曲目排最前 —— 它最可能是"非主打 / 冷门专辑"
    /// 这类真正的深挖结果，而这正是治「都是听过的老歌」的地方。
    var sortRank: Int {
        switch self {
        case .album: return 0
        case .track: return 1
        case .artist: return 2
        }
    }
}

// MARK: - RecommendationSeed

/// LLM 输出的一条选曲线索。
///
/// 刻意做成**扁平、字段几乎全可选**的形状，而不是 `oneOf` 判别联合 —— 跨模型 /
/// 跨接口形状的鲁棒性差很多。缺失的 `kind` 由实际填了哪些字段反推。
struct RecommendationSeed: Codable, Equatable, Sendable {
    let artist: String
    let tier: DiscoveryTier
    let kind: SeedKind
    let reason: String
    let album: String?
    let title: String?
    let wants: Int?
    let language: String?
    let era: String?

    /// 归一化后的主艺人，用于歌手上限判定与跨天热度排序。
    var primaryArtist: String { primaryArtistKey(artist) }

    /// 希望从这张专辑 / 这位艺人身上取几首。
    var resolvedWants: Int {
        min(max(wants ?? 1, 1), AppConfig.maxTracksPerAlbum)
    }

    /// 由实际填写的字段反推意图。
    static func inferredKind(title: String?, album: String?) -> SeedKind {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return .track }
        if let album, !album.trimmingCharacters(in: .whitespaces).isEmpty { return .album }
        return .artist
    }

    init(
        artist: String,
        tier: DiscoveryTier,
        kind: SeedKind,
        reason: String = "",
        album: String? = nil,
        title: String? = nil,
        wants: Int? = nil,
        language: String? = nil,
        era: String? = nil
    ) {
        self.artist = artist
        self.tier = tier
        self.kind = kind
        self.reason = reason
        self.album = album
        self.title = title
        self.wants = wants
        self.language = language
        self.era = era
    }

    // MARK: Lenient decoding

    /// 宽松解码：未知的 `tier` 退到 `.confident`，缺失 / 未知的 `kind` 由字段反推，
    /// `wants` 允许是字符串。模型偶尔不守 schema，不值得为此丢整条 seed。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // artist 是唯一真正必需的字段；缺失即让上层跳过这条 seed。
        let rawArtist = try container.decode(String.self, forKey: .artist)
        artist = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)

        // `try?` 会把嵌套可选拍平（SE-0230），所以这里直接得到 `String?`。
        reason = (try? container.decode(String.self, forKey: .reason)) ?? ""
        album = try? container.decodeIfPresent(String.self, forKey: .album)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        language = try? container.decodeIfPresent(String.self, forKey: .language)
        era = try? container.decodeIfPresent(String.self, forKey: .era)

        let rawTier = try? container.decodeIfPresent(String.self, forKey: .tier)
        tier = rawTier.flatMap(DiscoveryTier.init(rawValue:)) ?? .confident

        let rawKind = try? container.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(SeedKind.init(rawValue:))
            ?? Self.inferredKind(title: title, album: album)

        if let number = try? container.decode(Int.self, forKey: .wants) {
            wants = number
        } else if let text = try? container.decode(String.self, forKey: .wants),
                  let parsed = Int(text) {
            wants = parsed
        } else {
            wants = nil
        }
    }
}

// MARK: - ResolvedCandidate

/// 已经落到真实 catalog 上的候选曲目 —— composer 的输入单元。
struct ResolvedCandidate: Equatable, Sendable {
    /// 持久化身份（catalog `MusicItemID` + 展示用歌名 / 艺人）。
    let info: TrackInfo
    let tier: DiscoveryTier
    let seedKind: SeedKind
    /// 是否为"放宽后才允许"的回填候选（曲库重叠 / 最近播放）。排序时排最后。
    let isBackfill: Bool
    /// catalog 的**原始**标题，未归一化 —— 内容类型过滤必须用它，
    /// 因为归一化恰好会剥掉 `(Live)` / `(伴奏)` 所在的括号。
    let rawTitle: String
    let albumTitle: String?
    let duration: TimeInterval
    let genreNames: [String]
    let isCompilation: Bool
    let releaseDate: Date?
    /// 专辑内的音轨号。用于「避开主打歌」的深挖偏置。
    let trackNumber: Int?
    /// 所在专辑的曲目总数。少于 6 首的专辑不套深挖偏置 —— 迷你专辑里
    /// 前三首未必是主打。
    let albumTrackCount: Int?

    /// 归一化主艺人，用于上限判定与跨天热度排序。
    var primaryArtist: String { primaryArtistKey(info.artist) }

    /// 层内排序用。回填候选永远排最后。
    var seedRank: Int { isBackfill ? 3 : seedKind.sortRank }

    init(
        info: TrackInfo,
        tier: DiscoveryTier,
        seedKind: SeedKind,
        isBackfill: Bool = false,
        rawTitle: String,
        albumTitle: String? = nil,
        duration: TimeInterval = 0,
        genreNames: [String] = [],
        isCompilation: Bool = false,
        releaseDate: Date? = nil,
        trackNumber: Int? = nil,
        albumTrackCount: Int? = nil
    ) {
        self.info = info
        self.tier = tier
        self.seedKind = seedKind
        self.isBackfill = isBackfill
        self.rawTitle = rawTitle
        self.albumTitle = albumTitle
        self.duration = duration
        self.genreNames = genreNames
        self.isCompilation = isCompilation
        self.releaseDate = releaseDate
        self.trackNumber = trackNumber
        self.albumTrackCount = albumTrackCount
    }
}

// MARK: - Artist Identity

/// 把 `A feat. B` / `A ft. B` / `A featuring B` / `A、B` 折叠成主艺人 `A`。
///
/// 刻意**不**折叠 `&`、`x`、`+`：这些可能是乐队名的组成部分
/// （Simon & Garfunkel、X Japan），错误合并会把两个不同艺人算成同一个，
/// 从而误触歌手上限 —— 那比漏合并更伤推荐质量。
func primaryArtistKey(_ value: String) -> String {
    let normalized = normalizedKey(value)
    guard !normalized.isEmpty else { return normalized }

    let markers = [" feat.", " feat ", " ft.", " ft ", " featuring ", "、", "，", ","]
    var cut = normalized.count
    for marker in markers {
        guard let range = normalized.range(of: marker) else { continue }
        cut = min(cut, normalized.distance(from: normalized.startIndex, to: range.lowerBound))
    }

    let head = String(normalized.prefix(cut)).trimmingCharacters(in: .whitespaces)
    return head.isEmpty ? normalized : head
}

// MARK: - Stable Noise

/// 稳定哈希：跨启动、跨进程结果一致。
///
/// **不能用 `Hasher`** —— Swift 的 Hasher 每次进程启动都会重新播种，
/// 同一天的推荐会在两次运行间排出不同顺序，等于把"确定性"这个卖点丢掉。
/// FNV-1a + splitmix64 收尾，纯算术、无随机种子。
func stableNoise(_ value: String, seed: UInt64) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325 &+ seed
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    hash ^= hash >> 30
    hash = hash &* 0xbf58_476d_1ce4_e5b9
    hash ^= hash >> 27
    hash = hash &* 0x94d0_49bb_1331_11eb
    hash ^= hash >> 31
    return hash
}
