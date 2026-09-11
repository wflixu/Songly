//
//  AlbumTrackPicker.swift
//  Songly
//
//  从一张专辑的曲目里挑出这条 seed 想要的那几首。
//
//  这里是整条链路里**唯一能主动挖到非主打歌**的地方。改造前 LLM 只能凭记忆
//  报歌名，而它记住的永远是主打歌 —— 这就是「都是听过的老歌」最直接的来源。
//  把 seed 指向专辑、再从专辑里避开前两轨，才有可能拿到真正的 B 面。
//
//  纯函数，可完整单测。
//

import Foundation

enum AlbumTrackPicker {

    /// 低于这个曲目数的专辑不套深挖偏置 —— 迷你专辑 / 单曲碟里，
    /// 前三轨未必是主打，套了反而会挑到奇怪的位置。
    static let deepCutMinimumTrackCount = 6

    /// 挑曲。
    ///
    /// - Parameters:
    ///   - tracks: 同一张专辑的全部曲目。
    ///   - wants: 这条 seed 想要几首。
    ///   - exclusions: 硬排除集合。
    ///   - maxPerAlbum: 单张专辑的取数上限。
    static func pick(
        from tracks: [ResolvedCandidate],
        wants: Int,
        exclusions: PlaylistComposer.ExclusionSet,
        maxPerAlbum: Int = AppConfig.maxTracksPerAlbum
    ) -> [ResolvedCandidate] {
        let limit = min(max(wants, 1), maxPerAlbum)
        guard !tracks.isEmpty, limit > 0 else { return [] }

        let strict = tracks.filter { isEligible($0, exclusions: exclusions, allowLibrary: false) }
        if !strict.isEmpty {
            return Array(strict.sorted(by: isBetter).prefix(limit))
        }

        // 整张专辑都在排除集合里时不直接判死 —— 退回允许与曲库重叠。
        // 一条 seed 能解析出东西，总比空手而归强；真正的硬排除
        // （已推荐过 / 最近播放）仍然生效。
        let relaxed = tracks.filter { isEligible($0, exclusions: exclusions, allowLibrary: true) }
        return Array(relaxed.sorted(by: isBetter).prefix(limit))
    }

    // MARK: - Private

    private static func isEligible(
        _ candidate: ResolvedCandidate,
        exclusions: PlaylistComposer.ExclusionSet,
        allowLibrary: Bool
    ) -> Bool {
        if ContentTypeFilter.rejection(for: candidate) != nil { return false }
        if exclusions.songIDs.contains(candidate.info.id) { return false }
        if exclusions.keys.contains(candidate.info.key) { return false }
        if exclusions.recentlyPlayedKeys.contains(candidate.info.key) { return false }
        if !allowLibrary, exclusions.libraryKeys.contains(candidate.info.key) { return false }
        return true
    }

    /// 排序：越靠前越该被选中。
    private static func isBetter(_ lhs: ResolvedCandidate, _ rhs: ResolvedCandidate) -> Bool {
        let left = key(lhs), right = key(rhs)
        if left != right { return left.lexicographicallyPrecedes(right) }
        // 最终 tie-break，保证同一天同一张专辑挑出来的曲目是确定的。
        return lhs.info.id < rhs.info.id
    }

    private static func key(_ candidate: ResolvedCandidate) -> [Int] {
        [
            // 深挖偏置：曲目数够多的专辑里，把前两轨（通常是主打）排到最后。
            isLeadTrack(candidate) ? 1 : 0,
            // 合辑垫后。
            candidate.isCompilation ? 1 : 0,
            candidate.trackNumber ?? Int.max,
            candidate.duration < 45 ? 1 : 0,
        ]
    }

    private static func isLeadTrack(_ candidate: ResolvedCandidate) -> Bool {
        guard let trackNumber = candidate.trackNumber,
              let count = candidate.albumTrackCount,
              count >= deepCutMinimumTrackCount else { return false }
        return trackNumber <= 2
    }
}
