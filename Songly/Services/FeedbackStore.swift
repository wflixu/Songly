//
//  FeedbackStore.swift
//  Songly
//
//  把散落在历史记录里的用户反馈**派生**成推荐管线能吃的三种形态。
//
//  刻意不做成一张独立的表：判定就存在 `TrackInfo.verdict` 里（`tracksJSON` 内），
//  这里只负责扫一遍汇总。好处是不用碰 SwiftData schema，而且判定与它所属的
//  歌单永远一致 —— 不会有第二份数据可以漂移。
//
//  代价是每次运行要解码一遍全部历史（一年约 9000 个小对象）。相对 20–120 秒的
//  管线可忽略；真成瓶颈再加派生缓存。
//

import Foundation
import SwiftData

// MARK: - Summary

/// 给 prompt 用的紧凑反馈摘要。
///
/// 每一项都已排序、已封顶，所以同一批反馈渲染出的字节完全相同 —— 这是
/// `systemPrefix` 前缀缓存的前提。
struct FeedbackSummary: Equatable, Sendable {
    /// "歌名 - 艺人"，按出现次数降序、同次数按名称升序。
    var lovedSongs: [String] = []
    var lovedArtists: [String] = []
    var removedSongs: [String] = []
    var removedArtists: [String] = []
    var ratingCounts: [PlaylistRating: Int] = [:]

    static let empty = FeedbackSummary()

    var isEmpty: Bool {
        lovedSongs.isEmpty && lovedArtists.isEmpty
            && removedSongs.isEmpty && removedArtists.isEmpty
            && ratingCounts.isEmpty
    }

