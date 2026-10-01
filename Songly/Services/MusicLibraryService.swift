//
//  MusicLibraryService.swift
//  Songly
//
//  「超赞」在 Apple Music 侧的副作用。**主记录永远是本地的** —— 这里的两步
//  都是次级的，失败不回滚本地标记，也绝不静默吞掉。
//
//  ⚠️ 名字陷阱：本文件写的是 **Apple Music 账号里的评分**（Music app 里那个
//  红心），它和本 App 自己的 `TrackVerdict.loved` 是两套互不相干的系统。
//  MusicKit 的 Swift API **完全不提供**评分读写（`rating`/`favorite`/`love`
//  在 MusicKit.swiftinterface 里零命中），所以写回只能手写 REST。
//  `MusicDataRequest` 会替我们带上 developer token 与 user token，
//  不需要自建 JWT 那套基建。
//

import Foundation
import MusicKit

// MARK: - 结果类型

enum AddOutcome: Equatable, Sendable {
    case added
    /// 这首歌本来就在用户的资料库里。
    ///
    /// **这是成功，不是失败。** 我们推荐的候选虽然刻意排除曲库，但放宽路径
    /// 允许与曲库重叠，所以「超赞一首自己本来就有的歌」是常见情况。把它当
    /// 错误处理，会让一次完全成功的操作弹出错误提示。
    case alreadyOwned
}

enum MusicLibraryServiceError: LocalizedError, Equatable {
    case songNotFound
    case permissionDenied
    /// 这首歌在当前地区 / 这个账号下无法加入资料库。**不要重试。**
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .songNotFound:      return "在曲库里找不到这首歌"
        case .permissionDenied:  return "没有 Apple Music 访问权限"
        case .unavailable:       return "这首歌在当前地区无法加入资料库"
        case .failed(let detail): return detail
        }
    }
}

// MARK: - 评分读取结果

/// 批量读评分的产物。
///
/// **刻意不抛错**：调用方（隐式信号检测器）按契约必须降级而不是中断管线 ——
/// 读不到评分只意味着「少了一路信号」，不该让今天出不来歌单。
struct RatingReadResult: Sendable, Equatable {
    /// songID → `1`（⭐ 收藏）/ `-1`（不喜欢）。
    ///
    /// **不在字典里 = 没标过。** 这与「读失败」是两回事 —— 后者看 `failure`。
    /// 探测要回答的正是「没标过的歌是缺席还是 404」，两种都不能当成错误。
    var ratings: [String: Int] = [:]
    /// 非 nil 表示中途失败，内容是可读原因（进诊断日志）。
    var failure: String?

    static let empty = RatingReadResult()
}

// MARK: - Protocol

protocol MusicLibraryServicing: Sendable {
    func addToLibrary(songID: String) async throws -> AddOutcome
    func setLovedRating(songID: String) async throws
    /// 批量读回评分。**不抛错**，失败体现在 `failure` 里。
    func readRatings(songIDs: [String]) async -> RatingReadResult
}

// MARK: - Service

final class MusicLibraryService: MusicLibraryServicing {

    private static let apiBase = "https://api.music.apple.com/v1/me/ratings"

    init() {}

    // MARK: 收藏

    func addToLibrary(songID: String) async throws -> AddOutcome {
        let request = MusicCatalogResourceRequest<Song>(
            matching: \.id, equalTo: MusicItemID(songID)
        )
        let response: MusicCatalogResourceResponse<Song>
        do {
            response = try await request.response()
        } catch {
            throw MusicLibraryServiceError.failed(error.localizedDescription)
        }
        guard let song = response.items.first else {
            throw MusicLibraryServiceError.songNotFound
        }

        do {
            try await MusicLibrary.shared.add(song)
            return .added
        } catch let error as MusicLibrary.Error {
            switch error {
            case .itemAlreadyAdded:
                return .alreadyOwned
            case .permissionDenied:
                throw MusicLibraryServiceError.permissionDenied
            case .unableToAddItem:
                throw MusicLibraryServiceError.unavailable
            default:
                throw MusicLibraryServiceError.failed(error.localizedDescription)
            }
        } catch {
            throw MusicLibraryServiceError.failed(error.localizedDescription)
        }
    }

    // MARK: 写回评分

    /// 把「喜欢」写回 Apple Music 账号。
    ///
    /// 端点与 ID 口径见 `probeRatingWrite` 的探测结论 —— 在探测通过之前，
    /// 调用方应当把它当作**可失败的可选步骤**。
    func setLovedRating(songID: String) async throws {
        try await putRating(path: "songs", songID: songID, value: 1)
    }

