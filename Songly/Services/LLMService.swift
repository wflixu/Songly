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
            return "API Key 未配置"
        case .timeout:
            return "AI 服务响应超时"
        case .httpError(let code, _):
            return "AI 服务返回错误 (HTTP \(code))"
        case .parseError:
            return "AI 响应解析失败"
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
}

// MARK: - DeepSeek API Client

final class LLMService: LLMServiceProtocol {
    private let session: URLSession
    private let apiKey: String

    init(apiKey: String = AppEnvironment.deepseekAPIKey) {
        self.apiKey = apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.requestTimeout
        config.timeoutIntervalForResource = AppConfig.requestTimeout + 5
        self.session = URLSession(configuration: config)
    }

    // MARK: - Seed API (v3)

    func requestSeeds(_ request: SeedRequest) async throws -> SeedResponse {
        guard AppEnvironment.isAPIKeyConfigured else {
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
        guard AppEnvironment.isAPIKeyConfigured else {
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
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
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
