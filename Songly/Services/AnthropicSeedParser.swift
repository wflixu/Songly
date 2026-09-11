//
//  AnthropicSeedParser.swift
//  Songly
//
//  把 DeepSeek Anthropic 兼容端点的响应解析成 `SeedResponse`。
//
//  纯函数、无网络 —— 这是唯一需要覆盖 LLM 响应形状的地方，所以刻意从传输层
//  拆出来，可以拿固定 fixture 完整单测。
//

import Foundation

enum AnthropicSeedParserError: LocalizedError, Equatable {
    case notJSON(String)
    case serverError(String)
    case noToolUse(String)

    var errorDescription: String? {
        switch self {
        case .notJSON: return "AI 响应不是合法 JSON"
        case .serverError: return "AI 服务返回错误"
        case .noToolUse: return "AI 响应里没有 return_seeds 工具调用"
        }
    }
}

enum AnthropicSeedParser {

    static func parse(_ data: Data) throws -> SeedResponse {
        let raw = String(data: data, encoding: .utf8) ?? ""

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicSeedParserError.notJSON(String(raw.prefix(300)))
        }

        // 网关层有时会以 200 + error 体返回失败，先认出来，别当成"没解析到工具调用"。
        if let error = json["error"] {
            throw AnthropicSeedParserError.serverError(describe(error))
        }

        let stopReason = json["stop_reason"] as? String
        let usage = parseUsage(json["usage"])

        // 遍历**全部** content block，而不是取第一个 text block。
        // `disable_parallel_tool_use` 会被服务端忽略，所以一个回合里出现多个
        // `tool_use` 是正常情况；工具调用前面也可能插入 `thinking` / `text` block，
        // 都要静默跳过。
        var seeds: [RecommendationSeed] = []
        var toolCalls: [SeedToolCall] = []

        for block in (json["content"] as? [[String: Any]]) ?? [] {
            guard (block["type"] as? String) == "tool_use",
                  (block["name"] as? String) == SeedToolSchema.name,
                  let id = block["id"] as? String,
                  let input = block["input"] else { continue }

            // 每个 tool_use 都必须能被回显 —— 缺了 input 就没法构造下一轮请求，
            // 丢掉它会让后续 `tool_result` 数量对不上直接 400。
            guard let inputJSON = try? JSONSerialization.data(withJSONObject: input) else { continue }

            toolCalls.append(SeedToolCall(id: id, name: SeedToolSchema.name, inputJSON: inputJSON))
            seeds.append(contentsOf: decodeSeeds(from: input))
        }

        guard !toolCalls.isEmpty else {
            throw AnthropicSeedParserError.noToolUse(String(raw.prefix(300)))
        }

        return SeedResponse(
            seeds: seeds,
            toolCalls: toolCalls,
            // 截断时已解析的部分仍然可用，只是不足以凑满歌单 ——
            // 由补位轮去补，不要在这里当成失败。
            truncated: stopReason == "max_tokens",
            usage: usage
        )
    }

    /// 取出指定名字的工具调用 `input` 的原始 JSON 字节。
    ///
    /// 响应形状只在这一处解析 —— 口味画像与 seed 两条链路共用它，
    /// 免得两边各写一遍 block 扫描逻辑然后慢慢漂移。
    static func toolInput(in data: Data, named name: String) throws -> Data {
        let raw = String(data: data, encoding: .utf8) ?? ""

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicSeedParserError.notJSON(String(raw.prefix(300)))
        }
        if let error = json["error"] {
            throw AnthropicSeedParserError.serverError(describe(error))
        }

        for block in (json["content"] as? [[String: Any]]) ?? [] {
            guard (block["type"] as? String) == "tool_use",
                  (block["name"] as? String) == name,
                  let input = block["input"],
                  let inputJSON = try? JSONSerialization.data(withJSONObject: input) else { continue }
            return inputJSON
        }

        throw AnthropicSeedParserError.noToolUse(String(raw.prefix(300)))
    }

    // MARK: - Private

    /// 逐条解码，一条形状异常不连累其余 —— 模型偶尔会漏字段，
    /// 为了一条坏 seed 丢掉整轮输出不值得。
    private static func decodeSeeds(from input: Any) -> [RecommendationSeed] {
        guard let dict = input as? [String: Any],
              let rawSeeds = dict["seeds"] as? [[String: Any]] else { return [] }

        var result: [RecommendationSeed] = []
        result.reserveCapacity(min(rawSeeds.count, AppConfig.maxSeedsPerRound))

        for rawSeed in rawSeeds.prefix(AppConfig.maxSeedsPerRound) {
            guard let seedData = try? JSONSerialization.data(withJSONObject: rawSeed),
                  let seed = try? JSONDecoder().decode(RecommendationSeed.self, from: seedData) else {
                continue
            }
            result.append(seed)
        }
        return result
    }

    private static func parseUsage(_ raw: Any?) -> TokenUsage {
        guard let dict = raw as? [String: Any] else { return TokenUsage() }
        return TokenUsage(
            inputTokens: dict["input_tokens"] as? Int ?? 0,
            outputTokens: dict["output_tokens"] as? Int ?? 0,
            cacheReadTokens: dict["cache_read_input_tokens"] as? Int ?? 0,
            cacheCreationTokens: dict["cache_creation_input_tokens"] as? Int ?? 0
        )
    }

    private static func describe(_ error: Any) -> String {
        if let dict = error as? [String: Any], let message = dict["message"] as? String {
            return message
        }
        return String(describing: error).prefix(300).description
    }
}
