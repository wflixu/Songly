//
//  ImplicitSignalDetector.swift
//  Songly
//
//  从 Apple Music 回读「他后来对我推荐过的那些歌做了什么」。
//
//  为什么需要它：App 只能收到**在 App 内**主动点的反馈（超赞 / 删除 / 歌单评分），
//  而用户自述「我平时主要是在 Apple Music 里操作，很少回到这个 APP」。
//  这不是猜测 —— 2026-10-01 导出的 37 条历史记录里，**verdict 数 = 0、歌单评分数 = 0**。
//  显式反馈对这个账号等于死代码，隐式信号是**唯一可能存在的信号源**。
//
//  按代码库既有的「纯函数 vs I/O」缝切开（对照 `PlaylistComposer` 纯 /
//  `CatalogResolver` I/O）：`ImplicitSignalClassifier` 完全纯，可整天单测；
//  `ImplicitSignalDetector` 只有网络与 MusicKit，且**按契约不抛错**。
//

import Foundation
import MusicKit

// MARK: - 输入

/// 一个候选：我们推荐过的某一首歌，以及判断归因所需的上下文。
///
/// 全部来自本地记录，不含任何网络状态 —— 这样检测器与分类器可以分别单测。
struct ImplicitCandidate: Sendable, Equatable {
    let songID: String
    /// 归一化「歌名 + 艺人」。歌单 diff 只能按它比对，不能按 id。
    let key: TrackKey
    /// "歌名 - 艺人"，渲染用。
    let displayName: String
    /// 主艺人 key（`primaryArtistKey` 的产物，已小写化）。
    let artist: String
    /// 回看窗口内**最早**一次推荐它的日期。
    ///
    /// 刻意取「最早」而不是「最近」：他在第 2 次推荐后才收藏时，用「最近」会漏判。
    let firstRecommendedAt: Date
    /// 那次建的 Apple Music 歌单（可能为 nil）。
    let playlistID: String?
    /// 他已经在本 App 里表过态 —— 这类候选**整条跳过**（见分类器）。
    let hasExplicitVerdict: Bool
    /// **我们**把它加进资料库的时刻。非 nil 表示库里的它不构成「他自己收的」。
    let librarySyncedAt: Date?
}

/// 一份待比对的歌单：当初建它时推荐了哪些歌。
struct ImplicitPlaylistTarget: Sendable, Equatable {
    let playlistID: String
    /// 记录里当时**可见**的曲目（已排除 App 内删掉的）。
    let expectedKeys: [TrackKey]
}

// MARK: - 观测（网络的原始事实）

/// 网络的**原始事实**，不含任何权重判断。
///
/// 刻意把日期原样带回来、把「算不算入库」留给分类器 —— 否则判断逻辑就散落在
/// 网络代码里，没法单测。
struct ImplicitObservation: Sendable, Equatable {
    /// `rating == 1`。**不在集合里 = 没标过**，与「读失败」是两回事。
    var starredSongIDs: Set<String> = []
    /// `rating == -1`。
    var dislikedSongIDs: Set<String> = []
    /// songID → 在资料库里的入库时间（`Song.libraryAddedDate`）。
    var libraryAddedDates: [String: Date] = [:]
    /// songID → 最近播放时间（`Song.lastPlayedDate`）。
    var lastPlayedDates: [String: Date] = [:]
    /// 从我们建的歌单里消失的曲目（按归一化 key）。
    var removedFromPlaylistKeys: Set<TrackKey> = []
    /// 有子步骤没跑成。**不影响管线继续**，只是信号变少。
    var degraded: Bool = false
    /// 失败原因，进 `logDiagnostics`。
    var notes: [String] = []

    static let empty = ImplicitObservation(degraded: true)
}

// MARK: - 产出

/// 分类结果。prompt 与 composer 直接可用。
struct ImplicitSignals: Sendable, Equatable {
    /// 每类信号最多写进 prompt 几条。列表已排序，所以截断是确定的。
    static let maxShownPerCategory = 10

    /// 主艺人 → 权重。**尚未与显式反馈合并、也尚未夹到 `-5...5`**。
    var artistWeights: [String: Int] = [:]
    var starred: [String] = []
    var adopted: [String] = []
    var listened: [String] = []
    var removedSongs: [String] = []
    /// 硬排除：catalog ID。
    var removedIDs: Set<String> = []
    /// 硬排除：归一化文本键（跨 ID 口径的兜底）。
    var removedKeys: Set<TrackKey> = []

    static let empty = ImplicitSignals()

    /// 有没有值得写进 prompt 的内容。硬排除**不算** —— 它走 composer，不走 prompt。
    var hasPromptContent: Bool {
        !starred.isEmpty || !adopted.isEmpty || !listened.isEmpty || !removedSongs.isEmpty
    }

