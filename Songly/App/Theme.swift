//
//  Theme.swift
//  Songly
//
//  设计令牌。此前这些数值散落在各视图里且互相矛盾 —— 光圆角就有
//  12 / 14 / 16 / 20 四个值而没有规则，阴影有两套写法（`opacity(0.04)
//  radius:8 y:2` 与 `opacity(0.03) radius:4 y:1`）。集中到这里，
//  以后调整才有单点。
//

import SwiftUI

enum Theme {

    // MARK: - 品牌渐变

    /// 乐遇的主色，与 App Icon 的蓝→紫同族。
    ///
    /// 使用规则只有一条：**它是「今天这份歌单」的封套**。只出现在四个地方 ——
    /// ① 今日卡（idle/generating 时整块、completed 时顶部带）；
    /// ② 主行动按钮；③ 专辑封面缺图时的占位格；④ App Icon 的深色/着色槽位。
    /// 其余一律不用，否则它就从「身份」退化成「装饰」。
    static let brandGradient = LinearGradient(
        colors: [.pink.opacity(0.85), .purple.opacity(0.6), .blue.opacity(0.7)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 品牌主色。直接读 Assets 里的 `AccentColor`，所以明暗两套值是**单点**的。
    /// 渐变本身不能当 `.tint`（它是多色的），需要单一主色的地方用这个。
    static let brand = Color("AccentColor")

    // MARK: - 渐变上的前景色

    /// 渐变是深色底，所以落在它上面的文字与控件一律取白，不跟随明暗模式。
    static let onBrand = Color.white
    static let onBrandSecondary = Color.white.opacity(0.85)
    static let onBrandTertiary = Color.white.opacity(0.65)

    // MARK: - 圆角

    enum Radius {
        /// 卡片。
        static let card: CGFloat = 20
        /// 卡片内的按钮 / 控件。
        static let control: CGFloat = 14
        /// 小色块底板。
        static let tile: CGFloat = 12
        /// 封面缩略图。
        static let thumbnail: CGFloat = 8
    }

    // MARK: - 间距

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        /// 页面左右边距。
        static let page: CGFloat = 16
    }

    // MARK: - 尺寸

    enum Size {
        /// 曲目行封面（44pt @3x = 132px，存的 160px URL 有余量）。
        static let trackArtwork: CGFloat = 44
        /// 歌单行封面。
        static let playlistArtwork: CGFloat = 52
        /// 今日卡封面拼贴里每个格子。
        static let mosaicArtwork: CGFloat = 68
        /// 主按钮高度。
        static let primaryButton: CGFloat = 50
        /// 图标底板。
        static let iconTile: CGFloat = 32
    }
}

// MARK: - 层级的强调色

extension DiscoveryTier {
    /// 曲目行徽章的颜色。
    ///
    /// 这套配色刻意只有两个强调色，且只出现在少数几行上（25 首里大约 7 首）。
    /// `confident` 用中性色 —— 它本来也不打徽章（见 `showsBadge`）。
    var badgeColor: Color {
        switch self {
        case .confident: return .secondary
        case .fresh: return Theme.brand
        case .bold: return .orange
        }
    }
}

// MARK: - 卡片外观

extension View {
    /// 统一的卡片外观：系统背景 + 连续圆角 + 一道极浅的投影。
    ///
    /// 底色用语义色 `.background` 而不是写死的白，暗色模式因此不需要任何分支。
    func cardSurface(radius: CGFloat = Theme.Radius.card) -> some View {
        background(.background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}
