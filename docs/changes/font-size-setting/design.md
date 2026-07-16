<!-- doc-init template version: v1.0 -->
# Design: font-size-setting（结果浮窗字号可配）

- **Owner**: 技术方案官（Claude / Fable），on behalf of wu.nerd
- **Reviewers**: Codex（对抗式交叉评审）、wu.nerd
- **状态**: Draft → 待评审
- **创建日期**: 2026-07-16
- **关联**: [proposal.md](./proposal.md) · [spec-delta](./specs/grammar-review/spec.md) · Issue RAS-56（从 RAS-53 拆出，proposal 中写 RAS-54 为拆分时占位号，实际落在 RAS-56）
- **分支**: `feat/font-size-setting`（基于 `feat/53-ai-followup`）

## 1. 概述

给结果浮窗引入**统一字体来源** `ReviewTypography`：一个由「字号档位」派生的语义角色→字号映射表，取代 `ReviewView.swift` 内 39 处散落的 `.caption` / `.callout` / `.system(size:)` 硬编码。设置页新增 4 档预设字号（小 / 标准 / 大 / 特大），**默认「大」**（正文 14.5pt > 旧基准 13pt，满足「比现状大一档」）。档位经 `SettingsStore` 持久化（UserDefaults），改动即时生效；`ReviewWindowController` 显式订阅档位变化触发一次既有 `refreshMeasurement` 链路，维持 RAS-53 已修的 `maxH` 封顶 / 中部滚动 / 底栏固定，不改 `ReviewWindowSizing` clamp 数学。

## 2. 关键决策

### D1 交互形态：4 档预设（segmented Picker），不用滑块

| 维度 | 预设档（选定） | 滑块 |
|---|---|---|
| 可测性 | 离散枚举，确定性断言 | 连续浮点，边界值矩阵大 |
| spec 对齐 | spec-delta 通篇用「档位 / 最大档」措辞 | 需重述 spec |
| 平台惯例 | macOS 系统设置·文字大小即预设档 | 少见 |
| 代码惯例 | 与 `reviewTheme` / `windowBehaviorMode` 的 rawValue 枚举 + segmented 模式完全同款 | 需新增防抖与任意缩放处理 |

**结论：预设档。** 滑块的「无级微调」收益对 4 档区间（12–16pt）无实际意义，成本（防抖、测试矩阵、任意浮点下的布局验证）显著更高。

### D2 档位定义：`ReviewFontTier` 4 档，锚定旧正文基准 13pt

| 档位 | rawValue | 显示名 | 正文 pt | scale（=正文/13） |
|---|---|---|---|---|
| small | `small` | 小 | 12 | ≈0.923 |
| standard | `standard` | 标准 | 13（=旧基准） | 1.0 |
| **large（默认）** | `large` | 大 | **14.5** | ≈1.115 |
| xLarge | `xlarge` | 特大 | 16 | ≈1.231 |

- **锚点**：`ReviewTypography.legacyBodyBaseline = 13`（本 change 前正文无显式字体 → macOS `.body` 默认 13pt）。spec「默认大于旧正文基准」的断言即 `Typography(默认档).body > legacyBodyBaseline`，不依赖散落硬值。
- 「标准」档 = 按现状固化的 pt 表（scale 1.0），视觉还原现状观感（准确口径见 D3），给想回到旧观感的用户留退路。
- 所有派生字号做**半点取整**（`round(pt × scale × 2) / 2`），避免怪异小数导致的渲染模糊。
- 默认档经 `UserDefaults.register(defaults:)` 注册为 `large`：全新安装与**未显式设置过的老用户**升级后都得到新默认（与 `streamingEnabled` / `reviewTheme` 既有升级语义一致）；显式改过档位的用户不受影响。非法 rawValue fallback `large`（与 `WindowBehaviorMode.rawValueOrDefault` 模式一致）。

### D3 统一字体来源：`ReviewTypography` 语义角色表（新文件，纯逻辑可单测）

