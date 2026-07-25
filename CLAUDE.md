# Songly — Claude 项目指南

## 项目概述

**乐遇 Songly** — 为 Apple Music 国区用户提供 AI 驱动的个性化每日歌单推荐。

核心链路：MusicKit 读用户收藏 → LLM（DeepSeek）分析口味 → MusicKit 搜索曲库匹配 → 自动创建 Apple Music 播放列表。

## 技术栈

| 层 | 方案 |
|----|------|
| 语言 | Swift 5.0 |
| UI | SwiftUI |
| 数据 | SwiftData |
| 音乐 | MusicKit |
| AI | DeepSeek API |
| 开发 | Xcode project (直接管理) |
| 测试 | Swift Testing (单元), XCTest (UI) |
| 最低系统 | iOS 26.5 |

## 项目结构

```
Songly/
├── Songly/                  # 主应用
│   ├── SonglyApp.swift      # @main App 入口
│   ├── ContentView.swift    # 主界面
│   ├── Item.swift           # 数据模型
│   └── Assets.xcassets/     # 资源
├── SonglyTests/             # 单元测试 (Swift Testing)
├── SonglyUITests/           # UI 测试 (XCTest)
├── Songly.xcodeproj/        # Xcode 项目
└── specs/                   # 产品文档
    ├── idea.md              # 原始想法
    └── prd.md               # 产品需求文档
```

## 构建命令

```bash
# 命令行构建
xcodebuild -project Songly.xcodeproj -scheme Songly -destination 'platform=iOS Simulator,name=iPhone 17' build

# 运行测试
xcodebuild -project Songly.xcodeproj -scheme Songly test -destination 'platform=iOS Simulator,name=iPhone 17'
```

## 代码规范

- 使用 SwiftUI 原生组件，不引入第三方 UI 框架
- 数据持久化使用 SwiftData (`@Model`, `@Query`, `ModelContainer`)
- 异步操作使用 `async/await`
- API Key 等敏感信息不硬编码，使用 `.xcconfig` 或环境变量

## MusicKit 要点

- `MusicAuthorization.request()` — 授权
- `MusicLibraryRequest<Song>()` — 读收藏
- `MusicCatalogSearchRequest` — 搜索曲库
- `Playlist` CRUD — 创建/更新播放列表

## 重要约定

- **MVP 阶段不做商业化**，只验证推荐质量
- **直接管理 .pbxproj**，通过 Xcode 添加/删除文件
- **iPhone + iPad 双平台**（TARGETED_DEVICE_FAMILY = 1,2）
- Bundle ID 前缀: `cn.wflixu`
- Team ID: `4L3563XCBN`
