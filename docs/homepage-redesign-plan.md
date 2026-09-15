# Songly 首页重设计 & 功能扩展 实施方案

> 状态：待审核  
> 日期：2026-07-26

## Context

MVP 歌单生成管线已跑通（MusicKit → DeepSeek → Apple Music 播放列表）。当前首页存在以下问题需要解决：
- Header 设计偏离第一版的简洁优雅
- 「今日推荐」卡片空白过多，交互单一
- 「想听点什么」QuickPick 区域与风格选择功能重叠
- 底部统计图标含义不清
- 缺少歌单历史记录和管理入口
- LLM Prompt 推荐比例仅考虑中/英文二分，缺少纯音乐等类别

## 目标

重新设计首页布局，新增歌单管理功能，提升交互沉浸感，调整推荐比例。

---

## 页面布局（从上到下）

### 1. Hero Header — 恢复第一版感觉

**改动**：缩小高度 140→100pt，字体改为语义化尺寸，收紧间距(spacing: 2)，保留「乐遇」品牌词 + 日期 + tagline。

```
┌─ 渐变背景 (pink→purple→blue) ──────────┐
│  乐遇                    ← .title2, bold, rounded
│  7月26日 · 星期日        ← .subheadline, white 0.85
│  AI 驱动的个性化歌单     ← .caption, white 0.6
└──────────────────────────────────────┘  height: 100
```

**文件**：`HomeView.swift` → `heroBanner`

### 2. 今日推荐卡片 — 沉浸式双入口

**Idle 态**：两个按钮替代原来单一的大按钮

```
┌─ 今日推荐 ─────────────────────────────┐
│  ✨ 准备好发现新音乐了吗？              │
│  基于你的收藏品味，AI 为你推荐专属好歌  │
│                                        │
│  ┌──────────────────────────────────┐  │
│  │  🎵  直接生成歌单    (filled, gradient) │
│  └──────────────────────────────────┘  │
│  ┌──────────────────────────────────┐  │
│  │  🎨  选择风格生成    (bordered)  │  │
│  └──────────────────────────────────┘  │
└────────────────────────────────────────┘
```

- **直接生成歌单**：一键触发 `runDailyRecommendation()`，使用默认策略
- **选择风格生成**：弹出 `.sheet` → `StylePickerView`

**生成中态**：`ImmersiveProgressView` — 脉冲环 + 阶段文字渐变切换 + 渐变背景色相微动 + 取消按钮。`searchingCatalog` 阶段显示确定进度条。

**完成态**：展示歌单名 + 歌曲数 + 「在 Apple Music 中查看」+「重新生成」

**Error 态**：错误信息 + 重试按钮(仅 retryable)

**文件**：`HomeView.swift` → 重写 `todayCard`；新建 `ImmersiveProgressView.swift`

### 3. 最近歌单预览 — 替代原 QuickPick

原「想听点什么？」区域删除（功能合并到风格选择器）。改为展示最近 3 条 `RecommendationRecord`：

```
┌─ 最近歌单                          查看全部 → ─┐
│  🎵 每日推荐 · 7月26日    25首 · 风格探索 · 今天  │
│  🎸 摇滚精选 · 7月25日    20首 · 风格探索 · 昨天  │
│  🎷 爵士精选 · 7月24日    18首 · 风格探索 · 周三  │
└────────────────────────────────────────────────┘
```

- 「查看全部」→ `NavigationLink` push `PlaylistHistoryView`
- 点击卡片 → `NavigationLink` push `PlaylistDetailView`

**文件**：新建 `PlaylistCard.swift`；`HomeView.swift` 新增 `recentPlaylistsSection`

### 4. 底部统计 — 简化为 2 卡片

```
┌──────────────┐  ┌──────────────┐
│  📋  12      │  │  ⏰  每日    │
│  份歌单      │  │  6:00 自动  │
└──────────────┘  └──────────────┘
```

替代原来三列（歌单数 / 每日自动更新 / AI个性化）。

---

## 导航架构

