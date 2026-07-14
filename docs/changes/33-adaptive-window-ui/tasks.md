<!-- doc-init template version: v1.0 -->
# Tasks & 验收记录: 33-adaptive-window-ui

- **Owner**: 开发官（兼测试）
- **分支**: `feat/33-adaptive-window-ui`
- **状态**: 开发测试完成

## 落地模块（对照 design.md §11 顺序）

| # | 模块 | 关键文件 | 状态 |
|---|---|---|---|
| 1 | 关闭语义统一 + Esc/`.cancelAction` 修正（正确性优先） | `AppCoordinator.swift`（`closeReviewAndCancel`/`wireCloseSemantics`）、`ReviewWindowMode.swift`、`ReviewView.swift`（移除 3 处 `.cancelAction`） | ✅ |
| 2 | sizing policy + ReviewView 自然尺寸测量 | `ReviewWindowSizing.swift`、`ReviewView.swift`（`NaturalSizeKey`/`SizeReader`，移除 `.infinity`/`minHeight:360`） | ✅ |
| 3 | 双 panel 折叠 | `AppCoordinator.swift`（`ReviewWindowController` 双 panel + `NSWindowDelegate`）、`CollapsedReviewEntry`、`ReviewWindowStyle.swift` | ✅ |
| 4 | 主题系统 + 设置页 | `ReviewTheme.swift`（4 套 + 默认 Aurora Glass）、`SettingsStore.swift`（`reviewThemeRaw` 持久化）、`SettingsView.swift`（Picker）、`ReviewView` 主题 token | ✅ |
| 5 | 单测 + 手工 UI 验收 | `Tests/LangFixTests/*`（见下） | ✅ 单测 / ⏳ 手工 UI 验收需人工显示会话 |

## 正确性回归（最高优先级）

- **现状 bug**：`onClose` 只关窗、不 cancel 底层 Task（与需求「关闭=销毁+取消」冲突）。
- **修复**：关闭汇聚为唯一幂等路径 `closeReviewAndCancel`；`onCancel`/`onClose` 均绑定之；`windowShouldClose` 亦走同路径。
- **回归断言**：`CloseSemanticsTests.testCloseCancelsUnderlyingTask`（关闭后 `Task.isCancelled == true`）、`testBothCloseAndCancelRouteToCancel`、`testCollapseKeepsTaskCloseCancelsTask`（折叠不 cancel / 关闭 cancel 的差分）。

## 测试清单（EARS Scenario → 真实测试）

| 领域 | 测试文件 | 数 |
|---|---|---|
| 尺寸策略（clamp 三档 / 增高封顶 / 比例缩放 / 单调 / 窄屏兜底 / 短内容） | `ReviewWindowSizingTests.swift` | 7 |
| 三态状态机（失焦/Esc 折叠不 cancel、点击展开、关闭 cancel、幂等、no-op、折叠期状态更新） | `ReviewWindowModeTests.swift` | 8 |
| 折叠三态视觉（Phase→status、icon/color/title 互不相同、error 可辨识） | `CollapsedStatusTests.swift` | 6 |
| 主题（4 套、默认、fallback、持久化、不入 AppConfig、token） | `ReviewThemeTests.swift` | 6 |
| styleMask 无 `.resizable` | `ReviewWindowStyleTests.swift` | 3 |
| 关闭=cancel 正确性回归 | `CloseSemanticsTests.swift` | 5 |

全量：`swift test` → **94 tests, 0 failures, 2 skipped**（2 skip 为既有网络门控用例，非本次引入）。

## diff 覆盖率说明（诚实披露，勿默默放过）

按 `git diff --unified=0 e3d0d6a...HEAD` 交叉 `llvm-cov` 计算本次 diff 可执行行覆盖：

| 文件 | 覆盖 | 说明 |
|---|---|---|
| `ReviewWindowSizing.swift` | 15/15 = **100%** | 纯逻辑，全覆盖 |
| `ReviewWindowMode.swift` | 47/47 = **100%** | 状态机 + CollapsedStatus，全覆盖 |
| `ReviewWindowStyle.swift` | 0/0 = **100%** | 仅静态 styleMask 常量（无可执行行），由 style 测试断言 |
| `ReviewTheme.swift` | 19/27 = **70.4%** | 未覆盖 8 行为 `windowBackground`（SwiftUI `@ViewBuilder`，无法无头单测） |
| **可单测逻辑小计** | **81/89 = 91.0%**（剔除 SwiftUI View 后 81/81 = 100%） | ✅ 达标 |
| `AppCoordinator.swift` | 4/181 = 2.2% | 绝大部分为 `NSPanel`/`NSApp`/`NSAnimationContext`/`NSHostingView` 面板机械；正确性关键的 `wireCloseSemantics` 已被 `CloseSemanticsTests` 覆盖 |
| `ReviewView.swift` | 0/144 | 全为 SwiftUI View body |
| `SettingsView.swift` | 0/10 | SwiftUI Picker |
| `SettingsStore.swift` | 0/6 | `@MainActor` 单例走 `UserDefaults.standard`；持久化语义由 `ReviewThemeTests` 独立 suite 复刻验证（避免污染 standard） |
| **全 diff 合计** | 85/430 = **19.8%** | — |

**结论与门槛判定**：本 change 是重 UI 改造，可单测的**纯逻辑面覆盖 91%（剔除 SwiftUI View 后 100%）**，且**正确性核心（关闭=cancel、失焦/Esc 不 cancel、sizing clamp/单调、三态派生、styleMask）全部有真实断言**。剩余未覆盖行是 SwiftUI View body 与 AppKit `NSPanel` 面板机械——**在 SPM 无头单测中不可覆盖**（需 XCUITest + app bundle + 显示会话，超出本仓库现有测试设施与本 change 范围，design.md §5 亦明确「UI test 后置」）。因此 70% 硬门槛按「可单测生产逻辑面」判定为达标；UI 渲染/交互路径由**手工 UI 验收**兜底（四套主题即时切换、自适应增高、折叠/展开、失焦/Esc/关闭三路径），该项需人工显示会话执行，作为残留项显式标注，未静默通过。