```swift
/// 结果浮窗统一字体来源：档位 → 语义角色字号。纯逻辑、无 UI 依赖，可单测。
struct ReviewTypography {
    static let legacyBodyBaseline: CGFloat = 13   // 本 change 前正文 = macOS .body 默认
    let tier: ReviewFontTier
    // 角色字号（base pt @standard × tier.scale，半点取整）：
    var body: CGFloat        // 13 → 正文卡片（修正结果 / 地道版 / 流式预览 / loading / error 文案）
    var bubble: CGFloat      // 12.5 → 追问气泡 / Markdown 回答 / composer 输入框
    var issueLine: CGFloat   // 12 → issue 卡 before→after 行（原 .callout）
    var header: CGFloat      // 11 → 顶部状态 Label（原 .subheadline，semibold）
    var sectionLabel: CGFloat // 10 → 区块小标题 / 总评 / 直译 / reason / hint（原 .caption）
    var badge: CGFloat       // 10 → 类别徽标 / 严重度 / 「修正 N」chip（原 .caption2 / system 10）
    var chipTitle: CGFloat   // 12.5 → ActionChip 标题（medium rounded）
    var chipIcon: CGFloat    // 11 → ActionChip 图标（semibold）
    var iconAction: CGFloat  // 13 → composer 尾部按钮图标（semibold）
    // Font 便捷访问器：bodyFont / bubbleFont / … 内部统一 .system(size:weight:design:)
}
```

**「标准档 = 现状」的准确口径**（Codex 评审🟡5 修正）：现状混用语义字体（`.body`/`.callout`/`.subheadline`/`.caption`），其 pt 值是「macOS 默认内容尺寸下」的当前系统取值（13/12/11/10）；本设计将其**固化为显式 pt**。standard 档承诺的是**视觉上还原现状观感**（按上述固化表），不承诺与旧渲染像素级逐点相等；锚点回归测试锁的是 typography 表自身不漂移（§7-3）。

**替换策略：`ReviewView.swift` 内全部文本字号点（含无显式 font 的正文/diff）改为 typography 角色引用，消灭系统 text style 与字面量。** 逐点映射表见 §4。完成门禁为双层（Codex 评审🟡4 修正）：
1. **grep 辅助门禁**（抓显式残留）：`grep -nE '\.font\(\.(caption|callout|subheadline|body|footnote|title|headline|largeTitle)|\.system\(size:' Sources/LangFix/ReviewView.swift`，白名单（§4.5 标注「不缩放」各点）外零命中；
2. **checklist 主门禁**（抓「无显式 font」漏网——grep 抓不到）：按 §4.5 映射表逐行核对每个 `Text` / `TextField` / `Label` / 字体图标构造点已显式接 typography 或在白名单内，作为 PR review checklist 逐项打勾。

**传递方式（Codex 评审🔴2 修正）：单一真相源 + 逐级传参，双层保证两棵树同档位。**
- **root 层同源**：显示树 root（`ReviewView`）与测量树 root（`ReviewMeasurementView`）是两个独立构造的 root（`makeReviewView` / `makeMeasurementView` 分别构造），typography **不由 controller 作为参数注入**（注入路径会引入两处构造传错/传旧值的可能），而是两个 root 在 `body` 内各自从已有的 `@ObservedObject settings` 派生：`let typography = ReviewTypography(tier: settings.reviewFontTier)`——与 `theme` 的现有做法完全同模式，两树读的是同一个 `SettingsStore.shared`，结构上不存在「两 root 档位不一致」的输入。
- **子树逐级传参**：typography 随 `theme` 一路显式传入 `ReviewContent` 及全部子 view（子 view 加 `let typography: ReviewTypography` 字段），**不用 EnvironmentKey**——`refreshMeasurement` 每次新建独立 `NSHostingController(rootView: ReviewMeasurementView(...))`，Environment 若漏注入会静默 fallback 默认值 → 测量字号 ≠ 显示字号 → 窗口高度算错且编译期不可见；逐级传参下漏传是编译错误。
- 两树同档位另有生产路径测试兜底（§7-4b）。

