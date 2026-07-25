# 乐遇 Songly — 开发计划

> **版本**: v1.1 — MVP（专家评审修订版）
> **最后更新**: 2026-07-13
> **关联文档**: [PRD](./prd.md) | [系统设计](./architecture.md)

---

## 1. 总体时间线

```
Week 1-2               Week 3               Week 4-5
┌──────────────────────┬───────────────────┬──────────────────┐
│ MVP 开发              │ 打磨 + TestFlight  │ MVP 验证          │
│ 核心管线 + 自动化     │ 测试 + 发布        │ 自用 + 内测       │
│                      │                   │                  │
│ M1→M2→M3→M4→M5→M6   │ M7→M8→M9          │ 收集反馈 + 决策    │
└──────────────────────┴───────────────────┴──────────────────┘
```

> ⚠️ **时间线说明：** 以上为理想排期（单人全职、无中断）。实际开发中，外部 API 调试（MusicKit、DeepSeek）、iOS 26.5 Beta 兼容问题、以及个人时间碎片化都可能导致周期延长至 3-4 周。**这是正常的**——MVP 的目标是验证推荐质量，不是赶工期。

### "行走骨架"策略（推荐）

与其按里程碑线性推进，建议在前 3 天先做一个**硬编码歌单的端到端行走骨架**：

1. M1 基础设施 + M2 授权
2. 用 5 首硬编码歌曲创测试歌单（跳过 LLM）
3. 验证：授权 → 创建歌单 → Apple Music 中可见

这个骨架一旦跑通，最不确定的 MusicKit 集成就被排除了。之后再接入 LLM，出问题时可以明确判定是 LLM 侧的问题。

---

## 2. 里程碑 (Milestones)

### M1 — 项目基础设施 ✅ (已完成)

> **目标**: 项目骨架搭建，可编译运行

| # | 任务 | 产出 | 状态 |
|---|------|------|------|
| 1.1 | Xcode 项目配置 | 可编译运行 | ✅ Done |
| 1.2 | SwiftData ModelContainer 注入 | SonglyApp 入口就绪 | ✅ Done |
| 1.3 | 基础文件结构搭建 | 按架构文档创建目录 | ⬜ Todo |
| 1.4 | API Key 通过 `INFOPLIST_KEY_` 前缀注入 .xcconfig | DeepSeek API Key 配置 | ⬜ Todo |
| 1.5 | `.gitignore` 添加 `.xcconfig` | 密钥不入库 | ⬜ Todo |
| 1.6 | Info.plist 添加 `NSAppleMusicUsageDescription` | 授权弹窗正常显示 | ⬜ Todo |
| 1.7 | 创建 `PrivacyInfo.xcprivacy` | 隐私清单（声明向 api.deepseek.com 传输数据） | ⬜ Todo |

### M2 — MusicKit 集成 + 授权流程

> **目标**: 完成用户授权 → 读取收藏的完整闭环

| # | 任务 | 产出 | 测试验收 |
|---|------|------|----------|
| 2.1 | 创建 `MusicKitService` + Protocol | 授权/读取/搜索接口定义 | Protocol 可 mock |
| 2.2 | 实现授权：先 `currentStatus` 再 `request()` | 仅在 `.notDetermined` 时弹窗 | 首次弹出授权；已拒绝则直接展示引导页 |
| 2.3 | 实现 `fetchLibrarySongs(limit:since:)` | 增量读取：首次全量 ≤200，后续按 `lastSyncDate` 增量 | 有收藏返回非空列表；无收藏返回空列表不崩溃 |
| 2.4 | 实现 `searchTrack(title:artist:)` | 三层匹配：精确→歌名→艺人比对 | 热门歌名一次命中；冷门歌名容错返回 nil 不抛异常 |
| 2.5 | 实现授权拒绝引导 UI | `ContentUnavailableView` + 跳转设置按钮 | 拒绝后看到引导页，点击可跳转系统设置 |
| 2.6 | `HomeView` 授权状态集成 | 首页根据授权状态展示不同 UI | authorized → 正常首页；denied → 引导页 |
| 2.7 | `SettingsView` 骨架 | 授权状态 + 通知状态 + 关于信息 | 页面可正常展示 |
| 2.8 | 收藏列表增量缓存 | SwiftData `lastSyncDate` 读写 | 第二次 fetch 仅拉取新增歌曲 |

