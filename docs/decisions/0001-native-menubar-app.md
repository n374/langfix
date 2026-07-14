<!-- doc-init template version: v1.0 -->
# ADR-0001: 采用原生 SwiftUI 菜单栏 App

- **状态**: Accepted
- **日期**: 2026-06-29
- **Owner（决策者）**: n374
- **Reviewers**: n374
- **关联 change**: —
- **影响 capability**: grammar-review

## 1. 上下文

需要一个「选中即触发、弹窗给修正」的 macOS 工具，体验要明显优于「一个简单调 AI 的脚本」（UI 弱、可信度低）。候选形态：原生 App、Electron、包装脚本（Python 菜单栏 + webview）。约束：触发要快（不打断输入）、要能渲染 diff/错误清单、要安全存密钥、个人自分发。

## 2. 决策

用 **Swift + SwiftUI（AppKit 补 NSPanel/Service/窗口定位）** 做一个**菜单栏常驻** App（`LSUIElement`，无 Dock 图标），Developer ID 分发。

## 3. 理由

- **零冷启动**：常驻进程，触发即出窗（目标 <300ms），脚本/Electron 冷启动达不到。
- **原生 UI**：浮窗、词级 diff 着色、错误卡片用原生最顺手、最轻。
- **安全**：Keychain、macOS Service 都是原生一等公民。
- **轻依赖**：尽量零第三方，维护面小。

## 4. 后果

- **正面**: 体验最佳、可长期演进、隐私可控。
- **负面**: 需要写 Swift；开发投入高于「包脚本」。
- **中立**: 仅 macOS（本就因 PopClip 限定 macOS）。

## 5. 备选方案

| 方案 | 优点 | 缺点 | 为什么不选 |
|---|---|---|---|
| Electron + 本地 AI 层 | 跨平台、Web UI 快 | 冷启动慢、包大、菜单栏/Service 体验差 | 触发延迟与原生感不达标 |
| Python(rumps) + pywebview 包脚本 | 落地最快 | 弹窗精致度/原生感弱、Service 集成别扭 | 目标是「相对完善、可长期演进」，选原生 |
| 纯 PopClip 内联展示（无独立 App） | 零额外进程 | 无法展示 diff/富文本/二次操作 | 满足不了「窗口 + 明确解释」 |

## 6. 实施

- 落地：建 Xcode 工程，菜单栏 + NSPanel + Service provider 骨架。
- 验收：对应 spec R1（触发即出窗）与 NFR-1（<300ms）。

### 6.1 顶层主菜单（round4 补充）

`LSUIElement` 应用默认**无主菜单栏**。为满足「顶层状态栏菜单」与「Cmd+, 打开设置」（macOS 通用约定），
在 `applicationDidFinishLaunching` 显式 `NSApp.mainMenu = AppMenu.build(target:)` 装一套主菜单（`AppMenu` 为纯构造、可单测）：

- **App 菜单**：关于 / 设置…（`Cmd+,`）/ 检查剪贴板 / 隐藏（`Cmd+H`）/ 退出（`Cmd+Q`）。
- **Edit 菜单**：撤销·重做·剪切·复制·粘贴·全选（走 first responder，使弹窗与设置文本框支持标准编辑快捷键）。
- **Window 菜单**：最小化（`Cmd+M`）/ 关闭（`Cmd+W`）。

`Cmd+,` 等 key equivalent 经 responder 链生效。右上角 `MenuBarExtra` 状态栏图标保留不变。

### 6.2 顶部主菜单栏"可见"——动态 activation policy（round6 修订）

round4 只设了 `NSApp.mainMenu`，但 `.accessory`(LSUIElement) 应用**即使前台也不显示顶部主菜单栏**（Apple/App名/文件/视图/帮助），用户因此"看不到菜单"。根因是 activation policy：`.accessory` 恒不显示主菜单栏。

修复（`AppCoordinator.syncActivationPolicy`）：**有可交互窗口（展开的弹窗 / 设置窗）时切 `.regular`**（此时才显示顶部主菜单栏），窗口全部关闭/折叠后回 `.accessory`。
- 决策纯函数 `wantsRegularPolicy(reviewExpanded:settingsVisible:)` 可单测；调用点：弹窗展示/关闭、展开/折叠(`onPresentationChange`)、设置窗开/关(`onClose`)。
- **权衡**：`.regular` 会**临时出现 Dock 图标**（仅在有窗口交互期间）；关掉窗口即恢复"无 Dock 图标"的菜单栏应用常态。这是"要可见主菜单栏"与"无 Dock 图标"不可兼得下的折中，如用户更在意后者可回退为仅保留 Cmd+, 快捷键（不显示菜单栏）。
- **验证边界**：主菜单栏是否真的显示是运行期 AppKit 行为，headless/CI 无法断言；自动化只覆盖 policy 决策与窗口可见性状态，**真机由用户确认**。

## 7. 修订历史

| 日期 | 状态变更 | 摘要 |
|---|---|---|
| 2026-06-29 | → Accepted | 初始决策 |
| 2026-07-07 | 补充 | round4：LSUIElement 应用补装顶层主菜单（App/Edit/Window）+ Cmd+, 打开设置 |
| 2026-07-08 | 修订 | round6：主菜单栏对 `.accessory` 不显示 → 动态 activation policy（有窗口切 `.regular` 显示菜单栏，代价临时 Dock 图标） |