    private func putRating(path: String, songID: String, value: Int) async throws {
        guard let url = URL(string: "\(Self.apiBase)/\(path)/\(songID)") else {
            throw MusicLibraryServiceError.failed("评分端点构造失败")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "type": "rating",
            "attributes": ["value": value],
        ])

        do {
            let response = try await MusicDataRequest(urlRequest: request).response()
            guard (200..<300).contains(response.urlResponse.statusCode) else {
                throw MusicLibraryServiceError.failed("HTTP \(response.urlResponse.statusCode)")
            }
        } catch let error as MusicDataRequest.Error {
            throw MusicLibraryServiceError.failed("\(error.status) \(error.title)：\(error.detailText)")
        }
    }

    // MARK: 探测

    /// 阶段 0 探测：确认写回评分这条路到底通不通。
    ///
    /// 要回答三件事，**任何一件都不能靠猜**：
    ///   1. `MusicDataRequest` 接不接受带 body 的 PUT
    ///   2. 写端点用目录 ID（`songs`）还是资料库 ID（`library-songs`）
    ///   3. 请求体的确切形状
    ///
    /// 返回一份可直接读的报告。探测不通过就砍掉写回，只保留「收藏进资料库」——
    /// 而不是留一个假装在工作、实际一直失败的功能。
    func probeRatingWrite(songID: String) async -> String {
        var lines: [String] = ["[Songly] ── 评分写回探测 ──", "catalog id = \(songID)"]

        for path in ["songs", "library-songs"] {
            let urlString = "\(Self.apiBase)/\(path)/\(songID)"
            guard let url = URL(string: urlString) else {
                lines.append("\(path)：URL 构造失败")
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "type": "rating",
                "attributes": ["value": 1],
            ])

            do {
                let response = try await MusicDataRequest(urlRequest: request).response()
                let code = response.urlResponse.statusCode
                let body = String(data: response.data, encoding: .utf8) ?? ""
                lines.append("PUT \(path) → HTTP \(code)"
                             + (body.isEmpty ? "（空 body）" : "｜\(body.prefix(300))"))
            } catch let error as MusicDataRequest.Error {
                lines.append("PUT \(path) → 抛错 status=\(error.status) code=\(error.code) "
                             + "title=\(error.title)｜\(error.detailText)")
            } catch {
                lines.append("PUT \(path) → 抛错 \(error.localizedDescription)")
            }
        }

        lines.append("若 `songs` 返回 2xx：用目录 ID 直写，写回只需一跳。")
        lines.append("若只有 `library-songs` 可用：需先在资料库里把这首歌查回来拿 library id。")
        lines.append("若两者都失败：砍掉写回，超赞只做「本地标记 + 收藏进资料库」。")
        return lines.joined(separator: "\n")
    }

    // MARK: 读回评分

    /// 批量读回用户对这几首歌的评分。
    ///
    /// ⚠️ **尚未在真机上验证过**（`GET /v1/me/ratings/*`）。调用方必须挂在
    /// `AppConfig.readAppleMusicRatings` 后面，并且**能接受它一直失败**。
    ///
    /// 目前**只走批量形式**：探测若证明批量不可用、而逐个 GET 可用，再补回退路径 ——
    /// 先写一条没验过的回退，等于把「没验证」的地方从一个变成两个。
    ///
    /// 判读口径：`data[].attributes.value`。**id 不在 data 里 = 没标过**，不是错误。
    func readRatings(songIDs: [String]) async -> RatingReadResult {
        guard !songIDs.isEmpty else { return .empty }
        var result = RatingReadResult()

        // 串行分片：并发更快，但更容易撞 Apple 的限流，而这条路径本来就在后台、
        // 有 8 秒预算，不值得为几秒去冒被限流的风险。
        for chunk in songIDs.chunked(into: AppConfig.ratingBatchChunkSize) {
            if Task.isCancelled { break }

            let ids = chunk.joined(separator: ",")
            guard let url = URL(string: "\(Self.apiBase)/songs?ids=\(ids)") else {
                result.failure = "评分端点构造失败"
                return result
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            do {
                let response = try await MusicDataRequest(urlRequest: request).response()
                let code = response.urlResponse.statusCode
                guard (200..<300).contains(code) else {
                    result.failure = "HTTP \(code)"
                    return result
                }
                result.ratings.merge(Self.parseRatings(response.data)) { _, new in new }
            } catch let error as MusicDataRequest.Error {
                result.failure = "\(error.status) \(error.title)：\(error.detailText)"
                return result
            } catch {
                result.failure = error.localizedDescription
                return result
            }
        }
        return result
    }

    /// 从 `/me/ratings/songs` 的响应里取出 `id → value`。
    ///
    /// 刻意用 `JSONSerialization` 而不是 `Codable` 结构体：这个端点的响应形状
    /// 还没在真机上确认过，写一套严格的 `Codable` 只会让「形状对不上」表现为
    /// 静默的空结果，而不是一条能读的失败原因。
    private static func parseRatings(_ data: Data) -> [String: Int] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return [:] }

        var ratings: [String: Int] = [:]
        for item in items {
            guard let id = item["id"] as? String,
                  let attributes = item["attributes"] as? [String: Any],
                  let value = attributes["value"] as? Int else { continue }
            ratings[id] = value
        }
        return ratings
    }

    // MARK: 探测：读回评分

    /// 阶段 0 探测：确认「⭐ 收藏」到底读不读得到、用哪条路。
    ///
    /// ⚠️ **必须同时跑一首他标过 ⭐ 的、和一首没标过的。** 没有阴性对照，
    /// 就无法区分「404 = 没标过」和「404 = 端点根本不通」—— 这正是写回探测
    /// 当年卡住的原因（见 `probeRatingWrite`）。
    func probeRatingRead(songIDs: [String]) async -> String {
        var lines: [String] = ["[Songly] ── 评分读取探测 ──"]
        guard !songIDs.isEmpty else {
            return "没有可用的曲目 ID —— 先在首页生成一份歌单。"
        }
        lines.append("样本 ID：\(songIDs.joined(separator: ", "))")
        lines.append("⚠️ 请确认这里面**至少有一首你标过 ⭐**、至少有一首没标过。")
        lines.append("")

        // A：批量形式（实现里走的就是这条）
        let batch = await readRatings(songIDs: songIDs)
        lines.append("A) GET /me/ratings/songs?ids=…")
        lines.append("   解析到 \(batch.ratings.count) 条评分｜失败：\(batch.failure ?? "无")")
        for id in songIDs {
            let value = batch.ratings[id].map(String.init) ?? "（不在 data 里 → 按「没标过」处理）"
            lines.append("   \(id) → \(value)")
        }
        lines.append("")

        // B / C：逐个形式，用来对照端点口径
        for path in ["songs", "library-songs"] {
            lines.append("B) GET /me/ratings/\(path)/<id>（逐个，只看第一首）")
            guard let id = songIDs.first,
                  let url = URL(string: "\(Self.apiBase)/\(path)/\(id)") else {
                lines.append("   URL 构造失败")
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            do {
                let response = try await MusicDataRequest(urlRequest: request).response()
                let code = response.urlResponse.statusCode
                let body = String(data: response.data, encoding: .utf8) ?? ""
                lines.append("   → HTTP \(code)｜\(body.prefix(200))")
            } catch let error as MusicDataRequest.Error {
                lines.append("   → 抛错 status=\(error.status) code=\(error.code) \(error.title)｜\(error.detailText)")
            } catch {
                lines.append("   → 抛错 \(error.localizedDescription)")
            }
        }

        lines.append("")
        lines.append("判读：")
        lines.append("· A 能解析出条目 → 打开 AppConfig.readAppleMusicRatings。")
        lines.append("· A 报 4xx/403 → 评分读不到，隐式信号退化为「入库 + 播放 + 歌单 diff」。")
        lines.append("· **没标过的歌返回 404 是正常的**，不是失败。")
        return lines.joined(separator: "\n")
    }

    // MARK: 探测：歌单条目

    /// 阶段 0 探测：确认歌单 diff 到底能不能做。
    ///
    /// 要回答四件事：
    ///   1. 资料库请求能不能按 id 查回我们建的歌单
    ///   2. `playlist.with([.entries])` 对**资料库歌单**是否可用（类型上成立，运行时未验证）
    ///   3. 有没有分页（`hasNextBatch`）
    ///   4. **`entry.title` / `entry.artistName` 能不能和本地 `TrackInfo` 对上**
    ///
    /// 第 4 条是判据：**匹配率 < 90% 就不做歌单 diff**。因为 `Playlist.Entry.id`
    /// 与我们的目录 ID **不同域**，只能靠文本比对 —— 比对不可靠，就会把整份歌单
    /// 判成「全被删了」，把 25 首歌永久打进排除集。
    func probePlaylistEntries(playlistID: String, expectedTitles: [String]) async -> String {
        var lines: [String] = ["[Songly] ── 歌单条目探测 ──", "playlist id = \(playlistID)"]

        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(playlistID))
        request.limit = 10

        do {
            let response = try await request.response()
            guard let playlist = response.items.first else {
                lines.append("1) 资料库请求查回 0 个歌单 —— 这个 ID 不在资料库里。")
                lines.append("   若歌单是刚建的，稍等再试；若已被删，这条就是「已删除」的证据。")
                return lines.joined(separator: "\n")
            }
            lines.append("1) ✅ 资料库请求查到：\(playlist.name)")

            let detailed = try await playlist.with([.entries])
            lines.append("2) ✅ with([.entries]) 可用")

            var all: [Playlist.Entry] = detailed.entries.map(Array.init) ?? []
            var current = detailed.entries
            let firstHasNext = current?.hasNextBatch ?? false
            var batches = 0
            while let cursor = current, cursor.hasNextBatch, batches < 20 {
                guard let next = try await cursor.nextBatch() else { break }
                all += Array(next)
                current = next
                batches += 1
            }
            lines.append("3) 条目 \(all.count) 条｜分页批次 \(batches)｜首屏 hasNextBatch = \(firstHasNext)")

            lines.append("")
            lines.append("4) 前 8 条的**原文**（对照本地的 TrackInfo）：")
            for entry in all.prefix(8) {
                lines.append("   title=[\(entry.title)] artist=[\(entry.artistName)] id=[\(entry.id.rawValue)]")
            }

            let expected = Set(expectedTitles.map(normalizedKey))
            let matched = all.filter { expected.contains(normalizedKey($0.title)) }.count
            let rate = expectedTitles.isEmpty ? 0 : Double(matched) / Double(expectedTitles.count)
            lines.append("")
            lines.append("匹配率（按标题归一化）：\(matched)/\(expectedTitles.count) = \(Int((rate * 100).rounded()))%")
            lines.append(rate >= 0.9
                ? "✅ 判据通过（≥90%）—— 歌单 diff 可以做。"
                : "❌ 判据未通过（<90%）—— **整个关掉歌单 diff**，不要降级为「放宽」。")
        } catch let error as MusicDataRequest.Error {
            lines.append("抛错 status=\(error.status) \(error.title)：\(error.detailText)")
        } catch {
            lines.append("抛错 \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 探测：删除歌单

    /// 阶段 0 探测：Apple Music 到底允不允许删歌单（第 3 项的前提）。
    ///
    /// **绝不碰用户已有的歌单。** 做法是新建一份一次性歌单、再尝试删掉它 ——
    /// 探测本身不能有任何破坏性。删不掉时那份空歌单会留下，报告里会提醒手动清理。
    func probePlaylistDelete() async -> String {
        var lines: [String] = ["[Songly] ── 歌单删除探测 ──"]
        lines.append("做法：新建一份**一次性空歌单**再尝试删它，绝不碰你已有的歌单。")

        let name = "Songly 删除探测 \(Int(Date().timeIntervalSince1970))"
        let playlist: Playlist
        do {
            playlist = try await MusicLibrary.shared.createPlaylist(
                name: name, description: "可安全删除"
            )
        } catch {
            lines.append("建探测歌单失败：\(error.localizedDescription)")
            return lines.joined(separator: "\n")
        }
        lines.append("已建：\(playlist.name)｜id=\(playlist.id.rawValue)（空的，没占你任何歌）")
        lines.append("")

        guard let url = URL(string:
            "https://api.music.apple.com/v1/me/library/playlists/\(playlist.id.rawValue)"
        ) else {
            lines.append("URL 构造失败")
            return lines.joined(separator: "\n")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        do {
            let response = try await MusicDataRequest(urlRequest: request).response()
            let code = response.urlResponse.statusCode
            lines.append("DELETE → HTTP \(code)")
            lines.append((200..<300).contains(code)
                ? "✅ 删除可用 —— 第 3 项（保留最近 7 份、其余自动清理）可以按计划实现。"
                : "❌ 删除不可用 —— 第 3 项退回「复用同一份歌单」。上面那份探测歌单请手动删掉。")
        } catch let error as MusicDataRequest.Error {
            lines.append("DELETE → 抛错 status=\(error.status) \(error.title)：\(error.detailText)")
            lines.append("❌ 删除不可用 —— 上面那份探测歌单请手动删掉。")
        } catch {
            lines.append("DELETE → 抛错 \(error.localizedDescription)")
            lines.append("上面那份探测歌单请手动删掉。")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 分片

private extension Array {
    /// 按固定大小切片。批量评分的 URL 长度与限流都需要它。
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