保持 2 Tab 不变。Home Tab 的 `NavigationStack` 内做 push 导航：

```
TabView
├── 首页 (NavigationStack)
│   ├── HomeView
│   ├── PlaylistHistoryView (push)
│   └── PlaylistDetailView (push)
│
└── 设置 (NavigationStack)
    └── SettingsView
```

- `StylePickerView` 以 `.sheet` 方式从 HomeView 弹出
- 不需要第三个 Tab

---

## 新增页面

### StylePickerView (Sheet)

8 种风格预设（2 列网格），对应扩展后的 `QuickPickStyle`：

| 枚举 | 名称 | Emoji | promptHint |
|------|------|-------|------------|
| `piano` **(新)** | 钢琴 | 🎹 | 推荐钢琴曲/钢琴独奏/钢琴伴奏的优美曲目 |
| `classical` **(新)** | 古典 | 🎻 | 推荐古典音乐/交响乐/室内乐经典作品 |
| `rock` | 摇滚 | 🎸 | 推荐摇滚/另类/独立摇滚，注重吉他编排 |
| `jazz` | 爵士 | 🎷 | 推荐爵士/融合/冷爵士，注重旋律和即兴 |
| `english` **(新)** | 英文 | 🌍 | 推荐热门/经典英文歌曲，欧美流行 |
| `instrumental` | 纯音乐 | 🎹 | 推荐纯音乐/器乐，适合专注或放松 |
| `surprise` | 来点不一样的 | 🔀 | 跨风格随机推荐，跳出舒适区 |
| `sleep` | 睡前放松 | 🌙 | 推荐舒缓放松的音乐，适合睡前 |

点击卡片 → dismiss sheet → 触发 `triggerStyledRecommendation(style:)`

### PlaylistHistoryView (Push)

- `List` + `@Query` 按 `date` 降序展示所有 `RecommendationRecord`
- 每行：emoji + 歌单名 + 歌曲数 + 策略 + 日期
- Swipe-to-delete → 删除 SwiftData 记录
- 空态：「还没有生成过歌单」
- 点击 → push `PlaylistDetailView`

### PlaylistDetailView (Push)

- 歌单元数据（策略、歌曲数、生成时间）
- 完整歌曲列表（复用 `TrackRow`）
- 「在 Apple Music 中打开」按钮
- 「删除此歌单」按钮（destructive + 确认弹窗）
- **注意**：删除仅移除本地记录，Apple Music 中的播放列表保留

---

## Prompt 比例调整

**PromptBuilder.swift** 第 67 行，从：

```
4. 中文歌曲占比 70-80%，英文歌曲占比 20-30%
```

改为：

```
4. 推荐歌曲的语言/类型比例：
   - 中文歌曲：约占 6/10，包括华语流行、民谣、国语经典等
   - 纯音乐/无人声器乐：约占 2/10，如钢琴曲、古典乐、后摇等
   - 非英文外语歌曲：约占 1/10，如日语、韩语、法语等
   - 英文歌曲：约占 1/10
   以上比例为近似值，优先保证推荐质量
```

---

## 沉浸式动画要点

`ImmersiveProgressView` 组件：

1. **脉冲环**：`Circle().trim()` + `rotationEffect` 驱动 repeating animation，带 glow shadow
2. **阶段切换**：`.id(state.stageIdentifier)` + `.transition(.opacity)` 实现文字淡入淡出
3. **渐变背景**：`TimelineView(.animation)` 驱动色相微动（蓝↔紫↔青）
4. **完成爆发**：`.scaleEffect` + `.spring()` 从 0.8 到 1.0，checkmark 弹入
5. **搜索进度**：`ProgressView(value:found, total:total)` 确定进度条

`RecommendationState` 新增 `stageIdentifier` 计算属性用于动画 keying。

---

## 文件变更清单

### 修改 (MODIFY)

