//
//  LLMContractTests.swift
//  SonglyTests
//
//  LLM 契约层：响应解析 + 多轮对话的线格式。
//
//  这一层值得单独测，是因为它有两个特点：
//  1. 服务端的形状容忍度很低 —— 一个字段对不上就是整轮 40 秒白烧；
//  2. 真实请求要花钱、要联网，靠"跑一次试试"来验证代价太高。
//

import Foundation
import Testing
@testable import Songly

// MARK: - Fixtures

/// 测试夹具：构造失败说明测试基础设施本身坏了，用 `try!` 让它在那一行就炸。
private func anthropicResponse(
    content: [[String: Any]],
    stopReason: String = "tool_use",
    usage: [String: Any]? = nil
) -> Data {
    var body: [String: Any] = [
        "id": "msg_test",
        "type": "message",
        "role": "assistant",
        "model": "deepseek-flash",
        "stop_reason": stopReason,
        "content": content,
    ]
    if let usage { body["usage"] = usage }
    return try! JSONSerialization.data(withJSONObject: body)
}

private func toolUseBlock(
    id: String = "call_test_1",
    seeds: [[String: Any]]
) -> [String: Any] {
    [
        "type": "tool_use",
        "id": id,
        "name": SeedToolSchema.name,
        "input": ["seeds": seeds],
    ]
}

private func seed(
    artist: String = "某艺人",
    title: String? = nil,
    album: String? = nil,
    tier: String = "confident",
    kind: String = "artist",
    reason: String = "测试"
) -> [String: Any] {
    var dict: [String: Any] = ["artist": artist, "tier": tier, "kind": kind, "reason": reason]
    if let title { dict["title"] = title }
    if let album { dict["album"] = album }
    return dict
}

// MARK: - Parser

@Suite("AnthropicSeedParser")
struct AnthropicSeedParserTests {

    @Test("从 tool_use block 解析出 seed 与调用信息")
    func parsesToolUseBlock() throws {
        let data = anthropicResponse(content: [
            toolUseBlock(seeds: [
                seed(artist: "周杰伦", title: "晴天", tier: "confident", kind: "track"),
                seed(artist: "王菲", album: "寓言", tier: "fresh", kind: "album"),
            ]),
        ])

        let response = try AnthropicSeedParser.parse(data)

        #expect(response.seeds.count == 2)
        #expect(response.seeds[0].artist == "周杰伦")
        #expect(response.seeds[0].tier == .confident)
        #expect(response.seeds[0].kind == .track)
        #expect(response.seeds[1].tier == .fresh)
        #expect(response.seeds[1].kind == .album)
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].id == "call_test_1")
        #expect(!response.truncated)
    }

    @Test("多个 tool_use block 全部保留 —— 少一个就会 400")
    func parsesMultipleToolUseBlocks() throws {
        // 服务端会忽略 disable_parallel_tool_use，一个回合里出现多个工具调用是
        // 正常情况。回显时必须全部带回，否则 tool_use 与 tool_result 数量对不上。
        let data = anthropicResponse(content: [
            toolUseBlock(id: "call_a", seeds: [seed(artist: "A")]),
            toolUseBlock(id: "call_b", seeds: [seed(artist: "B", tier: "bold")]),
        ])

        let response = try AnthropicSeedParser.parse(data)

        #expect(response.seeds.count == 2)
        #expect(response.toolCalls.map(\.id) == ["call_a", "call_b"])
    }

    @Test("thinking / text block 被静默跳过")
    func skipsNonToolBlocks() throws {
        let data = anthropicResponse(content: [
            ["type": "thinking", "thinking": "让我想想……"],
            ["type": "text", "text": "我先想想"],
            toolUseBlock(seeds: [seed()]),
        ])

        let response = try AnthropicSeedParser.parse(data)

        #expect(response.seeds.count == 1)
        #expect(response.toolCalls.count == 1)
    }

    @Test("stop_reason=max_tokens 标记为截断，而不是当成失败")
    func marksTruncation() throws {
        let data = anthropicResponse(
            content: [toolUseBlock(seeds: [seed()])],
            stopReason: "max_tokens"
        )

        let response = try AnthropicSeedParser.parse(data)

        #expect(response.truncated)
        // 被截断时已解析的部分仍然可用 —— 缺口交给补位轮去补。
        #expect(response.seeds.count == 1)
    }

    @Test("缓存用量按 Anthropic 兼容路径的字段名读取")
    func readsCacheUsage() throws {
        // 探测 P-8 确认：这条路径返回的是 cache_read_input_tokens，
        // 而不是 DeepSeek 原生的 prompt_cache_hit_tokens。
        let data = anthropicResponse(
            content: [toolUseBlock(seeds: [])],
            usage: [
                "input_tokens": 422,
                "output_tokens": 431,
                "cache_read_input_tokens": 300,
                "cache_creation_input_tokens": 12,
            ]
        )

        let response = try AnthropicSeedParser.parse(data)

        #expect(response.usage.inputTokens == 422)
        #expect(response.usage.outputTokens == 431)
        #expect(response.usage.cacheReadTokens == 300)
        #expect(response.usage.cacheCreationTokens == 12)
    }

    @Test("没有 tool_use 时抛错")
    func throwsWithoutToolUse() {
        let data = anthropicResponse(
            content: [["type": "text", "text": "我不干"]],
            stopReason: "end_turn"
        )
        #expect(throws: AnthropicSeedParserError.self) {
            try AnthropicSeedParser.parse(data)
        }
    }

    @Test("200 + error 体被识别为服务端错误，而不是解析失败")
    func recognizesErrorBody() {
        let data = try! JSONSerialization.data(
            withJSONObject: ["error": ["message": "rate limited"]]
        )
        #expect(throws: AnthropicSeedParserError.serverError("rate limited")) {
            try AnthropicSeedParser.parse(data)
        }
    }

    @Test("未知 tier / kind 走宽松回退，不丢整条 seed")
    func lenientDecoding() throws {
        let data = anthropicResponse(content: [
            toolUseBlock(seeds: [
                [
                    "artist": "某艺人",
                    "tier": "某个没见过的档位",
                    "kind": "???",
                    "reason": "模型没守 schema",
                ],
            ]),
        ])

        let response = try AnthropicSeedParser.parse(data)

        #expect(response.seeds.count == 1)
        #expect(response.seeds[0].tier == .confident)  // 未知 tier 的兜底
        #expect(response.seeds[0].kind == .artist)     // 没给 title/album → artist
    }

    @Test("缺少 artist 的坏 seed 被跳过，其余不受影响")
    func skipsMalformedSeed() throws {
        let data = anthropicResponse(content: [
            toolUseBlock(seeds: [
                ["tier": "confident", "kind": "artist", "reason": "没有 artist 字段"],
                seed(artist: "B", tier: "fresh"),
            ]),
        ])

        let response = try AnthropicSeedParser.parse(data)

        #expect(response.seeds.count == 1)
        #expect(response.seeds[0].artist == "B")
    }
}

