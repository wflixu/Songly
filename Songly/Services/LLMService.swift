//
//  LLMService.swift
//  Songly
//
//  DeepSeek API client for generating music recommendations.
//  Includes MockLLMService for development and testing.
//

import Foundation

// MARK: - Errors

enum LLMServiceError: LocalizedError {
    case apiKeyNotConfigured
    case timeout
    case httpError(statusCode: Int, body: String?)
    case parseError(String)
    case tooFewRecommendations(count: Int)

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
        case .tooFewRecommendations(let count):
            return "推荐结果不足 (仅 \(count) 首)"
        }
    }
}

// MARK: - Protocol

protocol LLMServiceProtocol: Sendable {
    /// Generate music recommendations from a prompt.
    func recommend(prompt: String) async throws -> [TrackItem]

    /// Quick health check (minimal API call).
    func healthCheck() async -> Bool
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

    func recommend(prompt: String) async throws -> [TrackItem] {
        guard AppEnvironment.isAPIKeyConfigured else {
            throw LLMServiceError.apiKeyNotConfigured
        }

        let body = try buildRequestBody(prompt: prompt)
        let data = try await performRequest(body: body)
        return try parseResponse(data: data)
    }

    func healthCheck() async -> Bool {
        do {
            let items = try await recommend(prompt: "推荐 1 首歌")
            return !items.isEmpty
        } catch {
            return false
        }
    }

    // MARK: - Private

    private func buildRequestBody(prompt: String) throws -> Data {
        let requestBody: [String: Any] = [
            "model": AppConfig.deepseekModel,
            "max_tokens": 1000,
            "system": "你是一个专业音乐推荐专家。只输出歌曲列表，每行格式「歌名 - 艺人名」，不输出任何额外说明。",
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        return try JSONSerialization.data(withJSONObject: requestBody)
    }

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

    // MARK: - Response Parsing

    private func parseResponse(data: Data) throws -> [TrackItem] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]],
              let firstBlock = contentArray.first,
              let content = firstBlock["text"] as? String
        else {
            throw LLMServiceError.parseError("Unexpected JSON structure")
        }

        let items = parseTrackList(from: content)
        guard items.count >= AppConfig.minTrackCount else {
            throw LLMServiceError.tooFewRecommendations(count: items.count)
        }

        return items
    }

    /// Parse LLM text output into [TrackItem], handling various formats.
    private func parseTrackList(from text: String) -> [TrackItem] {
        let lines = text.components(separatedBy: .newlines)
        var results: [TrackItem] = []

        for line in lines {
            let cleaned = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                // Remove leading numbers/bullets
                .replacingOccurrences(of: #"^\d+[\.\)、]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^[-•·]\s*"#, with: "", options: .regularExpression)

            guard !cleaned.isEmpty else { continue }

            // Try to split on common separators
            if let item = parseTrackLine(cleaned) {
                results.append(item)
            }
        }

        return results
    }

    private func parseTrackLine(_ line: String) -> TrackItem? {
        // Normalize dashes and separators
        let normalized = line
            .replacingOccurrences(of: "—", with: "-")  // em dash
            .replacingOccurrences(of: "–", with: "-")  // en dash

        // Remove parenthetical notes like "(Remastered 2009)"
        let cleaned = normalized
            .replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*（[^）]*）"#, with: "", options: .regularExpression)

        // Try separators in order of priority
        let separators = [" - ", " / ", " — ", "\" by ", ": "]
        for sep in separators {
            let components = cleaned.components(separatedBy: sep)
            if components.count >= 2 {
                let title = components[0].trimmingCharacters(in: .whitespaces)
                let artist = components[1].trimmingCharacters(in: .whitespaces)
                if !title.isEmpty && !artist.isEmpty {
                    return TrackItem(title: title, artist: artist)
                }
            }
        }

        return nil
    }
}

// MARK: - Mock (Development & Testing)

final class MockLLMService: LLMServiceProtocol {
    let shouldFail: Bool
    let mockDelay: TimeInterval

    init(shouldFail: Bool = false, mockDelay: TimeInterval = 1.0) {
        self.shouldFail = shouldFail
        self.mockDelay = mockDelay
    }

    private let mockTracks: [TrackItem] = [
        TrackItem(title: "Bohemian Rhapsody", artist: "Queen"),
        TrackItem(title: "Hotel California", artist: "Eagles"),
        TrackItem(title: "Imagine", artist: "John Lennon"),
        TrackItem(title: "Stairway to Heaven", artist: "Led Zeppelin"),
        TrackItem(title: "Yesterday", artist: "The Beatles"),
        TrackItem(title: "Smells Like Teen Spirit", artist: "Nirvana"),
        TrackItem(title: "Billie Jean", artist: "Michael Jackson"),
        TrackItem(title: "Purple Rain", artist: "Prince"),
        TrackItem(title: "Like a Rolling Stone", artist: "Bob Dylan"),
        TrackItem(title: "What's Going On", artist: "Marvin Gaye"),
        TrackItem(title: "Superstition", artist: "Stevie Wonder"),
        TrackItem(title: "Dreams", artist: "Fleetwood Mac"),
        TrackItem(title: "Heroes", artist: "David Bowie"),
        TrackItem(title: "Lose Yourself", artist: "Eminem"),
        TrackItem(title: "Redemption Song", artist: "Bob Marley"),
        TrackItem(title: "Creep", artist: "Radiohead"),
        TrackItem(title: "Come As You Are", artist: "Nirvana"),
        TrackItem(title: "Take On Me", artist: "a-ha"),
        TrackItem(title: "Sweet Child O' Mine", artist: "Guns N' Roses"),
        TrackItem(title: "Wonderwall", artist: "Oasis"),
        TrackItem(title: "Yellow", artist: "Coldplay"),
        TrackItem(title: "Clocks", artist: "Coldplay"),
        TrackItem(title: "Fix You", artist: "Coldplay"),
        TrackItem(title: "Viva la Vida", artist: "Coldplay"),
        TrackItem(title: "Shape of You", artist: "Ed Sheeran"),
    ]

    func recommend(prompt: String) async throws -> [TrackItem] {
        try await Task.sleep(nanoseconds: UInt64(mockDelay * 1_000_000_000))

        if shouldFail {
            throw LLMServiceError.timeout
        }

        // Deterministic pseudo-random: use prompt hash to vary results
        let results = mockTracks.shuffled()
        return Array(results.prefix(AppConfig.targetTrackCount))
    }

    func healthCheck() async -> Bool {
        return !shouldFail
    }
}