**关键文件：**
- `Songly/Services/MusicKitService.swift`
- `Songly/Views/HomeView.swift`
- `Songly/Views/SettingsView.swift`
- `Songly/Views/OnboardingView.swift`

### M3 — LLM 推荐引擎

> **目标**: DeepSeek API 调通，能生成推荐歌单并解析

| # | 任务 | 产出 | 测试验收 |
|---|------|------|----------|
| 3.1 | 创建 `LLMService` + Protocol | API 调用接口定义 | Protocol 可 mock |
| 3.2 | 实现 DeepSeek API 客户端 | HTTP 请求 + 响应解析 | API Key 正确 → 返回推荐列表；Key 错误 → 明确错误提示 |
| 3.3 | 实现 `PromptBuilder`（含 token 管理） | 策略+收藏+历史 → prompt，自动控制 token 预算 | 200 首歌输入自动采样至 token 限制内；输出包含去重列表 |
| 3.4 | 实现响应解析器（容错，基于真实输出） | 支持多种 LLM 实际输出格式 | 先跑 5 次真实 API 请求，收集格式后验证解析器 |
| 3.5 | 实现重试逻辑 | 超时 10s，3 次指数退避 (1s/2s/4s) | 模拟网络失败，验证重试 3 次后报错 |
| 3.6 | 创建 `MockLLMService` | 开发用 mock，返回假推荐 | 无需网络即可调试 UI |

**关键文件：**
- `Songly/Services/LLMService.swift`
- `Songly/Utils/PromptBuilder.swift`
- `Songly/Models/TrackItem.swift`

### M4 — 推荐引擎编排 + 播放列表创建

> **目标**: 完整跑通"收藏 → LLM → 搜索 → 创建歌单"全链路

| # | 任务 | 产出 | 测试验收 |
|---|------|------|----------|
| 4.1 | 创建 `RecommendationEngine`（actor） | actor 编排器 + `cancel()` | actor 序列化执行正确 |
| 4.2 | 实现 `PlaylistService`（含同名检测） | 创建/更新/查找播放列表 | 创建歌单后 Apple Music 中可见 |
| 4.3 | 实现播放列表去重逻辑 | 同日已有歌单 → 更新而非新建 | 同一天多次触发，只有一个歌单 |
| 4.4 | 实现 `HomeViewModel`（`@Observable` `@MainActor`） | 持有推荐状态、进度，桥接 engine → UI | loading → completed 状态 UI 正确切换 |
| 4.5 | 实现推荐结果 UI (`RecommendationResultView`) | 歌单预览 + 跳转按钮 | 点击"在 Apple Music 中打开"可跳转 |
| 4.6 | 实现 SwiftData 持久化（先存记录再建歌单） | 推荐记录写入本地，保存失败不创建歌单 | 重启 App 后历史数据仍在；保存失败无孤立歌单 |
| 4.7a | 端到端正常路径测试 | 有收藏 → 点推荐 → Apple Music 中出现新歌单 | 全链路可跑通 |
| 4.7b | 端到端异常路径测试 | 空收藏、LLM 失败、匹配率为 0、保存失败 | 各有正确的 error 状态 + UI 提示 |
| 4.7c | 端到端匹配率边界测试 | <20% 匹配率 | 弹出确认对话框，用户可选择"创建"/"换一批" |

**关键文件：**
- `Songly/Services/RecommendationEngine.swift`
- `Songly/Services/PlaylistService.swift`
- `Songly/ViewModels/HomeViewModel.swift`
- `Songly/Views/RecommendationResultView.swift`

**验收标准（M1-M4 完成后）：**
- [ ] 首次启动能完成 MusicKit 授权
- [ ] 点击"生成推荐"后，Apple Music 中出现新播放列表
- [ ] 播放列表名称格式正确: `🎵 每日推荐 · M月D日`
- [ ] 同日重复触发不会创建重复歌单
- [ ] SwiftData 保存失败时不会创建孤立歌单
- [ ] 生成的歌单可在 Apple Music App 中打开并播放

---

### M5 — 每日推荐自动化

> **目标**: 从手动触发升级为每日自动推荐

