//
//  LLMService.swift
//  Songly
//
//  DeepSeek API client for generating music recommendations.
//

import Foundation

// MARK: - Errors

enum LLMServiceError: LocalizedError {
    case apiKeyNotConfigured
    case timeout
    case httpError(statusCode: Int, body: String?)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .apiKeyNotConfigured:
            // 文案要说清「去哪里解决」。Key 现在由用户自己提供，这句话
            // 是他在整个 App 里唯一一次被告知该做什么。
            return "还没有配置 DeepSeek API Key，请在设置中填写"
        case .timeout:
            return "AI 服务响应超时"
        case .httpError(let code, _):
            return "AI 服务返回错误 (HTTP \(code))"
        case .parseError:
            return "AI 响应解析失败"
        }
    }
}

extension LLMServiceError {
    /// 重试不会让它变好：Key 缺失，以及 401/402/403 这类鉴权与配额错误。
    /// **429 除外** —— 它明确是「稍后再来」，重试是对的。
    ///
    /// 放在错误类型上而不是 `RecommendationEngine` 里，是因为画像刷新器也要用
    /// 同一个判断，而引擎那个是 `private static` 且在 actor 内。
    ///
    /// 改造前这里只认 `.apiKeyNotConfigured`，于是 `performRequest` 不重试的 4xx
    /// 到了 UI 层仍是 `retryable: true` —— 错误卡片会渲染出一个永远重试、永远
    /// 同样失败的「重试」按钮。Key 改由用户输入后，401 从「不可能发生」变成了
    /// 「新用户的第一次体验」，所以这个洞必须一起补上。
    var isTerminal: Bool {
        switch self {
        case .apiKeyNotConfigured:
            return true
        case .httpError(let code, _):
            return (400..<500).contains(code) && code != 429
        case .timeout, .parseError:
            return false
        }
    }
}

// MARK: - Protocol

/// 引擎依赖的抽象。
///
/// 原先 `LLMService` 是个**没有协议的 concrete class**，引擎在 LLM 这一层完全
/// 无法 mock —— 补位轮的状态机、以及"第 N 轮请求有没有正确回显第 N−1 轮的
/// `tool_use.id`"这类线格式 bug，都没法在没有真实网络请求的情况下验证。
protocol LLMServiceProtocol: Sendable {
    /// 发起一次 seed 请求。首轮与补位轮走的是同一个方法，
    /// 区别只在于 `request.messages` 里有没有历史轮次。
    func requestSeeds(_ request: SeedRequest) async throws -> SeedResponse

    /// 归纳用户的口味画像。频率很低（最多一周一次），不进每日路径。
    func requestTasteProfile(system: String, userMessage: String) async throws -> TasteProfilePayload

    /// 一次最小成本的连通性探测。**只给设置页用** —— 保存后告诉用户
    /// 「这把 Key 到底行不行」。
    ///
    /// 没有它，用户第一次知道自己打错了 Key 是在点「生成」之后，约 40 秒。
    /// 对自备 Key 的形态来说，这正是「门槛高」的主要来源。
    func verifyCredentials() async throws
}

// MARK: - DeepSeek API Client

final class LLMService: LLMServiceProtocol {
    private let session: URLSession
    /// 校验 Key 用的短超时会话 —— 不该让用户盯着 60 秒的转圈等一句「Key 对不对」。
    private let probeSession: URLSession
    private let keyStore: any APIKeyStoring

    /// 刻意**不给默认参数**：默认值就是 `AppEnvironment` 当初溜进来的那条缝，
    /// 一个「不用想也知道从哪来」的隐式来源。去掉它，编译器会把所有构造点
    /// 摊在明面上。
    init(keyStore: any APIKeyStoring) {
        self.keyStore = keyStore

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.requestTimeout
        config.timeoutIntervalForResource = AppConfig.requestTimeout + 5
        self.session = URLSession(configuration: config)

        let probe = URLSessionConfiguration.ephemeral
        probe.timeoutIntervalForRequest = AppConfig.keyProbeTimeout
        probe.timeoutIntervalForResource = AppConfig.keyProbeTimeout + 5
        self.probeSession = URLSession(configuration: probe)
    }

    // MARK: - Credentials

    /// **每次请求时向 store 求值**，不在 init 时快照。
    ///
    /// 原先 `private let apiKey` 是构造时固定的，用户在设置页改完 Key 不重启不生效；
    /// 更糟的是 guard 检查的是**静态** `AppEnvironment.isApiKeyConfigured`，与注入的
    /// 字符串毫无关系 —— `LLMService(apiKey: "真key")` 在 bundle 无配置时照样抛
    /// `apiKeyNotConfigured`。现在校验和请求头读的是同一个表达式，结构上不可能再漂移。
    ///
    /// 顺带：改造后这个类**完全无状态**（两个属性一个 `URLSession` 一个 store，
    /// 都是 Sendable），所以引擎（actor）与画像刷新器（`@MainActor`）并发共用
    /// 同一个实例是安全的。
    private var activeAPIKey: String {
        APIKeyPolicy.normalize(keyStore.load() ?? "")
    }