| 文件 | 改动 |
|------|------|
| `Songly/Views/HomeView.swift` | 全面重构：header, todayCard, recentPlaylists, stats, sheet/push |
| `Songly/ViewModels/HomeViewModel.swift` | 新增 `triggerStyledRecommendation(style:)`, `recentRecords`, `showStylePicker` |
| `Songly/Models/RecommendationStrategy.swift` | `QuickPickStyle` 扩展至 8 项；`RecommendationState` 新增 `stageIdentifier` |
| `Songly/Utils/PromptBuilder.swift` | 第 67 行比例从二分改为四分 (6:2:2:1) |
| `Songly/SonglyApp.swift` | 确保 NavigationStack 传递 modelContainer 环境 |
| `Songly/Views/Components/StyleButton.swift` | 适配风格选择器的大卡片样式 |

### 新建 (CREATE)

| 文件 | 用途 |
|------|------|
| `Songly/Views/StylePickerView.swift` | 风格选择 Sheet，2 列网格 8 种风格 |
| `Songly/Views/PlaylistHistoryView.swift` | 歌单历史列表，@Query + swipe-delete |
| `Songly/Views/PlaylistDetailView.swift` | 歌单详情：曲目列表 + 管理操作 |
| `Songly/Views/Components/PlaylistCard.swift` | 可复用歌单摘要卡片 |
| `Songly/Views/Components/ImmersiveProgressView.swift` | 沉浸式生成进度动画组件 |

### 移除/归档

| 文件 | 处理 |
|------|------|
| `Songly/Views/QuickPickView.swift` | 功能合并到 StylePickerView，可删除 |
| `Songly/ViewModels/QuickPickViewModel.swift` | 逻辑迁移到 HomeViewModel + StylePickerViewModel |
| `Songly/Views/RecommendationResultView.swift` | 保留参考，曲目渲染逻辑复用到 PlaylistDetailView |

---

## 前置修复：移除 MockLLMService

实施计划之前，先解决 MockLLMService 静默降级的问题：

1. 删除 `MockLLMService` 类（`LLMService.swift` 中）

> ⚠️ **已过时（2026-09）**：`isAPIKeyConfigured` 现在**必须保留** —— Key 改由用户
> 在设置页提供后，它是「用户到底配没配」的唯一真相来源。本节其余部分（移除
> MockLLMService）仍然成立。本文件是历史实施方案，不做重写。
2. 移除 `LLMServiceProtocol` 协议（不再需要 mock 实现）
3. `SonglyApp.swift` 中直接使用 `LLMService()`，移除 `isAPIKeyConfigured` 判断
4. 如 API Key 未配置，`LLMService.recommend()` 直接抛出 `apiKeyNotConfigured` 错误 → UI 显示明确错误信息

这样就不会出现“以为在用真 API，实际跑的是 mock”的情况。

## 实施顺序

1. **前置修复**：移除 MockLLMService → 真机验证 API Key 能正常调用
2. **Foundation**：扩展 `QuickPickStyle` → 添加 `stageIdentifier` → 更新 `PromptBuilder`
3. **新组件**：`ImmersiveProgressView` → `PlaylistCard` → `StylePickerView`
4. **新页面**：`PlaylistDetailView` → `PlaylistHistoryView`
5. **HomeView 重构**：Header → todayCard → recentPlaylists → stats → sheet/NavigationLink 接线
6. **HomeViewModel 更新**：新方法 + 新状态
7. **集成测试**：直接生成 / 选择风格生成 / 查看历史 / 详情 / 删除

---

## 验证

1. 构建通过：`xcodebuild -project Songly.xcodeproj -scheme Songly -destination 'platform=iOS Simulator,name=iPhone 17' build`
2. 真机验证完整流程：授权 → 直接生成歌单 → 完成 → 查看歌单详情 → 删除
3. 验证风格选择流程：选择风格 → Sheet 弹出 → 选择「钢琴」→ 生成 → 歌单出现在 Apple Music
4. 验证歌单历史：生成多个歌单 → 首页预览显示最近 3 个 → 查看全部 → 列表正确 → 滑动删除
5. 验证 Prompt 比例：检查生成的歌单中文/纯音乐/外语/英文比例是否接近 6:2:2:1