| # | 任务 | 产出 | 测试验收 |
|---|------|------|----------|
| 5.1 | 创建 `BackgroundTaskService` | BGAppRefreshTask 注册 + 调度（`earliestBeginDate` 设为明天 6:00 AM） | 注册不报错，首次调度成功 |
| 5.2 | 实现后台 handle + expirationHandler（合并） | 后台唤醒 → 跑推荐管线；超时调 `engine.cancel()` | 开发环境 LLDB 模拟可触发；超时取消不崩溃 |
| 5.3 | 实现前台补充检查 + 防重复查询（合并） | App 打开时检查今日是否已生成，未生成则补跑 | 后台未执行 → 前台自动补跑；同一天不会重复生成 |
| 5.4 | `NetworkMonitor` 网络状态跟踪 | `NWPathMonitor` 实时监控，离线不调 LLM，恢复后补跑 | 断网 → 报错不等待超时；恢复网络 → 自动触发 |

**关键文件：**
- `Songly/Services/BackgroundTaskService.swift`
- `Songly/Services/NetworkMonitor.swift`

**注意：**
- iOS 后台任务是"尽力而为"的——执行窗口通常 5-15 秒，系统随时可能 kill 任务
- **前台补充检查是真正的可靠性保障**，后台只是辅助
- BGAppRefreshTask 仅在真机上可测试，模拟器不支持
- 低电量模式禁止后台任务；设备重启后需首次打开 App 才会恢复调度

### M6 — "想听"快捷选择（MVP 精简版）

> **目标**: 用户可通过预设按钮即时切换推荐风格

| # | 任务 | 产出 | 测试验收 |
|---|------|------|----------|
| 6.1 | 创建 `QuickPickStyle` 枚举 + 3 种风格 | 🎸摇滚 / 🎷爵士 / 🔀惊喜（MVP 精简单，5 种风格枚举保留但只展示 3 个） | 每种风格关联正确的 prompt 提示词 |
| 6.2 | 实现 `QuickPickView` + `QuickPickViewModel` | 风格按钮网格 + 触发对应策略推荐 | 点击不同按钮生成不同风格的歌单 |
| 6.3 | PromptBuilder 支持风格参数 | 摇滚/爵士/惊喜注入不同策略描述 | 生成的歌单风格与选择一致 |

**关键文件：**
- `Songly/Views/QuickPickView.swift`
- `Songly/ViewModels/QuickPickViewModel.swift`
- `Songly/Views/Components/StyleButton.swift`
- `Songly/Models/RecommendationStrategy.swift`

**v1.1 精简说明：**
- Loading 动画使用系统 `ProgressView`（不用自定义动画）
- 推荐结果复用 `RecommendationResultView`（不新建独立结果 UI）
- MVP 只展示 3 种风格按钮，5 种枚举预留给 Phase 2

### M7 — 推送通知（MVP 精简版）

> **目标**: 歌单就绪后通知用户

| # | 任务 | 产出 | 测试验收 |
|---|------|------|----------|
| 7.1 | 创建 `NotificationService` | 权限请求 + 本地通知发送 | 首次请求权限弹窗 → 允许/拒绝 |
| 7.2 | 通知权限降级处理 | 拒绝后 App 内 badge 提示 | 通知关闭时首页展示角标数字 |
| 7.3 | 推荐完成后发送通知 | `sendRecommendationReady(count:)` | 点击通知打开 App |

**关键文件：**
- `Songly/Services/NotificationService.swift`

**v1.1 精简说明：**
- 去掉花式文案轮换（MVP 一条固定文案即可）
- 去掉 App 图标角标（仅首页 badge）
- "今日推荐已就绪" 足够满足验证需求

---

### M8 — 打磨 + 测试

> **目标**: 修复边缘情况，确保稳定性

| # | 任务 | 产出 | 测试验收 |
|---|------|------|----------|
| 8.1 | 网络错误 UI | 离线 → `ContentUnavailableView`；网络恢复 → 自动补跑 | 飞行模式 → 提示明确；关闭飞行模式 → 自动触发 |
| 8.2 | 授权边缘情况 UI | 授权未确定/已拒绝/运行时撤销 | 每种状态有正确 UI |
| 8.3 | API 错误 UI | LLM 超时/余额不足/4xx/5xx 均有不同提示 | 断网/API Key 失效等场景测试通过 |
| 8.4 | 空状态 UI | `ContentUnavailableView`：无收藏/无推荐/无网络 | 每个空状态有引导文案，非纯空白页 |
| 8.5 | Swift Testing 单元测试 | PromptBuilder, 解析器, SwiftData 模型序列化 | `xcodebuild test` 通过 |
| 8.6 | UI 测试关键路径 | 授权流程 + 推荐触发 + 错误恢复 | UI 测试通过 |
| 8.7 | iPad 适配 | Split View / Slide Over 正常 | iPad 上 UI 不拉伸变形 |
| 8.8 | 性能验证 | 冷启动 < 2s，推荐 < 30s，os_signpost 打点 | MetricKit 确认 |
| 8.9 | 无障碍基础 | Dynamic Type + VoiceOver 标签 + 最小 44×44 触摸区域 | VoiceOver 可操作核心流程 |
| 8.10 | README 更新 | 构建/运行/测试说明 | 新人可按 README 跑通 |

