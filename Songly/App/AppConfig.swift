//
//  AppConfig.swift
//  Songly
//
//  Global configuration constants.
//

import Foundation

enum AppConfig {
    // MARK: - DeepSeek API

    static let deepseekBaseURL = "https://api.deepseek.com/v1/chat/completions"
    static let deepseekModel = "deepseek-chat"
    static let requestTimeout: TimeInterval = 10
    static let maxRetries = 3
    static let retryDelays: [TimeInterval] = [1, 2, 4]

    // MARK: - Prompt

    static let maxPromptTokens = 2000
    static let targetTrackCount = 25
    static let minTrackCount = 10

    // MARK: - MusicKit

    static let maxLibrarySongs = 200
    static let searchConcurrency = 5
    static let matchRateThreshold = 0.2

    // MARK: - Background Task

    static let bgTaskIdentifier = "cn.wflixu.Songly.dailyRecommendation"
}