### D4 持久化与即时生效：`SettingsStore` 新增 `reviewFontTierRaw`

```swift
@Published var reviewFontTierRaw: String { didSet { d.set(reviewFontTierRaw, forKey: K.reviewFontTier) } }
var reviewFontTier: ReviewFontTier { ReviewFontTier(rawValueOrDefault: reviewFontTierRaw) }
// register defaults 追加: K.reviewFontTier: ReviewFontTier.defaultTier.rawValue   // .large
```

- **显示即时生效**：`ReviewView` / `ReviewMeasurementView` 已 `@ObservedObject settings`，档位 `@Published` 变更 → 自动重绘，与主题「切换即时生效」同机制，零新增管线。
- 键名 `reviewFontTier`，UserDefaults（非敏感，不进 Keychain，与红线 Constraint-1 一致）。
- 不进 `AppConfig`（与 AI 引擎无关，同 `reviewTheme` 的处理理由）。

### D5 窗口重测量：显式订阅档位变化，复用 RAS-53 链路

`ReviewWindowController.init` 新增（与 `stateChangeCancellable` / `followUpChangeCancellable` 同模式）：

```swift
fontTierCancellable = SettingsStore.shared.$reviewFontTierRaw
    .dropFirst().removeDuplicates()
    .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshMeasurement() } }
```

- **为何显式订阅而不依赖既有隐式链**：隐藏测量宿主（`measurementHosting`）虽也观察 settings，其 preference 回调理论上会带动 `refreshMeasurement`，但该链依赖隐藏宿主的布局时机，间接且不可断言；spec 明确要求「字号变更触发一次重测量」，显式订阅是确定性的最短路径。重测量幂等（`updateNaturalSize` 有 0.5pt 阈值），多触发一次无害。
- **时序注意**：`$reviewFontTierRaw` 在 willSet 时机发出新值，`DispatchQueue.main.async` 延到下一 runloop 后 `refreshMeasurement` 新建测量树，此时 `settings.reviewFontTier` 已是新值——与既有两条订阅的 async 处理一致，无竞态。
- **不改 `ReviewWindowSizing`**：字号变大 → 测量 `natural.height` 变大 → 既有 `target` clamp 到 `maxH`、`isOverflowing` 翻转 → 中部滚动 + 底栏固定。封顶行为零新逻辑。

### D6 设置页 UI：通用区「弹窗主题」下方加一行 segmented

```swift
field("字号（结果浮窗）") {
    Picker("字号", selection: $settings.reviewFontTierRaw) {
        ForEach(ReviewFontTier.allCases) { t in Text(t.displayName).tag(t.rawValue) }
    }
    .pickerStyle(.segmented).labelsHidden()
}
```

与「弹窗主题」segmented 完全同构。不加实时预览示例（浮窗本体即时生效即是预览，设置页保持克制）。**设置页自身文本不缩放**（字号作用域 = 结果浮窗，见 proposal Out of Scope）。

## 3. 架构图

字号从设置到屏幕的两条生效路径（显示重绘 + 窗口重测量）：

```mermaid
flowchart LR
    SV[SettingsView<br/>segmented 4档] -->|写 rawValue| SS[SettingsStore<br/>@Published reviewFontTierRaw<br/>UserDefaults 持久化]
    SS -->|@ObservedObject 重绘| RV[ReviewView / ReviewContent<br/>ReviewTypography 逐级传参]
    SS -->|"$reviewFontTierRaw.sink（D5 新增）"| RWC[ReviewWindowController<br/>refreshMeasurement]
    RWC -->|sizeThatFits| MS[ReviewMeasurementView<br/>同一 ReviewContent]
    MS -->|natural size| SZ[ReviewWindowSizing<br/>clamp 数学不改]
    SZ -->|maxH 封顶 / isOverflowing| RV
```

