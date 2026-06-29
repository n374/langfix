<!-- doc-init template version: v1.0 -->
# ADR-0003: AI 接入走 OpenAI 兼容 Chat Completions + 结构化输出降级

- **状态**: Accepted
- **日期**: 2026-06-29
- **Owner（决策者）**: n374
- **Reviewers**: n374
- **关联 change**: —
- **影响 capability**: grammar-review

## 1. 上下文

本项目接入的是**自建/中转的 OpenAI 兼容端点**。这类端点的现实是：
- 绝大多数兼容 **Chat Completions**（`/chat/completions`）。
- 不一定支持 OpenAI 专有的 **Responses API**。
- 对 `response_format: json_schema`（Structured Outputs，strict）支持参差：有的全支持、有的只支持 `json_object`（JSON mode）、有的两者都不支持。

一个容易踩的坑：直接用 OpenAI 专有的 Responses API + Structured Outputs。但在「OpenAI 兼容端点」约束下，硬绑 Responses API 会在中转端点上直接失败，因此必须面向兼容性更广的 Chat Completions 设计。

## 2. 决策

AI 层面向 **OpenAI 兼容 Chat Completions** 抽象，`baseURL / apiKey / model` 全部可配；结构化输出采用**分层降级**：
`json_schema(strict)` → `json_object` → 纯文本解析，**每层都做客户端 schema 校验**（见 [data-flow.md §3](../architecture/data-flow.md)、[ai-client.md §3](../architecture/modules/ai-client.md)）。

## 3. 理由

- Chat Completions 是 OpenAI 兼容生态的「最大公约数」，能覆盖用户的中转端点。
- 分层降级让「能力强的端点拿稳定结构、能力弱的端点也能用」，把厂商/端点差异收敛在 AIClient 内部，上层无感。
- 客户端始终校验，保证 UI 拿到的结构可靠（不被某端点的「半结构化」糊弄）。

## 4. 后果

- **正面**: 端点可移植；换中转/换模型只改配置。
- **负面**: 需实现并维护三级降级 + 探测缓存，复杂度高于「只调一种 API」。
- **中立**: 不使用 Responses API 的 server 端状态/工具编排（V1 用不到）。

## 5. 备选方案

| 方案 | 优点 | 缺点 | 为什么不选 |
|---|---|---|---|
| OpenAI Responses API + Structured Outputs | 官方新接口、能力最全 | 中转/自建端点不保证支持 | 与「OpenAI 兼容端点」约束冲突 |
| 只用 `json_object`（不试 json_schema） | 实现简单 | 放弃 strict 结构、对强端点欠优 | 降级链顺手包含它，无需牺牲强端点 |
| 纯 prompt 要 JSON（不用 response_format） | 端点要求最低 | 结构最不稳 | 仅作最末级回退 |

## 6. 实施

- AIClient 实现 §3 分层 + §4 校验/修复重试（[ai-client.md](../architecture/modules/ai-client.md)）。
- 验收：spec R6（降级）、R2（结构化展示）、NFR-4（三类端点兼容）。

## 7. 修订历史

| 日期 | 状态变更 | 摘要 |
|---|---|---|
| 2026-06-29 | → Accepted | 面向 OpenAI 兼容端点，定为 Chat Completions + 结构化输出降级 |
