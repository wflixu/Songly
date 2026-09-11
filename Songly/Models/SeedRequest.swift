//
//  SeedRequest.swift
//  Songly
//
//  v3 的 LLM 契约：强制工具调用 `return_seeds` 的 schema、跨轮对话消息、响应信封。
//
//  为什么用强制工具调用而不是 JSON mode：DeepSeek 的 Anthropic 兼容端点**没有**
//  `response_format`（该字段在兼容矩阵里根本不存在）。工具调用的 `input` 到达时
//  已经是解析好的 JSON，比旧的「正则拆 `歌名 - 艺人` 文本行」健壮得多。
//

import Foundation

// MARK: - Tool Schema

/// `return_seeds` 工具的定义。
///
/// Schema 形状上有两个刻意的决定：
/// - **扁平、字段几乎全可选**，而不是 `oneOf` 判别联合 —— 跨模型鲁棒性差很多；
/// - **不写 `additionalProperties: false`** —— 各家对它的强制程度不一，
///   被拒一次就是白烧一整轮（约 40 秒）。
enum SeedToolSchema {
    static let name = "return_seeds"

    static let description = """
    返回本次歌单的候选线索。每个 seed 是一个明确的选曲意图；系统会在 Apple Music \
    曲库里把它解析成真实可播放的曲目。只通过本工具输出，不要输出任何解释文本。
    """

    /// 注意：`minItems` / `maxItems` 只是提示，服务端不一定强制 ——
    /// 解析器一律会 clamp 到 `AppConfig.maxSeedsPerRound`，不能依赖服务端校验。
    static func inputSchema() -> [String: Any] {
        let seedProperties: [String: Any] = [
            "artist": [
                "type": "string",
                "description": "艺人名（必填），尽量用 Apple Music 上的官方写法",
            ],
            "album": [
                "type": "string",
                "description": "专辑名。填了就从这张专辑里挑曲目，能挖到非主打歌",
            ],
            "title": [
                "type": "string",
                "description": "歌曲名。只在很确定时填；填了就按这首歌精确匹配",
            ],
            "kind": [
                "type": "string",
                "enum": ["track", "album", "artist"],
                "description": "track=明确一首歌；album=从这张专辑里挑；artist=给我这位艺人的曲目",
            ],
            "tier": [
                "type": "string",
                "enum": DiscoveryTier.allCases.map(\.rawValue),
                "description": "confident=大概率喜欢；fresh=可能喜欢但带点新鲜感；bold=大胆探索",
            ],
            "reason": [
                "type": "string",
                "description": "一句话中文说明为什么适合此刻，不超过 30 字",
            ],
            "wants": [
                "type": "integer",
                "minimum": 1,
                "maximum": AppConfig.maxTracksPerAlbum,
                "description": "kind=album/artist 时希望取几首，默认 1",
            ],
            "language": [
                "type": "string",
                "enum": ["zh", "en", "ja", "ko", "other", "instrumental"],
            ],
            "era": [
                "type": "string",
                "description": "如 1990s / 2000s / 2010s / 2020s",
            ],
        ]

        let seedItems: [String: Any] = [
            "type": "object",
            "properties": seedProperties,
            "required": ["artist", "tier", "reason", "kind"],
        ]

        let seeds: [String: Any] = [
            "type": "array",
            "items": seedItems,
        ]

        return [
            "type": "object",
            "properties": ["seeds": seeds],
            "required": ["seeds"],
        ]
    }
}

// MARK: - Tool Call

/// 一轮响应里的一个 `tool_use` block。
struct SeedToolCall: Sendable, Equatable {
    let id: String
    let name: String
    /// `input` 的原始 JSON 字节。回显给服务端时必须**原样**回填 ——
    /// 不要经类型化 struct 重新编码（浮点格式差异可能触发严格校验）。
    let inputJSON: Data
}

// MARK: - Conversation Message

/// 本管线用到的三种对话消息形态。
///
/// 之所以能这么做多轮，是因为 DeepSeek 的 Anthropic 兼容路径是**唯一**
/// 允许在对话中途插入 `tool_result` 的接口（Chat Completions 不允许）。
enum SeedMessage: Sendable, Equatable {
    /// 第 1 轮的用户消息（情境 + 收藏抽样 + 排除清单 + 本次任务）。
    case user(String)
    /// 回显上一轮助手的工具调用。**必须把该轮所有调用都回填** ——
    /// Anthropic 要求每个 `tool_use` 都必须有对应的 `tool_result`。
    case assistantToolCalls([SeedToolCall])
    /// 工具结果 + 紧跟一条差量指令。
    /// `tool_result` **必须是 content 数组的第一块**，这是接口要求。
    case toolResults(toolUseIDs: [String], content: String, followUp: String?)

    /// 序列化成 Anthropic `messages` 数组的一个元素。
    var json: [String: Any] {
        switch self {
        case .user(let text):
            return ["role": "user", "content": text]

        case .assistantToolCalls(let calls):
            let blocks: [[String: Any]] = calls.map { call in
                let input = (try? JSONSerialization.jsonObject(with: call.inputJSON))
                    ?? [String: Any]()
                return ["type": "tool_use", "id": call.id, "name": call.name, "input": input]
            }
            return ["role": "assistant", "content": blocks]

        case .toolResults(let toolUseIDs, let content, let followUp):
            var blocks: [[String: Any]] = toolUseIDs.map { id in
                ["type": "tool_result", "tool_use_id": id, "content": content]
            }
            if let followUp, !followUp.isEmpty {
                blocks.append(["type": "text", "text": followUp])
            }
            return ["role": "user", "content": blocks]
        }
    }
}

// MARK: - Request

struct SeedRequest: Sendable, Equatable {
    /// 跨轮**且跨天**字节稳定的 system 前缀（画像 + 硬性规则）。
    ///
    /// **绝不能在 `system` 里放任何随时间变化的东西**（时间戳、场景、日期）——
    /// DeepSeek 的前缀缓存是自动生效的，任何一个字节变了整段缓存就失效，
    /// 输入价差约 50 倍。日期 / 小时 / 场景一律只放在 user 消息里。
    var system: String
    var messages: [SeedMessage]

    init(system: String, userMessage: String) {
        self.system = system
        self.messages = [.user(userMessage)]
    }

    /// 追加一轮：回显上一轮的 `tool_use`，再给出缺口结果与差量指令。
    mutating func appendRound(
        previous: SeedResponse,
        outcomeJSON: String,
        instruction: String
    ) {
        messages.append(.assistantToolCalls(previous.toolCalls))
        messages.append(.toolResults(
            toolUseIDs: previous.toolCalls.map(\.id),
            content: outcomeJSON,
            followUp: instruction
        ))
    }
}

// MARK: - Response

struct SeedResponse: Sendable, Equatable {
    var seeds: [RecommendationSeed]
    /// 本轮所有 `tool_use` 调用。回显时必须全部带回并逐一给出 `tool_result`。
    var toolCalls: [SeedToolCall]
    /// `stop_reason == "max_tokens"` —— 输出被截断，已解析的部分仍然可用。
    var truncated: Bool
    var usage: TokenUsage

    /// 便于调用方判断"这轮有没有拿到东西"。
    var isEmpty: Bool { seeds.isEmpty }
}

/// 用量。字段名按 Anthropic 兼容路径的实际返回（探测 P-8 确认）——
/// 是 `cache_read_input_tokens`，**不是** DeepSeek 原生的 `prompt_cache_hit_tokens`。
struct TokenUsage: Sendable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
}
