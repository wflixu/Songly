//
//  TasteProfile.swift
//  Songly
//
//  口味画像：把用户的收藏 / 播放次数 / 最近播放归纳成一份**显式的**偏好描述。
//
//  为什么需要它：改造前 prompt 给模型的只是 200 首歌的裸列表（而且那份列表
//  连标题都没有，见 `PromptBuilder.swift:44`）。模型要从一堆歌名里反推"这个人
//  是谁" —— 结果就是它退回到最安全的答案：大家都听过的热门金曲。
//
//  把画像显式写出来，模型才能从"猜这个人的口味"变成"按这份画像选歌"。
//

import Foundation

// MARK: - Library Snapshot

/// 从 `Song` 抽出来的轻量快照。
///
/// 存在的意义是让统计逻辑**脱离 MusicKit** —— 否则 `LibraryStats` 没法单测。
struct LibraryTrackSnapshot: Equatable, Sendable {
    let title: String
    let artist: String
    let genreNames: [String]
    let releaseYear: Int?
    let playCount: Int?
}

// MARK: - Library Stats

/// 本地计算的曲库统计。既喂给画像生成，也直接作为 prompt 的一个区块。
struct LibraryStats: Equatable, Sendable {
    struct Bucket: Equatable, Sendable {
        let name: String
        let count: Int
    }

    let trackCount: Int
    /// 流派分布，按数量降序，最多 12 项。
    let genres: [Bucket]
    /// 年代分布，按年代降序。
    let decades: [Bucket]
    /// 语言分布，count 是四舍五入后的百分比。
    let languageMix: [Bucket]
    /// 常听艺人（按收藏量），最多 12 项。
    let topArtists: [Bucket]

    static let maxBuckets = 12

    init(snapshot: [LibraryTrackSnapshot]) {
        trackCount = snapshot.count

        genres = Self.topBuckets(
            snapshot.flatMap(\.genreNames),
            limit: Self.maxBuckets
        )

        // 年代按时间倒序更符合直觉（2020s 在前），而不是按数量。
        decades = Self.topBuckets(
            snapshot.compactMap(\.releaseYear).map { "\($0 / 10 * 10)s" },
            limit: Self.maxBuckets
        ).sorted { $0.name > $1.name }

        topArtists = Self.topBuckets(snapshot.map(\.artist), limit: Self.maxBuckets)

        let languages = snapshot.map { Self.language(of: $0.title) }
        let total = max(languages.count, 1)
        languageMix = Self.topBuckets(languages, limit: 4).map { bucket in
            Bucket(name: bucket.name, count: Int((Double(bucket.count) / Double(total) * 100).rounded()))
        }
    }

