//
//  PromptBuilder.swift
//  Songly
//
//  Builds optimized LLM prompts with token budget management.
//

import Foundation
import MusicKit

struct PromptBuilder {

    // MARK: - Public

    /// Build a recommendation prompt.
    /// - Parameters:
    ///   - strategy: The recommendation strategy to apply.
    ///   - songs: User's library songs (may exceed token limit).
    ///   - history: Previously recommended track names for dedup.
    ///   - quickPickStyle: Optional QuickPick style override.
    ///   - maxTokens: Token budget for the user message.
    /// - Returns: A complete prompt string ready for the LLM.
    static func build(
        strategy: RecommendationStrategy = .styleExploration,
        songs: [Song],
        history: [String],
        quickPickStyle: QuickPickStyle? = nil,
        maxTokens: Int = AppConfig.maxPromptTokens
    ) -> String {
        // Sample songs to fit within token budget
        let sampledSongs = sampleSongs(songs, maxTokens: maxTokens)
        let songList = formatSongList(sampledSongs)

        // Build exclusion list
        let exclusionSection: String
        if history.isEmpty {
            exclusionSection = ""
        } else {
            let recent = Array(history.prefix(75)) // ~25 songs × 3 recs/song
            exclusionSection = """
            不要推荐以下歌曲（近期已推荐过）：
            \(recent.joined(separator: "\n"))

            """
        }

        // Determine the strategy hint
        let hint: String
        if let style = quickPickStyle {
            hint = style.promptHint
        } else {
            hint = strategy.promptHint
        }

        return """
        你是一个音乐推荐专家。用户收藏了以下歌曲：

        \(songList)

        请根据这些歌曲，推荐 \(AppConfig.targetTrackCount) 首 Apple Music 曲库中存在的歌曲。

        推荐策略：\(hint)

        要求：
        1. 每行格式：歌名 - 艺人名
        2. 不要推荐用户已经收藏的歌曲
        \(exclusionSection)4. 中文歌曲占比 70-80%，英文歌曲占比 20-30%
        5. 优先推荐冷门好歌，而非热门金曲大杂烩
        6. 确保推荐的歌在 Apple Music 曲库中存在（主流歌手的正式发行曲目）
        7. 输出仅包含歌曲列表，不要任何额外说明文字
        """
    }

    // MARK: - Private

    /// Sample songs to stay within token budget.
    /// Rough estimate: Chinese ~1 char/token, English ~3 chars/token.
    private static func sampleSongs(_ songs: [Song], maxTokens: Int) -> [Song] {
        var estimated = 0
        var result: [Song] = []

        for song in songs {
            let line = "\(song.title) - \(song.artistName)"
            // Conservative estimate: ~1.5 tokens per character for mixed CJK/Latin
            let tokens = Int(Double(line.count) * 1.5)
            if estimated + tokens > maxTokens {
                break
            }
            estimated += tokens
            result.append(song)
        }

        // At minimum include some songs
        if result.count < 20, songs.count >= 20 {
            return Array(songs.prefix(50))
        }

        return result
    }

    /// Format songs as a numbered list.
    private static func formatSongList(_ songs: [Song]) -> String {
        songs.enumerated().map { index, song in
            "\(index + 1). \(song.title) - \(song.artistName)"
        }.joined(separator: "\n")
    }
}
