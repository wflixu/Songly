# 乐遇 Songly — 产品需求文档 (PRD)

> **版本**: v1.0 — MVP
> **状态**: 验证期
> **最后更新**: 2026-07-12

---

## 1. 产品概要

### 1.1 一句话定位

**把网易云音乐级别的个性化推荐，搬到 Apple Music 里。**

### 1.2 解决的问题

Apple Music 曲库全、无广告、体验好，但个性化推荐弱，歌单容易听腻。
苹果 iOS 26.4 推出的 Playlist Playground（AI 歌单）国行不可用（依赖 Apple Intelligence），且不读取用户听歌历史，推荐质量差。

Songly 读取用户 Apple Music 收藏 → LLM 分析口味 → 在 Apple Music 曲库匹配歌曲 → 自动创建播放列表。**每日自动，完全个性化，国行完美可用。**

### 1.3 目标用户

| 维度 | 描述 |
|------|------|
| 核心用户 | 中国区 Apple Music 付费用户 |
| 年龄段 | 18-35 岁 |
| 痛点 | Apple Music 推荐不够好，羡慕网易云/Spotify 的推荐算法 |
| 付费意愿 | 已为 Apple Music 付费，对增值功能有付费意愿 |

---

## 2. MVP 范围

### 2.1 MVP 目标

> **验证核心命题：LLM 基于用户 Apple Music 收藏生成的歌单，用户觉得好听的频次有多高？**

### 2.2 MVP 功能清单

| ID | 功能 | 优先级 | 说明 |
|----|------|--------|------|
| F1 | **MusicKit 集成** | P0 | 请求用户授权，读取收藏歌曲列表 |
| F2 | **LLM 推荐引擎** | P0 | 基于用户收藏，调用 LLM 生成 20-30 首歌的推荐列表 |
| F3 | **Apple Music 曲库匹配** | P0 | 将 LLM 推荐的歌名+艺人，通过 MusicCatalogSearch 在 Apple Music 中匹配 |
| F4 | **自动创建播放列表** | P0 | 将匹配结果写入 Apple Music 播放列表 |
| F5 | **每日推荐** | P0 | 每天自动生成一份新歌单 |
| F6 | **想听 — 快捷选择** | P1 | 预设风格按钮（摇滚/纯音乐/爵士等），手动触发即时推荐 |
| F7 | **推送通知** | P1 | 歌单就绪时推送系统通知 |

### 2.3 MVP 明确不做

- 策略轮换（仅用 1-2 种策略验证）
- 用户反馈闭环（喜欢/不喜欢）
- 推荐历史
- 想听 — 文字自由输入
- 商业化付费墙
- macOS 版本

---

## 3. 功能详述

### 3.1 F1 — MusicKit 集成

**用户流程：**
1. 首次启动 → 弹出 MusicAuthorization 授权请求
2. 授权后 → 读取用户 `MusicLibraryRequest<Song>()` 收藏列表
3. 提取歌曲名 + 艺人名，构建用户口味画像

**技术要点：**
- 必须处理授权拒绝的情况（展示引导文案，引导用户去设置中开启）
- 收藏列表需本地缓存，避免每次都全量读取
- 增量更新：仅拉取新增收藏，减少 API 调用

### 3.2 F2 — LLM 推荐引擎

**输入：**
```
用户收藏的歌曲列表（歌名 + 艺人，最多取最近 200 首）
推荐策略描述（如"风格探索"）
历史推荐去重列表（避免重复推荐）
```

**Prompt 模板：**
```
你是一个音乐推荐专家。用户收藏了以下歌曲：
[歌曲列表]

请根据这些歌曲，推荐 25 首 Apple Music 曲库中存在的歌曲。
推荐策略：风格探索 — 基于用户的听歌品味，推荐相近风格但用户可能没听过的歌曲。

要求：
1. 每行格式：歌名 - 艺人名
2. 不要推荐用户已经收藏的歌曲
3. 不要推荐以下歌曲：[历史推荐列表]
4. 优先推荐冷门好歌，而非热门金曲大杂烩
5. 确保推荐的歌在 Apple Music 曲库中存在（主流歌手的正式发行曲目）
```

**LLM 选择：**
- 首选：DeepSeek API（国内可用，¥0.001/1K tokens，性价比极高）
- 备选：通义千问 API / 月之暗面 API

### 3.3 F3 — Apple Music 曲库匹配

**流程：**
1. 解析 LLM 返回的推荐列表（歌名 + 艺人）
2. 逐条调用 `MusicCatalogSearchRequest` 搜索
3. 匹配逻辑：歌名精确匹配 > 歌名模糊匹配 > 艺人+歌名组合匹配
4. 筛选出匹配成功的歌曲 ID 列表

**容错：**
- 搜索无结果时跳过，不影响其他推荐
- 目标匹配率 > 80%

### 3.4 F4 — 自动创建播放列表

**流程：**
1. 以匹配成功的歌曲 ID 列表创建 `Playlist`
2. 播放列表命名规则：`🎵 每日推荐 · M月D日`（如 `🎵 每日推荐 · 7月12日`）
3. 描述中写入推荐策略说明
4. 去重：检查是否已有同日歌单，有则更新而非新建

### 3.5 F5 — 每日推荐

**触发方式：**
- iOS Background Task（BGAppRefreshTask）定时触发
- 用户打开 App 时检查今天是否已生成，未生成则触发

**推荐策略（MVP 阶段）：**
- 基础策略：基于收藏的风格探索（仅此一种，验证效果）

### 3.6 F6 — 想听 — 快捷选择

**UI：**
- 首页展示 3-5 个预设风格按钮
- 按钮示例：🎸 摇滚 | 🎹 纯音乐 | 🎷 爵士 | 🔀 来点不一样的 | 🌙 睡前放松