    /// 给 prompt 用的紧凑文本块。**顺序完全确定**，同一次输入必然产出同一段文字。
    var compactBlock: String {
        var lines = ["共 \(trackCount) 首收藏"]
        if !genres.isEmpty {
            lines.append("流派：" + genres.map { "\($0.name) \($0.count)" }.joined(separator: "、"))
        }
        if !decades.isEmpty {
            lines.append("年代：" + decades.map { "\($0.name) \($0.count)" }.joined(separator: "、"))
        }
        if !languageMix.isEmpty {
            lines.append("语言：" + languageMix.map { "\($0.name) \($0.count)%" }.joined(separator: "、"))
        }
        if !topArtists.isEmpty {
            lines.append("常听艺人：" + topArtists.map { "\($0.name) \($0.count)" }.joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Private

    /// 计数 + 排序 + 截断。排序用「数量降序，名称升序」——
    /// 名称那层 tie-break 是必须的，否则同数量的桶顺序会随输入顺序漂移，
    /// 画像文本就不再字节稳定，缓存也就废了。
    private static func topBuckets(_ values: [String], limit: Int) -> [Bucket] {
        var counts: [String: Int] = [:]
        for value in values {
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .prefix(limit)
            .map { Bucket(name: $0.key, count: $0.value) }
    }

    /// 从歌名粗略判断语言。kanji 与 kana 会同时出现在日文歌名里，
    /// 所以**必须先判假名**，否则日文会被算成中文。
    static func language(of title: String) -> String {
        var hasKana = false
        var hasHangul = false
        var cjkCount = 0
        var latinCount = 0

        for scalar in title.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: hasKana = true
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hasHangul = true
            case 0x4E00...0x9FFF: cjkCount += 1
            case 0x41...0x5A, 0x61...0x7A: latinCount += 1
            default: break
            }
        }

        if hasHangul { return "韩文" }
        if hasKana { return "日文" }
        if cjkCount > 0, cjkCount >= latinCount { return "中文" }
        if latinCount > 0 { return "英文" }
        return "其他"
    }
}

// MARK: - Profile Payload

/// LLM 返回的画像内容（不含我们附加的元数据）。
struct TasteProfilePayload: Codable, Equatable, Sendable {
    /// 核心子流派。
    let coreGenres: [String]
    /// 代表艺人。
    let representativeArtists: [String]
    /// 年代偏好。
    let eraPreference: String
    /// 情绪 / 能量特征。
    let moodSignature: String
    /// 人声 vs 器乐倾向。
    let vocalPreference: String
    /// 语言分布。
    let languageDistribution: String
    /// 明确的「已经听腻的方向」—— 这是治「都是听过的老歌」最直接的一条。
    let tiredOf: [String]
    /// 一句话总览。
    let summary: String

    static let empty = TasteProfilePayload(
        coreGenres: [], representativeArtists: [],
        eraPreference: "", moodSignature: "", vocalPreference: "",
        languageDistribution: "", tiredOf: [], summary: ""
    )
}

// MARK: - Taste Profile

struct TasteProfile: Codable, Equatable, Sendable {
    /// 每次重新生成时 +1。**会进入 system 前缀**，所以它的变化会失效缓存 ——
    /// 这是有意的：画像变了，缓存本来就该失效。
    let version: Int
    let generatedAt: Date
    /// 生成时的曲库指纹，用于判断要不要重新生成。
    let libraryFingerprint: String
    let payload: TasteProfilePayload

    /// 放进 `system` 前缀的稳定文本块。
    ///
    /// **字节稳定性是硬要求**：DeepSeek 的前缀缓存是自动生效的，同一条前缀
    /// 只要有一个字节变化，整段缓存就失效，输入价差约 50 倍。
    /// 所以这里绝不能出现 `generatedAt` 之类每次都不同的东西 ——
    /// `version` 可以出现，因为它只在画像真正重算时才变。
    var profileBlock: String {
        var lines: [String] = ["（画像版本 \(version)）"]

        if !payload.coreGenres.isEmpty {
            lines.append("核心风格：" + payload.coreGenres.joined(separator: "、"))
        }
        if !payload.representativeArtists.isEmpty {
            lines.append("代表艺人：" + payload.representativeArtists.joined(separator: "、"))
        }
        if !payload.eraPreference.isEmpty {
            lines.append("年代偏好：" + payload.eraPreference)
        }
        if !payload.moodSignature.isEmpty {
            lines.append("情绪特征：" + payload.moodSignature)
        }
        if !payload.vocalPreference.isEmpty {
            lines.append("人声 / 器乐：" + payload.vocalPreference)
        }
        if !payload.languageDistribution.isEmpty {
            lines.append("语言分布：" + payload.languageDistribution)
        }
        if !payload.tiredOf.isEmpty {
            lines.append("已经听腻的方向（不要再推）：" + payload.tiredOf.joined(separator: "、"))
        }
        if !payload.summary.isEmpty {
            lines.append("一句话：" + payload.summary)
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Profile Tool Schema

/// 生成画像用的第二个强制工具调用。
enum TasteProfileToolSchema {
    static let name = "return_taste_profile"

    static let description = """
    根据用户的收藏与播放数据，归纳出一份音乐口味画像。只通过本工具输出。
    """

    static func inputSchema() -> [String: Any] {
        let properties: [String: Any] = [
            "coreGenres": [
                "type": "array",
                "items": ["type": "string"],
                "description": "核心子流派，3–6 个，尽量具体（如「华语民谣」而不是「流行」）",
            ],
            "representativeArtists": [
                "type": "array",
                "items": ["type": "string"],
                "description": "最能代表这位用户口味的艺人，5–10 个",
            ],
            "eraPreference": [
                "type": "string",
                "description": "年代偏好，一句话",
            ],
            "moodSignature": [
                "type": "string",
                "description": "情绪与能量特征，一句话（如「偏低能量、偏内省」）",
            ],
            "vocalPreference": [
                "type": "string",
                "description": "人声 vs 器乐倾向，一句话",
            ],
            "languageDistribution": [
                "type": "string",
                "description": "语言分布，一句话",
            ],
            "tiredOf": [
                "type": "array",
                "items": ["type": "string"],
                "description": "用户**大概率已经听腻、不要再推**的方向，2–5 条。这是最重要的一栏",
            ],
            "summary": [
                "type": "string",
                "description": "一句话总览这位用户是谁，不超过 40 字",
            ],
        ]

        return [
            "type": "object",
            "properties": properties,
            "required": [
                "coreGenres", "representativeArtists", "eraPreference",
                "moodSignature", "vocalPreference", "languageDistribution",
                "tiredOf", "summary",
            ],
        ]
    }
}

// MARK: - Fingerprint

/// 曲库指纹：用来判断"收藏变了没有"。
///
/// 用 `stableNoise` 而不是 `Hasher` —— Hasher 每次进程启动都重新播种，
/// 会让指纹每次都变，画像就会被无谓地反复重算。
enum LibraryFingerprint {
    static func make(from trackIDs: [String]) -> String {
        let canonical = trackIDs.sorted().joined(separator: "|")
        return String(stableNoise(canonical, seed: 0), radix: 16)
    }
}