## 4. 变更点与逐点映射（开发官执行清单）

### 4.1 新文件 `Sources/LangFix/ReviewTypography.swift`

`ReviewFontTier`（enum, String rawValue, CaseIterable, Identifiable, `defaultTier = .large`, `rawValueOrDefault`, `displayName`, `scale`）+ `ReviewTypography`（§2 D3 角色表 + Font 访问器）。

### 4.2 `SettingsStore.swift`

+1 `@Published reviewFontTierRaw` / K 键 / register 默认 / computed `reviewFontTier`（见 D4）。

### 4.3 `SettingsView.swift`

`generalSection` 内「弹窗主题」picker 之后插入字号 segmented（见 D6）。

### 4.4 `AppCoordinator.swift`（ReviewWindowController）

+1 `fontTierCancellable` 订阅（见 D5）。

### 4.5 `ReviewView.swift` 39 处字号点逐点映射

顶层 `ReviewView` / `ReviewMeasurementView` 从 `settings.reviewFontTier` 构造 `ReviewTypography`，随 `theme` 一路传入 `ReviewContent` 及全部子 view。

| 行（现状） | 现状字号 | 改为角色 |
|---|---|---|
| L126 ActionChip 图标 `system(11, semibold)` | 11 | `chipIcon` |
| L127 ActionChip 标题 `system(12.5, medium, rounded)` | 12.5 | `chipTitle` |
| L187 / L340 loading·error 文案（无显式 font） | body 13 | `body` |
| L216 / L246 / L427 / L430 / L433 状态 Label `.subheadline.bold()` | 11 | `header`（semibold） |
| L274 / L292 / L443 / L469 / L487 / L546 区块标题 `.caption` | 10 | `sectionLabel` |
| L279 / L454 / L548 正文卡片（无显式 font） | body 13 | `body` |
| L470 / L555 词级 diff `styledDiff(...)` 输出（无显式 font，Codex 评审🔴1 补） | body 13 | `body`（在 reduce 结果 Text 上整体 `.font(bodyFont)`，分段样式只保留颜色/删除线/加粗） |
| L276 / L445「复制/已复制」原生小按钮、ProgressView | 控件 | **不缩放**（原生 `controlSize(.small)` 控件，非文本区；改 font 不改控件度量，缩放反而破坏对齐，白名单） |
| L287 / L462 总评 `.caption`；L312 HintLine 文本 `.caption`（直译/理由共用） | 10 | `sectionLabel` |
| L309 HintLine 图标 `system(10, semibold)` | 10 | `badge`（semibold） |
| L339 ErrorView 感叹号 `.largeTitle` | — | **不缩放**（装饰图标，白名单） |
| L505 / L506「AI 追问」分隔行 `.caption2` / `.caption` | 10 | `badge` / `sectionLabel` |
| L554 地道版对照标题 `.caption2` | 10 | `badge` |
| L570 / L571 composerNotice `.caption2` | 10 | `badge` |
| L601 composer TextField `system(12.5)` | 12.5 | `bubble` |
| L643 iconButton `system(13, semibold)` | 13 | `iconAction` |
| L717 ReferenceChips「修正 N」`system(10, semibold)` | 10 | `badge`（semibold） |
| L742 UserBubble `system(12.5)`；L814 MarkdownText `system(12.5)` | 12.5 | `bubble` |
| L780 / L781 FailedBubble `.caption.bold()` / `.caption` | 10 | `sectionLabel` |
| L843 / L851 / L856 / L863 / L872 issue 徽标与箭头 `.caption2` | 10 | `badge` |
| L875 issue before→after 行 `.callout` | 12 | `issueLine` |
| L876 issue reason `.caption` | 10 | `sectionLabel` |
| L917 / L920 折叠胶囊标题 / pin `system(13/10)` | — | **不缩放**（胶囊 148×44 固定 frame，缩放会截断；非「结果浮窗文本区」） |
| L801 TypingCursor 光标高 14（frame 非 font） | — | 跟随缩放：`bubble + 1.5`（低风险细节，保持与气泡文字等高观感） |