**交互：**
- 点击按钮 → 即时调用 LLM 推荐链路
- 生成中显示 loading 动画
- 完成后展示歌单预览 + 跳转 Apple Music 按钮

### 3.7 F7 — 推送通知

**触发时机：**
- 每日推荐歌单创建完成后

**通知文案模板：**
- `🎵 今天的每日推荐已就绪！25 首新歌等你来听`
- `🎸 你的摇滚歌单已生成，打开听听？`

**降级：**
- 用户关闭通知权限时，App 内红点/badge 提示

---

## 4. 技术架构

### 4.1 技术栈

| 层 | 方案 |
|----|------|
| 前端框架 | SwiftUI (iOS 26.5+) |
| 本地存储 | SwiftData |
| 音乐数据 | MusicKit Swift Framework |
| AI 引擎 | DeepSeek API（主）/ 通义千问 API（备） |
| 项目生成 | Xcode 直接管理 |
| 架构模式 | MVVM |

### 4.2 核心数据流

```
MusicAuthorization.request()
        ↓
MusicLibraryRequest<Song>()  →  [用户收藏列表]
        ↓
构建 Prompt → DeepSeek API  →  [推荐歌单]
        ↓
MusicCatalogSearchRequest    →  [匹配歌曲 ID]
        ↓
Playlist.create()            →  Apple Music 播放列表
        ↓
UNUserNotificationCenter     →  推送通知
```

### 4.3 关键 API

| API | 用途 |
|-----|------|
| `MusicAuthorization.request()` | 请求 MusicKit 授权 |
| `MusicLibraryRequest<Song>()` | 读取用户收藏歌曲 |
| `MusicCatalogSearchRequest` | 在 Apple Music 曲库搜索歌曲 |
| `Playlist` CRUD API | 创建/更新播放列表 |
| `BGAppRefreshTask` | iOS 后台定时任务 |
| `UNUserNotificationCenter` | 推送通知 |

### 4.4 数据模型 (SwiftData)

```swift
@Model
final class RecommendationRecord {
    var date: Date
    var strategy: String
    var songCount: Int
    var trackIDs: [String]       // 推荐歌曲的 Apple Music ID
    var trackNames: [String]     // 推荐歌曲名称
}

@Model
final class UserPreferences {
    var favoriteGenres: [String]
    var lastSyncDate: Date?
    var totalRecommendations: Int
}
```

---

## 5. 非功能需求

### 5.1 性能

| 指标 | 目标 |
|------|------|
| LLM API 响应 | < 10s |
| MusicKit 搜索（25首） | < 15s |
| 整体推荐生成 | < 30s |
| App 冷启动 | < 2s |

### 5.2 可靠性

- MusicKit 搜索失败时，已匹配的歌曲正常创建歌单，未匹配的跳过
- LLM API 超时重试 3 次，仍失败则通知用户稍后再试
- 后台任务失败不影响下次触发

### 5.3 隐私

- 收藏歌曲数据仅用于构建 LLM prompt，不上传至第三方服务器（除 API 调用外）
- API Key 不硬编码在客户端，通过环境变量或配置文件注入
- 不收集用户 Apple ID 或任何个人身份信息

### 5.4 兼容性

- 最低支持 iOS 26.5
- 仅支持 iPhone + iPad（`TARGETED_DEVICE_FAMILY = 1,2`）
- 需要有效的 Apple Music 订阅才能使用 MusicKit

---

## 6. 验收标准

### 6.1 MVP 核心验证指标

| 编号 | 指标 | 目标 | 测量方式 |
|------|------|------|----------|
| S1 | 自己连续使用天数 | ≥ 14 天 | 自记录 |
| S2 | 推荐新鲜感满意度 | ≥ 60% 的天数觉得有新鲜感 | 自评 |
| S3 | 内测用户满意度 | ≥ "还不错" | 每日一句话反馈 |
| S4 | MusicKit 搜索匹配率 | > 80% | 自动统计 |
| S5 | 「想听」风格匹配准确率 | 不翻车（基本匹配） | 自评 |

### 6.2 功能验收 (QA Checklist)

- [ ] 首次启动 → 授权流程正常
- [ ] 授权拒绝 → 引导文案展示
- [ ] 每日推荐 → 歌单自动创建到 Apple Music
- [ ] 推送通知 → 歌单就绪时收到通知
- [ ] 想听快捷按钮 → 每种风格生成歌单
- [ ] 生成的歌单可在 Apple Music App 中打开播放

---

## 7. 里程碑

### Phase 1 — MVP 开发（第 1-2 周）

| 周次 | 任务 |
|------|------|
| W1 | MusicKit 集成 + 授权流程、LLM 推荐链路、MusicKit 搜索匹配 |
| W2 | 播放列表创建、每日推荐后台任务、想听快捷选择、推送通知 |

### Phase 1.5 — MVP 验证（第 3-4 周）

- 自己每天使用，记录推荐质量
- 邀请 5-10 人内测
- 收集反馈，优化 prompt

### Phase 2 — PMF 后（验证通过后启动）

> 详见 idea.md 第 8 节

---

## 8. 附录

### A. 参考文档

- [Apple MusicKit Documentation](https://developer.apple.com/documentation/musickit)
- [MusicCatalogSearchRequest](https://developer.apple.com/documentation/musickit/musiccatalogsearchrequest)
- [DeepSeek API 定价](https://platform.deepseek.com/api-docs/pricing)
- [原始想法文档](idea.md)

### B. 变更记录

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-07-12 | v1.0 | 初始 PRD，基于 idea.md 整理 |