    /// 渲染成 prompt 的一个小节。全空时返回 `nil`，调用方整块省略。
    var promptBlock: String? {
        guard !isEmpty else { return nil }

        var lines: [String] = ["## 用户明确反馈", ""]

        if !lovedArtists.isEmpty {
            lines.append("他标过「超赞」的艺人：\(lovedArtists.joined(separator: "、"))")
        }
        if !lovedSongs.isEmpty {
            lines.append("他标过「超赞」的歌：\(lovedSongs.joined(separator: "、"))")
        }
        if !removedArtists.isEmpty {
            lines.append("他删掉过这些艺人的歌（不要再提这些方向）：\(removedArtists.joined(separator: "、"))")
        }
        if !removedSongs.isEmpty {
            lines.append("他明确删掉的歌：\(removedSongs.joined(separator: "、"))")
        }
        if !ratingCounts.isEmpty {
            // 按 `allCases` 遍历而不是遍历字典 —— 字典顺序不稳定，会击穿缓存。
            let parts = PlaylistRating.allCases.compactMap { rating -> String? in
                guard let count = ratingCounts[rating], count > 0 else { return nil }
                return "\(rating.displayName) ×\(count)"
            }
            if !parts.isEmpty {
                lines.append("他最近对歌单的评价：\(parts.joined(separator: "、"))")
            }
        }
        lines.append("")
        lines.append("「超赞」是他主动表示惊喜的方向，值得多挖；「删掉」是硬性排除，绝不能再出现。")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Store

@MainActor
final class FeedbackStore {

    /// 一次扫描的全部产出。
    struct Derived: Sendable {
        /// songID → 最终判定（最近的记录说了算）。
        var verdicts: [String: TrackVerdict] = [:]
        /// 永久排除：catalog ID。
        var removedIDs: Set<String> = []
        /// 永久排除：归一化文本键（用于跨 ID 口径的兜底匹配）。
        var removedKeys: Set<TrackKey> = []
        /// 隐式排除：他被发现从**我们建的歌单里**自己删掉的歌。
        ///
        /// 与显式的 `removedIDs` 走同一个「永不放宽」出口（它同样是刚性的用户意志），
        /// 但**分开存** —— 诊断日志要能回答「这个闸门挡了多少次」，混在一起就分不清
        /// 「他删了多少」和「他删了多少次 App 里的」。
        var implicitRemovedIDs: Set<String> = []
        var implicitRemovedKeys: Set<TrackKey> = []
        /// 主艺人 → 权重。正数上浮，负数下沉。已夹取。
        var artistWeights: [String: Int] = [:]
        var summary: FeedbackSummary = .empty
    }

    /// 排除了多少首歌算「足够强」的信号 —— 超出部分夹取，避免刷屏式反馈
    /// 把某个艺人一路顶到排序最前。
    /// 艺人权重的全局上下限。**不是 private** —— 隐式信号合并后要夹到同一个范围，
    /// 两处各写一个数字迟早会漂移。
    /// `nonisolated`：它是个常量，而 `@MainActor` 会把静态成员一并隔离 ——
    /// 那样 `ImplicitSignalClassifier`（纯函数、非主线程）就读不到它了。
    nonisolated static let weightRange = -5...5
    private static let maxLovedSongs = 15
    private static let maxLovedArtists = 12
    private static let maxRemovedSongs = 15
    private static let maxRemovedArtists = 8

    /// 收 `ModelContext` 而不是 `ModelContainer` —— 视图层只有 `@Environment(\.modelContext)`，
    /// 引擎那边传 `modelContainer.mainContext` 即可，两边都能用同一个类型。
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Derive

    func derive() -> Derived {
        var result = Derived()

        // 计数用的中间结构：name 用于渲染，count 用于排序。
        var lovedSong: [String: (name: String, count: Int)] = [:]
        var removedSong: [String: (name: String, count: Int)] = [:]
        var lovedArtist: [String: Int] = [:]
        var removedArtist: [String: Int] = [:]
        var ratingCounts: [PlaylistRating: Int] = [:]

        for record in allRecords() {   // 已按 date 降序 → 新的判定先到先得
            for track in record.tracks {
                let artist = primaryArtistKey(track.artist)

                // 同一首歌在多份歌单里出现时，**最新的记录说了算** ——
                // 那是「改主意了」的自然语义。
                if let verdict = track.verdict, result.verdicts[track.id] == nil {
                    result.verdicts[track.id] = verdict
                }

                // 隐式负面：他后来从我们建的歌单里自己删掉了这首歌。
                //
                // **不改 `FeedbackSummary`** —— 那是「他明确说了什么」的渲染，
                // 往里塞一条我们自己推断的东西，就是让 prompt 去对模型撒谎。
                // 隐式信号的措辞与归因在 `ImplicitSignals.promptBlock` 里单独讲。
                // 开关在这里判而不是在写入端判：写入端照常留痕（观测数据本身有价值），
                // 由这里决定它**生不生效** —— 这样以后翻开关，历史数据会一起跟着变。
                if AppConfig.treatPlaylistRemovalAsPermanent,
                   track.implicitRemovedAt != nil, track.verdict == nil {
                    result.implicitRemovedIDs.insert(track.id)
                    result.implicitRemovedKeys.insert(track.key)
                }

                switch track.verdict {
                case .loved:
                    lovedSong[track.id] = (track.name + " - " + track.artist,
                                           (lovedSong[track.id]?.count ?? 0) + 1)
                    lovedArtist[artist, default: 0] += 1
                    result.artistWeights[artist, default: 0] += 2

                case .removed:
                    removedSong[track.id] = (track.name + " - " + track.artist,
                                             (removedSong[track.id]?.count ?? 0) + 1)
                    removedArtist[artist, default: 0] += 1
                    result.removedIDs.insert(track.id)
                    result.removedKeys.insert(track.key)
                    result.artistWeights[artist, default: 0] -= 1

                case nil:
                    break
                }
            }

            // 歌单级的「准不准」作用在该歌单**仍然可见**的曲目所属艺人身上。
            // 只给一个 ±1 —— 它比单曲标记弱，因为「这份不准」可能只是选曲问题，
            // 未必是这个艺人的问题。
            if let rating = record.ratingValue {
                ratingCounts[rating, default: 0] += 1
                let delta = rating == .accurate ? 1 : (rating == .off ? -1 : 0)
                if delta != 0 {
                    for artist in Set(record.visibleTracks.map { primaryArtistKey($0.artist) }) {
                        result.artistWeights[artist, default: 0] += delta
                    }
                }
            }
        }

        result.artistWeights = result.artistWeights.mapValues {
            min(max($0, Self.weightRange.lowerBound), Self.weightRange.upperBound)
        }

        result.summary = FeedbackSummary(
            lovedSongs: ranked(lovedSong, limit: Self.maxLovedSongs),
            lovedArtists: ranked(lovedArtist, limit: Self.maxLovedArtists),
            removedSongs: ranked(removedSong, limit: Self.maxRemovedSongs),
            removedArtists: ranked(removedArtist, limit: Self.maxRemovedArtists),
            ratingCounts: ratingCounts
        )
        return result
    }

    // MARK: - Mutations

    /// 在指定记录上写一首歌的判定。
    ///
    /// 同时维护 `songCount`（当前曲目数，删除时递减）与 `removedCount`（差值），
    /// 让「N 首已移除」那行说明有据可依。
    @discardableResult
    func setVerdict(
        _ verdict: TrackVerdict?,
        forSongID songID: String,
        in record: RecommendationRecord
    ) -> Bool {
        var tracks = record.tracks
        guard let index = tracks.firstIndex(where: { $0.id == songID }) else { return false }

        let previous = tracks[index].verdict
        guard previous != verdict else { return true }

        tracks[index].verdict = verdict
        // 撤销（`verdict == nil`）时一并清掉时间戳 —— 留着一个「已撤销的判定时刻」，
        // 下游会以为它还是个有效信号。
        tracks[index].verdictUpdatedAt = verdict == nil ? nil : Date()
        record.tracks = tracks

        switch (previous, verdict) {
        case (_, .removed):
            record.songCount = max(0, record.songCount - 1)
            record.removedCount += 1
        case (.removed, _):
            record.songCount += 1
            record.removedCount = max(0, record.removedCount - 1)
        default:
            break
        }

        try? context.save()
        return true
    }

    /// 记下「**我们**把这首歌加进了他的资料库」。
    ///
    /// 必须在入库成功后调用。没有它，`TrackInfo.librarySyncedAt` 永远是 nil，
    /// 而「这首歌现在在他库里」就会被隐式信号误读成「他自己收的」——
    /// 白送一个正向信号，且是从我们自己的动作里凭空造出来的。
    ///
    /// 幂等：已经有时间戳就不覆盖（第一次写入才是「我们加进去」的真实时刻）。
    @discardableResult
    func markLibrarySynced(songID: String, in record: RecommendationRecord) -> Bool {
        var tracks = record.tracks
        guard let index = tracks.firstIndex(where: { $0.id == songID }) else { return false }
        guard tracks[index].librarySyncedAt == nil else { return true }
        tracks[index].librarySyncedAt = Date()
        record.tracks = tracks
        try? context.save()
        return true
    }

    /// 记下「他被发现从我们建的歌单里删掉了这首歌」。
    ///
    /// 落盘而不是每次重算：不落盘的话，这条排除会在记录滚出回看窗口时**蒸发** ——
    /// 而「删除应当永久生效」正是这套东西的设计前提。
    @discardableResult
    func markImplicitRemoved(songID: String, in record: RecommendationRecord) -> Bool {
        var tracks = record.tracks
        guard let index = tracks.firstIndex(where: { $0.id == songID }) else { return false }
        guard tracks[index].implicitRemovedAt == nil else { return true }
        tracks[index].implicitRemovedAt = Date()
        record.tracks = tracks
        try? context.save()
        return true
    }

    func setRating(_ rating: PlaylistRating?, on record: RecommendationRecord) {
        record.rating = rating?.rawValue
        // 与 `setVerdict` 同理：取消评价时把时刻也清掉。
        record.ratedAt = rating == nil ? nil : Date()
        try? context.save()
    }

    // MARK: - Private

    /// 全量、**不带时间窗** —— 删除是永久的，不能只扫最近 N 天。
    /// 这也是为什么不能用 `RecommendationEngine.fetchRecentRecords`（它总有时间窗）。
    private func allRecords() -> [RecommendationRecord] {
        let descriptor = FetchDescriptor<RecommendationRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 按次数降序、同次数按名称升序（保证同输入渲染出同样的字节），再取前 N。
    private func ranked(_ table: [String: (name: String, count: Int)], limit: Int) -> [String] {
        table.values
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs.name < rhs.name
            }
            .prefix(limit)
            .map(\.name)
    }

    private func ranked(_ table: [String: Int], limit: Int) -> [String] {
        table
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .prefix(limit)
            .map(\.key)
    }
}
