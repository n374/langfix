<!-- doc-init template version: v1.0 -->
# ADR-0004: 最小改动护栏（diff 比例阈值 + 重试）

- **状态**: Accepted
- **日期**: 2026-06-29
- **Owner（决策者）**: n374
- **Reviewers**: n374
- **关联 change**: —
- **影响 capability**: grammar-review

## 1. 上下文

产品核心价值是「在用户原表达上做**最小改动**」。最大失败模式是 AI **过度润色/整段重写**，改变原意与语气——这正是用户对通用润色工具不敢用的原因。仅靠 prompt 口头约束「最小改动」不可靠，模型仍可能放飞。

「应用侧 diff 比例护栏 + 重试」把「最小改动」从软约束变成可执行护栏，是守住核心价值的关键，故升级为项目红线（[constitution Constraint-3](../overview/constitution.md)）。

## 2. 决策

在 ReviewEngine 加一道**应用侧护栏**：
0. **diff 基准**：始终以**本地真实输入**（normalizedInput）作为 `original` 基准计算 `editRatio`，**不信任** AI 回显的 `original`（见 data-flow §3 校验）。
1. **短句豁免**：当 `origWords < minWordsForGuard`（默认 6）**或** `editedWords <= minAbsEdits`（默认 2）时，**跳过比例护栏**——短消息里一个必要替换的比例天然很高，按比例拦截会无意义误伤。
2. 计算词级编辑比例 `editRatio`；`editRatio > diffThreshold`（默认 0.35，可配）→ 用**更严格** prompt 重试一次（强调「只改必要错误、逐词保留」）。
3. 重试后仍超阈值 → **展示两轮中 `editRatio` 较小的一版**，置 `overEdited=true`，UI 顶部 banner「改动较大，请核对」。**护栏不阻断出结果**（始终给用户一版，见红线 Constraint-3）。

护栏**不可默认关闭**（红线）。阈值与豁免参数（`diffThreshold/minWordsForGuard/minAbsEdits`）按评测集（NFR-3）调参。

## 3. 理由

- 把「最小改动」变成可度量、可拦截、可提示的工程闸，不依赖模型自觉。
- 重试给模型一次「收敛」机会；仍不收敛则显式提示用户，而非悄悄给出过度改写。
- 阈值可配，便于按评测集（NFR-3）调参。

## 4. 后果

- **正面**: 直接守住核心价值；过度改写可见可控。
- **负面**: 偶发多一次 AI 往返（仅在首轮超阈值时）；阈值需调参。
- **中立**: `editRatio` 依赖 DiffEngine 的词级 diff，与 UI diff 复用同一实现。

## 5. 备选方案

| 方案 | 优点 | 缺点 | 为什么不选 |
|---|---|---|---|
| 仅 prompt 约束最小改动 | 简单 | 不可靠，模型仍会过度改写 | 守不住核心价值 |
| 让用户在 UI 里自己判断改多了 | 零实现 | 把负担丢给用户、违背「可信」原则 | 体验与价值都差 |
| 句子级（非词级）比例 | 实现略简 | 粒度粗，短消息不敏感 | 词级更贴合短文本 |

## 6. 实施

- DiffEngine 提供 `editRatio`；ReviewEngine 实现重试与 `overEdited` 置位（[ai-client.md §5](../architecture/modules/ai-client.md)）。
- 验收：spec R3 两个 Scenario（拦截重试 / 重试后仍过度）。

## 7. 修订历史

| 日期 | 状态变更 | 摘要 |
|---|---|---|
| 2026-06-29 | → Accepted | 确立护栏；升级为红线 Constraint-3 |