---

### M9 — TestFlight 发布准备

> **目标**: 将构建分发给内测用户

| # | 任务 | 产出 | 测试验收 |
|---|------|------|----------|
| 9.1 | App Store Connect 创建 App Record | Bundle ID `cn.wflixu.Songly` 注册 | App Store Connect 中可见 |
| 9.2 | 配置签名证书 + Provisioning Profile | Xcode 自动管理签名 | Archive 成功 |
| 9.3 | 上传首个 TestFlight Build | 内测版本可供下载 | TestFlight App 中可安装 |
| 9.4 | 准备内测说明文档 | 测试指引 + 已知问题 + 反馈渠道 | 测试者知道要做什么 |

> **注意：** TestFlight 外部测试审核需要 24-48 小时，**不晚于 Week 3 周一提交**，确保 Week 4 测试者可下载。

---

## 3. 任务依赖图

```
M1 (基础设施) ──→ M2 (MusicKit) ──→ M4 (编排引擎) ──→ M5 (每日自动)
                 ↘                ↗                    M6 (想听)
                  M3 (LLM引擎) ──┘                    M7 (推送)
                                                       ↘
                                          M8 (打磨) ←── M9 (TestFlight)
```

- **M2 和 M3 可任意顺序开发**（调 MusicKit vs 调 DeepSeek API，互不依赖）
- **M4 依赖 M2 + M3**（编排器需要两个 Service）
- **M5, M6, M7 依赖 M4**（都需要推荐引擎），三者间**可任意顺序**
- **M9 依赖 M8**（打磨完成再发布）
- ⚠️ 单人开发意味着"可并行"仅指顺序可互换，**不能真正缩短时间**

---

## 4. 按天排期（理想情况）

### Week 1

| 天 | 上午 | 下午 | 里程碑 |
|----|------|------|--------|
| **Day 1** | M1.3 文件结构 + M1.4 .xcconfig + M1.6 Info.plist | M2.1 Protocol + M2.2 授权 + M2.7 SettingsView 骨架 | M1 ✅ |
| **Day 2** | M2.3 增量读取 + M2.4 曲库搜索 | M2.5 拒绝引导 + M2.6 HomeView + M2.8 增量缓存 | M2 ✅ |
| **Day 3** | M3.1 LLMService Protocol + M3.2 API 客户端 | M3.3 PromptBuilder (含token管理) + M3.4 响应解析 | — |
| **Day 4** | M3.5 重试逻辑 + M3.6 MockLLMService | M4.1 RecommendationEngine (actor) | M3 ✅ |
| **Day 5** | M4.2 PlaylistService + M4.3 去重 | M4.4 HomeViewModel + M4.5 结果 UI | — |

### Week 2

| 天 | 上午 | 下午 | 里程碑 |
|----|------|------|--------|
| **Day 6** | M4.6 SwiftData 持久化 (先存后建) | M4.7a 正常路径测试 + M4.7b 异常路径测试 | M4 ✅ |
| **Day 7** | M4.7c 匹配率边界测试 | M5.1 BackgroundTaskService + M5.2 后台 handle | — |
| **Day 8** | M5.3 前台补充检查 + M5.4 NetworkMonitor | M6.1 风格枚举 + M6.2 QuickPickView+VM | M5 ✅ |
| **Day 9** | M6.3 PromptBuilder 风格扩展 | M7.1 NotificationService + M7.2 降级 + M7.3 发送通知 | M6 ✅ M7 ✅ |
| **Day 10** | M8.1 网络错误 + M8.2 授权边缘 + M8.3 API 错误 | M8.4 空状态 + M8.5 单元测试 | — |

### Week 3

| 天 | 上午 | 下午 | 里程碑 |
|----|------|------|--------|
| **Day 11** | M8.6 UI 测试 + M8.7 iPad 适配 | M8.8 性能验证 + M8.9 无障碍 | — |
| **Day 12** | M8.10 README | M9.1+M9.2 App Store Connect + 签名 | M8 ✅ |
| **Day 13** | M9.3 TestFlight 上传 + M9.4 内测说明 | 自用测试 + prompt 优化 | M9 ✅ 🎉 |