### 4.6 不改的部分（显式声明）

- `ReviewWindowSizing.swift`：clamp 数学、`minWidth/minHeight`、比例常量原样。
- `ReviewTheme` 体系：字号与主题正交，不并入 theme。
- 设置页自身字体、菜单栏、折叠胶囊。
- `AppConfig` / 引擎 / 提示词：零感知。

## 5. 影响面

| 文件 | 变更 | 风险 |
|---|---|---|
| `ReviewTypography.swift`（新） | ~80 行纯逻辑 | 低（可单测） |
| `SettingsStore.swift` | +4 行模式化代码 | 低 |
| `SettingsView.swift` | +8 行 | 低 |
| `AppCoordinator.swift` | +5 行订阅 | 低（幂等重测量） |
| `ReviewView.swift` | 39 处机械替换 + 子 view 加字段 | 中（量大但机械，grep 门禁兜底） |

与 **RAS-55（语言/i18n）**重叠文件 `SettingsStore/SettingsView/ReviewView` —— 维持 proposal §5 串行约束：**本 change 先合并，RAS-55 rebase**。开发前置 gate：**PR #4（ai-followup）先合并**，否则本分支 PR 混入 ai-followup 提交。

## 6. 风险与缓解

| 风险 | 等级 | 缓解 |
|---|---|---|
| 字号点遗漏，部分文本不缩放（含无显式 font 的正文/diff） | 中 | §4.5 逐点映射表（已含 diff/复制按钮白名单）+ D3 双层门禁（grep 辅助 + checklist 主） |
| 测量树与显示树字号不一致 → 窗口高度错 | 高（正确性） | D3 双层保证：两 root 各自从 `SettingsStore.shared` 派生（单一真相源）+ 子树逐级传参（漏传=编译错）+ §7-4b 生产路径测试 |
| 字号变更未触发重测量 → 溢出不封顶 | 高（正确性） | D5 显式订阅（不依赖隐式布局链）+ §7-4/4b 封顶与订阅链路测试 |
| 最大档下 336pt 最小宽出现坏折行 | 低 | xLarge 正文 16pt 在 336pt 宽约 21 汉字/行，可读；验收含最大档手动走查 |
| 老用户升级后观感突变 | 低 | 预期行为（需求即「默认调大」）；「标准」档一键回旧观感 |

## 7. 验收要点与测试建议

覆盖 spec-delta 4 个 Scenario 的 TBD 占位（MR 阶段替换为真实路径）：

1. **默认大于旧基准**（unit，建议 `Tests/LangFixTests/ReviewTypographyTests.swift`）：复刻 `register(defaults:)` 机制断言未设置时 tier == `.large`；`ReviewTypography(tier: .large).body > ReviewTypography.legacyBodyBaseline`。
2. **持久化**（unit，同文件）：独立 UserDefaults suite 写 rawValue → 重读还原（对齐 `ConfigDefaultsTests` 惯例）；非法 rawValue fallback `.large`。
3. **档位单调性 / 锚点回归**（unit）：4 档各角色字号严格递增；`standard` 档各角色 == D3 固化 pt 表（锁 typography 表自身不漂移，口径见 D3——不宣称与旧渲染像素相等）。
4. **大字号 + 长内容封顶**（unit）：用与 `refreshMeasurement` 相同的 `NSHostingController.sizeThatFits` 路径测同一长内容 state 在 `xLarge` 下 natural.height > `standard`，且 `ReviewWindowSizing.isOverflowing == true`、`target.height == maxH`（对齐 `ReviewWindowSizingTests` + RAS-53 回归模式；若 CI headless 下 hosting 测量不稳，降级为「sizing 纯逻辑断言 + 手动验收项」并在 PR 注明）。
   - **4b. 订阅链路生产测试**（Codex 评审🔴3 补，integration）：构造 `ReviewWindowController`（或提取其测量意图的可测封装）并注入长内容 state，改 `SettingsStore.shared.reviewFontTierRaw`（standard → xLarge），泵一次主 runloop，断言 natural size 变大 / `isOverflowing` 翻转 / 应用高度封顶——直接覆盖 D5 订阅是否接通、`dropFirst/removeDuplicates` 与 willSet+async 时序是否正确（对齐 RAS-53 followUp 订阅回归的测法；CI 中 NSPanel 构造不稳时降级为「订阅回调计数断言 + 手动验收项」并在 PR 注明。注意测后恢复 UserDefaults，避免污染其它用例）。
