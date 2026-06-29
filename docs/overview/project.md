<!-- doc-init template version: v1.0 -->
# LangFix Project Overview

> **Owner**: n374
> **创建日期**: 2026-06-29
> **最后更新**: 2026-06-29

## 1. 项目背景

在工作中经常需要用非母语（首要是英文，但不限于英文）与他人书面沟通。非母语写作常常是「把母语语义直译过去」，难以保证符合目标语言的语法与地道表达。

LangFix 是一个 macOS 工具：选中任意一段你写的目标语言文本 → PopClip 一键触发 → 弹出窗口，**在原表达基础上做最小改动**，明确指出哪里错、为什么错、怎么改更合适，解释用你的母语（中文）。

### 解决的核心痛点

1. 不确定自己写的目标语言文本哪里不符合语法 / 不地道。
2. 通用「润色」工具往往**整段重写**，改变原意与语气，反而不敢用。
3. 触发链路重（切窗口、贴文本、读长回复），打断沟通节奏。

### 目标用户

母语为中文、需要用非母语做书面沟通的人。首位用户 n374：技术能力强，可接受 Developer ID 自分发（无需上架）。解释统一用中文。

### 语言定位

「英文」只是首要使用场景，**不与英文绑死**：架构与文案按「任意目标语言 + 母语解释」设计，便于后续扩展到其他语言对。

## 2. 范围

### In Scope（V1）

- PopClip Service action 触发 → 菜单栏 App 弹窗。
- AI 识别语法 / 拼写 / 用词 / 地道度 / 语气问题，给出**最小改动**修正 + 中文逐条解释。
- 词级 diff 可视化 + 一键复制修正结果。
- 接入**任意 OpenAI 兼容端点**（base URL / API key / model 可配）；设置页含「测试连接」与数据流向说明。
- API key 存 Keychain；不记录消息内容（须明示：文本会发往用户配置的端点处理）。
- App 未运行时支持 Service 冷拉起；默认开 Launch at Login 以常驻、消除冷启动延迟。

### Non-Goals（V1 明确不做）

- **不自动替换/回填用户原选区**（需 Accessibility 或 paste-back，易误操作；先做可靠「复制」）。
- 不做流式输出（目标文本通常较短，非流式更稳）。
- 不自建后端 / 账号体系 / 多用户。
- 不上架 Mac App Store。
- 不做 Windows / Web / 移动端。
- 不做翻译器（多语言混排时只修目标语言片段，不翻译其余语言）。

## 3. 技术栈

| 维度 | 选型 | 决策依据 |
|---|---|---|
| 平台 | macOS 13+ | PopClip 仅 macOS；Service action 依赖 macOS Services |
| 语言/UI | Swift + SwiftUI（AppKit 补 `NSPanel` 浮窗、Service provider、窗口定位） | 原生体验、零冷启动、Keychain 直连 → [ADR-0001](../decisions/0001-native-menubar-app.md) |
| App 形态 | 菜单栏常驻（`LSUIElement`，无 Dock 图标） | 常驻避免每次冷启动延迟 |
| 触发 | PopClip **Service action** → macOS Service → App | 无 URL 长度/编码坑、无临时文件、无 shell 警告 → [ADR-0002](../decisions/0002-popclip-service-action.md) |
| AI 接入 | OpenAI 兼容 **Chat Completions** API，结构化输出分层降级 | 中转/自建端点普遍兼容 Chat Completions，未必支持 Responses API → [ADR-0003](../decisions/0003-openai-compatible-chat-completions.md) |
| 密钥 | macOS Keychain | 红线，见 constitution |
| 分发 | Developer ID 签名 +（可选）notarization | 自分发更顺，无需上架 |

## 4. 关键不变式

1. **最小改动**：`corrected` 应是对 `original` 的最小改动版。护栏**不阻断展示**而是约束+提示：改动比例超阈值 → 更严格重试一次；仍超 → 展示两轮中改动较小的一版并显式提示「改动较大，请核对」。详见 [ADR-0004](../decisions/0004-minimal-edit-guard.md)。
2. **密钥隔离**：API key 只存 Keychain，绝不进 UserDefaults / plist / 日志 / PopClip 配置。
3. **内容不落盘**：默认不记录原文与修正文到任何日志或历史。
4. **原选区不可变**：V1 不修改用户原选中文本，只提供复制。

## 5. 模块清单

| 模块 | 职责 | 文档 |
|---|---|---|
| PopClipBridge / Service | 注册并接收 macOS Service 输入，唤起 review 流程 | [architecture/modules/popclip-service.md](../architecture/modules/popclip-service.md) |
| ReviewEngine + AIClient | 调 AI、结构化输出降级、schema 校验、过度改写护栏与重试 | [architecture/modules/ai-client.md](../architecture/modules/ai-client.md) |
| ReviewWindow | 浮窗 UI：修正全文 / 词级 diff / 错误清单 / 复制与二次操作 | [architecture/modules/review-window.md](../architecture/modules/review-window.md) |
| SettingsStore | 端点 / 模型 / 阈值 / 偏好（UserDefaults） | 见 [architecture/tech-stack.md](../architecture/tech-stack.md) |
| KeychainStore | API key 读写 | 见 [overview/constitution.md](./constitution.md) |
| DiffEngine | 原文/修正文词级 diff 计算 | 见 [architecture/modules/review-window.md](../architecture/modules/review-window.md) |

## 6. 目标与验收

> 把「依赖所接 AI 模型效果」的指标与「确定性的功能验收」分开：前者是努力目标、用于调参，**不作为发布硬门槛**；后者用 mock 可自动化、与模型质量无关，才是发布验收标准。

### 6.1 设计目标（非验收，依赖所接模型）

- **最小改动质量**：在评测集（真实写作样例）上，人工判定「仅修正必要错误、未过度改写」尽量高（目标 ≥ 90%）。用途：调 prompt 与护栏阈值。
- **解释有用性**：中文解释能让用户理解错因（目标 ≥ 90%）。
- **AI 往返延迟**：P50 < 2.5s（取决于所配端点/模型）。

### 6.2 功能验收（确定性，发布硬标准）

- **触发→出窗 < 300ms**（常驻态；冷拉起豁免）。
- **配置链路**：base URL / key / model 配置与 Keychain 存取正确；缺配置时拦截并引导设置。
- **结构化输出降级**：`json_schema → json_object → text` 三级在三类 mock 端点上均产出可渲染结果。
- **最小改动护栏**：在构造的 mock AI 返回下，按规则正确触发 strict 重试 / overEdited banner / 短句豁免 / 以本地输入为基准。
- **diff 与复制**：词级 diff 计算正确；「复制修正结果」内容等于 `corrected`。
- **隐私**：API key 不入明文存储；日志不含原文/修正文。

> 这些验收项均不依赖「AI 改得好不好」，只验证 App 的确定性行为，对应 spec 各 Requirement 的「覆盖测试」。

## 7. 关联文档

- 宪法（红线）：[constitution.md](./constitution.md)
- 架构总览：[../architecture/README.md](../architecture/README.md)
- 技术选型详情：[../architecture/tech-stack.md](../architecture/tech-stack.md)
- Living spec：[../specs/grammar-review/spec.md](../specs/grammar-review/spec.md)
- 决策记录：[../decisions/README.md](../decisions/README.md)