> ⚠️ **再次提醒：** 这是理想排期。实际执行中，遇到 iOS Beta bug、API 调试卡壳、个人事务等，延至 3-4 周也完全正常。MVP 的目标是验证推荐质量，不是赶工。

---

## 5. MVP 验证期计划（Week 3-5）

### 5.1 Go/No-Go 量化标准

> **在验证期开始前就定义好阈值，避免乐观偏差。**

| 指标 | Go 阈值 | No-Go 阈值 | 测量方式 |
|------|---------|------------|----------|
| 自己连续使用天数 | ≥ 14 天 | < 7 天就失去兴趣 | 自记录 |
| 每日新鲜感（自评） | ≥ 60% 天数 ≥ 4 分 | < 30% 天数 ≥ 4 分 | 每日 1-5 评分 |
| MusicKit 搜索匹配率 | ≥ 80% | < 50% | 自动统计 |
| 内测用户满意度 | ≥ 60% 表示"还不错/推荐" | < 30% 正面反馈 | 每日一句话反馈 |
| 想听风格匹配准确率 | ≥ 70% "基本匹配" | < 30% | 自评 |

**决策规则：**
- **Go:** 全部 5 项指标达到 Go 阈值 → 进入 Phase 2（策略轮换 + 反馈闭环 + 商业化）
- **条件 Go:** 3-4 项达标 → 再迭代一轮（优化 prompt + 修复匹配问题）后重新评估
- **No-Go:** ≥ 3 项未达标 → 承认 LLM 推荐在 Apple Music 曲库约束下效果不足，止损

### 5.2 验证期活动

| 周次 | 活动 | 产出 |
|------|------|------|
| **W3** | 自己每天使用，记录推荐质量 | 每日推荐质量评分 + 改进笔记 |
| **W3** | Prompt 优化迭代 | 至少 3 轮 prompt 调整 |
| **W3 周一** | 提交 TestFlight 审核 | 确保 W4 测试者可下载 |
| **W4** | 邀请 5-10 人内测 | TestFlight 分发 |
| **W4** | 收集内测反馈 | 反馈汇总表格 |
| **W4 末** | 对照 Go/No-Go 标准决策 | Go / 条件 Go / No-Go |

### 5.3 数据收集模板

| 日期 | 策略 | 匹配率 | 新鲜感(1-5) | 好听(1-5) | 实际听了几首 | 备注 |
|------|------|--------|------------|----------|------------|------|
| 7/15 | 风格探索 | 88% | 4 | 3 | 5 | 今天推的太流行 |
| 7/16 | 风格探索 | 92% | 5 | 5 | 18 | 有惊喜！|
| ... | ... | ... | ... | ... | ... | ... |

### 5.4 内测用户筛选标准

- **必要条件：** 中国区 Apple Music 付费订阅用户
- **多样性：** 至少包含 2 种不同音乐口味（如华语流行 / 欧美摇滚 / 日系ACG）
- **排除：** 不选"什么都可以"的随和型用户——他们反馈偏正向但信号弱
- **理想：** 选平时会主动找新歌听、有一定音乐品味要求的用户

### 5.5 内测反馈问题模板

1. 今天的推荐整体怎么样？（1-5 分）
2. 有没有让你惊喜/失望的歌？具体是哪首？
3. 歌单风格和你选的标签匹配吗？
4. 推荐的歌有多少首是你本来就知道的？（新歌 vs 老歌比例）
5. 你实际听了其中几首？
6. 还有什么想吐槽的？

---

## 6. 风险与应急