// MARK: - Wire Format

@Suite("SeedRequest 线格式")
struct SeedRequestWireFormatTests {

    /// 这是那个「不写测试就得花一次真实 400 才能发现」的 bug：
    /// 第 N 轮必须回显第 N−1 轮**原样**的 `tool_use.id` 与 `input`。
    @Test("补位轮回显上一轮的 tool_use.id 与原始 input")
    func appendRoundEchoesPreviousToolUse() throws {
        let originalInput: [String: Any] = ["seeds": [["artist": "A", "tier": "confident"]]]
        let originalJSON = try JSONSerialization.data(withJSONObject: originalInput)
        let previous = SeedResponse(
            seeds: [],
            toolCalls: [SeedToolCall(id: "call_abc", name: SeedToolSchema.name, inputJSON: originalJSON)],
            truncated: false,
            usage: TokenUsage()
        )

        var request = SeedRequest(system: "S", userMessage: "第一次")
        request.appendRound(previous: previous, outcomeJSON: #"{"need":2}"#, instruction: "再补 2 条")

        #expect(request.messages.count == 3)

        guard case .assistantToolCalls(let calls) = request.messages[1] else {
            Issue.record("第二条消息应该是 assistantToolCalls")
            return
        }
        #expect(calls.map(\.id) == ["call_abc"])
        #expect(calls[0].inputJSON == originalJSON)

        guard case .toolResults(let ids, let content, let followUp) = request.messages[2] else {
            Issue.record("第三条消息应该是 toolResults")
            return
        }
        #expect(ids == ["call_abc"])
        #expect(content == #"{"need":2}"#)
        #expect(followUp == "再补 2 条")
    }

    @Test("多个 tool_use 时逐一给出 tool_result")
    func oneResultPerToolUse() {
        let previous = SeedResponse(
            seeds: [],
            toolCalls: [
                SeedToolCall(id: "a", name: SeedToolSchema.name, inputJSON: Data("{}".utf8)),
                SeedToolCall(id: "b", name: SeedToolSchema.name, inputJSON: Data("{}".utf8)),
            ],
            truncated: false,
            usage: TokenUsage()
        )

        var request = SeedRequest(system: "S", userMessage: "x")
        request.appendRound(previous: previous, outcomeJSON: "{}", instruction: "y")

        guard case .toolResults(let ids, _, _) = request.messages[2] else {
            Issue.record("第三条消息应该是 toolResults")
            return
        }
        #expect(ids == ["a", "b"])
    }

    @Test("tool_result 在序列化后必须排在文本块之前")
    func toolResultBlockComesFirst() {
        let message = SeedMessage.toolResults(toolUseIDs: ["call_1"], content: "{}", followUp: "继续")
        let blocks = message.json["content"] as? [[String: Any]]

        #expect(blocks?.first?["type"] as? String == "tool_result")
        #expect(blocks?.count == 2)
        #expect(blocks?.last?["type"] as? String == "text")
    }

    @Test("没有差量指令时不追加空的 text 块")
    func omitsEmptyFollowUp() {
        let message = SeedMessage.toolResults(toolUseIDs: ["call_1"], content: "{}", followUp: nil)
        let blocks = message.json["content"] as? [[String: Any]]
        #expect(blocks?.count == 1)
    }

    @Test("assistant 回合的 input 原样回填，不经类型化重编码")
    func assistantInputIsEchoedVerbatim() {
        let json = Data(#"{"seeds":[{"wants":2}]}"#.utf8)
        let message = SeedMessage.assistantToolCalls([
            SeedToolCall(id: "c", name: SeedToolSchema.name, inputJSON: json),
        ])

        let content = message.json["content"] as? [[String: Any]]
        let input = content?.first?["input"] as? [String: Any]
        let seeds = input?["seeds"] as? [[String: Any]]

        #expect(seeds?.first?["wants"] as? Int == 2)
    }
}

// MARK: - Request Body

@Suite("请求体形状")
struct SeedRequestBodyTests {

    private func body(_ service: LLMService, system: String = "S", user: String = "U") throws -> [String: Any] {
        let data = try service.buildSeedRequestBody(SeedRequest(system: system, userMessage: user))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("模型 ID 必须是当前计费的 deepseek-flash")
    func usesCurrentModelID() throws {
        // `deepseek-v4-flash` 已被官方退役 —— 它还能路由，但那是未文档化的
        // 兜底行为。这条断言就是防止它悄悄回退到旧值。
        let json = try body(LLMService(keyStore: InMemoryAPIKeyStore(initial: nil)))
        #expect(json["model"] as? String == "deepseek-flash")
        #expect(AppConfig.deepseekModel == "deepseek-flash")
    }

    @Test("输出上限不再是 1000")
    func raisesOutputCeiling() throws {
        // 旧值 1000 只够 25–40 行歌名，是「歌单长度不稳定」的直接原因之一。
        let json = try body(LLMService(keyStore: InMemoryAPIKeyStore(initial: nil)))
        #expect(json["max_tokens"] as? Int == AppConfig.llmMaxOutputTokens)
        #expect((json["max_tokens"] as? Int ?? 0) >= 8000)
    }

    @Test("强制工具调用，且 thinking 必须关闭")
    func forcesToolChoice() throws {
        // 服务端在「强制 tool_choice + thinking 开启」时返回 400，
        // 这两项是绑定的，改一个就会整体失效。
        let json = try body(LLMService(keyStore: InMemoryAPIKeyStore(initial: nil)))

        let thinking = json["thinking"] as? [String: Any]
        #expect(thinking?["type"] as? String == "disabled")

        let choice = json["tool_choice"] as? [String: Any]
        #expect(choice?["type"] as? String == "tool")
        #expect(choice?["name"] as? String == SeedToolSchema.name)

        let tools = json["tools"] as? [[String: Any]]
        #expect(tools?.count == 1)
        #expect(tools?.first?["name"] as? String == SeedToolSchema.name)
        #expect(tools?.first?["input_schema"] != nil)
    }

    @Test("system 与 messages 原样透传")
    func passesThroughSystemAndMessages() throws {
        let json = try body(LLMService(keyStore: InMemoryAPIKeyStore(initial: nil)), system: "画像在这里", user: "任务在这里")
        #expect(json["system"] as? String == "画像在这里")

        let messages = json["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?.first?["role"] as? String == "user")
        #expect(messages?.first?["content"] as? String == "任务在这里")
    }
}
