//
//  TasteProfileStore.swift
//  Songly
//
//  口味画像的持久化与刷新策略。
//
//  用 `UserDefaults` + JSON 而不是 SwiftData：画像本质上是**可重新生成的缓存**，
//  丢了就重算（代价是一次 LLM 调用），不值得为它引入一次 schema 迁移。
//

import Foundation

/// `@unchecked Sendable` 的理由：这个类没有可变状态（两个属性都是 `let`），
/// 而 `UserDefaults` 本身是线程安全的。没有任何需要同步的东西。
final class TasteProfileStore: @unchecked Sendable {
    static let defaultKey = "songly.tasteProfile.v1"

    /// 画像最长有效期：一周。再久就该重新看看这个人了。
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// 因曲库变化触发重算的最小间隔。
    ///
    /// 不设这个下限的话，用户每加一首歌都会触发一次完整的画像重算 ——
    /// 那是一次 LLM 调用，还可能挤进推荐流程的预算里。
    static let minRefreshInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = TasteProfileStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> TasteProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TasteProfile.self, from: data)
    }

    func save(_ profile: TasteProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    // MARK: - Refresh Policy

    /// 是否需要重新生成画像。
    ///
    /// 三种情况要重算：从来没有过、过期了、曲库变了（但距上次生成已超过最小间隔）。
    static func shouldRefresh(
        existing: TasteProfile?,
        libraryFingerprint: String,
        now: Date = Date(),
        maxAge: TimeInterval = TasteProfileStore.maxAge,
        minInterval: TimeInterval = TasteProfileStore.minRefreshInterval
    ) -> Bool {
        guard let existing else { return true }

        let age = now.timeIntervalSince(existing.generatedAt)
        if age >= maxAge { return true }
        if existing.libraryFingerprint != libraryFingerprint, age >= minInterval { return true }
        return false
    }

    /// 生成一份新画像（版本号递增）。
    func makeProfile(
        payload: TasteProfilePayload,
        libraryFingerprint: String,
        previous: TasteProfile?,
        now: Date = Date()
    ) -> TasteProfile {
        TasteProfile(
            version: (previous?.version ?? 0) + 1,
            generatedAt: now,
            libraryFingerprint: libraryFingerprint,
            payload: payload
        )
    }
}