| 风险 | 概率 | 影响 | 应急方案 |
|------|------|------|----------|
| DeepSeek API 不稳定 | 中 | 高 | 接入通义千问作为备用 LLM（半天工作量） |
| **MusicKit 搜索匹配率低** | 中 | **高** | 核心风险！优化 prompt 约束 LLM 推荐热门/正式发行曲目；支持低匹配率时用户选择仍创建或重试 |
| **LLM 推荐质量差** | **高** | 高 | MVP 核心验证命题——默认预期是首次 prompt 质量不理想，需持续迭代。如果 3 轮优化后仍不达标，考虑切换 LLM provider 或调整 prompt 策略 |
| 后台任务不可靠 | **确定** | 低 | 前台补充检查是**主路径**，后台只是辅助。文档已明确此预期 |
| App Store 审核受阻 | 低 | 高 | MusicKit 为标准 API，使用合规；如有问题可申诉 |
| iOS 26.5 Beta 兼容性 | 中 | 中 | 关注 Beta 更新，及时适配 API 变化；预留 1-2 天 buffer |
| **Apple Music 订阅要求限制内测范围** | 高 | 中 | 筛选内测用户前先确认订阅状态；考虑为无订阅的潜在测试者提供少量 Apple Music 礼品卡 |
| 单人开发 bus factor | 低 | 极高 | 每日 push 代码；架构决策写入 ADR；关键配置文档化 |
| TestFlight 审核延迟 | 中 | 中 | 不晚于 W3 周一提交，留足 48h 审核 buffer |
| DeepSeek API Key 泄露 | 低 | 低 | 消费限额 50 元/月；独立 Key；每用户年成本 ~¥0.5，刷 Key 收益极低 |

---

## 7. 每日开发检查清单

每天开始前：
- [ ] 拉取最新代码
- [ ] 确认项目可编译运行
- [ ] 确认项目可编译运行

每次提交前：
- [ ] 代码编译通过 (`⌘+B`)
- [ ] 相关测试通过 (`⌘+U`)
- [ ] `.xcconfig` 文件未提交（在 `.gitignore` 中）
- [ ] 不包含硬编码的 API Key
- [ ] `PrivacyInfo.xcprivacy` 已更新（如有新增数据使用）
- [ ] Commit message 遵循 [Conventional Commits](https://www.conventionalcommits.org/)

---

## 附录 A: 关键文件清单

| 文件 | 里程碑 | 说明 |
|------|--------|------|
| `Songly/App/AppConfig.swift` | M1 | 全局常量（API endpoints, 超时配置等） |
| `Songly/App/AppEnvironment.swift` | M1 | 环境变量读取（INFOPLIST_KEY_DEEPSEEK_API_KEY） |
| `Songly/Models/RecommendationRecord.swift` | M1 | SwiftData 推荐记录模型（TrackInfo JSON 存储） |
| `Songly/Models/UserPreferences.swift` | M1 | SwiftData 用户偏好模型（不含 auth 状态缓存） |
| `Songly/Models/TrackItem.swift` | M3 | LLM 返回曲目模型 + TrackInfo 结构体 |
| `Songly/Models/RecommendationStrategy.swift` | M6 | 策略/风格枚举定义 |
| `Songly/Services/MusicKitService.swift` | M2 | MusicKit 授权+增量读取+并发搜索 |
| `Songly/Services/LLMService.swift` | M3 | DeepSeek API 客户端 + 响应解析 |
| `Songly/Services/PlaylistService.swift` | M4 | 播放列表 CRUD + 同名检测 |
| `Songly/Services/RecommendationEngine.swift` | M4 | actor 推荐管线编排器 |
| `Songly/Services/NotificationService.swift` | M7 | 推送通知管理 |
| `Songly/Services/BackgroundTaskService.swift` | M5 | 后台任务管理 + earliestBeginDate 修复 |
| `Songly/Services/NetworkMonitor.swift` | M5 | NWPathMonitor 网络状态监控 |
| `Songly/Utils/PromptBuilder.swift` | M3 | LLM Prompt 构造器（含 token 管理） |
| `Songly/ViewModels/HomeViewModel.swift` | M4 | @Observable @MainActor 首页状态管理 |
| `Songly/ViewModels/QuickPickViewModel.swift` | M6 | @Observable @MainActor 快捷选择 |
| `Songly/Views/HomeView.swift` | M2 | 首页 |
| `Songly/Views/OnboardingView.swift` | M2 | 首启引导页 |
| `Songly/Views/QuickPickView.swift` | M6 | "想听"风格选择（3 按钮） |
| `Songly/Views/RecommendationResultView.swift` | M4 | 推荐结果展示 + 跳转按钮 |
| `Songly/Views/SettingsView.swift` | M2 | 设置页（授权+通知+关于） |
| `Songly/Views/Components/StyleButton.swift` | M6 | 风格按钮组件（≥44×44 触摸区域） |
| `Songly/Views/Components/TrackRow.swift` | M4 | 歌曲行组件 |
| `Songly/Localization/Localizable.xcstrings` | M1 | 字符串目录 |