    /// internal 而非 private：这是「注入的 Key 与校验用的 Key 是否同源」唯一
    /// 能被单元测试断言的地方，不用真的联网。
    var isAPIKeyConfigured: Bool {
        APIKeyPolicy.isUsable(activeAPIKey)
    }

    // MARK: - Seed API (v3)

    func requestSeeds(_ request: SeedRequest) async throws -> SeedResponse {
        guard isAPIKeyConfigured else {
            throw LLMServiceError.apiKeyNotConfigured
        }

        let body = try buildSeedRequestBody(request)
        let data = try await performRequest(body: body)

        do {
            return try AnthropicSeedParser.parse(data)
        } catch {
            throw LLMServiceError.parseError(error.localizedDescription)
        }
    }

    /// 生成口味画像。走的是同一个传输层，只是换一个工具 schema。
    func requestTasteProfile(system: String, userMessage: String) async throws -> TasteProfilePayload {
        guard isAPIKeyConfigured else {
            throw LLMServiceError.apiKeyNotConfigured
        }

        let body = try JSONSerialization.data(withJSONObject: buildToolBody(
            system: system,
            toolName: TasteProfileToolSchema.name,
            toolDescription: TasteProfileToolSchema.description,
            inputSchema: TasteProfileToolSchema.inputSchema(),
            messages: [["role": "user", "content": userMessage]]
        ))

        let data = try await performRequest(body: body)

        do {
            let inputJSON = try AnthropicSeedParser.toolInput(in: data, named: TasteProfileToolSchema.name)
            return try JSONDecoder().decode(TasteProfilePayload.self, from: inputJSON)
        } catch {
            throw LLMServiceError.parseError(error.localizedDescription)
        }
    }

    // MARK: - Credential Probe

    func verifyCredentials() async throws {
        guard isAPIKeyConfigured else { throw LLMServiceError.apiKeyNotConfigured }

        // 刻意不复用 `buildToolBody`：它硬编码了 tools + tool_choice，为了验证
        // 一把 Key 而走一遍强制工具调用是多余的。也刻意不复用 `session` ——
        // 见 `AppConfig.keyProbeTimeout`。
        let body = try JSONSerialization.data(withJSONObject: [
            "model": AppConfig.deepseekModel,
            "max_tokens": AppConfig.keyProbeMaxTokens,
            "thinking": ["type": "disabled"],
            "messages": [["role": "user", "content": "hi"]],
        ])

        var request = URLRequest(url: URL(string: AppConfig.deepseekBaseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(activeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = body

        // 不重试：校验失败就是失败，重试只会让用户多等两轮退避。
        // 网络层的错误原样抛给调用方，由它区分「Key 有问题」与「网线有问题」。
        let (data, response) = try await probeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMServiceError.httpError(statusCode: -1, body: nil)
        }
        guard http.statusCode == 200 else {
            throw LLMServiceError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }
    }

    /// 内部可见而非 private：请求体的形状是容易静默出错的地方（模型 ID 写成
    /// 已退役的名字、忘记加 `tool_choice`、把 thinking 打开），值得直接测。
    func buildSeedRequestBody(_ request: SeedRequest) throws -> Data {
        try JSONSerialization.data(withJSONObject: buildToolBody(
            system: request.system,
            toolName: SeedToolSchema.name,
            toolDescription: SeedToolSchema.description,
            inputSchema: SeedToolSchema.inputSchema(),
            messages: request.messages.map(\.json)
        ))
    }

    /// 强制工具调用的请求体。seed 与画像共用 —— 两者唯一的差别就是工具 schema。
    func buildToolBody(
        system: String,
        toolName: String,
        toolDescription: String,
        inputSchema: [String: Any],
        messages: [[String: Any]]
    ) -> [String: Any] {
        [
            "model": AppConfig.deepseekModel,
            "max_tokens": AppConfig.llmMaxOutputTokens,
            // 强制 tool_choice 与 thinking 不能同时开（服务端返回 400），
            // 所以这里必须是 disabled。
            "thinking": ["type": "disabled"],
            "system": system,
            "tools": [[
                "name": toolName,
                "description": toolDescription,
                "input_schema": inputSchema,
            ]],
            "tool_choice": ["type": "tool", "name": toolName],
            "messages": messages,
        ]
    }

    // MARK: - Transport

    private func performRequest(body: Data) async throws -> Data {
        let url = URL(string: AppConfig.deepseekBaseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(activeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = body

        // Retry with exponential backoff
        var lastError: Error?
        for attempt in 0..<AppConfig.maxRetries {
            if attempt > 0 {
                let delay = AppConfig.retryDelays[min(attempt - 1, AppConfig.retryDelays.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastError = LLMServiceError.httpError(statusCode: -1, body: nil)
                    continue
                }

                switch httpResponse.statusCode {
                case 200:
                    return data
                case 400..<500:
                    // Client error — don't retry
                    let body = String(data: data, encoding: .utf8)
                    throw LLMServiceError.httpError(statusCode: httpResponse.statusCode, body: body)
                default:
                    lastError = LLMServiceError.httpError(statusCode: httpResponse.statusCode, body: nil)
                    continue
                }
            } catch {
                lastError = error
                if error is LLMServiceError {
                    throw error // Don't retry client errors
                }
                continue
            }
        }

        throw lastError ?? LLMServiceError.timeout
    }
}
