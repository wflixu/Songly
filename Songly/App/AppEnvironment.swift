//
//  AppEnvironment.swift
//  Songly
//
//  Reads configuration values injected via INFOPLIST_KEY_* build settings.
//

import Foundation

enum AppEnvironment {
    /// DeepSeek API key, injected from .xcconfig via INFOPLIST_KEY_DEEPSEEK_API_KEY.
    static var deepseekAPIKey: String {
        Bundle.main.infoDictionary?["DEEPSEEK_API_KEY"] as? String ?? ""
    }

    /// Whether a valid-looking API key is configured.
    static var isAPIKeyConfigured: Bool {
        let key = deepseekAPIKey
        return !key.isEmpty && !key.hasPrefix("sk-your")
    }
}
