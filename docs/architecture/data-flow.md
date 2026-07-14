<!-- doc-init template version: v1.0 -->
# 数据流 / Data Flow

> **Owner**: n374
> 触发 → AI → 渲染的端到端时序、输入输出 Schema、护栏与错误路径。

## 1. 端到端时序

```mermaid
sequenceDiagram
  participant U as 用户
  participant PC as PopClip
  participant SVC as macOS Service
  participant RE as ReviewEngine
  participant AC as AIClient
  participant EP as AI 端点
  participant RW as ReviewWindow

  U->>PC: 选中文本 + 点击 LangFix 按钮
  PC->>SVC: 发送选中纯文本（NSPasteboard）
  SVC->>RE: 唤起 review(text)
  RE->>RW: 立即弹窗，显示 loading（可取消）
  RE->>AC: review(text, settings)
  AC->>EP: POST /chat/completions（结构化输出）
  EP-->>AC: JSON 结果
  AC->>AC: schema 校验 +（如失败）一次修复重试
  AC->>RE: ReviewResult（已校验）
  RE->>RE: 过度改写护栏：diff 比例 > 阈值?
  alt 超阈值
    RE->>AC: 更严格 prompt 重试一次
    AC->>EP: POST（stricter）
    EP-->>AC: JSON
    AC->>RE: ReviewResult'
  end
  RE->>RW: 渲染 corrected + 词级 diff + issues
  U->>RW: 复制修正结果 / 二次操作 / Esc 关闭
```

## 1.1 流式增量渲染时序（streamingEnabled=true 且端点支持流式）

把「等完整结果再渲染」（`loading → result`）升级为「预览→定稿」（`loading → streaming → result`）。
「流式仅在非护栏路径生效」的语义从**事前判定**重构为**事后定稿**：firstPass 走流式预览，
护栏复核（含 strict 重试）始终在**完整 corrected** 上跑、仍是唯一真相。详见
[changes/streaming-incremental-render/design.md](../changes/streaming-incremental-render/design.md)。

```mermaid
sequenceDiagram
  participant CO as AppCoordinator(@MainActor)
  participant RE as ReviewEngine
  participant AC as AIClient
  participant EP as AI 端点
  participant RW as ReviewWindow

  CO->>RW: phase = .loading
  CO->>RE: reviewStreaming(text, cfg, onPreview)
  RE->>AC: reviewStreaming(.firstPass, onPreview)
  AC->>EP: POST /chat/completions (stream:true, tier)
  EP-->>AC: SSE data: delta.content（逐帧）
  AC->>AC: PartialReviewParser.feed → corrected 稳定前缀（预览专用）
  AC-->>CO: onPreview(corrected, .receiving)   // @MainActor 顺序、带 generation 屏障
  CO->>RW: phase = .streaming(preview)          // 「校对预览中」、无 diff、复制禁用、可取消
  EP-->>AC: data: [DONE]
  AC->>AC: parseAndValidate(完整 content)        // 唯一真相、基准一致性
  AC-->>RE: firstPass ReviewResult
  RE->>RE: editStats 护栏（ADR-0004 不变）
  alt 未触发护栏
    RE-->>CO: 返回 result
  else 触发护栏（firstPass 超阈值）
    RE-->>CO: onPreview(.finalizing)             // 冻结预览第一版
    RE->>AC: review(.strict)                     // 既有非流式，复用
    AC-->>RE: strict result（或 throw → D6 兜底 firstPass+overEdited）
    RE-->>CO: 返回定稿 result
  end
  CO->>RW: phase = .result(最终结果 + 词级 diff)  // 去预览标记、终态才出 diff
```

**关键约束**：
- **PartialReviewParser 仅供预览**，有 bug 最多让预览不理想；最终输出永远由 `parseAndValidate` 决定（§3）。
- **是否流式只看两点**：流式开关 AND 端点支持流式。结构化 tier 降级、strict 重试、repair、截断重发**都不是回退理由**，统一走「预览→定稿」收敛。
- **流式能力缓存独立于结构化 tier 缓存**（正交）；端点不支持流式 → 静默回退非流式（见 §5）。
- **词级 diff 仍仅在完整 corrected 定稿时渲染**，流式期间无 diff（红线 Constraint-3 未被破坏）。

## 2. 输入

- **来源**：PopClip Service action 发送的**纯文本**（`public.utf8-plain-text`）。
- **预处理**：trim 首尾空白；保留内部换行；空文本或超长（> `maxChars`，默认 4000）直接拒绝并提示（见 spec R8）。

## 3. AI 输出 Schema（ReviewResult）

> AIClient 内部把 AI 返回的 JSON 解析并校验为下列结构后才交给上层。字段稳定是 UI 可靠渲染的前提。

```jsonc
{
  "has_issues": true,                  // 是否存在需修改项
  "original": "...",                   // 回显（用于 diff 与校验）
  "corrected": "最小改动修正版",         // 主结果
  "translation_zh": "corrected 的简体中文直译",  // round4：帮助中文母语用户核对修正后含义；可缺省（缺则空串）
  "summary_zh": "一句话总评（中文）",
  "issues": [
    {
      "category": "grammar|spelling|word_choice|naturalness|tone|punctuation",
      "severity": "error|improvement|optional",
      "before": "原文片段（须为 original 的精确子串，供 diff 定位）",
      "after": "修正片段",
      "reason_zh": "中文解释：哪里错 / 为什么错 / 怎么改更自然"
    }
  ],
  "alternative": "可选：更地道的整体改写（明确标注为「非最小改动版」，可为空）",
  "alternative_reason_zh": "可选：一句中文说明「为什么更地道/改动点」（round6，仅当给了 alternative 时；UI 另用 input→alternative 词级 diff 高亮改动点）"
}
```

