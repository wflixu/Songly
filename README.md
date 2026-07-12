# 🎵 乐遇 Songly

> **遇见音乐，遇见喜欢**

为 Apple Music 国区用户打造的 AI 个性化每日歌单推荐。读取你的收藏 → AI 分析口味 → 自动创建播放列表。**每日自动，完全个性化，国行完美可用。**

---

## 为什么需要 Songly？

Apple Music 曲库全、无广告、体验好，但 **个性化推荐太弱了**。

苹果 iOS 26.4 推出了 Playlist Playground（AI 歌单），但它：
- ❌ 国行不可用（依赖 Apple Intelligence）
- ❌ 不读你的听歌历史
- ❌ 推荐质量差（热门金曲大杂烩）

**Songly 来填补这个空缺** — 像网易云音乐的"心动"推荐一样懂你，但把歌单直接建在你的 Apple Music 里。

---

## 核心功能（MVP）

| 功能 | 说明 |
|------|------|
| 📊 **每日推荐** | 每天早上自动生成一份 20-30 首歌的新歌单 |
| 🎯 **想听（快捷选择）** | 点击预设风格按钮，即时生成指定风格歌单 |
| 📱 **自动保存** | 推荐歌单自动写入 Apple Music，打开就能听 |
| 🔔 **推送通知** | 歌单就绪时通知你 |

---

## 技术栈

| 层 | 方案 |
|----|------|
| 前端 | SwiftUI (iOS 26.5+) |
| 数据 | SwiftData |
| 音乐 | MusicKit Swift Framework |
| AI 引擎 | DeepSeek API |
| 项目构建 | XcodeGen |

---

## 快速开始

### 环境要求

- macOS 26+ with Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Apple Music 订阅
- DeepSeek API Key

### 克隆 & 启动

```bash
git clone <repo-url>
cd Songly

# 生成 Xcode 项目
xcodegen generate --spec project.yml

# 在 Xcode 中打开
open Songly.xcodeproj

# 或命令行构建
xcodebuild -project Songly.xcodeproj -scheme Songly -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### 运行测试

```bash
xcodebuild -project Songly.xcodeproj -scheme Songly test -destination 'platform=iOS Simulator,name=iPhone 17'
```

---

## 项目结构

```
Songly/
├── Songly/                  # 主应用
│   ├── SonglyApp.swift      # App 入口
│   ├── ContentView.swift    # 主界面
│   ├── Item.swift           # 数据模型
│   └── Assets.xcassets/     # 资源
├── SonglyTests/             # 单元测试 (Swift Testing)
├── SonglyUITests/           # UI 测试 (XCTest)
├── Songly.xcodeproj/        # Xcode 项目（XcodeGen 生成）
├── project.yml              # XcodeGen 配置
└── specs/                   # 产品文档
    ├── idea.md              # 原始想法
    └── prd.md               # 产品需求文档
```

---

## 路线图

- [x] 项目初始化 + XcodeGen 配置
- [ ] Phase 1: MVP 开发 — MusicKit 集成 + LLM 推荐链路
- [ ] Phase 1.5: 自我验证 2 周 + 小范围内测
- [ ] Phase 2: 策略轮换、反馈闭环、商业化（PMF 验证通过后）

详见 [specs/prd.md](specs/prd.md)

---

## 竞品对比

| App | 个性化 | 每日自动 | 国行可用 |
|-----|--------|---------|---------|
| Playlist Playground (苹果) | ❌ | ❌ | ❌ |
| PlaylistAI | ❌ | ❌ | ✅ |
| **Songly（本项目）** | ✅ | ✅ | ✅ |

---

## 许可

MIT License
