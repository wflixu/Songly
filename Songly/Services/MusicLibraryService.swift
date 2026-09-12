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

// MARK: - Protocol

protocol MusicLibraryServicing: Sendable {
    func addToLibrary(songID: String) async throws -> AddOutcome
    func setLovedRating(songID: String) async throws
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
}
