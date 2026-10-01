//
//  ContentTypeFilterTests.swift
//  SonglyTests
//
//  MusicKit 不提供任何内容类型标记（没有 isVocal / isLive / isCover），
//  这些规则就是唯一的防线 —— 一旦误判，用户会在歌单里看到伴奏或翻唱。
//

import Foundation
import Testing
@testable import Songly

private func candidate(
    id: String = "id",
    title: String,
    album: String? = nil,
    duration: TimeInterval = 200,
    genreNames: [String] = []
) -> ResolvedCandidate {
    ResolvedCandidate(
        info: TrackInfo(id: id, name: title, artist: "某艺人"),
        tier: .confident,
        seedKind: .album,
        rawTitle: title,
        albumTitle: album,
        duration: duration,
        genreNames: genreNames
    )
}

@Suite("ContentTypeFilter")
struct ContentTypeFilterTests {

    // MARK: 拒绝

    @Test("伴奏一律拒，古典流派也不例外")
    func karaokeRejectedEvenInClassicalGenre() {
        // 「伴奏」不会出现在正经器乐作品上，所以这一条不开任何流派豁免。
        let c = candidate(title: "晴天 (伴奏)", genreNames: ["古典"])
        #expect(ContentTypeFilter.rejection(for: c) == .karaoke)
    }

    @Test("现场版在开关打开时被拒")
    func liveRejectedWhenFlagOn() {
        let c = candidate(title: "晴天 (Live)")
        #expect(ContentTypeFilter.rejection(for: c, rejectLive: true) == .liveVersion)
    }

    @Test("流行歌的混音版被拒")
    func remixRejectedInPopGenre() {
        let c = candidate(title: "X (Remix)", genreNames: ["流行"])
        #expect(ContentTypeFilter.rejection(for: c) == .remixVersion)
    }

    @Test("过短的间奏被拒")
    func interludeRejected() {
        let c = candidate(title: "Intro", duration: 32)
        #expect(ContentTypeFilter.rejection(for: c) == .interlude)
    }

    @Test("致敬合辑被拒")
    func tributeAlbumRejected() {
        let c = candidate(title: "某曲", album: "A Tribute to 某某")
        #expect(ContentTypeFilter.rejection(for: c) == .compilationTribute)
    }

    // MARK: 接受

    @Test("钢琴器乐正常通过")
    func pianoInstrumentalAccepted() {
        let c = candidate(title: "River Flows in You", genreNames: ["钢琴"])
        #expect(ContentTypeFilter.rejection(for: c) == nil)
    }

    @Test("Remastered 必须被接受")
    func remasteredIsAccepted() {
        // 国区常常只有重制版在架，拒掉它会静默删掉大量合法曲目。
        let c = candidate(title: "晴天 (Remastered 2012)")
        #expect(ContentTypeFilter.rejection(for: c) == nil)
    }

    @Test("现场版在开关关闭时通过")
    func liveAcceptedWhenFlagOff() {
        let c = candidate(title: "晴天 (Live)")
        #expect(ContentTypeFilter.rejection(for: c, rejectLive: false) == nil)
    }

    @Test("电子流派的混音版通过")
    func remixAcceptedInElectronicGenre() {
        let c = candidate(title: "X (Remix)", genreNames: ["电子"])
        #expect(ContentTypeFilter.rejection(for: c) == nil)
    }

    @Test("歌名里带 Live 但不含现场标记的歌不被误杀")
    func liveWordInTitleIsNotEnough() {
        // 《Live and Let Die》是正经歌名。模式必须收紧到"括号里的 Live"或
        // "Live at/from/in"，否则会把一大批正常歌曲砍掉。
        let c = candidate(title: "Live and Let Die")
        #expect(ContentTypeFilter.rejection(for: c, rejectLive: true) == nil)
    }

    @Test("拿不到时长时不能当成间奏")
    func zeroDurationIsNotInterlude() {
        // MusicKit 取不到时长会返回 0；不加守卫会把整批曲目误杀。
        let c = candidate(title: "某曲", duration: 0)
        #expect(ContentTypeFilter.rejection(for: c) == nil)
    }
}
