//
//  ArtworkView.swift
//  Songly
//
//  专辑封面的加载与显示。
//
//  刻意**不用裸 `AsyncImage`**：它每次被构造都从 `.empty` 起步，行滚出
//  `LazyVStack` 再滚回来时会先渲染一帧占位图 —— **即使缓存已经命中**。
//  在快速滚动里这就读作闪烁。`ArtworkStore` 用 NSCache 存的是**已解码的
//  `UIImage`**（`URLCache` 只存原始 `Data`，省不掉解码），命中时同步返回，
//  视图首帧就是图。
//

import SwiftUI
import UIKit

// MARK: - Store

@MainActor
final class ArtworkStore {
    static let shared = ArtworkStore()

    private let cache = NSCache<NSString, UIImage>()
    /// 同一张图被多行同时请求时，只发一次网络请求。
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 300
    }

    /// 同步命中。视图第一帧就能拿到图，因此不会闪。
    func cached(_ urlString: String) -> UIImage? {
        cache.object(forKey: urlString as NSString)
    }

    func image(for urlString: String) async -> UIImage? {
        if let hit = cached(urlString) { return hit }
        if let running = inflight[urlString] { return await running.value }

        let task = Task<UIImage?, Never> {
            guard let url = URL(string: urlString),
                  let (data, _) = try? await URLSession.shared.data(from: url)
            else { return nil }
            return UIImage(data: data)
        }
        inflight[urlString] = task
        let image = await task.value
        inflight[urlString] = nil
        if let image { cache.setObject(image, forKey: urlString as NSString) }
        return image
    }
}

// MARK: - Thumbnail

/// 方形封面缩略图。
///
/// 缺图时的占位按用途分两种，不能一律用品牌渐变 —— 旧记录整份歌单都没有
/// 封面，若每行都铺渐变，列表会变成一堵色墙。所以：
/// - 曲目行用**安静的中性占位**（`usesBrandPlaceholder: false`）；
/// - 今日卡的拼贴用**品牌渐变**，那里本来就只有 4 格，且是「这份歌单」的
///   身份面（旧记录下四格渐变恰好等同于 idle 态那块封套，观感是连续的）。
struct ArtworkThumbnail: View {
    let urlString: String?
    var side: CGFloat = Theme.Size.trackArtwork
    var radius: CGFloat = Theme.Radius.thumbnail
    var usesBrandPlaceholder: Bool = false

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if usesBrandPlaceholder {
                Theme.brandGradient
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: side * 0.3))
                            .foregroundStyle(Theme.onBrand.opacity(0.75))
                    }
            } else {
                Rectangle()
                    .fill(.secondary.opacity(0.12))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: side * 0.3))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // `.task(id:)` 而不是 `.onAppear`：行被复用到另一首歌时能重新取图。
        .task(id: urlString) {
            guard let urlString else {
                image = nil
                return
            }
            // 分开写而不是 `cached(...) ?? await image(for:)` —— `??` 的右侧
            // 是 autoclosure，不能跨 await。
            if let hit = ArtworkStore.shared.cached(urlString) {
                image = hit
            } else {
                image = await ArtworkStore.shared.image(for: urlString)
            }
        }
    }
}

// MARK: - Mosaic

/// 歌单的 2×2 封面拼贴。
///
/// 用「前 4 首的封面」而不是单张封面，因为它更能代表一份混杂的歌单，并且
/// **不需要额外存一个大图 URL** —— 用的就是每首歌已经存好的 160px 缩略图。
struct ArtworkMosaic: View {
    let tracks: [TrackInfo]
    var side: CGFloat = Theme.Size.mosaicArtwork
    var gap: CGFloat = 3

    private var tile: CGFloat { (side - gap) / 2 }

    var body: some View {
        let urls = tracks.prefix(4).map(\.artworkURL)
        VStack(spacing: gap) {
            HStack(spacing: gap) { cell(urls, 0); cell(urls, 1) }
            HStack(spacing: gap) { cell(urls, 2); cell(urls, 3) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    @ViewBuilder
    private func cell(_ urls: [String?], _ index: Int) -> some View {
        ArtworkThumbnail(
            urlString: index < urls.count ? urls[index] : nil,
            side: tile,
            radius: 0,
            usesBrandPlaceholder: true
        )
    }
}

#Preview {
    VStack(spacing: 24) {
        HStack(spacing: 12) {
            ArtworkThumbnail(urlString: nil)
            ArtworkThumbnail(urlString: nil, usesBrandPlaceholder: true)
        }
        ArtworkMosaic(tracks: [])
        ArtworkMosaic(tracks: [
            TrackInfo(id: "1", name: "A", artist: "X"),
            TrackInfo(id: "2", name: "B", artist: "Y"),
            TrackInfo(id: "3", name: "C", artist: "Z"),
        ])
    }
    .padding()
}
