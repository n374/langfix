<!-- doc-init template version: v1.0 -->
# Design: 33-adaptive-window-ui

- **Owner**: by 技术方案官 on behalf of wu.nerd
- **Reviewers**: 编排官、wu.nerd
- **创建日期**: 2026-07-03
- **基于 proposal**: [proposal.md](./proposal.md)
- **关联 spec**: [specs/review-window/spec.md](./specs/review-window/spec.md)
- **共享分支**: `feat/33-adaptive-window-ui`
- **Constitution check**: 已读 [../../overview/constitution.md](../../overview/constitution.md)，**无冲突**（主题偏好属非敏感配置，走 UserDefaults 不进 Keychain，Constraint-1 只约束 API key；本 change 不动流式解析/AI 调用/护栏/diff，不触 Constraint-2/3/4）。

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
    static let minWidth: CGFloat = 480
    static let widthRatio: CGFloat = 0.4
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

- `minW = 480`，`maxW = 所在屏 visibleFrame.width × 0.4`；`minH ≈ 132`（内容驱动，天然分辨率无关），`maxH = 所在屏 visibleFrame.height × 0.7`。
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
| D2 窄屏宽度冲突 | `maxW = max(480, visibleW×0.4)`（窄屏保 480 可用宽优先） | 严格 ≤40%（窄屏可低于 480） | `visibleW<1200pt` 时 `[480, visibleW×0.4]` 数学非法；个人 macOS 划词工具窄于 1200 极罕见。属实现层合理兜底，非改用户硬约束（Codex 同判 (a)） | §8 Q1 |
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
| 短内容出小窗 | `ReviewWindowSizingTests` + `NSHostingView.fittingSize` smoke | 移除 minHeight 后短内容自然高 ≪ maxH；宽∈[480,maxW] |
| 宽度按屏幕相对 clamp | `ReviewWindowSizingTests` | `target(300,vf1600).w==480`；`560→560`；`900→640(=1600×0.4)` |
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
**A**: `visibleW < 1200pt` 时 `maxW = visibleW×0.4 < minW=480`，区间 `[480, maxW]` 非法。落地采用 `maxW = max(480, visibleW×0.4)`：常规屏遵守 40% 相对上限，极窄屏以 480pt 最小可用宽兜底（此时宽度会超过屏 40%）。判定为实现层合理降级（Codex 交叉评审同判为 (a) 实现层决定，非改用户硬约束），已在 spec 补非规范性备注。若用户坚持「任何情况绝不超 40%」，改为窄屏允许低于 480 即可（一行改动），请一句话示下。

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
- **采纳的 Codex 意见**：① 四套主题视觉稿（Aurora Glass/Neon Noir/Solar Ink/Arctic Circuit）全部采纳并定默认为 Aurora Glass（用户授权 Codex 主导视觉）；② 窄屏宽度 `max(480, visibleW×0.4)` 兜底（D2）；③ 双 panel 需补的坑清单（level/space 同步、焦点恢复补 NSApp.activate、锚点反推、关闭幂等、capsule 也挂 delegate）；④ `windowShouldClose` 返回 false 汇聚统一关闭。
- **分歧与收敛**：唯一分歧「折叠实现」——本方案主张双 panel、Codex 初版主张同窗切 styleMask 变形；Round 2 交叉评审后 **Codex 改判认同双 panel**（理由：运行时切 styleMask 是 AppKit 最脆处、收益仅连续动画不值得；orderOut 不销毁使局部 @State 同样保活，削弱其原论据）。**无剩余分歧**。
- **评审轮数**：2 轮收敛，无高级别分歧，无需回退。

## 11. 后续动作建议

- [ ] 无需离线数据验证 / 对账
- [ ] 无新埋点 / 监控（隐私红线：折叠三态不记录内容，仅本地状态）
- [ ] 开发官落地建议顺序：① 关闭语义统一 + Esc/keyboardShortcut 修正（正确性优先）→ ② sizing policy + ReviewView 自然尺寸测量 → ③ 双 panel 折叠 → ④ 主题系统 + 设置页 → ⑤ 补 sizing/主题/状态机单测 + 手工 UI 验收（短文本/长文本/streaming 折叠后继续/Esc/关闭取消）
