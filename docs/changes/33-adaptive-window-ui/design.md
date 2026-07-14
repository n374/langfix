<!-- doc-init template version: v1.0 -->
# Design: 33-adaptive-window-ui

- **Owner**: by 技术方案官 on behalf of wu.nerd
- **Reviewers**: 编排官、wu.nerd
- **创建日期**: 2026-07-03（Round 2 增补：2026-07-06；Round 3 增补：2026-07-07）
- **状态**: Round 1/2 已落地（PR #2 OPEN）；**Round 3 设计定稿**（本次，高度 bug 根因反转——实测钉死单调锁 + 初始屏幕定位，Codex 对抗评审 3 轮收敛「通过」）
- **基于 proposal**: [proposal.md](./proposal.md)（Round 2 见 §9，Round 3 见 §10）
- **Round 3 章节**: 见 [§13 Round 3](#13-round-3高度-bug-根因反转实测钉死单调锁--初始屏幕定位)（本次新增，§1–§12 保留为历史基线）。
- **关联 spec**: [specs/review-window/spec.md](./specs/review-window/spec.md)
- **共享分支**: `feat/33-adaptive-window-ui`
- **Constitution check**: 已读 [../../overview/constitution.md](../../overview/constitution.md)，**无冲突**（窗口行为模式与主题一样属非敏感偏好，走 UserDefaults 不进 Keychain，Constraint-1 只约束 API key；本 change（含 Round 2）不动流式解析/AI 调用/护栏/diff，不触 Constraint-2/3/4）。
- **Round 2 章节**: 见 [§12 Round 2](#12-round-2bug-修复--三模式交互改写含-codex-ui-定稿)（本次新增，Round 1 内容 §1–§11 保留为历史基线）。

## 1. 概述

把固定 `480×460` 的 `ReviewWindowController`（`NSPanel`）升级为「**尺寸随内容自适应 + 三态窗体（展开/折叠/关闭）+ 多主题科幻视觉**」的弹窗外壳。核心思路是把改造拆成四个正交层，互不污染既有流式/护栏逻辑：

1. **窗口状态层**：新增 `ReviewWindowMode = expanded / collapsed / closed`，由 controller 持有；`ReviewState.Phase`（AI 业务态）保持不变，两者解耦。
2. **尺寸适配层**：SwiftUI 用 `PreferenceKey` 上报**内容自然尺寸**（不是 ScrollView viewport），AppKit 侧做屏幕相对 clamp、节流、单调增高、`NSPanel.setFrame`。
3. **视觉主题层**：新增 `ReviewTheme` 值类型 + `ReviewThemeID` 枚举，主题选择存 UserDefaults，`ReviewView` 与折叠胶囊共用主题 token。
4. **关闭语义层**：把「销毁 + cancel Task」汇聚成**唯一幂等路径**；Esc / 失焦只折叠、不取消。

> **Codex 交叉评审**：本方案与 Codex 独立方案并行产出后交叉评审 2 轮收敛，双方对四层拆分、所有正确性要点完全一致，唯一分歧「折叠实现方式」Codex 复审后改判认同本方案（双 panel）。评审摘要见 §10。

## 2. 架构与方案

### 2.0 现状与关键差异（先纠正一处需求阶段口径）

现状 `ReviewWindowController`（`Sources/LangFix/AppCoordinator.swift:149-189`）：`NSPanel`，`contentRect` 固定 `480×460`，`styleMask=[.titled,.closable,.resizable,.fullSizeContentView]`，`level=.floating`，`hidesOnDeactivate=false`，**当前无任何失焦处理**；Esc 由 local monitor 直接 `close()`。回调侧：`onCancel` 会 `currentTask.cancel()` + 关窗，但 **`onClose` 只关窗、不 cancel**——这是与需求「关闭=销毁+取消请求」直接冲突的正确性缺口，本 change 必须修。

### 2.1 窗口尺寸自适应实现

#### (a) 尺寸规则（纯逻辑，抽成可单测的 policy）

```swift
struct ReviewWindowSizing {
    static let minWidth: CGFloat = 336
    static let widthRatio: CGFloat = 0.28
    static let heightRatio: CGFloat = 0.7
    var minHeight: CGFloat = 132   // 容纳透明标题栏 + 首行状态 + footer 的自然最小高

    /// 屏幕相对上限。窄屏兜底：见 §3 决策 D2。
    func limits(visibleFrame vf: CGRect) -> CGSize {
        CGSize(width:  max(Self.minWidth, vf.width  * Self.widthRatio),
               height: max(minHeight,     vf.height * Self.heightRatio))
    }

    func target(natural: CGSize, visibleFrame vf: CGRect) -> CGSize {
        let m = limits(visibleFrame: vf)
        return CGSize(width:  min(max(natural.width,  Self.minWidth), m.width),
                      height: min(max(natural.height, minHeight),     m.height))
    }
}
```

- `minW = 336`，`maxW = 所在屏 visibleFrame.width × 0.28`；`minH ≈ 132`（内容驱动，天然分辨率无关），`maxH = 所在屏 visibleFrame.height × 0.7`。
- **所在屏取 `panel.screen ?? NSScreen.main`**；panel 未上屏时先 `center()`，上屏后首次 resize 再按真实 `panel.screen` 计算（多屏正确）。
- 超上限的维度由内容区内部 `ScrollView` 承载。

#### (b) SwiftUI 测量内容自然尺寸（关键：不要测 ScrollView viewport）

`ReviewView` 现有 `.frame(minWidth:440, minHeight:360)`（`ReviewView.swift:22`）会把短内容强行撑大，**必须移除**；loading/error 的 `.frame(maxWidth:.infinity, maxHeight:.infinity)`（`ReviewView.swift:34,112`）也要收敛为自然 padding，否则短内容永远填满、不缩小。

用 `PreferenceKey` + `GeometryReader` 上报**内容 VStack 的自然尺寸**：

```swift
private struct NaturalSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        value = CGSize(width: max(value.width, n.width), height: max(value.height, n.height))
    }
}
private struct SizeReader: View {
    var body: some View {
        GeometryReader { p in Color.clear.preference(key: NaturalSizeKey.self, value: p.size) }
    }
}
```

- `SizeReader()` 放在**可滚内容 VStack 的 `.background`**（不是 ScrollView 的 background），拿到的是内容真实自然高。header/footer 是固定块，其高度并入总测量或由 controller 常量补偿。
- 内容区结构：外层根据完整自然高决定是否封顶；封顶（自然高 > maxH）后给内容区一个「maxH − header − footer」的可滚固定高，`ScrollView` 才真正滚动；未封顶时内容区自然高、不滚动。
- `ReviewView` 新签名（把主题与回调注入，去掉硬编码尺寸）：

```swift
struct ReviewView: View {
    @ObservedObject var state: ReviewState
    let theme: ReviewTheme
    let maxContentSize: CGSize
    let onNaturalSizeChange: (CGSize) -> Void
    var body: some View {
        themedContent
            .fixedSize(horizontal: false, vertical: true)
            .background(SizeReader())
            .onPreferenceChange(NaturalSizeKey.self, perform: onNaturalSizeChange)
            .frame(maxWidth: maxContentSize.width, maxHeight: maxContentSize.height)
    }
}
```

#### (c) AppKit 驱动 NSPanel：节流 + 单调增高 + 动画

流式逐字会令自然高频繁变化，不能每字符 `setFrame`。规则：

- **节流**：50–80ms debounce 合并多帧（取 60ms）。
- **阈值**：宽变化 ≥ 8pt、高变化 ≥ 6pt 才 resize。
- **单调增高**：loading/streaming 阶段高度只增不减（配合既有单调前缀守卫，防抖不闪）；result/error 收敛时也不明显缩小（从 streaming 切 result 保持不缩，避免闪跳）。
- **锚点固定**：以窗口顶边 `maxY` 为锚向下增高，不上下跳；resize 后 `keepFrameInVisibleScreen` 用 `panel.screen` 的 `visibleFrame` 把越界的 frame 平移回屏内。
- **动画**：`NSAnimationContext` 0.16s easeOut 仅用于阶段切换 / 折叠展开的平滑；流式高频增高用直接 `setFrame`（或极短动画），避免「动画永远追内容」的滞后感。

```swift
private func scheduleResize(toNatural natural: CGSize) {
    guard mode == .expanded else { return }               // 折叠态不 resize 展开 panel
    pendingResize?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.applyResize(natural) }
    pendingResize = item
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60), execute: item)
}
private func applyResize(_ natural: CGSize) {
    let vf = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
    var target = sizing.target(natural: natural, visibleFrame: vf)
    switch state.phase {                                   // 单调增高守卫
    case .loading, .streaming: target.height = max(lastSize.height, target.height)
    default: break
    }
    guard abs(target.width - lastSize.width) >= 8 || abs(target.height - lastSize.height) >= 6 else { return }
    lastSize = target
    var frame = panel.frame
    let top = frame.maxY
    frame.size = panel.frameRect(forContentRect: NSRect(origin: .zero, size: target)).size
    frame.origin.y = top - frame.height                    // 顶边锚定，向下长
    keepFrameInVisibleScreen(&frame, visibleFrame: vf)
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.16; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().setFrame(frame, display: true)
    }
}
```

### 2.2 三态状态机（展开 / 折叠 / 关闭）

窗口态与业务态解耦：

```swift
enum ReviewWindowMode: Equatable { case expanded, collapsed, closed }
```

| 当前 | 触发 | 下一态 | 副作用 |
|---|---|---|---|
| expanded | resignKey / Esc | collapsed | 保留两 panel、保留 state、**Task 继续** |
| expanded | 关闭按钮 / 取消按钮 / 标题栏关闭 | closed | **cancel Task** → orderOut+close 两 panel → 释放 |
| collapsed | 点击胶囊 | expanded | 恢复展开尺寸、`makeKeyAndOrderFront` |
| collapsed | phase 变化 | collapsed | 只更新胶囊三态，不自动展开 |
| collapsed | 关闭路径 | closed | 同 expanded 关闭 |
| closed | 任意 | closed | 幂等，不再应用 UI 更新 |

`ReviewState.Phase` 不变（`.loading/.streaming/.result/.error`）；折叠胶囊三态由 Phase **派生**：

```swift
enum CollapsedStatus: Equatable {
    case working, done, failed
    init(_ phase: ReviewState.Phase) {
        switch phase {
        case .loading, .streaming: self = .working
        case .result:              self = .done
        case .error:               self = .failed
        }
    }
}
```

**折叠实现 = 双 panel 共享同一个 `ReviewState`（关键决策 D1，见 §3）**：

- `expandedPanel`：`[.titled, .closable, .fullSizeContentView]`（**去 `.resizable`**），承载 `ReviewView`。
- `capsulePanel`：`[.borderless, .nonactivatingPanel]`，承载 `CollapsedReviewEntry`（胶囊）。
- 折叠 = `expandedPanel.orderOut(nil)` + `capsulePanel.orderFront(nil)`；展开 = `capsulePanel.orderOut(nil)` + `expandedPanel.makeKeyAndOrderFront(nil)`（App inactive 时补 `NSApp.activate`）。
- **两 panel 都不销毁**：展开 panel 的 NSHostingView + SwiftUI 局部 `@State`（复制按钮「已复制」、DisclosureGroup 展开态）在折叠期间保活。
- 两 panel 的 SwiftUI 都 `@ObservedObject` **同一个** `ReviewState` → 折叠胶囊自动随 phase 显示三态，展开态自动随流式增量刷新。Task 在 `AppCoordinator`，与哪个 panel 在前无关，**折叠期间流式后台继续**。
- **双 panel 必补的坑**（Codex 评审补充，见 §10）：`level`/`collectionBehavior`/`isReleasedWhenClosed=false` 两 panel 保持一致（防跳层/丢 Space）；折叠前记录 expanded frame 锚点，胶囊按同锚点定位，展开时从胶囊 frame 反推并 clamp 到 visibleFrame；关闭时两 panel 都 orderOut+close、清 delegate、释放 hosting ref。

### 2.3 失焦 / Esc → 折叠

controller 继承 `NSObject, NSWindowDelegate`，监听 expandedPanel 的 `windowDidResignKey`：

```swift
func windowDidResignKey(_ n: Notification) { scheduleCollapseAfterFocusSettles() }

private func scheduleCollapseAfterFocusSettles() {
    guard mode == .expanded else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
        guard let self, self.mode == .expanded, !self.expandedPanel.isKeyWindow else { return }
        // 焦点抖动过滤：输入法候选窗通常不成为 keyWindow，120ms 延迟足以过滤瞬时切换。
        self.collapse()
    }
}
```

- **Esc 改为折叠**（现 local monitor 直接 close → 改 `collapse()`）：

```swift
escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
    guard e.keyCode == 53 else { return e }
    self?.collapse(); return nil
}
```

- **必须移除 SwiftUI 按钮的 `.keyboardShortcut(.cancelAction)`**（`ReviewView.swift` 的取消/关闭按钮 32、90、233 行）：`.cancelAction` 绑定 Esc，会先于 monitor 吃掉事件触发关闭/取消。改后 Esc 只归 controller 折叠；关闭只能点击按钮或标题栏关闭。
- **打开设置造成的失焦**：符合「失焦→折叠」语义，允许折叠但**绝不 cancel**（这是 UI 态切换，不是关闭）。

### 2.4 关闭汇聚为单一幂等 cancel 路径（修正正确性缺口）

`AppCoordinator` 侧统一：

```swift
private func closeReviewAndCancel() {          // 幂等
    currentTask?.cancel()
    generation += 1                            // 让在途 preview 回调失效
    reviewController?.close()                   // 两 panel 都 orderOut+close、清 delegate
    reviewController = nil
}
```

`start(input:cfg:)` 里：

```swift
state.onCancel = { [weak self] in self?.closeReviewAndCancel() }
state.onClose  = { [weak self] in self?.closeReviewAndCancel() }   // 修复：onClose 现在也 cancel
```

- **新触发替换旧弹窗**：`start()` 开头显式 `closeReviewAndCancel()` 取消上一代 Task 再建新 state/Task，避免旧请求泄漏（现状是先 present 再 cancel，语义脆弱）。
- **标题栏关闭按钮**：`func windowShouldClose(_:) -> Bool { closeReviewAndCancel(); return false }` 汇聚到同一路径（controller 持 delegate 引用调 Coordinator 注入的 `onRequestClose`）。capsulePanel 无关闭按钮，但也挂同一 delegate 防 `performClose`/未来入口绕过。
- 底层取消链已验证可靠：`currentTask.cancel()` → `URLSession.AsyncBytes` 抛 → `ReviewError.cancelled`（`AIClient.swift:233-236`），streaming/strict 两轮都尊重取消。

### 2.5 折叠入口视觉（胶囊 + 三态）

```swift
struct CollapsedReviewEntry: View {
    @ObservedObject var state: ReviewState
    let theme: ReviewTheme
    let onExpand: () -> Void
    private var status: CollapsedStatus { .init(state.phase) }
    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 8) {
                Image(systemName: status.icon)      // 见下表
                Text(status.title).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundColor(theme.collapsedForeground)
            .padding(.horizontal, 14).frame(width: 132, height: 44)
            .background(theme.material)
            .overlay(Capsule().stroke(status.color, lineWidth: 1.2))
            .shadow(color: status.color.opacity(theme.glowOpacity), radius: 12)
            .clipShape(Capsule())
        }.buttonStyle(.plain)
    }
}
```

三态映射（颜色取当前主题 token，图标/语义固定）：

| 状态 | Phase | 图标（SF Symbol） | 语义色 token |
|---|---|---|---|
| 进行中 | loading / streaming | `sparkles` / `waveform.path.ecg` | `theme.accent` |
| 已完成 | result | `checkmark.seal.fill` | `theme.success` |
| 出错 | error | `exclamationmark.triangle.fill` | `theme.error` |

- 胶囊尺寸 `132×44`（比小球更易辨识；小球留作主题变体）。
- 极简动效：折叠/展开 crossfade + `scale 0.96→1.0`；进行中态 1.6s 呼吸（`symbolEffect(.pulse)`，macOS 13 缺失时手写 opacity/scale），**不做旋转/长弹性**。

### 2.6 多主题架构（Codex 主导视觉，见 §2.7）

```swift
enum ReviewThemeID: String, CaseIterable, Identifiable {
    case auroraGlass, neonNoir, solarInk, arcticCircuit
    var id: String { rawValue }
}
struct ReviewTheme {
    let id: ReviewThemeID; let displayName: String
    let material: Material                       // 不可 Codable → 只持久化 id
    let backgroundTop, backgroundBottom: Color
    let primaryText, secondaryText: Color
    let accent, success, warning, error: Color
    let cardFill, cardStroke, glow: Color
    let glowOpacity: Double; let cornerRadius, borderWidth: CGFloat
    let animationDuration: Double
    var collapsedForeground: Color { primaryText }
}
enum ReviewThemeCatalog { static func theme(_ id: ReviewThemeID) -> ReviewTheme { /* 静态表 */ } }
```

- **持久化**：`SettingsStore` 加 `@Published var reviewThemeRaw`（UserDefaults key `reviewTheme`，`register` 默认 `auroraGlass`）；只存 `ReviewThemeID.rawValue`（Material 不可 Codable）；非法 rawValue fallback 默认。**主题不进 `AppConfig`**（与 AI 引擎无关）。
- **即时生效**：`ReviewView` / `CollapsedReviewEntry` 持 `@ObservedObject settings = SettingsStore.shared`（或读 controller 每次注入的 theme）；用户在设置切换 → SwiftUI 自动重绘展开态与胶囊。
- **设置接入**（`SettingsView.swift` 的 `generalSection`）：

```swift
Picker("弹窗主题", selection: $settings.reviewThemeRaw) {
    ForEach(ReviewThemeID.allCases) { id in
        Text(ReviewThemeCatalog.theme(id).displayName).tag(id.rawValue)
    }
}.pickerStyle(.segmented)
```

- **落到 ReviewView 的最小改动边界**：把现有硬编码色（`Color(nsColor:.textBackgroundColor)`、`Color.gray.opacity(...)`、`.accentColor` 等）替换为 theme token，抽 `ThemedCard` / themed header/badge/按钮 tint 复用容器；**不重写业务布局**（不碰 diff/护栏/流式解析，守 Constraint-3 与 Out-of-Scope）。

### 2.7 四套主题视觉稿（Codex 定稿，用户保留选定权）

> 用户已授权「以 Codex 最终设计为准，能多设计几套更好」；下列 4 套由 Codex 产出，**默认 Aurora Glass**。具体 hex 见下，落地时可微调。**若用户想删减/改默认，在父 Issue 一句话即可。**

| 主题 | 定位 | 背景 | 主色 / 成功 / 警告 / 错误 | 卡片 / 描边 | 发光 | 圆角(窗/卡) | 折叠胶囊 | 动效 |
|---|---|---|---|---|---|---|---|---|
| **A. Aurora Glass**（默认） | 冷静透明、macOS 原生感最强，最不抢内容 | `.ultraThinMaterial` + `#07111F` 12% | `#7DD3FC` / `#34D399` / `#FBBF24` / `#FB7185` | `#0B1220` 58% / `#7DD3FC` 22% | cyan `0.22` | 18 / 8 | 冰蓝半透胶囊 | 160ms easeOut，working 1.6s 呼吸，无旋转 |
| **B. Neon Noir** | 暗色霓虹、最「赛博」 | `.thinMaterial` + `#050508` | `#A78BFA`(+辅 `#22D3EE`) / `#10B981` / `#F59E0B` / `#F43F5E` | `#111018` 72% / `#A78BFA` 35% | purple/cyan 双描边 `0.30` | 16 / 7 | 深黑胶囊+左侧霓虹状态点 | 折叠 scale `0.98→1.0`，无夸张弹性 |
| **C. Solar Ink** | 深色纸面金墨、艺术感，避免全紫蓝单调 | `.regularMaterial` + `#11100C` | `#F6C453`(+辅 `#38BDF8`) / `#84CC16` / `#F97316` / `#EF4444` | `#1A1712` 68% / `#F6C453` 28% | warm gold `0.18` | 14 / 6 | 黑金胶囊，working 金色进度弧 | 120ms，干净快速 |
| **D. Arctic Circuit** | 明暗兼容最好，白玻璃+极地蓝 | `.ultraThinMaterial` + light/dark 自适应 | `#0EA5E9`(+辅 `#14B8A6`) / `#22C55E` / `#EAB308` / `#DC2626` | light `#FFF` 70% / dark `#0F172A` 62%；描边 `#38BDF8` 24% | 低 `0.12` | 18 / 8 | 浅玻璃胶囊，白天清晰 | 仅 opacity+frame，几乎无装饰 |

文本色：A 主 `#EAF6FF`/次 `#9FB4C7`；B 主 `#F5F3FF`/次 `#A1A1AA`；C 主 `#FFF7E6`/次 `#C8BFAE`；D 主 light `#0F172A`/dark `#E2E8F0`、次 `#64748B`。

### 2.8 移除 `.resizable`

`expandedPanel` styleMask 从 `[.titled,.closable,.resizable,.fullSizeContentView]` → `[.titled,.closable,.fullSizeContentView]`。尺寸完全由 §2.1 measurement 回调驱动（`.resizable` 移除不影响程序化 `setContentSize`/`setFrame`）。连带：清理 `ReviewView` 的 `.infinity` 填充与 `minHeight:360`（见 §2.1b），否则短内容不缩。

## 3. 关键决策

| 决策点 | 选择 | 备选 | 理由 | 关联 |
|---|---|---|---|---|
| D1 折叠实现 | **双 panel 共享 ReviewState** | 同窗切 styleMask 变形 | 展开/折叠是两种窗口语义（key/Esc/失焦/标题栏 vs borderless/nonactivating/自绘胶囊）；运行时切 styleMask 是 AppKit 最脆处，收益仅连续动画不值得。orderOut 不销毁 → 局部 @State 同样保活 | Codex 复审改判认同（§10） |
| D2 窄屏宽度冲突 | `maxW = max(336, visibleW×0.28)`（窄屏保 336 可用宽优先） | 严格 ≤28%（窄屏可低于 336） | round3 用户要求宽度再减 30%，由 `480/0.4` 等比收窄为 `336/0.28`；极窄屏仍以最小可用宽兜底 | §8 Q1 |
| D3 窗口态载体 | controller 持 `ReviewWindowMode`，不塞进 `Phase` | 复用 `ReviewState.Phase` | Phase 是 AI 任务态；展开/折叠是容器态，耦合会污染流式逻辑 | §2.2 |
| D4 关闭语义 | close = cancel（幂等单一路径）；Esc/失焦不 cancel | 维持 onClose 不 cancel | 现状 onClose 不 cancel 与需求「关闭=销毁+取消」直接冲突，是正确性缺口 | §2.4 |
| D5 默认主题 | Aurora Glass | 其余 3 套 | 最不抢内容又满足科幻/艺术调性；明/暗环境可读 | §2.7 |
| D6 折叠形态 | 胶囊（132×44） | 小球 | 胶囊可容图标+文字，三态辨识更强；小球留作主题变体 | §2.5 |

## 4. 影响分析

### 4.1 受影响的 capability

| Capability | 影响类型 | 需更新 spec |
|---|---|---|
| review-window | ADDED（本 change 新建） | 本 change 的 [spec](./specs/review-window/spec.md)；已补一条窄屏宽度实现备注（非规范性） |
| grammar-review | 无 | 否（不动纠错/护栏/流式解析/diff） |

### 4.2 受影响的接口 / 文件

| 文件 | 影响 | 兼容性 |
|---|---|---|
| `AppCoordinator.swift`（`ReviewWindowController`） | 重构为双 panel + NSWindowDelegate + sizing 回调；`start`/关闭语义统一 cancel | 内部实现，无外部契约；MenuBar/Service 入口不变 |
| `ReviewView.swift` | 新增 `theme`/`maxContentSize`/`onNaturalSizeChange` 参数；移除 `.infinity`/`minHeight`；色值换 theme token；移除 `.cancelAction` | 视图私有，随 controller 一起改 |
| `ReviewState.swift` | 保持 Phase；`onCancel/onClose` 语义收敛（回调签名不变） | 兼容 |
| `SettingsStore.swift` | 加 `reviewThemeRaw` + 默认注册（theme 不入 `AppConfig`） | 新增字段，旧用户读默认 |
| `SettingsView.swift` | `generalSection` 加主题 Picker | 兼容 |
| 新增 | `ReviewWindowSizing`、`ReviewWindowMode`、`CollapsedStatus`、`ReviewTheme`/`ReviewThemeID`/`ReviewThemeCatalog`、`CollapsedReviewEntry` | 新增 |

### 4.3 受影响的运维

无监控/告警/SOP。无数据迁移（主题默认值经 UserDefaults `register` 提供，旧用户升级即得默认 Aurora Glass）。

## 5. 测试策略（对照 spec.md 逐条把 TBD 具体化）

原则：把 sizing/状态机/主题/三态映射抽成**纯逻辑单测**（现仓库以 XCTest 单测为主，UI test 后置）。

| spec Scenario | 测试落点 | 断言 |
|---|---|---|
| 短内容出小窗 | `ReviewWindowSizingTests` + `NSHostingView.fittingSize` smoke | 移除 minHeight 后短内容自然高 ≪ maxH；宽∈[336,maxW] |
| 宽度按屏幕相对 clamp | `ReviewWindowSizingTests` | `target(300,vf1600).w==336`；`400→400`；`900→448(=1600×0.28)` |
| 流式增高到上限后滚动 | `ReviewWindowSizingTests` 序列 | 自然高 `[120,180,260,900]`，vf.h=1000 → `[132,180,260,700]`，末帧需内部滚动 |
| 上限随分辨率按比例缩放 | `ReviewWindowSizingTests` 双 vf | vf.h=1000→maxH=700；vf.h=1400→maxH=980（比例非固定 px） |
| 高度单调不减 | `ReviewWindowSizingTests` | streaming 下多帧调用高度序列单调不减 |
| 失焦折叠且后台继续 | `ReviewWindowModeTests`（纯状态机 reduce） | expanded+resignKey→collapsed 且 **cancel 未被调用**；折叠期喂 preview→state 仍更新 |
| Esc 等同失焦 | `ReviewWindowModeTests` | expanded+esc→collapsed，cancel 未调用 |
| 点击入口展开恢复 | `ReviewWindowModeTests` | collapsed+click→expanded；展开后内容=最新 state |
| 关闭取消在途请求 | `AppCoordinator` cancel seam（注入 closure） | `onClose?()` 与 `onCancel?()` 都触发同一 `closeReviewAndCancel`（cancel 被调）；Esc/resignKey 不触发 cancel（**最高优先级，现状 bug 回归**） |
| 进行中/完成视觉区分 | `CollapsedStatusTests` | `.loading/.streaming→working`、`.result→done`、`.error→failed`；三态 icon/color token 互不相同 |
| 出错态可辨识 | `CollapsedStatusTests` | error 态 token 区别于其余两态 |
| 切换主题即时生效 | `ThemeStoreTests`（独立 UserDefaults suite） | 写 `neonNoir` 读出 `neonNoir`；持久化跨实例 |
| 默认主题 | `ThemeStoreTests` | 未设置时 `reviewThemeRaw==auroraGlass`；非法 rawValue fallback 默认；theme 不在 `AppConfig` |
| 无手动缩放 | `ReviewWindowStyleTests` | `expandedPanel.styleMask` 不含 `.resizable`（styleMask 抽工厂或测试 accessor） |

## 6. 兼容性与迁移

无破坏性变更。旧用户升级：主题默认 Aurora Glass（UserDefaults register 兜底）；窗口从固定尺寸变自适应，行为增强无回退。MenuBar / PopClip Service 触发入口不变。

## 7. 红线检查

- [x] 已核对 [constitution.md](../../overview/constitution.md) 4 条红线
- [x] **无触碰**：主题偏好非敏感 → UserDefaults（Constraint-1 仅约束 API key）；不新增日志/落盘原文修正文（Constraint-2）；不动最小改动护栏/diff（Constraint-3）；不改用户原选区（Constraint-4）
- [x] 无强制覆盖需求（§8 无红线覆盖记录）

## 8. Clarifications

### Q1: 窄屏宽度数学冲突（D2）
**A**: round3 用户实测后要求「宽度再减少 30%」，因此宽度参数从 `minW=480 / maxW=visibleW×0.4` 等比收窄为 `minW=336 / maxW=visibleW×0.28`。当 `visibleW < 1200pt` 时 `maxW = visibleW×0.28 < minW=336`，区间 `[336, maxW]` 非法。落地采用 `maxW = max(336, visibleW×0.28)`：常规屏遵守 28% 相对上限，极窄屏以 336pt 最小可用宽兜底。若用户坚持「任何情况绝不超 28%」，改为窄屏允许低于 336 即可（一行改动）。

### 红线强制覆盖记录
不适用（本 change 无红线覆盖）。

## 9. 风险

| 风险 | 缓解 |
|---|---|
| 流式逐帧增高抖动 / 频繁重排 | 60ms debounce + 6/8pt 阈值 + 单调增高 + 顶边锚定；仅阶段切换/折叠走动画，流式增高直接 setFrame |
| SwiftUI 自然尺寸被 ScrollView viewport 与 `.infinity`/`minHeight` 污染 | measurement 放内容 VStack 而非 ScrollView；先删 `minHeight:360` 与 loading/error 的 `.infinity` 填充（否则短内容不缩，验收会挂） |
| Esc 被 `.keyboardShortcut(.cancelAction)` 抢 | 移除取消/关闭按钮的 `.cancelAction`，Esc 归 controller 折叠（本 change 强制项） |
| 双 panel level/space/焦点不同步 | 两 panel 统一 level/collectionBehavior/isReleasedWhenClosed；点击胶囊后 orderOut 胶囊→expanded makeKeyAndOrderFront(+NSApp.activate)；锚点记录反推 |
| 打开设置触发折叠让用户意外 | 符合失焦→折叠语义，可接受；关键是**绝不 cancel**，只折叠 |
| 多屏取错屏 | 以 `panel.screen ?? NSScreen.main` 的 visibleFrame 为准；先 center 上屏后再按真实屏计算 |
| 关闭路径遗漏取消（现状 onClose bug） | close 汇聚单一幂等 `closeReviewAndCancel`；`windowShouldClose` 也走同路径；专测覆盖（§5 最高优先级） |

## 10. Codex 交叉评审摘要

- **协作方式**：需求规格摘要（无方案倾向）交 Codex，与本方案**并行独立**产出后交叉评审，**2 轮收敛**。
- **共识（双方独立一致）**：四层拆分（窗口态/尺寸/主题/关闭）；窗口态与 `Phase` 解耦；PreferenceKey 测**内容自然尺寸而非 ScrollView viewport**；节流+阈值+单调增高+顶边锚定；`onClose` 当前不 cancel 是必须修的正确性 bug；Esc 必须移除 `.keyboardShortcut(.cancelAction)` 否则抢事件；移除 `.infinity`/`minHeight:360` 否则短内容不缩；resignKey+120ms 去抖过滤焦点抖动；三态胶囊由 Phase 派生；主题 UserDefaults 只存 id（Material 不可 Codable）+ 默认 + Picker + 环境注入；抽纯 sizing/状态机做单测。
- **采纳的 Codex 意见**：① 四套主题视觉稿（Aurora Glass/Neon Noir/Solar Ink/Arctic Circuit）全部采纳并定默认为 Aurora Glass（用户授权 Codex 主导视觉）；② 窄屏宽度 `max(336, visibleW×0.28)` 兜底（D2，round3 收窄 30% 后同步更新）；③ 双 panel 需补的坑清单（level/space 同步、焦点恢复补 NSApp.activate、锚点反推、关闭幂等、capsule 也挂 delegate）；④ `windowShouldClose` 返回 false 汇聚统一关闭。
- **分歧与收敛**：唯一分歧「折叠实现」——本方案主张双 panel、Codex 初版主张同窗切 styleMask 变形；Round 2 交叉评审后 **Codex 改判认同双 panel**（理由：运行时切 styleMask 是 AppKit 最脆处、收益仅连续动画不值得；orderOut 不销毁使局部 @State 同样保活，削弱其原论据）。**无剩余分歧**。
- **评审轮数**：2 轮收敛，无高级别分歧，无需回退。

## 11. 后续动作建议

- [ ] 无需离线数据验证 / 对账
- [ ] 无新埋点 / 监控（隐私红线：折叠三态不记录内容，仅本地状态）
- [ ] 开发官落地建议顺序：① 关闭语义统一 + Esc/keyboardShortcut 修正（正确性优先）→ ② sizing policy + ReviewView 自然尺寸测量 → ③ 双 panel 折叠 → ④ 主题系统 + 设置页 → ⑤ 补 sizing/主题/状态机单测 + 手工 UI 验收（短文本/长文本/streaming 折叠后继续/Esc/关闭取消）

---

## 12. Round 2（bug 修复 + 三模式交互改写，含 Codex UI 定稿）

> **需求来源**：proposal [§9](./proposal.md)（用户拍板 `fc90708a` 逐条落定）+ spec `review-window` Round 2 差分。**Round 1（§1–§11）为历史基线，未推翻**；本节只描述 Round 2 的增量设计。
> **协作**：Codex 主导 UI/视觉设计（用户点名「让 Codex 设计 UI」），本方（Claude）做内部落地设计；两线并行后**对抗式交叉评审 3 轮收敛**（摘要见 §12.14）。
> **落地基线是当前已合入代码**（不是 §1–§11 的计划稿）：Round 1 已把 `ReviewWindowSizing` / `ReviewWindowMode` / `ReviewWindowStyle` / `ReviewTheme` / 双 panel `ReviewWindowController` / `CollapsedReviewEntry` / 主题 Picker 全部落地（commit `4672394`…`61139ff`）。本节所有改动均相对**已落地代码**。

### 12.0 Round 2 要解决的四件事（与已落地代码的差距）

| # | 需求 | 已落地代码现状 | Round 2 差距 |
|---|---|---|---|
| Bug1 | ≤maxH 绝不出现纵向滚动条、实时增高 | `ReviewView` 恒定 `ScrollView` 包裹（`ReviewView.swift:24`）；controller 60ms debounce + 高 6pt 阈值 + `animator()`（`AppCoordinator.swift` `updateNaturalSize`/`applyResize`） | 恒定 ScrollView + resize 滞后 → 流式增高期出现滚动条。需结构性消除 |
| Bug2 | 展开按当刻内容重算尺寸 | `applyExpand` 恢复 `savedExpandedFrame`（折叠当刻冻结的尺寸） | 直接复用旧尺寸 = Bug2。需展开时重测重算 |
| 三模式 | A/B/C（默认 C）+ 单一状态机 | `ReviewWindowMode.reduce` 无 behavior、失焦在所有场景都折叠；两 panel 恒 `.floating` | 需引入 behavior 轴、失焦仅 A 折叠、层级随模式、单一状态机 |
| 隐藏图标 | A/B/C 三模式都提供、点击折叠 | 无此事件、无此控件 | 需新增 `.hideIcon` 事件 + 标题栏控件 + 设置持久化 |

### 12.1 Bug1：逐帧无滚动条（结构保证，非时序保证）

**根因**：`ReviewView` 恒定用 `ScrollView` 包裹内容；controller 的 resize 走 60ms debounce + 6pt 阈值 + 动画。流式逐帧增高时，内容自然高**领先于**滞后的窗口高度 → `ScrollView` 内容高于其 viewport → 渲染纵向滚动条（正是「先出滚动条再撑开」的中间帧）。

**定稿方案 = 结构性消除 + 测量/显示解耦 + runloop 合并**（Codex P0.1/P0.2/P1.6 采纳）：

#### (a) 结构门控——未封顶时视图树里根本不存在可显示的 vertical scroller
- 用**测量得到的自然高**决定：`isOverflowing = latestNaturalSize.height > maxH + ε`（`ε` 仅覆盖浮点误差，**不覆盖真实高度**）。
- `isOverflowing == false`：`ReviewView` **直接渲染 `phaseContent`，不包滚动容器** → 结构上不可能出现纵向滚动条，**与窗口 frame 是否在同一绘制帧修正无关**（这是「逐帧无滚动条」的正确性根据）。窗口 frame 滞后的最坏情况只是内容底部被裁 ≤1 帧（不可见），绝不出现滚动条。
- `isOverflowing == true`：内容 wrap 进 `ScrollView`，其 frame 高固定为 `maxH`，超出部分内部滚动（spec 允许）。

```swift
// ReviewView：显示树按 controller 注入的 isOverflowing 决定是否包滚动容器（不自测几何，避免反馈环）
struct ReviewView: View {
    @ObservedObject var state: ReviewState
    let theme: ReviewTheme
    let maxContentSize: CGSize
    let isOverflowing: Bool           // ← controller 依据 latestNaturalSize 计算后注入
    var body: some View {
        Group {
            if isOverflowing {
                ScrollView { phaseContent.frame(maxWidth: maxContentSize.width, alignment: .leading) }
                    .frame(maxWidth: maxContentSize.width, maxHeight: maxContentSize.height)
            } else {
                phaseContent
                    .frame(maxWidth: maxContentSize.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)   // 未封顶：内容按自然高，绝不出现滚动条
            }
        }
        .background(theme.windowBackground)
    }
}
```

#### (b) 测量树与显示树分离（消除 overflow 边界反跳，Codex P0.2）
`naturalH` 逼近 `maxH` 时，若 wrap/unwrap `ScrollView` 会改变可用宽度/inset（尤其系统「始终显示滚动条」辅助功能设置下滚动条占布局宽）→ 文本重排 → `naturalH` 反跳、在边界反复横跳。故：
- **自然尺寸只由一份专用测量宿主产出**（见 §12.3 measurement host），它**恒定无滚动容器、固定内容宽**，测量口径**不随显示树 wrap/unwrap 变化**；
- 显示树的 `isOverflowing` 仅读该测量宿主的 `latestNaturalSize`，二者解耦 → 无跨边界反馈环。

#### (c) resize 时序——去 debounce/动画，runloop 合并只 apply 最新值（Codex P1.6）
- **去掉 60ms debounce 与高度 6pt 阈值**（未封顶时降到 subpixel `ε`）：流式增高不得被节流阻挡，否则重现滞后→滚动条。
- 高频 preference 回调只更新 `latestNaturalSize` 并置 `pendingResize` 标志；**下一个 main runloop tick 只执行一次 `setFrame`**，apply 当刻最新值（避免每 token 都 setFrame 造成 AppKit/SwiftUI 互相追布局）。
- **流式增高用直接 `setFrame(display: true)`，不加动画**（动画会让窗口永远追内容 = 滚动条）；动画仅保留给**阶段切换**与**折叠/展开**（0.12–0.16s）。
- 保留 streaming **单调增高守卫**（`monotonicTarget`，配合单调前缀守卫防抖不闪缩）。
- 顶边锚定 + `keepFrameInVisibleScreen` 不变。

**验收口径（写进 spec，可实现验证）**：`naturalH ≤ maxH` 时（1）显示树层级中**不含可显示的 vertical scroller**；（2）resize 仅 runloop 合并、**无 debounce/动画/6pt 阈值阻挡增长**。二者同时成立才通过；happy-path 出现滚动条即不通过（正确性红线，不因概率降级）。

### 12.2 Bug2：展开按当刻内容重算尺寸

**根因**：`applyExpand` 恢复 `savedExpandedFrame`（折叠当刻的尺寸）。

**定稿方案**：展开时**丢弃 saved 的尺寸、只留锚点**（顶边 `origin.y`）；用 §12.3 measurement host 的 `latestNaturalSize`（保证是折叠期持续刷新后的当刻值）→ `sizing.target(natural:visibleFrame:)` clamp → 按顶边锚点 `setFrame` 为重算尺寸 → 重置 `lastSize` 基线 → `makeKeyAndOrderFront`。展开后再 `layoutSubtreeIfNeeded` 触发一次 preference 校正（belt-and-suspenders）。

```swift
private func applyExpand(from: ReviewWindowMode) {
    capsulePanel.orderOut(nil)
    let vf = (expandedPanel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
    let target = sizing.target(natural: latestNaturalSize, visibleFrame: vf)   // ← 当刻内容，不用旧 frame
    var f = expandedPanel.frame
    let top = savedExpandedFrame?.maxY ?? f.maxY                                // 只借锚点
    f.size = expandedPanel.frameRect(forContentRect: NSRect(origin: .zero, size: target)).size
    f.origin.y = top - f.height
    keepFrameInVisibleScreen(&f, visibleFrame: vf)
    lastSize = target                                                          // 重置节流基线
    applyLevel(for: behavior, panel: expandedPanel)                            // 层级随模式（§12.4）
    expandedPanel.setFrame(f, display: true)
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    expandedPanel.makeKeyAndOrderFront(nil)
    expandedHosting.layoutSubtreeIfNeeded()
}
```

**验收**：折叠期喂增量使内容变高/变矮，展开首帧 frame == `recompute(折叠期更新后的当刻内容)` 且 **≠ 折叠前尺寸**。

### 12.3 常驻测量宿主（Bug1 测量源 + Bug2 折叠期持续刷新的共同底座，Codex P0.3 最终采纳）

**问题**：Bug2 依赖「折叠期 `latestNaturalSize` 持续刷新」。但若测量子树在折叠态被条件分支卸载、或 expanded panel ordered-out 后不再 layout，则 `@ObservedObject` 更新**不会凭空产生新 preference**，`latestNaturalSize` 会停在折叠前旧值 → Bug2 重现。

**定稿方案 = 专用、常驻、参与 layout 的独立测量宿主**：
- 新增一个**专用 measurement `NSHostingView`**，渲染与展开态相同的 `phaseContent`（共享同一 `ReviewState`）+ `NaturalSizeKey`，**固定内容宽、无滚动容器、`alpha=0` 不参与显示、不影响胶囊视觉**。
- 该宿主**始终挂在当前 on-screen 的 panel 视图树里**：折叠态挂到 **capsule panel**（折叠期 capsule 是 ordered-in、持续 layout），展开态挂到 **expanded panel**；模式切换时随之 re-parent，**任何态都不被条件分支卸载**。
- 每次 `state` 变更后、以及**展开重算前**，对该宿主显式 `layoutSubtreeIfNeeded()`，从 `NaturalSizeKey`/`fittingSize` 更新 `latestNaturalSize`；**不依赖 ordered-out 窗口自发 layout**。
- 于是 `latestNaturalSize` 全程有效：Bug1 的 `isOverflowing` 与 Bug2 的展开重算都读它。

> 该宿主是**测量单一真相源**，与显示树彻底解耦（§12.1b），既消除 overflow 边界反跳，又保证折叠期测量不失效。Codex 第 3 轮确认此口径闭环、无残留。

### 12.4 三模式单一状态机（mode × 容器态）

**新增 behavior 轴**（`WindowBehaviorMode`，持久化，见 §12.9）：

```swift
enum WindowBehaviorMode: String, CaseIterable, Identifiable, Sendable {
    case focusCollapse   // A 失焦折叠
    case alwaysOnTop     // B 始终置顶
    case normal          // C 默认窗口（默认）
    var id: String { rawValue }
    static let defaultMode: WindowBehaviorMode = .normal
}
```

**单一状态机 = `behavior × presentation` + 显式副作用 actions**（Codex P1.4 采纳：把 behavior 编码进态、reduce 产出 action 列表，便于枚举全矩阵测试，避免漏组合）：

```swift
struct ReviewWindowMachineState: Equatable, Sendable {
    var behavior: WindowBehaviorMode          // 开窗时捕获，运行期不变（§12.9 决策）
    var presentation: ReviewWindowMode        // expanded / collapsed / closed
}
enum ReviewWindowAction: Equatable, Sendable {
    case applyLevel        // 依 behavior 施加窗口层级（两 panel）
    case recomputeSize     // 展开：按当刻内容重算尺寸（Bug2）
    case cancelTask        // 关闭：取消底层 Task
    case orderCapsule      // 折叠：显示胶囊、orderOut 展开
    case orderExpanded     // 展开：显示展开、orderOut 胶囊
}
struct ReviewWindowOutcome: Equatable, Sendable {
    var presentation: ReviewWindowMode
    var actions: [ReviewWindowAction]
}

extension ReviewWindowMachineState {
    func reduce(_ event: ReviewWindowEvent) -> ReviewWindowOutcome {
        if presentation == .closed { return .init(presentation: .closed, actions: []) }
        switch (presentation, event) {
        case (.expanded, .resignKey):
            // 失焦仅在 A 折叠；B/C no-op（B 保持置顶、C 可被遮挡但不折叠）
            return behavior == .focusCollapse
                ? .init(presentation: .collapsed, actions: [.orderCapsule, .applyLevel])
                : .init(presentation: .expanded, actions: [])
        case (.expanded, .esc), (.expanded, .hideIcon):
            // Esc / 隐藏图标：三模式一律折叠为胶囊（不 cancel）
            return .init(presentation: .collapsed, actions: [.orderCapsule, .applyLevel])
        case (.collapsed, .tapCapsule):
            // 点击胶囊：三模式一律展开 + 按当刻内容重算（Bug2）
            return .init(presentation: .expanded, actions: [.recomputeSize, .applyLevel, .orderExpanded])
        case (_, .closeRequested):
            // 关闭是唯一 cancel 路径（三模式共用）
            return .init(presentation: .closed, actions: [.cancelTask])
        default:
            return .init(presentation: presentation, actions: [])   // 无意义组合 no-op
        }
    }
}
```

新增事件：`ReviewWindowEvent.hideIcon`。`.resignKey` 语义从「无条件折叠」下沉为「**仅 A 折叠**」。

**controller 侧**：`windowDidResignKey` 只在 `behavior == .focusCollapse` 时安排 120ms 去抖后的 `.resignKey`（B/C 不监听/直接忽略）；`applyLevel` / `recomputeSize` / `cancelTask` 等按 action 派发。关闭仍委托 Coordinator 唯一 `closeReviewAndCancel`（Round 1 语义不变）。

### 12.5 窗口层级随模式（两 panel、两态统一施加，Codex P1.5）

层级是 `behavior` 的函数，**对 expanded panel 与 capsule panel 都施加，且在展开/折叠切换时各自 re-apply**：

```swift
private func applyLevel(for behavior: WindowBehaviorMode, panel: NSPanel) {
    switch behavior {
    case .alwaysOnTop:                       // B：展开态与胶囊态都置顶
        panel.isFloatingPanel = true
        panel.level = .floating
    case .focusCollapse, .normal:            // A / C：普通层级，可被其他窗口遮挡
        panel.isFloatingPanel = false
        panel.level = .normal
    }
}
```

- Round 1 两 panel 恒 `.floating` 的写法（`configurePanels`）改为按 behavior 施加；`hidesOnDeactivate=false`、`collectionBehavior`、`isReleasedWhenClosed=false` 三模式共用不变。
- **A 模式改 `.normal` 后失焦折叠仍可靠**：折叠由 `windowDidResignKey` → 状态机驱动，**与窗口 level 无关**（`.normal` 窗口同样收到 `resignKey`）；120ms 去抖 + `!isKeyWindow` 复检过滤输入法/临时子面板的焦点抖动，Round 1 已验证的过滤逻辑保留。
- **B 胶囊置顶、A/C 胶囊普通层级**：`applyCollapse` 里对 capsule panel 也调 `applyLevel(for: behavior, panel: capsulePanel)`。

### 12.6 隐藏图标（A/B/C 三模式都提供，Codex UI 定稿：标题栏 accessory）

- **载体**：`NSTitlebarAccessoryViewController`，`layoutAttribute = .right`，内部 `NSHostingView` 承载 SwiftUI 小按钮。**放标题栏、不进 `phaseContent` 测量树**——避免污染 §12.3 的自然尺寸测量（Codex 明确反对 `.overlay` 进内容树赌布局边界）。
- **视觉**：SF Symbol `minus.circle`（**不用 `xmark` 系列**，避免与关闭语义混淆）；按钮 24×24pt、命中区 28×28pt；tooltip「隐藏为胶囊」；hover 背景 `theme.cardFill.opacity(0.75)` + 描边 `theme.cardStroke`，`.easeOut(0.12)`；颜色中性/主题 accent，**不用红色**（红色留给关闭）。各主题微调见 §12.8 末。
- **行为**：点击 → `handle(.hideIcon)` → 三模式折叠为胶囊、**不 cancel**。与关闭区分：关闭仍走系统标题栏关闭按钮 / 内容区「关闭·取消」按钮（→ `closeRequested`）。

### 12.7 设置界面三模式选择器（Codex UI 定稿：单选卡片）

- **控件形态 = 三张单选卡片**（不用分段控件）。理由（Codex）：A/B/C 差异非三个短词能讲清，尤其 **B「始终置顶但 Esc/隐藏仍可折叠为胶囊」必须写明**，否则用户误以为置顶不可收起——分段控件把语义藏进 tooltip，验收心智风险高。
- 卡片规格：`VStack` + 3 个自定义 `Button` 卡片，绑定 `settings.windowBehaviorModeRaw`；每项高 56–64pt、圆角 8；选中态 `theme.accent` 1.5pt 描边 + `checkmark.circle.fill`。默认选中 **C**。

| 模式 | 图标 | 主文案 | 副文案 |
|---|---|---|---|
| A | `eye.slash` | 失焦折叠 | 切到别处自动变胶囊；Esc / 隐藏也会折叠 |
| B | `pin.fill` | 始终置顶 | 窗口和胶囊都保持置顶；Esc / 隐藏可暂收 |
| C（默认） | `macwindow` | 默认窗口 | 像普通窗口一样可被遮挡；Esc / 隐藏可收起 |

- 落点：`SettingsView.generalSection`，紧邻现有「弹窗主题」Picker。

### 12.8 折叠胶囊三态视觉增强（Codex 定稿）

Round 1 基础版（`sparkles` / `checkmark.seal.fill` / `exclamationmark.triangle.fill` + 语义色 token）方向正确、保留。Round 2 增强：

- 胶囊尺寸 `132×44` → **`148×44`**（B 模式加置顶暗示后不挤）。
- 三态动效：进行中 `sparkles`+`accent`，pulse 1.15s `easeInOut`（scale 1.0→1.06 / opacity 0.75→1.0）；已完成 `checkmark.seal.fill`+`success`，进入时一次 0.16s settle、不持续动；出错 `exclamationmark.triangle.fill`+`error`，进入 2 次短闪（单次 0.12s，总 ≤0.3s）。
- **B 模式置顶暗示**：胶囊右上角 10pt `pin.fill` 小徽标、`opacity 0.72`，不改胶囊主体布局；A/C 不显示。**不用更强光效**表示置顶（会与「出错/完成」状态色抢语义）。
- 隐藏图标各主题：Aurora Glass `accent` 70%、冷玻璃 hover；Neon Noir 描边稍亮（防紫黑里看不见）；Solar Ink 金色 accent、hover 阴影降 0.12；Arctic Circuit 默认 `.secondary`、hover 才上 accent。

### 12.9 持久化 + 模式切换即时性决策

- **持久化**：`SettingsStore` 新增 `@Published var windowBehaviorModeRaw`（UserDefaults key `windowBehaviorMode`，`register` 默认 `normal`=C），只存 rawValue，非法值 fallback 默认；**不进 `AppConfig`**（与 AI 引擎无关），与主题偏好同规格（非敏感 → 不碰 constitution 红线）。
- **模式切换即时性决策（本阶段拍板项）= 下次开窗生效**：`behavior` 在窗口 **`present()` 时捕获**并写入 `ReviewWindowMachineState.behavior`，运行期不变；改设置**不回溯改已打开窗口**的层级/焦点行为，下次开窗读新值。
  - **理由**：纠错弹窗生命周期极短（一次划词一个窗），中途改 level（普通↔floating）叠加折叠/展开会引入层级/焦点抖动（proposal §9.6 风险）；捕获式最简单、可测、无抖动。与需求官建议一致。
  - 代码/测试注释写明此捕获时机，避免「设置窗开着已有弹窗时用户以为即时生效」的误解（Codex P2.7）。

### 12.10 Round 2 关键决策

| 决策点 | 选择 | 备选 | 理由 | 关联 |
|---|---|---|---|---|
| R1 Bug1 消除方式 | 结构门控（未封顶不包滚动容器）+ 测量/显示解耦 | 仅调小 debounce / 隐藏 scroller | 结构上不存在 scroller → 与帧时序无关的正确性保证；纯调时序仍有中间帧风险 | §12.1 |
| R2 测量源 | 常驻独立 measurement host（固定宽、无滚动、alpha0） | 复用显示树的 PreferenceKey | 折叠期显示树可能不 layout → 测量失效（Bug2）；且显示树 wrap/unwrap 致边界反跳 | §12.3 / Codex P0.2/P0.3 |
| R3 resize 时序 | 去 debounce/动画，pending-flag runloop 合并只 apply 最新 | 保留 60ms debounce | debounce 制造滞后 = 滚动条；runloop 合并既跟手又不过度 setFrame | §12.1c / Codex P1.6 |
| R4 状态机形态 | `behavior×presentation` + 显式 action 列表 | behavior 仅作 reduce 入参 | 编码进态 + action 化便于枚举 3×事件全矩阵、不漏副作用组合 | §12.4 / Codex P1.4 |
| R5 层级施加 | level=f(behavior)，两 panel 两态都施加并 re-apply | 仅改 expanded level | 胶囊层级也须随模式（B 胶囊置顶）；漏一处即层级分叉 | §12.5 / Codex P1.5 |
| R6 模式切换即时性 | 下次开窗生效（present 时捕获） | 即时作用于已开窗口 | 弹窗短命 + 避免中途改 level 抖动；最简可测 | §12.9 |
| R7 隐藏图标载体 | 标题栏 `NSTitlebarAccessoryViewController` | 内容区 `.overlay(.topTrailing)` | 不污染自然尺寸测量树（Bug1 测量口径） | §12.6 / Codex UI |
| R8 三模式选择器 | 单选卡片 | 分段控件 | B 模式语义须显式写明，分段控件藏语义、验收心智风险高 | §12.7 / Codex UI |

### 12.11 Round 2 影响面（相对已落地代码）

| 文件 | Round 2 改动 | 兼容性 |
|---|---|---|
| `ReviewWindowMode.swift` | 新增 `WindowBehaviorMode`；`ReviewWindowMachineState`（behavior×presentation）；`ReviewWindowAction` / `ReviewWindowOutcome`；`reduce` 改产出 action 列表；新增事件 `.hideIcon`；`.resignKey` 语义下沉为仅 A | 纯逻辑，随控制器改；旧 `reduce` 测试需迁移到新签名 |
| `AppCoordinator.swift`（`ReviewWindowController`） | 常驻 measurement host + re-parent；`isOverflowing` 计算并注入 ReviewView；去 debounce → pending-flag runloop 合并 setFrame；`applyExpand` 改重算（Bug2）；`applyLevel(for:panel:)` 两 panel 两态施加；`windowDidResignKey` 仅 A；标题栏隐藏图标 accessory；`present` 时捕获 behavior | 内部实现；入口不变 |
| `ReviewView.swift` | 去掉恒定 `ScrollView`，改 `isOverflowing ? ScrollView : 直渲`；自然尺寸测量移交 measurement host（显示树不自测几何） | 视图私有 |
| `SettingsStore.swift` | 新增 `windowBehaviorModeRaw` + `register` 默认 `normal` + 便捷 `windowBehaviorMode` 计算属性 | 新增字段，旧用户读默认 C |
| `SettingsView.swift` | `generalSection` 加三模式单选卡片 | 兼容 |
| 新增（可选拆分） | `WindowBehaviorMode`、隐藏图标 SwiftUI 小视图、三模式卡片视图 | 新增 |

### 12.12 Round 2 测试策略（把 spec Round 2 TBD 具体化，交开发测试阶段落地）

> spec `review-window` 里 Round 2 新增/改写 Scenario 已由开发测试阶段替换为真实测试路径；下表保留设计阶段给出的可落地单测口径。SwiftUI View body / NSPanel 面板机械层由手工 UI 验收兜底。

| spec Scenario（Round 2） | 测试落点 | 断言 |
|---|---|---|
| 未达 maxH 无滚动条（Bug1） | `ReviewWindowSizingTests` + controller `isOverflowing` seam | 逐帧喂 `naturalH ≤ maxH`：`isOverflowing==false`（显示树不含滚动容器）；窗口 contentH == naturalH；无 vertical scroller |
| 超 maxH 才滚动 | `ReviewWindowSizingTests` | `naturalH > maxH+ε` → `isOverflowing==true`、contentH 封顶 maxH |
| 展开按当刻内容重算（Bug2） | 控制器 recompute seam（注入 `latestNaturalSize`） | 折叠前 S0；折叠期改 `latestNaturalSize`（增/减）；展开断言 frame==`sizing.target(当刻,vf)` 且 `!= S0` |
| 折叠期测量不失效 | measurement host 更新路径 | 折叠态喂 state 变更 → `latestNaturalSize` 随之更新（不停在旧值） |
| 全新安装默认 C | `WindowModeStoreTests`（独立 UserDefaults suite） | 未写偏好 → `windowBehaviorMode == .normal` |
| 模式持久化 | `WindowModeStoreTests` | set `.alwaysOnTop` → 读回 B；跨新实例仍 B；非法 rawValue fallback C |
| 失焦行为随模式差分 | `ReviewWindowModeTests`（3×事件矩阵） | A+resignKey→collapsed；B/C+resignKey→expanded（no-op） |
| Esc / 隐藏图标三模式一律折叠 | `ReviewWindowModeTests` | A/B/C + esc / hideIcon → collapsed 且 outcome 无 `.cancelTask` |
| 点击胶囊三模式展开+重算 | `ReviewWindowModeTests` | A/B/C：collapsed+tapCapsule → expanded 且 actions 含 `.recomputeSize` |
| 层级随模式差分 | `ReviewWindowLevelTests`（对 `applyLevel` 结果断言，或注入 fake panel） | B→`.floating`+`isFloatingPanel`；A/C→`.normal`；胶囊同 behavior |
| 关闭唯一 cancel（三模式） | 沿用 `CloseSemanticsTests` | closeRequested→outcome 含 `.cancelTask`；esc/resignKey/hideIcon 均无 |
| 模式切换下次开窗生效 | 控制器 present seam | 改设置后已开窗口 behavior 不变；下次 present 读新值 |

### 12.13 Constitution check（Round 2）

- [x] 已读 [constitution.md](../../overview/constitution.md) 4 条红线，**Round 2 无冲突**。
- [x] 窗口行为模式 = **非敏感偏好** → UserDefaults（Constraint-1 仅约束 API key，不进 Keychain）。
- [x] 不新增日志/落盘原文修正文（Constraint-2）；不动最小改动护栏/diff/流式解析/AI 调用（Constraint-3）；不改用户原选区（Constraint-4）。
- [x] 无红线强制覆盖。

### 12.14 Codex 交叉评审摘要（Round 2）

- **协作方式**：用户点名「让 Codex 设计 UI」——Codex **主导 UI/视觉设计**（设置三模式选择器 / 隐藏图标 / 胶囊三态），Claude 做内部落地设计；两线并行后**对抗式交叉评审 3 轮收敛**。
- **Codex 主导并采纳的 UI 定稿**：① 设置三模式 = **单选卡片**（非分段控件，因 B 语义须显式写明）；② 隐藏图标 = **标题栏 accessory + `minus.circle`**（不进内容测量树、不用 xmark/红色）；③ 胶囊三态保留并增强（148×44、三态动效时长、**B 模式 `pin.fill` 置顶暗示**）。四套主题体系（Aurora Glass 默认）Round 1 已定、本轮不推翻。
- **Codex 对抗评审我方内部方案的关键意见（全部采纳，逐条闭环）**：
  - **P0.1**：Bug1 不能只靠时序，要**结构保证**（未封顶不包滚动容器）→ §12.1a。
  - **P0.2**：overflow 边界 wrap/unwrap 致 `naturalH` 反跳 → **测量树与显示树分离** → §12.1b/§12.3。
  - **P0.3**（第 2 轮提出、第 3 轮确认闭环）：折叠期测量链路有隐含前提，orderOut 后可能不 layout → **专用常驻测量宿主、任何态不卸载、显式 layoutSubtreeIfNeeded** → §12.3。
  - **P1.4**：状态机把 behavior 编码进态、reduce 产出 action 列表、枚举 3×事件全矩阵 → §12.4。
  - **P1.5**：层级须两 panel 两态统一施加并 re-apply → §12.5。
  - **P1.6**：去 debounce 但需 pending-flag runloop 合并、避免每 token setFrame → §12.1c。
  - **P2.7/P2.8**：模式切换「下次开窗生效」需注释/测试写清；隐藏图标须进状态机+持久化+测试 → §12.9/§12.6/§12.12。
- **分歧与收敛**：无高级别不可约分歧；三轮均为**正确性/可行性沿本方向的收紧**（非路线之争），本方逐条采纳。**Codex 第 3 轮结论：通过，残留问题无。**
- **评审轮数**：**3 轮收敛**（第 1 轮 Codex 提 P0/P1/P2 → 采纳；第 2 轮确认，剩 P0.3 折叠期测量 → 补常驻测量宿主；第 3 轮确认 P0.3 闭环、通过）。无需回退。

### 12.15 待用户拍板的视觉项（视觉审美用户保留权）

主题体系（4 套、默认 Aurora Glass）Round 1 已定、本轮不变；Round 2 新增 3 处视觉决策已按 **Codex 推荐默认**写入本设计，**开发可基于此推进**。以下 3 项属用户保留的审美取舍，若要改，一句话即可（改动都很小）：

| # | 视觉项 | Codex 推荐（现默认） | 备选 |
|---|---|---|---|
| V1 | 设置三模式选择器 | 三张单选卡片（带副文案解释） | 分段控件（省空间但藏语义） |
| V2 | 隐藏图标 | 标题栏右侧 `minus.circle` | 其它 SF Symbol / 位置 |
| V3 | B 模式置顶暗示 | 胶囊右上 10pt `pin.fill` 小徽标 | 不加暗示 / 换表现 |

### 12.16 Round 2 后续动作建议（开发测试阶段）

- 建议落地顺序：① `WindowBehaviorMode` + 状态机改 action 化 + `.hideIcon`（纯逻辑、先补 3×事件矩阵单测）→ ② 常驻 measurement host + `isOverflowing` 注入 + 去 debounce（Bug1，正确性优先）→ ③ `applyExpand` 重算（Bug2）→ ④ `applyLevel` 两 panel 两态 + `windowDidResignKey` 仅 A → ⑤ 设置三模式卡片 + `windowBehaviorModeRaw` 持久化 + 标题栏隐藏图标 → ⑥ spec Round 2 覆盖测试路径替换 + 手工 UI 验收。
- **dev↔test 内循环边界**：开发官落地②③ 时必须**主动做 Bug1/Bug2 的失败/边界验收**（不是只跑 happy-path）——Bug1 逐帧断言「≤maxH 无 scroller」、Bug2 断言「展开尺寸 == 当刻重算 ≠ 折叠前」；测试阶段独立复核这两条正确性红线（不因触发概率降级）。
- 无离线数据/对账；无新埋点/监控（折叠三态不记录内容，仅本地状态）。

### 12.17 Round 2 变更历史

| 轮次 | 日期 | 变更 |
|---|---|---|
| Round 2 设计 | 2026-07-06 | Bug1 结构门控 + 测量/显示解耦 + runloop 合并；Bug2 常驻测量宿主 + 展开重算；三模式单一状态机（behavior×presentation+action）；层级随模式两 panel 两态；隐藏图标标题栏 accessory；设置三模式单选卡片；胶囊三态增强 + B 置顶暗示；模式切换下次开窗生效。Codex 主导 UI + 交叉评审 3 轮收敛。 |

---

## 13. Round 3（高度 bug 根因反转：实测钉死单调锁 + 初始屏幕定位）

> **需求来源**：proposal [§10](./proposal.md)（用户第 3 次报同类高度 bug，要求「修到对抗评审通过为止」）+ spec `review-window` Round 3 H1/H2 硬验收。
> **本轮性质特殊**：同一「窗口高度暴涨/卡在接近最大」bug 在 round2（`1a0c974`）、round2.5（`1ee16b5`）两次修复后仍复发。本轮**先用实测驱动真实路径钉死根因、再设计修复**，对抗式交叉评审是硬 gate（Codex 3 轮收敛，最终「通过」）。
> **诚实记录（根因反转）**：需求/上游把根因定性为「测量 greedy-fill 把内容撑到 ≈maxH」。**本轮实测证伪了这一假设**——真实测量是正确的，真正被复现的根因是 `ReviewWindowSizing.monotonicTarget` 的**流式高度永久单调锁**。详见 §13.1。

### 13.1 根因定位（实测驱动真实路径，非算术推断）

**方法**：在 `swift test` 里加临时 probe seam 驱动**真实** `ReviewWindowController.showCentered()` / `refreshMeasurement()` / `applyResize()`（**不预塞自然高度**），打印生产测量出的 `latestNaturalSize` 与 `expandedPanel` 实际 content 尺寸。屏幕 `maxH=734.3`。

**实测 ground truth**：

| 场景 | 生产测得 natural.height | 实际 applied.height | 判读 |
|---|---|---|---|
| loading 初始 | 184 | 216 | 正常，非 maxH |
| long streaming（长内容） | 600 | 600 | 随内容增，正确 |
| **long 之后喂 short streaming** | **200（正确回落）** | **600（卡死）** | ← **bug 复现** |
| **long 之后回 loading** | **184（正确回落）** | **600（卡死）** | ← bug 复现 |
| 隔离 host：container 高 200 vs 800 | fitting/sizeThatFits 均 152 | — | container 高**未污染**测量 |

**结论（Codex 独立复核一致）**：

1. **测量是正确的**：真实 `refreshMeasurement` 在四种内容下量出的自然高（184/600/200/184）都正确。`ReviewMeasurementView` 的 `.fixedSize(horizontal:false, vertical:true)` 使**高度不会 greedy-fill**（对照：宽度因 `ThemedCard` 的 `.frame(maxWidth:.infinity)` 才填到 maxW=537.5，`natural.width` 恒为 maxW 属预期，非 bug）。→ **「greedy-fill 测量污染」假设被实测证伪**；隔离 fittingSize 也未被 800pt container 污染。
2. **真正被复现的根因 = `ReviewWindowSizing.monotonicTarget` 的流式单调锁**（`ReviewWindowSizing.swift:43` + `AppCoordinator.applyResize` 传 `isStreaming=true`，`AppCoordinator.swift:418`）：streaming/loading 态执行 `t.height = max(lastHeight, t.height)`，round2.5 加的特判**只在 `lastHeight >= maxH(734)` 才允许回落**。当峰值停在 **maxH 以下**（如 600）、或内容变短、或某一帧瞬时测高，applied 高度就**永久卡在峰值**不回落——正是用户「涨上去下不来 / 内容短却一堆失控空白 / 窗口接近最大」的现象（H1 初始态、H2 加载过程同源）。
3. **为什么修了两次没好**：两次修复都在**算术/测量层**打转（`ReviewWindowSizing` 111 单测全绿，但都直接喂正确自然高度、绕过真实 apply 逻辑），从未测「峰后回落」这条真实路径。这正是「happy-path 全绿 ≠ 验收通过」——绿的部分绕开了出错的环节（单调锁）。

### 13.2 修复 R3-1：去除永久单调锁（本次真根因）

- `applyResize` 改用 `sizing.target(natural:, visibleFrame:)`（当刻 clamp，**可增可减**），**删除** `monotonicTarget` 的 `max(lastHeight, ·)` 永久锁与 round2.5 的 `lastHeight >= maxH` 特判。
- **抗抖**：保留 `applyResize` 现有 `0.5pt` 阈值 + `scheduleApplyLatestSize` 的 runloop 合并即可；**若** UI verify 观察到流式逐帧抖动，才追加**有界、可取消、无峰值记忆**的 shrink-settle（缩小延迟一帧/几十 ms，期间新 measurement 到来即取消重算，到点仍以最新 natural 计算）。**绝不允许**任何形式的 `max(lastHeight, ·)` 历史峰值锁。
- **Bug1 不回归**：round2「未超 maxH 无纵向滚动条」由 `isOverflowing` 结构门控保证（`ReviewView` 依 controller 注入的 `isOverflowing` 决定是否包 `ScrollView`），**与单调锁无关**，故移除单调锁不影响 Bug1 的结构保证。
- **统一入口（Codex 验收硬点 #1）**：`applyResize` 的**所有**入口（loading/streaming/result/error 切换、`recomputeSize` 展开路径）必须统一走 `target()`，**不得残留任何基于旧 `lastHeight` 的峰值记忆**。

### 13.3 修复 R3-2：测量硬化（防御纵深，非本次根因）

> 实测已证明当前测量正确；本项是**防御纵深 + 满足 spec 新增「内容自然高度按内在尺寸测量」Requirement + 验收纪律**，不是本次复现根因。诚实标注避免再次误把它当根因。

- `refreshMeasurement` 弃用「挂在显示 container 上的 `measurementHosting.fittingSize`」双通道（fittingSize + preference 两条通道存在竞态），改用**独立、不挂显示 container** 的 `NSHostingController<ReviewMeasurementView>.sizeThatFits(in: CGSize(width: maxW, height: .greatestFiniteMagnitude))` 作**单一确定测量源**——固定宽、无界高，结构上免疫 container/frame 耦合与历史帧污染。
- **测量环境等价（Codex 验收硬点 #2）**：独立测量视图必须继承与显示视图**等价的环境与约束**——宽度(=maxW)、字体/动态字号、`layoutDirection`、content 数据、状态分支；否则会把「显示容器污染」换成「测量环境不一致」的新坑。
- `ReviewMeasurementView` 保持无 `ScrollView`、无 `maxHeight`、保留 `.fixedSize(vertical:true)`。

### 13.4 H1（初始加载态失控空白）

同源于 §13.1 单调锁（初始态若被上一帧高度锚定或非当刻自然高，即在取消按钮下方留失控空白）。修复即 R3-1：loading 态 applied 高度 = 当刻自然高经 clamp（下夹 `minH`），随内容回落。**留白纪律**：loading 现有 24pt 内边距属克制，可接受；cancel 按钮下方 **>32pt 视为 H1 回归**，验收须断言无失控空白。

### 13.5 初始屏幕定位（Codex 按 UI/UX 定，用户已授权）

用户澄清「起始更高」实为**定位诉求（往上/可往右挪）**，非尺寸。替换 `showCentered()` 里的 `expandedPanel.center()`：

```swift
let dxRatio: CGFloat = 0.54   // 比水平居中略右（不抢注意力）
let dyRatio: CGFloat = 0.66   // 比垂直居中明显上移（进入上半视线区）
origin.x = vf.minX + (vf.width  - frame.width)  * dxRatio
origin.y = vf.minY + (vf.height - frame.height) * dyRatio
keepFrameInVisibleScreen(&frame, visibleFrame: vf)
```

- `0.66`：窗口越高可移动空间越小，天然避免贴顶；`0.54`：轻微右移。
- **宽度口径不动**（round2.5 定 `minW=336 / maxW=屏宽×0.28`）。
- **越界兜底（Codex 验收硬点 #4）**：初始定位后、以及**每次 resize 之后**都要再走 `keepFrameInVisibleScreen`，保证整窗 `⊆ visibleFrame`，避免内容变高/变矮后越界或跳位。

### 13.6 Round 3 测试策略（真实路径，禁预塞自然高，绿≠通过）

> 硬约束（交开发官执行）：H1/H2 回归测试**必须驱动真实测量+apply 路径**（真实 `ReviewWindowController` / `ReviewMeasurementView`），**禁止预塞自然高度**；**必测失败路径**；`swift test` 全绿不构成通过。为此需给 `ReviewWindowController` 加 `internal` test seam（如 `refreshMeasurementForTesting()`、`applyAndReadContentSizeForTesting(phase:)`），**seam 必须调用生产 `refreshMeasurement()`/`applyResize()`，不得直接写 natural height**。

| 场景（spec H1/H2 + 硬化） | 测试落点 | 断言 |
|---|---|---|
| **峰后回落（本次根因回归）** | 真实控制器：showCentered → long streaming（applied≈峰 600）→ short streaming | `natural.height≈小(200)` 且 `applied.height≈target(200)`、`applied≠旧峰`；再切 loading 继续回落到 ≈184，**不卡 600** |
| 单调锁反转（纯 sizing） | `ReviewWindowSizingTests` | **反转/替换** `testHeightMonotonicWhenStreaming`；新增 `lastHeight=600,maxH=700,natural=200,isStreaming=true ⇒ 200`；覆盖 `lastHeight=maxH` 与 `lastHeight<maxH` 两类回落 |
| H2 逐帧不超前 | 真实控制器逐块喂增量 | 每块固有高 `h_N<maxH` 时 applied≈`h_N`、`<maxH`、小步单调增；出现「先跳 maxH 再填」即 fail |
| H1 初始无失控空白 | 真实控制器 loading | applied≈loading 固有高（下夹 minH）；cancel 下方留白 ≤32pt |
| **greedy-fill 失败线（测量 Requirement 防御纵深）** | 真实 `ReviewMeasurementView`/measure：超高 container 下短 loading | measured height `< 0.5×maxH`；若 measured≈maxH **直接 fail** |
| 长内容仍封顶+滚动（Codex 验收硬点 #3） | 真实控制器 | `natural>maxH` → applied clamp 到 `maxH` 且 `isOverflowing=true` 滚动可用；短内容无滚动条不回归 |
| 初始定位不越界 | sizing/controller | dx=0.54/dy=0.66 定位后整窗 `⊆ visibleFrame`；resize 后仍在屏内 |

> **CI 可行性**：真实 `NSHostingController.sizeThatFits`/控制器路径需 macOS 会话（登录态可跑；纯无头 WindowServer 环境作 AppKit 集成测试单独标注）。spec 覆盖测试标 `TBD(unit/UI:...)`，dev 阶段选可行载体，但**不得**退回「喂正确自然高度」的伪覆盖（这正是前两次复发的原因）。

### 13.7 Round 3 影响面

| 文件 | Round 3 改动 |
|---|---|
| `ReviewWindowSizing.swift` | 删除/改写 `monotonicTarget` 的单调锁与 round2.5 特判；`applyResize` 侧改调 `target()`。`target/limits/isOverflowing` 不变 |
| `AppCoordinator.swift` | `applyResize` 统一走 `target()`（全入口）；`refreshMeasurement` 改独立 `NSHostingController.sizeThatFits` 单一源、measure 不挂显示 container；`showCentered` 定位改 dx0.54/dy0.66 + resize 后 keepFrameInVisibleScreen；加 test seam |
| `ReviewView.swift` | `ReviewMeasurementView` 保持结构（无 ScrollView / 无 maxHeight / fixedSize vertical），确保测量环境与显示等价 |
| `Tests/` | 新增真实路径回归测试（峰后回落 / greedy-fill 失败线 / H1 / 长内容封顶）；反转 `testHeightMonotonicWhenStreaming` |

### 13.8 Codex 对抗式交叉评审摘要（Round 3）

- **协作方式**：Claude 与 Codex **并行独立诊断**根因；Claude 用**实测驱动真实路径**取得 ground truth。**对抗式交叉评审 3 轮收敛**。
- **第 1 轮（独立诊断）**：双方**都**先倾向「`NSHostingView.fittingSize` 测量污染 / greedy-fill」假设（Codex 主张改 `sizeThatFits`、measure 不挂 container）。
- **反转（实测证伪）**：Claude 实测真实控制器路径 → 测量正确（natural 184/600/200/184 均对）、container 高不污染 fittingSize；**证伪 greedy-fill 假设**，暴露真根因 = `monotonicTarget` 单调锁「峰后不回落」。
- **第 2 轮（对抗复核）**：把实测证据交 Codex 独立复核；Codex **独立追踪代码路径确认**（`lastHeight=600,maxH=734,natural=200 → max(600,200)=600` 卡死），**同意**真根因是单调锁、测量本身正确；细化抗抖必须「有界、可取消、无峰值记忆」+ 测试口径。
- **第 3 轮（定稿确认）**：Codex 对定稿（R3-1 去锁 + R3-2 测量硬化 + 真实路径测试 + UI 定位 + 诚实记录反转）判**「通过」**，补 4 条开发验收硬点（统一 resize 入口、测量环境等价、长内容封顶+滚动、resize 后保持屏内）——均已并入 §13.2/13.3/13.5/13.6。
- **结论**：3 轮收敛、无高级别不可约分歧、无需回退。**关键教训**：正确性根因必须由**驱动真实路径的实测**钉死，不能停在算术单测（前两次复发正因如此）。

### 13.9 Round 3 待用户拍板的视觉项（用户已授权 Codex，仅供可选覆盖）

用户已明确「留白多少、窗口放哪，让 Codex 按 UI/UX 规范设计」。以下已按 Codex 定稿写入、**开发可直接推进**，用户若要改一句话即可：

| 项 | Codex 定（现默认） |
|---|---|
| 初始屏幕定位 | 相对可用空间 dx=0.54（略右）、dy=0.66（明显上移），不越界 |
| 留白 | 贴合内容、仅保留现有克制内边距（loading 24pt）；cancel 下方 >32pt 视为 H1 bug |

### 13.10 Round 3 后续动作建议（开发测试阶段）

- 落地顺序：① **R3-1 去单调锁**（`applyResize` 全入口走 `target()`，删峰值锁）——正确性优先，先补「峰后回落」真实路径回归测试并让它先 fail 再 fix → ② **R3-2 测量改 `sizeThatFits` 独立源**（防御纵深）+ greedy-fill 失败线测试 → ③ 初始定位 dx0.54/dy0.66 + resize 后 keepFrameInVisibleScreen → ④ 反转 `testHeightMonotonicWhenStreaming`、补 H1/长内容封顶测试、把 spec H1/H2 的 `TBD` 替换真实测试路径 → ⑤ 手工 UI 验收（短/长/流式峰后变短/loading 空白/初始位置）。
- **dev↔test 内循环红线**：测试**必须驱动真实测量+apply 路径**、**必测失败路径**（峰后回落、greedy-fill）；**`swift test` 全绿 ≠ 通过**（前两次复发的直接原因）。测试阶段独立复核这两条，正确性问题不因触发概率降级。

### 13.11 Round 3 变更历史

| 轮次 | 日期 | 变更 |
|---|---|---|
| Round 3 设计 | 2026-07-07 | **实测钉死根因反转**：greedy-fill 测量污染假设被证伪，真根因 = `monotonicTarget` 流式单调锁「峰后不回落」。R3-1 去永久单调锁（applyResize 全入口走 target、可增可减）；R3-2 测量改独立 `NSHostingController.sizeThatFits` 单一源（防御纵深）；初始定位 dx0.54/dy0.66 不越界；真实路径回归测试（峰后回落/greedy-fill 失败线/H1/长内容封顶）。Codex 对抗评审 3 轮收敛「通过」。 |