    /// 渲染成 prompt 的一个小节。全空时返回 `nil`，调用方整块省略 ——
    /// 「无信号时消息逐字节不变」是这里的前提条件。
    var promptBlock: String? {
        guard hasPromptContent else { return nil }

        var lines: [String] = [
            "## 他的实际收听行为（弱信号）",
            "",
            "以下不是他主动说的，是我们回读他在 Apple Music 里的动作推断出来的 ——",
            "可信度**低于**上面的「用户明确反馈」，只当作方向参考，不要升级成硬性规则",
            "（唯一例外见最后一句）：",
            "",
        ]

        if !starred.isEmpty {
            lines.append("他打了 ⭐ 收藏的推荐曲目：\(starred.joined(separator: "、"))")
        }
        if !adopted.isEmpty {
            lines.append("他后来加进资料库的推荐曲目：\(adopted.joined(separator: "、"))")
        }
        if !listened.isEmpty {
            lines.append("他后来又听过的推荐曲目：\(listened.joined(separator: "、"))")
        }

        // 只有正向信号时才说这句 —— 整块只有「删掉」时，这句读起来前言不搭后语。
        if !starred.isEmpty || !adopted.isEmpty || !listened.isEmpty {
            lines.append("")
            lines.append("⭐ 与「加进资料库」说明这个方向对味，可以多挖一点；")
            lines.append("「后来听过」只说明他点开过，**不代表喜欢**，不要因为这个方向加大配额。")
        }

        if !removedSongs.isEmpty {
            lines.append("")
            lines.append("**他从前几期歌单里删掉的曲目：\(removedSongs.joined(separator: "、"))。"
                         + "这些是硬性排除，绝不能再出现。**")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Protocol

protocol ImplicitSignalDetecting: Sendable {
    /// **永不抛错、永不失败整条管线。**
    ///
    /// 任何子步骤失败只让对应字段为空并记一条 note —— 读不到隐式信号只意味着
    /// 「少了一路参考」，绝不该让今天出不来歌单。
    func observe(
        _ candidates: [ImplicitCandidate],
        playlists: [ImplicitPlaylistTarget]
    ) async -> ImplicitObservation
}

// MARK: - 分类器（纯函数）

enum ImplicitSignalClassifier {

    // MARK: 歌单 diff 的判定（纯，可单测）

    /// 歌单 diff 的**判定**部分 —— 与网络、与 MusicKit 类型都无关。
    ///
    /// 抽出来是为了让这几道「安全闸门」能被真正测到：它们是整套隐式信号里
    /// **最危险的一环**（判错一次，25 首歌永久进排除集，而用户看不见也没法撤销），
    /// 埋在私有方法里就没法单测。
    ///
    /// 调用方负责闸 1（抓取 + 分页排空成功）与闸 4（按归一化 key 比对），
    /// 把结果交给这里做闸 2 / 闸 3。
    static func playlistDiff(
        expected: [TrackKey],
        present: Set<TrackKey>,
        entriesEmpty: Bool
    ) -> (removed: Set<TrackKey>, note: String?) {
        // 闸 2：空歌单不做任何归因。
        guard !entriesEmpty else { return ([], "playlist_empty") }

        // 闸 3：存活率。**全都不见了那是 bug，不是用户在清理。**
        // 这道闸是防投毒的关键 —— 比对方式或分页一旦出错，整份歌单会被判成
        // 「全被删了」，而那个错误没有任何下游能纠正。
        let survivors = expected.filter { present.contains($0) }.count
        let ratio = expected.isEmpty ? 1 : Double(survivors) / Double(expected.count)
        guard ratio >= AppConfig.implicitRemovalMinSurvivorRatio else {
            return ([], "playlist_diff_suspect")
        }

        return (Set(expected).subtracting(present), nil)
    }

    /// 入库时间的宽限。
    ///
    /// `libraryAddedDate` 与我们记录的时间戳不可能严格对齐（他可能在推荐后几分钟、
    /// 也可能隔一天才加），差一天以内仍算「是我们推荐的后果」。
    static let libraryDateSlack: TimeInterval = 24 * 60 * 60

    /// 把「原始事实」变成权重与硬排除集合。
    ///
    /// 归因是全部难点 —— 三条硬规则：
    /// 1. 已在本 App 表过态的候选**整条跳过**；
    /// 2. 一首歌**只计一次**，取最强档（⭐ > 被删 > 不喜欢 > 入库 > 听过），绝不叠加；
    /// 3. 正向只归到**艺人**，不归到单曲偏好 —— 因为评分没有时间戳，
    ///    六月前给的 ⭐ 和昨晚给的 ⭐ 无法区分，单曲级的归因太容易被这一点污染。
    static func classify(
        _ candidates: [ImplicitCandidate],
        observation: ImplicitObservation
    ) -> ImplicitSignals {
        var signals = ImplicitSignals()
        var weights: [String: Int] = [:]
        var starred: [String] = []
        var adopted: [String] = []
        var listened: [String] = []
        var removed: [String] = []

        for candidate in candidates {
            // 规则 1：已经表过态的一律不看。
            //
            // 这一条就干净地解决了「我们自己造成的入库」这个污染源：
            // `PlaylistDetailView.syncLovedToAppleMusic` 只在用户点 App 内「超赞」
            // 时被调用（`love(_:)` 且 `next == .loved` 才可达），所以**我们造成的
            // 每一次入库，其 `verdict` 当时必然是 `.loved`** —— 全部被这里挡掉。
            guard !candidate.hasExplicitVerdict else { continue }

            // 规则 2：命中即 `continue`，所以每首歌只贡献一次。
            if observation.starredSongIDs.contains(candidate.songID) {
                starred.append(candidate.displayName)
                weights[candidate.artist, default: 0] += AppConfig.implicitPositiveArtistWeight
                continue
            }

            // ⭐ 优先于「被删」：⭐ 是对这首歌**明确**的正面表态，而「从歌单里消失」
            // 至少有一种无害读法（「这首我早就有」）。把用户亲手标过的歌永久排除，
            // 是这两个错误里更坏的那个。
            if observation.removedFromPlaylistKeys.contains(candidate.key) {
                signals.removedIDs.insert(candidate.songID)
                signals.removedKeys.insert(candidate.key)
                removed.append(candidate.displayName)
                weights[candidate.artist, default: 0] += AppConfig.implicitNegativeArtistWeight
                continue
            }

            if observation.dislikedSongIDs.contains(candidate.songID) {
                weights[candidate.artist, default: 0] += AppConfig.implicitNegativeArtistWeight
                continue
            }

            // 入库：必须**不是我们加的**（`librarySyncedAt == nil`），
            // 且入库时间要落在推荐之后（留一天宽限）。
            if candidate.librarySyncedAt == nil,
               let addedAt = observation.libraryAddedDates[candidate.songID],
               addedAt >= candidate.firstRecommendedAt.addingTimeInterval(-libraryDateSlack) {
                adopted.append(candidate.displayName)
                weights[candidate.artist, default: 0] += AppConfig.implicitPositiveArtistWeight
                continue
            }

            // 听过：**只进 prompt、不动权重**。一天推 25 首，好奇心点开一下不是偏好。
            // 等以后存了播放次数的基线，「听了十几遍」才可以升级成权重信号。
            if let playedAt = observation.lastPlayedDates[candidate.songID],
               playedAt > candidate.firstRecommendedAt {
                listened.append(candidate.displayName)
                continue
            }
        }

        // 先夹到隐式信号自己的范围，之后再与显式反馈合并、再夹到全局 `-5...5`。
        // 两步夹取是故意的：15 个显式超赞已经能顶到 ±5，而隐式信号廉价易累积
        // （每次播放、每次入库都可能加一笔），不先夹一道会把显式的分量冲掉。
        let range = AppConfig.implicitArtistWeightRange
        signals.artistWeights = weights.mapValues {
            min(max($0, range.lowerBound), range.upperBound)
        }

        // 排序保证同一批输入渲染出同样的字节。这里每首歌最多出现一次（计数恒为 1），
        // 所以「按名升序」与显式反馈那套「次数降序、同次数按名升序」等价。
        signals.starred = Array(starred.sorted().prefix(ImplicitSignals.maxShownPerCategory))
        signals.adopted = Array(adopted.sorted().prefix(ImplicitSignals.maxShownPerCategory))
        signals.listened = Array(listened.sorted().prefix(ImplicitSignals.maxShownPerCategory))
        signals.removedSongs = Array(removed.sorted().prefix(ImplicitSignals.maxShownPerCategory))
        return signals
    }
}

// MARK: - 检测器（I/O）

/// 只有网络与 MusicKit，没有任何权重判断。
///
/// **普通 `final class`，不是 actor、也不是 `@MainActor`：**
/// - 不是 actor：没有共享可变状态，而引擎本身已是 actor，会串行化整条管线；
/// - 不是 `@MainActor`：2–4 次串行网络往返会卡住主线程。
///
/// 它也**不碰 SwiftData** —— 读记录照旧归 `FeedbackStore` / 引擎，
/// 这符合 `FeedbackStore` 头部注释定下的归属规则。
final class ImplicitSignalDetector: ImplicitSignalDetecting {

    private let libraryService: MusicLibraryServicing
    private let musicKit: MusicKitServiceProtocol

    init(
        libraryService: MusicLibraryServicing = MusicLibraryService(),
        musicKit: MusicKitServiceProtocol = MusicKitService()
    ) {
        self.libraryService = libraryService
        self.musicKit = musicKit
    }

    func observe(
        _ candidates: [ImplicitCandidate],
        playlists: [ImplicitPlaylistTarget]
    ) async -> ImplicitObservation {
        var observation = ImplicitObservation()
        guard AppConfig.implicitSignalsEnabled, !candidates.isEmpty else {
            observation.degraded = true
            observation.notes.append("implicit_disabled_or_empty")
            return observation
        }

        let ids = candidates.map(\.songID)

        // 1) 资料库：定向查这几首现在在不在库里。
        //
        // **定向查而不是拉全量** —— `fetchLibrarySongs(limit:)` 有上限，曲库大的用户
        // 会漏，而漏掉的恰好可能是「他刚加进来的那几首」。
        do {
            let songs = try await musicKit.fetchLibrarySongs(ids: ids)
            for song in songs {
                let id = song.id.rawValue
                if let added = song.libraryAddedDate { observation.libraryAddedDates[id] = added }
                if let played = song.lastPlayedDate { observation.lastPlayedDates[id] = played }
            }
        } catch {
            observation.degraded = true
            observation.notes.append("library_read_failed")
        }

        if Task.isCancelled { return observation }

        // 2) 评分（⭐）。挂在开关后面 —— 这条路尚未在真机验证过。
        //    关掉时其余信号照跑，它们用的都是已验证的 MusicKit API。
        if AppConfig.readAppleMusicRatings {
            let ratings = await libraryService.readRatings(songIDs: ids)
            for (id, value) in ratings.ratings {
                if value > 0 {
                    observation.starredSongIDs.insert(id)
                } else if value < 0 {
                    observation.dislikedSongIDs.insert(id)
                }
            }
            if let failure = ratings.failure {
                observation.degraded = true
                observation.notes.append("ratings_read_failed")
                _ = failure   // 具体原因留在探测报告里，日志只记一个稳定的短名
            }
        } else {
            observation.notes.append("ratings_read_disabled")
        }

        if Task.isCancelled { return observation }

        // 3) 歌单 diff：他有没有从我们建的歌单里删歌。
        for target in playlists.prefix(AppConfig.maxPlaylistDiffsPerRun) {
            if Task.isCancelled { break }
            let outcome = await diffPlaylist(target)
            observation.removedFromPlaylistKeys.formUnion(outcome.removed)
            if let note = outcome.note { observation.notes.append(note) }
        }

        observation.notes.sort()
        return observation
    }

    // MARK: 歌单 diff

    /// 一份歌单的差异。
    ///
    /// **四道闸门全过才允许归因。** 这是整套隐式信号里最危险的一环：
    /// `Playlist.Entry.id` 与我们的目录 ID **是两套不同的域**，一旦比对方式
    /// 或分页出错，「我们推的全都不见了」会被当成用户大清理，25 首歌永久进排除集 ——
    /// 而这个错误用户看不见、也没法撤销。
    private func diffPlaylist(
        _ target: ImplicitPlaylistTarget
    ) async -> (removed: Set<TrackKey>, note: String?) {
        guard !target.expectedKeys.isEmpty else { return ([], nil) }

        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(target.playlistID))
        request.limit = 1

        let playlist: Playlist
        do {
            guard let found = try await request.response().items.first else {
                // 歌单查不到。可能是被他删了，也可能是资料库重装 —— 两者签名一样。
                // **什么都不标**：删掉整份歌单绝不能翻译成 25 首永久排除。
                return ([], "playlist_missing")
            }
            playlist = found
        } catch {
            return ([], "playlist_lookup_failed")
        }

        // 闸 1：抓取 + 分页排空都要成功。
        let entries: [Playlist.Entry]
        do {
            let detailed = try await playlist.with([.entries])
            var collected: [Playlist.Entry] = detailed.entries.map(Array.init) ?? []
            var cursor = detailed.entries
            var batches = 0
            while let current = cursor, current.hasNextBatch {
                guard batches < 20 else { return ([], "playlist_paging_suspect") }
                guard let next = try await current.nextBatch() else { break }
                collected += Array(next)
                cursor = next
                batches += 1
            }
            entries = collected
        } catch {
            return ([], "playlist_entries_failed")
        }

        // 闸 4：按**归一化 歌名 + 艺人**比对，**绝不能按 id**。
        // `Playlist.Entry.id` 与我们的目录 ID 是两套不同的域，按 id 比对会把整份
        // 歌单判成全被删了。
        let present = Set(entries.map {
            TrackKey(title: normalizedKey($0.title), artist: normalizedKey($0.artistName))
        })

        // 闸 2 / 闸 3 在纯函数里，可单测。
        return ImplicitSignalClassifier.playlistDiff(
            expected: target.expectedKeys,
            present: present,
            entriesEmpty: entries.isEmpty
        )
    }
}
