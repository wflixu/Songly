//
//  APIKeyStore.swift
//  Songly
//
//  DeepSeek API Key 的持久化与校验策略。
//
//  用 Keychain 而不是 `UserDefaults`（`TasteProfileStore` 的选择）：画像丢了
//  重算一次就行，而 API Key 是**用户的凭据** —— 明文躺在 plist 里，设备备份和
//  文件系统访问都能读到，泄漏的后果由用户承担。两者的取舍不同，所以存法不同。
//
//  改造前这套东西的注入方式是构建期脚本读 `api_key.env` 生成 `api_config.json`
//  打进 bundle。那条路已经废弃：它把开发者的 Key 发给了每一个用户，而且
//  `INFOPLIST_KEY_DEEPSEEK_API_KEY` 让 Key 出现在 Release 的 Info.plist 里，
//  可以被 `strings` 从 IPA 提取。
//

import Foundation
import Security

// MARK: - Protocol

protocol APIKeyStoring: Sendable {
    /// 当前存储的 Key。未配置、读取失败都返回 `nil` —— 读路径不该抛。
    func load() -> String?

    /// 覆盖写入。**失败必须抛**：设置页要如实告诉用户「没存上」，
    /// 不能像 `TasteProfileStore.save` 那样静默 return —— 那会让用户以为
    /// 存好了，直到下次生成才以「Key 未配置」的形式发现。
    func save(_ key: String) throws

    /// 删除。不存在不算错误。
    func clear() throws
}

// MARK: - Errors

enum APIKeyStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串操作失败（\(status)：\(message)）"
        case .encodingFailed:
            return "Key 无法编码为 UTF-8"
        }
    }
}

// MARK: - Keychain Implementation

/// 与 `TasteProfileStore` 的关键差异：**这里用 struct，不用 `@unchecked Sendable` class**。
///
/// 两个属性都是 `let String`，编译器能自己证明 `Sendable`，不需要 `@unchecked`
/// 这个逃生舱 —— 而 Keychain API 本身是线程安全的。用 class 只会白白丢掉这层验证。
struct KeychainAPIKeyStore: APIKeyStoring {
    /// 带版本命名，与 `TasteProfileStore.defaultKey = "songly.tasteProfile.v1"` 同一约定：
    /// 将来换服务商（或换 Key 的形态）时改 account 即可并存，不用做数据迁移。
    static let defaultService = "cn.wflixu.Songly.credentials"
    static let defaultAccount = "deepseek.apiKey.v1"

    private let service: String
    private let account: String

    init(service: String = Self.defaultService, account: String = Self.defaultAccount) {
        self.service = service
        self.account = account
    }

    /// 定位条目用的基础 query。
    ///
    /// `kSecAttrService` / `kSecAttrAccount` 是可注入的，单测据此用 `test.<UUID>`
    /// 建隔离条目 —— 单测跑在宿主 App 里（`TEST_HOST = Songly.app`），不隔离就会
    /// 读写到开发者的真实 Key。
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        // 包括 errSecItemNotFound 在内的一切非成功状态都当作「没配」——
        // 读路径返回 nil 而不是抛错，调用方只需要回答「有没有 Key」。
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String) throws {
        guard let data = key.data(using: .utf8) else { throw APIKeyStoreError.encodingFailed }

        // 先删再加，而不是 `SecItemUpdate`：后者要先查询才能决定走 add 还是
        // update，两个分支都得处理 notFound，代码更多而收益为零。
        try clear()

        var query = baseQuery
        query[kSecValueData as String] = data
        // AfterFirstUnlock 而非 WhenUnlocked：App 有 `BGTaskScheduler` 每日后台
        // 预生成（`AppConfig.bgTaskIdentifier`），用 WhenUnlocked 的话手机锁屏时的
        // 后台唤醒会拿不到 Key，整个后台功能**静默**失效 —— 这正是
        // `SonglyApp.swift` 里记录过的那个「调度回调拿不到东西」的坑，
        // 不能在凭据这一层再犯一次。
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // ThisDeviceOnly：不同步 iCloud 钥匙串、不进加密备份。用户手打的 Key
        // 出现在他另一台设备或备份里都是意外行为，换机重填一次的代价更小。

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw APIKeyStoreError.unexpectedStatus(status) }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.unexpectedStatus(status)
        }
    }
}

// MARK: - Policy

enum APIKeyPolicyError: LocalizedError {
    case empty
    case placeholder

    var errorDescription: String? {
        switch self {
        case .empty: return "请填写 API Key"
        case .placeholder: return "这看起来是文档里的示例占位符，不是真实的 Key"
        }
    }
}

/// Key 的归一化与可用性判定。
///
/// **读路径与写路径都必须从这里取。** 改造前的 bug 就是两个判断分散在不同地方：
/// `LLMService` 的 guard 检查静态的 `AppEnvironment.isApiKeyConfigured`，而请求头
/// 用的是 init 时快照的另一个字符串，于是 `LLMService(apiKey: "真key")` 在 bundle
/// 无配置时照样抛 `apiKeyNotConfigured`。把判断收进一个 enum 是防止它重演的结构性
/// 手段，而不是风格偏好。
enum APIKeyPolicy {
    /// 粘贴常带换行/空格，必须归一化后再比较与存储。
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 明显不是 Key 的输入：空、以及文档示例里的 `sk-your-…` 占位符。
    static func isUsable(_ raw: String) -> Bool {
        let key = normalize(raw)
        return !key.isEmpty && !key.hasPrefix("sk-your")
    }

    /// 写路径用。抛错而不是返回 Bool，是为了让设置页能给出**具体**原因。
    ///
    /// 它保证了一条不变式：**Keychain 里只可能存着能用的 Key**。因此
    /// 「已存储」与「可用」不会出现中间态 —— 设置页显示「已配置」时，
    /// 请求路径必然也会认为已配置。
    static func validate(_ raw: String) throws -> String {
        let key = normalize(raw)
        guard !key.isEmpty else { throw APIKeyPolicyError.empty }
        guard !key.hasPrefix("sk-your") else { throw APIKeyPolicyError.placeholder }
        return key
    }
}
