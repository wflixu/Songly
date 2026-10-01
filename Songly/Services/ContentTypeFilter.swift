//
//  ContentTypeFilter.swift
//  Songly
//
//  MusicKit 的 `Song` 上**没有任何内容类型标记** —— 没有 isVocal / isLive /
//  isCover / isRemix / isInstrumental，`AudioVariant` 是音质枚举而不是内容类型。
//  所以"排除伴奏、翻唱、Live、混音版"只能靠自建启发式规则。
//

import Foundation

/// 被内容类型规则拒掉的原因。
enum ContentRejection: String, Equatable, Sendable {
    case karaoke
    case instrumentalVersion
    case coverVersion
    case liveVersion
    case remixVersion
    case interlude
    case compilationTribute

    var displayName: String {
        switch self {
        case .karaoke: return "伴奏 / 卡拉OK"
        case .instrumentalVersion: return "器乐版"
        case .coverVersion: return "翻唱"
        case .liveVersion: return "现场版"
        case .remixVersion: return "混音版"
        case .interlude: return "间奏 / 过短"
        case .compilationTribute: return "合辑 / 致敬"
        }
    }
}

enum ContentTypeFilter {

    /// "本来就没有主唱"的流派。在这些流派里，器乐版和翻唱是正常形态，不该拒。
    static let instrumentalGenres: Set<String> = [
        "古典", "classical", "器乐", "instrumental", "钢琴", "piano",
        "纯音乐", "new age", "轻音乐", "爵士", "jazz", "后摇", "post-rock",
        "原声", "soundtrack", "配乐", "氛围", "ambient", "world", "世界音乐",
    ]

    /// 混音在这些流派里是正常形态。
    static let electronicGenres: Set<String> = [
        "电子", "electronic", "电音", "dance", "house", "techno", "edm", "trance",
    ]

    /// 判定一条候选曲目是否应该因为内容类型被拒。返回 `nil` 表示通过。
    ///
    /// 顺序固定，返回第一个命中的原因：
    /// `karaoke → instrumentalVersion → coverVersion → liveVersion →
    ///  remixVersion → interlude → compilationTribute`
    ///
    /// - Parameter rejectLive: 是否拒绝现场版。默认取配置值，显式传入以便测试两个分支。
    static func rejection(
        for candidate: ResolvedCandidate,
        rejectLive: Bool = AppConfig.rejectLiveTitles
    ) -> ContentRejection? {
        // 必须匹配 catalog 的**原始**标题 —— 归一化会剥掉括号，而 `(Live)`
        // 和 `(伴奏)` 恰恰就住在括号里。
        let title = candidate.rawTitle
        let album = candidate.albumTitle

        let isInstrumentalGenre = matchesGenre(candidate.genreNames, in: instrumentalGenres)
        let isElectronicGenre = matchesGenre(candidate.genreNames, in: electronicGenres)

        // 1. 伴奏 / 卡拉OK —— 任何流派下都拒。
        //    这类词不会出现在正经的器乐作品上，所以不开豁免。
        if matches(title, #"伴奏|カラオケ|karaoke|off[-\s]?vocal|无和声|無人聲|伴唱"#) {
            return .karaoke
        }

        // 2. 明确的"器乐版"标注 —— 器乐 / 古典流派里这是正常形态。
        if matches(title, #"instrumental\s*(version|ver\.?)|inst\.\s*$"#), !isInstrumentalGenre {
            return .instrumentalVersion
        }

        // 3. 翻唱版。注意这里**不**匹配 album 上的 `tribute` / `合辑` —— 那是
        //    规则 7 的职责。两条规则都写 `tribute` 会让致敬合辑被误判成翻唱。
        let coverInTitle = matches(title, #"翻唱|cover\s*version|tribute|covered\s*by|致敬"#)
        let coverInAlbum = matches(album, #"翻唱|cover\s*version|covered\s*by"#)
        if (coverInTitle || coverInAlbum), !isInstrumentalGenre, !isElectronicGenre {
            return .coverVersion
        }

        // 4. 现场版。模式刻意收紧成"括号里的 Live"或"Live at/from/in/version"，
        //    否则会把《Live and Let Die》这种正经歌名误杀。
        if rejectLive,
           matches(title, #"[（(]\s*live\b|\blive\s+(at|from|in|version|session)\b|现场版|演唱会|unplugged|live\s*版"#) {
            return .liveVersion
        }

        // 5. 混音版 —— 电子流派里是正常形态。
        if matches(title, #"remix|rmx|混音版|bootleg|重混"#), !isElectronicGenre {
            return .remixVersion
        }

        // 6. 间奏 / 过短。`duration > 0` 是必要的守卫：MusicKit 拿不到时长时
        //    会给 0，不加这个判断会把整批曲目误杀。
        if candidate.duration > 0, candidate.duration < 45 {
            return .interlude
        }

        // 7. 合辑 / 致敬专辑。
        if matches(album, #"tribute|致敬|群星|various\s*artists|合辑"#) {
            return .compilationTribute
        }

        // 注意：`Remastered` 刻意**不**作为拒绝理由 —— 国区常常只有重制版在架，
        // 拒掉它会静默删掉大量合法曲目。此行为由 `remasteredIsAccepted` 钉死。
        return nil
    }

    // MARK: - Private

    private static func matches(_ text: String?, _ pattern: String) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 流派名做子串匹配，这样 "Chinese Classical" 也能命中 "classical"，
    /// "爵士乐" 也能命中 "爵士"。
    private static func matchesGenre(_ genreNames: [String], in set: Set<String>) -> Bool {
        for name in genreNames {
            let lower = name.lowercased()
            if set.contains(where: { lower.contains($0) }) { return true }
        }
        return false
    }
}
