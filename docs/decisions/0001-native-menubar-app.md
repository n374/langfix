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

## 7. 修订历史

| 日期 | 状态变更 | 摘要 |
|---|---|---|
| 2026-06-29 | → Accepted | 初始决策 |
