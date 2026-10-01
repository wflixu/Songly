//
//  APIKeyTests.swift
//  SonglyTests
//
//  API Key 的存储、策略，以及「注入的 Key 就是校验用的 Key」这条结构性不变式。
//
//  最后一类是这一层存在的**主要原因**：改造前 `LLMService` 的 guard 检查的是静态
//  `AppEnvironment`，而请求头用的是构造时快照的另一个字符串 —— 两者可以同时存在
//  且互相矛盾。那种 bug 不会崩、不会报错，只会表现为「我明明配了 Key 却说没配」。
//

import Foundation
import Testing
@testable import Songly

// MARK: - Test Double

/// 内存版 store。
///
/// **刻意放在测试目标而不是 App 目标**：生产代码里不该存在一个「Key 可以凭空出现」
/// 的实现，那会让「Key 到底从哪来」这个问题重新变得模糊 —— 而这正是这次重构
/// 要终结的东西。
final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(initial: String? = nil) {
        self.value = initial
    }

    func load() -> String? {
        lock.withLock { value }
    }

    func save(_ key: String) throws {
        lock.withLock { value = key }
    }

    func clear() throws {
        lock.withLock { value = nil }
    }
}

// MARK: - Policy

@Suite("API Key 策略")
struct APIKeyPolicyTests {

    @Test("归一化去掉首尾空白与换行")
    func normalizeTrimsWhitespace() {
        // 粘贴 Key 时几乎必然带上换行 —— 这是最常见的「看起来对但用不了」。
        #expect(APIKeyPolicy.normalize(" sk-abc\n") == "sk-abc")
        #expect(APIKeyPolicy.normalize("\t sk-abc  ") == "sk-abc")
        #expect(APIKeyPolicy.normalize("sk-abc") == "sk-abc")
    }

    @Test("空值与占位符都判定为不可用")
    func unusableInputs() {
        #expect(!APIKeyPolicy.isUsable(""))
        #expect(!APIKeyPolicy.isUsable("   "))
        #expect(!APIKeyPolicy.isUsable("\n"))
        // 文档示例里的占位符。用户从 README 抄一行过来是很常见的失误。
        #expect(!APIKeyPolicy.isUsable("sk-your-key-here"))
        #expect(APIKeyPolicy.isUsable("sk-abc"))
        #expect(APIKeyPolicy.isUsable("  sk-abc  "))
    }

    @Test("validate 给出具体原因而不是笼统失败")
    func validateThrowsSpecificErrors() throws {
        #expect(throws: APIKeyPolicyError.self) { try APIKeyPolicy.validate("") }
        #expect(throws: APIKeyPolicyError.self) { try APIKeyPolicy.validate("sk-your-key") }
        #expect(try APIKeyPolicy.validate("  sk-real  ") == "sk-real")
    }
}

// MARK: - LLMService 同源不变式

@Suite("LLMService 凭据")
struct LLMServiceCredentialTests {

    /// 这一条是整次重构的防复发钉子。
    @Test("注入的 Key 就是校验用的 Key —— 不再看 bundle")
    func injectedKeyIsTheOneValidated() {
        // bundle 里现在没有任何 api_config.json，改造前 `LLMService(apiKey:)`
        // 在这个前提下会抛 apiKeyNotConfigured —— 因为 guard 看的是静态值。
        #expect(!LLMService(keyStore: InMemoryAPIKeyStore(initial: nil)).isAPIKeyConfigured)
        #expect(!LLMService(keyStore: InMemoryAPIKeyStore(initial: "")).isAPIKeyConfigured)
        #expect(LLMService(keyStore: InMemoryAPIKeyStore(initial: "sk-abc")).isAPIKeyConfigured)
        // 占位符同样不算配置好，与写路径的 validate 口径一致。
        #expect(!LLMService(keyStore: InMemoryAPIKeyStore(initial: "sk-your-x")).isAPIKeyConfigured)
    }

    @Test("改完 Key 立刻生效，不需要重建 LLMService")
    func keyIsResolvedPerRequest() throws {
        // 这是「App 里三处共用一个实例、且用户在设置页改完 Key 无需重启」这条
        // 需求的唯一自动化守卫：如果哪天有人把 activeAPIKey 改回 init 快照，
        // 这条会立刻变红。
        let store = InMemoryAPIKeyStore(initial: "")
        let service = LLMService(keyStore: store)
        #expect(!service.isAPIKeyConfigured)

        try store.save("sk-live")
        #expect(service.isAPIKeyConfigured)

        try store.clear()
        #expect(!service.isAPIKeyConfigured)
    }

    @Test("未配置 Key 时拒绝发请求")
    func rejectsRequestWithoutKey() async {
        let service = LLMService(keyStore: InMemoryAPIKeyStore(initial: nil))
        await #expect(throws: LLMServiceError.self) {
            try await service.verifyCredentials()
        }
    }
}

// MARK: - isTerminal

@Suite("错误可重试性")
struct LLMServiceErrorTests {

    @Test("鉴权与配额错误不可重试，429 与 5xx 可重试")
    func terminalClassification() {
        #expect(LLMServiceError.apiKeyNotConfigured.isTerminal)
        #expect(LLMServiceError.httpError(statusCode: 401, body: nil).isTerminal)
        #expect(LLMServiceError.httpError(statusCode: 402, body: nil).isTerminal)
        #expect(LLMServiceError.httpError(statusCode: 403, body: nil).isTerminal)

        // 429 明确是「稍后再来」，重试是对的 —— 把它归进 terminal 会让
        // 限流场景直接失败。
        #expect(!LLMServiceError.httpError(statusCode: 429, body: nil).isTerminal)
        #expect(!LLMServiceError.httpError(statusCode: 500, body: nil).isTerminal)
        #expect(!LLMServiceError.httpError(statusCode: 503, body: nil).isTerminal)
        #expect(!LLMServiceError.timeout.isTerminal)
        #expect(!LLMServiceError.parseError("x").isTerminal)
    }
}

// MARK: - Keychain

@Suite("Keychain 往返")
struct KeychainAPIKeyStoreTests {

    @Test("写入 / 覆盖 / 删除")
    func roundTrip() throws {
        // 用 UUID 作 account，**绝不碰真实的 `deepseek.apiKey.v1`** ——
        // 单测跑在宿主 App 里（`TEST_HOST = Songly.app`），这是唯一的隔离手段。
        let store = KeychainAPIKeyStore(account: "test.\(UUID().uuidString)")
        defer { try? store.clear() }

        #expect(store.load() == nil)

        try store.save("sk-first")
        #expect(store.load() == "sk-first")

        // 覆盖：验证 save 内部「先 clear 再 add」真的成立 —— 直接 SecItemAdd
        // 在这里会返回 errSecDuplicateItem。
        try store.save("sk-second")
        #expect(store.load() == "sk-second")

        try store.clear()
        #expect(store.load() == nil)
        // 幂等：删一个不存在的条目不该抛。
        try store.clear()
    }
}
