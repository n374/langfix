<!-- doc-init template version: v1.0 -->
# Module: ReviewWindow + DiffEngine

> **Owner**: n374
> 职责：把 `ReviewResult` 渲染成一个轻量、可信、可核对的浮窗；提供复制与二次操作。不持有/不修改用户原选区。

## 1. 窗体

- `NSPanel`（floating level，`.nonactivatingPanel` 可选），出现在**鼠标附近或屏幕中心**，非全屏。
- 出现即可见（loading 态先行），AI 返回后填充内容。
- 关闭：`Esc` / 点击窗外 / 关闭按钮。
- 性能目标：触发到出窗 < 300ms（NFR-1），不等待 AI。

## 2. 布局（从上到下）

```
┌────────────────────────────────────────────┐
│ [状态条] ✓ 无明显错误 / 发现 N 处可改进        │  ← overEdited 时此处变 ⚠️ banner
├────────────────────────────────────────────┤
│ 修正结果（corrected 全文）        [复制] 按钮   │  ← 主结果，最显眼
├────────────────────────────────────────────┤
│ 词级 diff：  the ~~quick~~ **fast** brown … │  ← 删除红色删除线 / 新增绿色高亮
├────────────────────────────────────────────┤
│ 错误清单（issues）                            │
│  ┌──────────────────────────────────────┐  │
│  │ [语法·error] "have went" → "have gone" │  │
│  │ 中文解释：go 的过去分词是 gone，不是 went │  │
│  └──────────────────────────────────────┘  │
│  ┌──────────────────────────────────────┐  │
│  │ [用词·improvement] "very big" → "huge" │  │
│  │ 中文解释：口语里 huge 更自然简洁           │  │
│  └──────────────────────────────────────┘  │
├────────────────────────────────────────────┤
│ ▸ 更地道的整体说法（可选，折叠，非最小改动）     │  ← alternative，默认折叠
├────────────────────────────────────────────┤
│ [复制修正结果] [复制解释] [重新检查]            │
│ 语气：(保持) (更自然) (更正式)  ← 二次 refine   │
└────────────────────────────────────────────┘
```

## 3. 错误条目（issue card）

每条：
- **类型徽章**：语法 / 拼写 / 用词 / 地道度 / 语气 / 标点（对应 `category`）。
- **严重度**：error（红）/ improvement（黄）/ optional（灰）。
- **before → after**：原片段 → 修正片段。
- **中文解释**：`reason_zh`，说清哪错、为何错、怎么改。

## 4. DiffEngine（词级 diff）

- 输入：`original`、`corrected`。
- 算法：按词/标点 tokenize → LCS / `CollectionDifference` 求最短编辑序列。
- 输出：渲染片段序列 `[.same(s) | .delete(s) | .insert(s)]`，UI 据此着色（删除红删除线、新增绿高亮、替换并列）。
- 同时供 ReviewEngine 计算 `editRatio = (删除词 + 新增词) / max(原词数, 1)`，喂给最小改动护栏（[ADR-0004](../../decisions/0004-minimal-edit-guard.md)）。

## 5. 交互

| 操作 | 行为 | spec |
|---|---|---|
| 复制修正结果 | `corrected` → 剪贴板 | R4 |
| 复制解释 | issues 的中文解释汇总 → 剪贴板 | — |
| 重新检查 | 重发当前文本 | — |
| 语气 切换 | 以 `keep/casual/formal` 临时重跑（二次 refine，不改默认） | — |
| Esc / 点窗外 | 关闭 | — |
| loading 中取消 | 中止请求、关窗 | R5 |
| streaming 中取消 | 中止流式请求、关窗（语义同 loading） | R5 / 流式态可取消 |

> **不提供**「替换原选区」（V1 红线 Constraint-4）。
> 「复制解释 / 重新检查 / 语气切换」为便利项，**不纳入 V1 强制验收**（见 [spec §2.1](../../specs/grammar-review/spec.md)）；V1 验收只要求「复制修正结果」可靠。

## 6. 状态

对应 `ReviewState.Phase`：`loading / streaming(StreamingPreview) / result(ReviewResult) / error`。

| 状态 | 展示 |
|---|---|
| loading | 进度指示 + 可取消（R5） |
| streaming（校对预览中） | 「校对预览中…/定稿中…」徽标 + corrected 逐字预览（打字机）+ 已闭合 issue 卡片；**无词级 diff、复制禁用、可取消**。`StreamingPreview` 为预览专用值（独立于 `ReviewResult`），由 `PartialReviewParser` 增量产出，**永不参与正确性**（见 [ai-client.md §3.5](./ai-client.md)）。preview 回调 `@MainActor` 顺序 `await`，带 generation/取消屏障 + 单调前缀守卫，杜绝旧任务污染/取消后更新已关窗 |
| 成功·有问题 | 完整布局（去预览标记、终态才出词级 diff） |
| 成功·无问题 | 状态条「✓ 无明显错误」，corrected==original，可显示一条 optional（R11） |
| overEdited | 顶部 ⚠️ banner「AI 改动较大，请核对」 |
| 错误 | 错误文案 + 重试/设置入口（R7） |

> **预览→定稿**：流式期间为 `.streaming` 预览（无 diff），护栏复核（含 strict 重试）完成后切 `.result`，去「校对预览中」标记并渲染完整 corrected + 词级 diff + issues。strict 覆盖预览第一版被呈现为「预览→定稿」收敛，而非错误闪烁。

## 7. 覆盖测试（待落地）

- diff 计算正确性：`DiffEngineTests.swift::{testSingleWordReplacement, testInsertionAndDeletionCounted, testIdenticalHasNoEdits, testTokenizePreservesWordsAndSeparators}`
- 复制修正结果写剪贴板：`TBD(ui: 点击复制 → 断言 NSPasteboard.string == corrected)`
- 无问题态展示：`TBD(ui: has_issues=false → 断言显示「无明显错误」且不展示删改高亮)`

## 8. 关联

- Schema：[../data-flow.md §3](../data-flow.md)
- 护栏：[ADR-0004](../../decisions/0004-minimal-edit-guard.md)
- 需求：[spec R2/R4/R5/R10/R11](../../specs/grammar-review/spec.md)
