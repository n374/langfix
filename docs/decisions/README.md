<!-- doc-init template version: v1.0 -->
# 决策记录 / ADRs

> 架构与选型决策。编号 4 位、从 0001 起，**不跳号、不复用**。新增 ADR 先在下表抢占编号。

## 编号索引（编号锁定表）

| 编号 | 标题 | 状态 | 日期 |
|---|---|---|---|
| [0001](./0001-native-menubar-app.md) | 采用原生 SwiftUI 菜单栏 App | Accepted | 2026-06-29 |
| [0002](./0002-popclip-service-action.md) | PopClip 用 Service action 触发 | Accepted | 2026-06-29 |
| [0003](./0003-openai-compatible-chat-completions.md) | AI 接入走 OpenAI 兼容 Chat Completions + 结构化输出降级 | Accepted | 2026-06-29 |
| [0004](./0004-minimal-edit-guard.md) | 最小改动护栏（diff 比例阈值 + 重试） | Accepted | 2026-06-29 |
| [0005](./0005-v1-scope.md) | V1 范围：非流式、不自动替换选区 | Accepted | 2026-06-29 |

每个 ADR 就技术权衡本身陈述决策与备选方案。新增决策时在上表抢占下一个编号，写 `decisions/NNNN-<topic>.md`。
