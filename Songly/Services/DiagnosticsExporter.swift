//
//  DiagnosticsExporter.swift
//  Songly
//
//  把库里的推荐记录导成一份 JSON 文件，供离线分析。
//
//  为什么需要它：在此之前**全 App 没有任何数据出口** —— 记录都留在设备里，
//  唯一的出口是 DEBUG 控制台的 `print`。想比对两个算法版本、或想把数据拿去做
//  分析，第一步得先能把它拿出来。
//
//  ⚠️ 这是一个**把数据送出设备**的动作：内容包含歌名、艺人、收藏与收听记录。
//  调用方（设置页）必须先把这件事明确告诉用户，不能静默导出。
//

import Foundation
import SwiftData

@MainActor
enum DiagnosticsExporter {

    /// 导出**文件格式**的版本。与 `AppConfig.pipelineVersion` 无关 ——
    /// 那一头描述算法，这一头描述这份 JSON 长什么样。格式变了才 +1。
    static let formatVersion = 1

    /// 生成导出文件，返回其 URL（位于临时目录）。
    ///
    /// 按 `date` **升序**排列，与 App 里的展示顺序相反 —— 分析时按时间正序读更自然。
    static func write(context: ModelContext, now: Date = Date()) throws -> URL {
        let descriptor = FetchDescriptor<RecommendationRecord>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        let records = (try? context.fetch(descriptor)) ?? []

        var payload: [String: Any] = [
            "format_version": formatVersion,
            "exported_at": iso8601(now),
            "record_count": records.count,
            // 当前生效的版本。**每条记录自己也带一份** —— 这两个值只在
            // 「全部记录都产自同一版」时才相等，跨版本时以记录里的为准。
            "current_pipeline_version": AppConfig.pipelineVersion,
            "current_prompt_version": AppConfig.promptVersion,
            "current_model": AppConfig.deepseekModel,
            "records": records.map(recordJSON),
        ]
        if let version = Self.appVersion {
            payload["app_version"] = version
        }

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(now))
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 单条记录

    private static func recordJSON(_ record: RecommendationRecord) -> [String: Any] {
        var json: [String: Any] = [
            "date": iso8601(record.date),
            "created_at": iso8601(record.createdAt),
            "source": record.source,
            "strategy": record.strategy,
            "status": record.status,
            "song_count": record.songCount,
            "removed_count": record.removedCount,
            // 版本标识。**0 = 先于本机制存在的旧记录**，不是真实版本。
            "pipeline_version": record.pipelineVersion,
            "prompt_version": record.promptVersion,
            "tracks": record.tracks.map(trackJSON),
        ]

        // 可选字段逐个 `if let`，而不是直接赋值 —— 直接赋值时类型是 `Any?`，
        // 混着 nil 与非 nil 容易写出「键在但值是 null」这种半吊子结果。
        if let value = record.quickPickStyle { json["quick_pick_style"] = value }
        if let value = record.playlistName { json["playlist_name"] = value }
        if let value = record.playlistID { json["playlist_id"] = value }
        if let value = record.scene { json["scene"] = value }
        if let value = record.rating { json["rating"] = value }
        if let value = record.ratedAt { json["rated_at"] = iso8601(value) }
        if let value = record.modelID { json["model_id"] = value }
        if let value = record.failureReason { json["failure_reason"] = value }

        // 诊断在库里存的是一个 JSON 字符串，导出时**展开成对象** ——
        // 否则拿到这份文件的人还得再解析一层。
        if let raw = record.diagnosticsJSON,
           let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            json["diagnostics"] = parsed
        }

        return json
    }

    private static func trackJSON(_ track: TrackInfo) -> [String: Any] {
        var json: [String: Any] = [
            "id": track.id,
            "name": track.name,
            "artist": track.artist,
        ]
        if let tier = track.tier { json["tier"] = tier.rawValue }
        if let verdict = track.verdict { json["verdict"] = verdict.rawValue }
        if let at = track.verdictUpdatedAt { json["verdict_updated_at"] = iso8601(at) }
        return json
    }

    // MARK: - 杂项

    /// ISO8601，不带毫秒 —— 分析时够用，且人眼好读。
    private static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// 文件名带上算法版本与日期，两个批次的导出文件放在一起也不会混淆。
    private static func fileName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "songly-diagnostics-v\(AppConfig.pipelineVersion)-\(formatter.string(from: date)).json"
    }

    /// 与设置页「关于」里显示的是同一个口径。读 bundle，不写死。
    private static var appVersion: String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        guard let build = info?["CFBundleVersion"] as? String, build != short else {
            return short
        }
        return "\(short) (\(build))"
    }
}