**校验规则（客户端）**：
1. `corrected` / `original` / `has_issues` 必填且类型正确。
2. **基准一致性**：AI 回显的 `original` 必须等于本地真实输入（trim 后逐字符比较）。**不一致**说明模型擅自改写了输入——此时**以本地输入为准覆盖** `result.original`，diff 与最小改动护栏一律基于本地输入计算，绝不基于模型回显（否则 diff/护栏会被模型「洗白」）。
3. `has_issues=false` 时 `corrected` 必须等于本地输入（已无需改动），`issues` 可为空。
4. 每个 `issue.before` 应为本地输入的子串（用于 diff 高亮锚定）；不满足时降级为「整体 diff」而非逐条锚定（不阻断展示）。
5. **截断/拒答**：若响应 `finish_reason == "length"`（被 max_tokens 截断）或返回非法/不完整 JSON 或 refusal → 进「修复/重试」（见下）。
6. 校验失败 → 一次「修复重试」（把校验错误回传给模型要求修正；截断则提高 max_tokens 重发一次）；再失败 → 退化为「纯文本展示（以本地输入为 corrected）+ 错误提示」。

> **流式预览的解析（preview-only）**：流式期间由 `PartialReviewParser`（schema-aware 容错增量扫描器）从累积 SSE 文本逐字提取 `corrected` 稳定前缀 + 已闭合的结构化字段，仅用于 `.streaming` 态预览渲染（`StreamingPreview` 值，独立于 `ReviewResult`）。**它永不参与正确性**：流结束后完整 content 仍走上述同一套 `parseAndValidate` 作唯一真相。本仓库 `.text` tier 仍是 JSON（只是不加 `response_format`），故**所有 tier 的预览都走 JSON 字段扫描器**，「累积原始文本直接当 corrected」仅在最终 `parseAndValidate` 彻底失败时兜底。

## 4. 过度改写护栏（最小改动闸）

详见 [ADR-0004](../decisions/0004-minimal-edit-guard.md)。

- **基准**：以本地真实输入为 `original`（见 §3 规则 2），词级编辑比例 `ratio = editedWords / max(origWords, 1)`。
- **短句豁免**：`origWords < 6` 或 `editedWords <= 2` 时跳过比例护栏（短消息一个必要替换比例天然高，按比例拦截会误伤）。
- `ratio > threshold`（默认 0.35，可配）→ 用更严格 prompt 重试**一次**（强调「只改必要错误，逐词保留」）。
- 重试后仍 `> threshold` → **展示两轮中 `ratio` 较小的一版**，窗口顶部加 banner：「⚠️ AI 改动较大，请逐条核对」。护栏**不阻断出结果**。
- 该护栏不可默认关闭（红线 Constraint-3）。

## 5. 错误与边界路径

| 情况 | 行为（对应 spec） |
|---|---|
| 空文本 / 超长 | 弹窗提示拒绝，不发请求（R8） |
| 网络失败 / 超时 | 显示错误 + 「重试」按钮；不崩溃（R7） |
| 鉴权失败 401/403 | 提示「检查 API key / 端点」并给设置入口（R7） |
| 限流 429 | 提示稍后重试，可附 backoff（R7） |
| 端点不支持 `json_schema` | AIClient 自动降级 `json_object` → 纯文本解析（R6） |
| 端点不支持流式（200 非 SSE / 400-stream / 半截断流） | **静默回退非流式**完整渲染，不弹错；协议级不支持缓存 unsupported，瞬时断流不缓存（最多本次回退） |
| 流式截断 `finish_reason=length` | 切 `.finalizing` 冻结预览、后台非流式 bump 定稿，**不擦预览、不标流式不支持** |
| 流式 strict 重试请求自身 throw（D6） | 定稿 firstPass + `overEdited`（与「护栏不阻断出结果」同向；统一应用于 `review` 与 `reviewStreaming`） |
| 模型返回非法 JSON | 修复重试一次 → 仍失败则纯文本展示（R6） |
| `finish_reason=length`（被截断）| 提高 max_tokens 重发一次 → 仍截断则纯文本展示并提示（R6） |
| refusal / 非 schema 文本 | 视为校验失败走修复重试 → 仍失败则纯文本展示（R6） |
| AI 回显 original ≠ 本地输入 | 以本地输入覆盖基准，diff/护栏均基于本地输入（§3 规则 2） |
| 原文已正确 | `has_issues=false`，标注「无明显错误」，可给可选优化（R11） |
| 多语言混排 | 只修目标语言，不翻译其余语言（R12） |

## 6. 关联资源

- 模块细节：[modules/ai-client.md](./modules/ai-client.md)、[modules/review-window.md](./modules/review-window.md)
- 需求与覆盖测试：[../specs/grammar-review/spec.md](../specs/grammar-review/spec.md)