5. **grep 门禁 + checklist 门禁**：见 §2 D3 双层门禁——grep 白名单外零命中（辅助）+ §4.5 逐行 review checklist（主，兜「无显式 font」漏网）。
6. **手动走查**：浮窗展示中切 4 档 → 文本即时缩放、窗口高度随之调整；最大档 + 长追问 → 高度封顶 `maxH`、中部滚动、底栏固定、不超屏；重启后档位保持。

## 8. 评审记录

**回合 1（2026-07-16，Codex `codex exec -s read-only`，结论「需改」）**，逐条处理：

| # | 级别 | 问题 | 裁决 |
|---|---|---|---|
| 1 | 🔴 | §4.5 漏 `styledDiff` 词级 diff 文本（L470/L555 无显式 font），违反 spec「diff 随字号缩放」 | **采纳**：补入映射表（→`body`，整体 `.font` 于 reduce 结果） |
| 2 | 🔴 | 「逐级传参保证两树同源」论证过度：显示/测量是两个独立 root 分别构造 | **采纳**：D3 改为「两 root 各自从 `SettingsStore.shared` 派生（单一真相源）+ 子树逐级传参」双层保证，并加 §7-4b 生产测试 |
| 3 | 🔴 | 测试未覆盖 `$reviewFontTierRaw` 订阅→重测量链路 | **采纳**：新增 §7-4b 生产路径测试 |
| 4 | 🟡 | grep 门禁抓不到「无显式 font」文本 | **采纳**：改为双层门禁（checklist 主、grep 辅助） |
| 5 | 🟡 | 「standard 逐点等于现状」缺旧渲染基线证据 | **采纳**：改口为「按 macOS 默认内容尺寸固化 pt、视觉还原观感」，锚点测试只锁表自身 |
| 6 | 🟢 | 建议补「不进 AppConfig」小测试 | **部分采纳**：`AppConfig` 无该字段是结构性事实（无字段即编译期可证），不设运行时测试；D4 已显式声明不进 `AppConfig` |

**回合 2（2026-07-16，Codex 复核修订版）**：结论「**通过**」。6 条问题逐条确认：1–5 已有效解决；第 6 条驳回成立（`AppConfig` 闭合结构 + `config()` 显式构造，非阻断项）。新增修改面（diff 映射、复制按钮白名单、双层门禁、两 root 同源论证、§7-4b）复核无新高/中风险。附一条实现备注（不要求改设计）：**§7-4b 测试内容长度应选「standard 未溢出、xLarge 溢出」区间，否则 `isOverflowing` 翻转断言可能不稳**——已转交开发/MR 阶段落实。分歧：无。

## 变更历史

| 日期 | 作者 | 变更 |
|---|---|---|
| 2026-07-16 | 技术方案官 | 初版设计（D1–D6 + 逐点映射 + 测试建议） |
| 2026-07-16 | 技术方案官 | 按 Codex 回合 1 意见修订：补 diff 映射、两树同源改单一真相源、增订阅链路测试、门禁双层化、standard 档口径修正 |
