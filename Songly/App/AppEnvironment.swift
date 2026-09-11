//
//  AppEnvironment.swift
//  Songly
//
//  Reads configuration values from bundled api_config.json (generated at build time).
//

import Foundation

enum AppEnvironment {
    /// DeepSeek API key, loaded from bundled api_config.json.
    static var deepseekAPIKey: String {
        guard let url = Bundle.main.url(forResource: "api_config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let key = json["DEEPSEEK_API_KEY"],
              !key.isEmpty else {
            return ""
        }
        return key
    }

    /// Whether a valid-looking API key is configured.
    static var isAPIKeyConfigured: Bool {
        let key = deepseekAPIKey
        return !key.isEmpty && !key.hasPrefix("sk-your")
    }
}
