# LangFix

一个 macOS 菜单栏划词写作纠错工具：选中你用非母语（首要场景是英文，不限于英文）写的一段文本 → 通过 PopClip 触发 → 弹窗给出**最小改动**的语法 / 拼写 / 用词 / 地道度修正，并用你的母语（中文）解释哪里错、为什么、怎么改。

> A macOS menu-bar writing-correction tool: select text you wrote in a non-native language → trigger via PopClip → a popup shows **minimal-edit** corrections with explanations in your native language.

## 技术路线

- 原生 **SwiftUI** 菜单栏常驻 App（AppKit 补 `NSPanel` 浮窗 / Service provider）
- 触发：PopClip **Service action** → macOS Service
- AI：**OpenAI 兼容端点**（base URL / key / model 全可配），结构化输出三级降级
- 密钥进 Keychain，消息内容不落盘

## 安装

`./build.sh dmg` 生成 `dist/LangFix-<版本>.dmg`，打开后把 LangFix 拖到 Applications 即可（首次启动被拦：右键 → 打开）。详见 [INSTALL.md](./INSTALL.md)。

## 文档

完整设计文档（背景 / 架构 / spec / 决策记录）见 [`docs/`](./docs/README.md)。

- 想了解项目：[`docs/overview/project.md`](./docs/overview/project.md)
- 想动手实现：[`docs/architecture/README.md`](./docs/architecture/README.md) + [`docs/specs/grammar-review/spec.md`](./docs/specs/grammar-review/spec.md)
- 想知道为什么这么设计：[`docs/decisions/README.md`](./docs/decisions/README.md)
