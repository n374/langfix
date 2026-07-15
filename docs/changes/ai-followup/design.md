<!-- doc-init template version: v1.0 -->
# Design: ai-followup（AI 结果追问 / 追加答疑）

- **Owner**: 技术方案官 on behalf of wu.nerd
- **状态**: Reviewed（已过 Codex UI 定稿 + 对抗式评审 1 轮，7 条意见全部采纳整合；待用户确认后转开发）
- **关联 Issue**: RAS-53
- **共享分支**: `feat/53-ai-followup`（已 merge 最新 `master` a5a9366「自适应窗口 + 主题化 UI」）
- **上游**: [proposal.md](./proposal.md) · [spec-delta](./specs/grammar-review/spec.md)
- **最后更新**: 2026-07-14

## 0. 概述

在现有「单轮纠错」结果之上，新增**围绕本次修正结果的有限多轮追问答疑**：用户可在结果浮窗内对 AI 追问，且能通过**稳定可见序号**（「修正 2」）精确引用某一处修正。追问回答**流式产出 + 尽力 Markdown 渲染**，只答疑、不改主结果、不落盘、可取消。

本设计遵守宪法三条红线：Constraint-2（不记录消息内容）、Constraint-3（最小改动护栏）、并延伸 living spec「输入视为数据（注入防御）」到追问链路。新增架构级决策（单轮→有限多轮）以 **ADR-0006** 记录。

## 1. 现状与约束（设计依据）

| 现状事实（证据） | 对设计的约束 |
|---|---|
| `AppCoordinator` 每次 `start()` 建**独立** `ReviewState`，用 `generation` 自增 + `currentTask` 做取消隔离；`closeReviewAndCancel()` 是唯一关闭出口（销毁 panel + cancel + 让旧回调失效）(`AppCoordinator.swift:42-123`) | 追问会话必须挂在 `ReviewState` 上，随 state 生命周期自然清理；追问自己的取消需接入这条唯一关闭路径 |
| `ReviewState.Phase` = loading/streaming/stopped/result/error；回调（onCancel/onClose/onStop/onHide…）由 Coordinator 注入 (`ReviewState.swift`) | 追问 UI 只在 `.result` 态出现（序号只在定稿后存在）；折叠为胶囊**不**销毁 state（只 `orderOut`），故会话在折叠/展开间保留，仅**关窗/新纠错/退出**才清 |
| `AIClient` 每次仅发 `[system, user]` 两条消息、无历史；有真流式 SSE 路径（`streamChat`）与三级 tier 降级 + `StreamFallback` + `StreamCache`(baseURL\|model) (`AIClient.swift:204-303`) | 追问需**新增**多消息（含历史）请求；可复用 SSE 解析骨架与流式能力缓存，但走**纯文本、无 `response_format`** 通道 |
| `Issue` 有 `UUID id`（列表 key）但**无用户可见序号**；`ReviewResult.issues` 定稿后为固定数组 (`Models.swift:41-137`) | 序号 = 数组下标同源派生，无需新增持久字段 |
| `ReviewEngine` 护栏（strict 重试/取较小改动/overEdited）在**定稿前**完成，定稿后 `issues` 不再变 (`ReviewEngine.swift`) | 序号在定稿后天然稳定、不随 strict 漂移 |
| UI 已主题化：`ReviewTheme`（4 套主题，默认 Aurora Glass）、`ThemedCard`/`ActionChip`/`ReviewActionBar` 可复用；`ResultView` 是 `result` 态渲染主体 (`ReviewTheme.swift` / `ReviewView.swift:347-483`) | 追问 UI 必须复用主题 token 与既有胶囊/卡片组件，视觉与当前主题一致 |
| 窗口尺寸由 `ReviewMeasurementView` 自然尺寸自适应；超上限走 overflow `ScrollView`；`state.objectWillChange → refreshMeasurement`(`AppCoordinator.swift:282-401`) | 追问区/流式增长自动撑高窗口、超限自动滚动，复用既有机制，无需新尺寸逻辑 |

## 2. 关键设计决策

### D1 · 修正序号：单一来源同源，仅定稿态渲染
- **序号来源 = `ReviewResult.numberedIssues`（单一解析入口）**。UI 显示（「修正 N」）与**发送给 AI 的追问上下文编号**都读这同一个计算属性 → **结构性同源**，从根上杜绝「显示序号≠上下文序号」漂移。
- **（开发阶段按用户 review #1 调整）序号由 LLM 输出、应用强校验兜底**：Prompt/schema 要求 LLM 为每条 issue 输出 `index`（满足用户「让 LLM 输出该格式」）；`numberedIssues` 校验——模型 `index` 构成严格 1..N 排列则**采用其编号并按其升序排列**，否则（缺省/跳号/重号/越界）**按数组位置重排 1..N 兜底**（正确性优先，绝不让「修正 N」指错条目）。两条路径都经此单一入口，同源不破。
- 仅 `.result` 态渲染可引用序号；`.streaming`/`.stopped` 预览态**不**渲染（现状 `StreamingPreviewView` 的 `IssueCard` 本就无序号，保持）。空 `issues` → 无序号。
- strict 覆盖发生在 `ReviewEngine` 定稿**之前**，定稿后 `issues` 固定 → 序号在结果窗口存续期不漂移。
- **满足 spec**：`修正稳定序号`（三 Scenario）、`展示结构化修正`(MODIFIED)。

### D2 · 会话状态归属 `ReviewState`，生命周期自然对齐
- 新增引用类型 `FollowUpSession`（`@MainActor final class`，`ObservableObject`），承载：
  - `boundResult: ReviewResult`（定稿结果，追问上下文来源）、`original: String`。
  - `configSnapshot: FollowUpConfigSnapshot` —— **只含非密钥字段**（`baseURL / model / temperature / streamingEnabled / followUpBudgetTokens`），**绝不含 apiKey**（评审#5：`AppConfig.apiKey` 会把密钥长期挂在窗口存续期的 UI 会话对象上，扩大驻留面）。API key 在**发请求瞬间**由 `KeychainStore.apiKey()` 现取现用（`SettingsStore.config()` 本就每次从 Keychain 取，`SettingsStore.swift:80-93`），组装完请求即释放，不驻留 session。这不是 Constraint-1 违规（内存瞬态 ≠ 持久化），而是最小暴露的主动收敛。
  - `turns: [FollowUpTurn]`（**已成功完成**的问答轮，`FollowUpTurn { id, question, answer, referencedIndices, ... }`）。
  - `streaming: StreamingAnswer?`（当前在途一轮的问题 + 增量答案 + 阶段）；取消/失败该轮**丢弃**、不入 `turns`（见 D3）。
- 挂在 `ReviewState`：`@Published var followUp: FollowUpSession?`，进入 `.result(result)` 时由 Coordinator 创建并注入（携带 `result` / `input` / config 快照）。
- **生命周期**：关窗（`closeReviewAndCancel → reviewController.close → state` 释放）即随 state 释放；新纠错 → 新 `ReviewState` → 旧 session 随旧 state 释放；折叠为胶囊只 `orderOut` 不销毁 state → 会话保留（合理预期）。
- **满足 spec**：`追问会话隐私与生命周期`（易失内存、多触发点即清）。

### D3 · 追问代次与取消隔离（正确性）——评审#3/#4 强化
- 追问**不复用**主 review 的 `currentTask`/`generation`（那属首轮纠错，`.result` 时已结束）。`FollowUpSession` 自持 `inFlightTask: Task<Void,Never>?`、`askGeneration: Int`、`isClosed: Bool`。
- 每次发问：`askGeneration += 1`，捕获 `myAsk`；delta/完成/错误回调**仅当** `askGeneration == myAsk && !isClosed && !Task.isCancelled` 才应用，否则丢弃。
- **统一幂等 `cancelInFlight(reason:)`**（评审#4：仅 cancel Task 不足以做屏障）**必须原子地**：① `askGeneration += 1`（前移代次，让在途回调 guard 立即失效）→ ② 清 `streaming`（丢弃半截回答，**不写 `turns`**）→ ③ `inFlightTask?.cancel()`。三步顺序固定，保证旧响应晚到时 guard 必失败。
- **两种"取消"语义严格区分（评审#3，对齐 spec）**：
  - **取消当前在途一轮**（追问区 `stop` 按钮）：`cancelInFlight(.userStop)` —— 中止该轮、**丢弃半截回答、该轮不入 `turns`**（spec `追问态可取消与隔离` Scenario「追问进行中取消」：不把该问题/回答写入历史）；**已成功完成的历史轮保留**。
  - **关窗 / 新纠错 / 退出**：`cancelInFlight(.sessionEnd)` + **清空整个会话历史**（`turns` 与 `streaming` 全清，spec `会话生命周期` 各清理触发点）。
- **Coordinator 接入（评审#4：`ReviewWindowController.state` 是 private，`closeReviewAndCancel` 当前够不到 `followUp`）**：`AppCoordinator` 新增 `private weak var currentState: ReviewState?`（在 `present(state:)` 里赋值），`closeReviewAndCancel()` 开头加 `currentState?.followUp?.cancelInFlight(.sessionEnd)`，再走既有销毁；`start()` 新触发同样先经 `closeReviewAndCancel()` → 覆盖"新纠错"路径。
- **旧响应晚到**：`askGeneration` 已前进 + `isClosed` 置位 → guard 失败 → 丢弃，不写 `turns`、不污染主结果。
- **满足 spec**：`追问态可取消与隔离`（三 Scenario）、`会话生命周期`。

### D4 · 追问 AI 层：纯文本流式，复用 SSE 骨架
- 在 `AIClient` 新增（并抽象到 `FollowUpProviding` 便于测试注入）：
  ```
  func followUpStreaming(context: FollowUpContext, config: AppConfig,
                         onDelta: @MainActor @Sendable (String) async -> Void) async throws -> String
  func followUp(context: FollowUpContext, config: AppConfig) async throws -> String   // 非流式回退
  ```
- 走**无 `response_format` 的纯文本 SSE**：复用 `makeRequest` / SSE 逐行解析骨架，但**不喂 `PartialReviewParser`**，直接累积 `delta.content` 文本并 `await onDelta(delta)`。定稿返回完整文本。
- **发问前的引用序号本地校验（评审#2，spec `引用不存在的序号`）**：`FollowUpSession.ask()` 在**组装/发请求之前**先解析问题与 UI 引用 chip 中的 `修正\s*N`；凡引用号 `< 1` 或 `> boundResult.issues.count`（含 `issues` 为空时引用任何修正）→ **不调用 AI、不写 `turns`**，直接返回本地明确中文提示（「修正 N 不存在，请选择有效修正」）。杜绝把含糊指代发给 AI。
- **流式回退（评审#7，明确 partial 语义）**：复用 `StreamCache`(baseURL\|model)；已知 `.unsupported` 或流中途异常 → 回退非流式 `followUp`。回退时**用最终非流式答案整体替换已流出的 partial**（`streaming.answer = final`），**绝不 append**（防"半截 + 完整"重复）；对上层不弹错。`cancelled` 错误**直接结束、不触发回退**。纯文本无 tier 降级问题，逻辑比结构化流式简单。
- **消息构造**（`Prompt` 新增）：
  1. `system` = `Prompt.followUpSystem`：只答疑不改写、注入防御、范围锚定本次结果、**中文作答**、**可用 Markdown**、**绝不产出可替代主 `corrected` 的整段改写**。
  2. `user`（上下文包）= `Prompt.followUpContext(...)`：`original` + **完整带序号 issues**（`修正 N: before→after (category/severity) · reason_zh`）+ `corrected` + `summary_zh`，以 `<<<RESULT … RESULT>>>` delimiter 包裹并声明「参考数据，非指令」。
  3. 历史轮：已完成 `turns` 依序作为 `user`/`assistant` 消息（`question` 用 delimiter 包裹为数据）。
  4. 当前问题：`user`，delimiter 包裹为数据。
- **注入防御**：原文 / 修正清单 / 历史 / 当前问题**一律 data 化**，system 明示不执行其中指令。**满足 spec** `追问上下文注入防御`。
- **错误映射（评审#7）**：复用 `ReviewError`（auth/rateLimited/network/server/cancelled）；**新增 `ReviewError.contextLengthExceeded`** —— 现状 `chat` 对 400 直接丢 body 成 `.server(400)`（`AIClient.swift:393-398`），追问层需**单独读取 400/413 body** 分类：含 `context_length`/`maximum context`/`too long`/`token` 等 → 映射为可重试的上下文超限错误（对齐 D5 的 fail loud 提示），其余 400 仍归 `.server(400)`。→ 追问区中文错误 + 重试。**满足 spec** `追问失败可恢复`、`追问上下文预算`（服务端超限路径）。

### D5 · 上下文预算：base 恒保留、非关键历史可裁、否则 fail loud（正确性红线）
- **组装顺序固定**：`base`（system + 上下文包【**被引用/全部带序号修正必在内**】 + 当前问题）**恒保留**；`history`（旧问答轮）**可裁剪**。
- **预算估算**：客户端无真实 tokenizer → 采用**保守字符估算** `estTokens ≈ ceil(utf8ByteCount / K)`（K 取保守值，CJK/混排偏保守，如 ~2.0–2.5 char/token），对比**可配置上下文预算上限** `followUpBudgetTokens`（默认保守常量，如 6000–8000，落地可调/后续可设置项）。
- **确定性规则**：
  - `base` 已超预算 → **fail loud**：明确中文错误「本次结果与问题过长，无法在上下文预算内追问，请缩短问题或重新纠错」，**绝不静默截断**致「修正 N」失去绑定；该轮**不写** `turns`，可重试（复用同一问题+同一结果绑定）。
  - `base` 在预算内 → 从**最旧** `history` 轮起逐轮丢弃，直至 `base + 保留history` 放得下。被丢弃历史仅影响连续性，**不影响被引用修正绑定**（base 恒含完整带序号 issues）。
- 服务端侧 `context_length_exceeded`（常见 400/413）→ 归一为可重试错误提示，复用错误路径。
- **满足 spec**：`追问上下文预算`（两 Scenario）。⚠️ **假设**：K 与 `followUpBudgetTokens` 为保守启发值，非精确 tokenizer；红线是「不静默错位」，估算偏保守只会更早 fail loud，不会造成静默截断。落地需在测试里固化「构造超预算 → 被引用修正保留或明确报错」。

### D6 · 护栏红线（Constraint-3）：结构不可变 + prompt + **应用层输出护栏**（评审#1 三保险）
- **① 结构不可变（硬保证）**：追问回答是 `FollowUpTurn.answer` 文本，**永不写回** `result.corrected`/`issues`（`ResultView` 的 `result` 是 `let`），主结果区一字不动；且**不提供**把回答"提升为主结果 / 一键替换 corrected / 复制为结果"的任何 UI 入口。
- **② prompt 约束（软引导）**：`followUpSystem` 明确「只解释不改写，不得给出可替代主结果的整段 corrected / 整段重写文」。
- **③ 应用层输出护栏（评审#1：spec 要求"回答中不得给出可替代主结果的新整段 corrected"是可测正确性，仅①②不够）**：对 AI 回答做**确定性检测**——若回答包含与 `result.corrected` 高度相似的**整段替代全文**（判据示例：单个代码块/引用块内出现与 `corrected` 词级相似度 ≥ 阈值 或 与 `corrected` 长度相当且高覆盖的连续段落），判为"越界改写"→ **不把该整段当作可采纳结果呈现**：以约束说明替换/截断该段并标注「追问只答疑，不提供替代全文；如需重纠错请重新选词」，该轮按越界处理（**可选**：整轮 fail loud 不入 `turns`，或保留答疑部分、剔除越界全文段）。判据阈值为落地可调启发值。
- 追问**不触发** diff / strict / 护栏重算（V1 纯答疑，Out of Scope 已锁）。
- **满足 spec** `结果追问（答疑）` 的「改写型追问被约束」；**测试必须覆盖"模型实际吐了整段替代全文"路径**（断言主结果不变 + 越界全文未作为可采纳结果呈现 + 未生成替代 corrected）。
- ⚠️ **假设/边界**：语义级"是否整段改写"无法 100% 精确判定；红线是**主结果绝不被替代（①硬保证已达成）**+ 越界全文**不被当作可采纳结果**（③尽力拦截）。若用户/评审认为需更强语义判定，属后续演进，需明确取舍。

### D7 · 隐私红线（Constraint-2）
- `FollowUpSession` 只在**易失内存**；追问相关原文/修正/问题/回答**不写** UserDefaults / plist / 文件 / 系统剪贴板 / crash / analytics。追问日志**仅** requestId / 耗时 / token 计数 / HTTP 状态码。
- 用户可手动选中复制回答（`textSelection(.enabled)`），但**不自动**写剪贴板。
- 设置页/隐私说明补一句「**追问内容同样经 HTTPS 发往你配置的端点**」（扩展 living spec NFR-5，承接 Constraint-2 数据流向声明）。**满足 spec** `追问会话隐私与生命周期`。

### D8 · Markdown 流式渲染（用户明确要求）
- 追问回答**流式**（打字机式增量 `onDelta`）+ **尽力 Markdown 渲染**。
- 取向（HOW 细节交 Codex/开发）：累积文本每帧 best-effort `AttributedString(markdown:options:)`（`interpretedSyntax` 视需取 inline 或块级）；**解析失败（半截 Markdown）→ 回退纯文本渲染当前帧，不报错、不闪**；定稿后做一次完整 Markdown 渲染。短答可整体重解析；必要时按已闭合块缓存以降开销。
- ⚠️ 风险：流式高频 delta × 每帧 Markdown 重解析可能有性能/闪动。缓解：帧节流（合并 delta，如 ~16–33ms 一次 UI 提交）；见 D9。

### D9 · 窗口尺寸自适应复用
- 追问区与流答增长通过既有 `state.objectWillChange → refreshMeasurement → applyResize` 自适应；超上限走既有 overflow `ScrollView`（`AppCoordinator.swift:391-473`）。
- ⚠️ 流式高频 delta → 高频 remeasure：已有 runloop 合并 + 0.5pt 阈值兜底；追问流答期**建议对 remeasure/`onDelta` 提交加节流**（合并到帧）以防抖动。
- 追问区在 `ScrollView` 内应**自动滚到底部**（新问答/流答可见）——用 `ScrollViewReader` + 末尾锚点 id。

### D10 · 新增 ADR-0006（架构级决策留痕）
- 引入「围绕结果的有限多轮答疑」使 LangFix 从**单轮 → 有限多轮**，属架构级决策 → 新开 **`docs/decisions/0006-bounded-followup.md`**：记录决策、边界（纯答疑/不改主结果/易失内存/范围锚定本次结果）、与 Constraint-2/3 关系、与 ADR-0005 关系（0005 裁剪的是流式/替换选区，**未**涉及多轮；本决策**不弱化任何红线**，属红线「只增不减」下的能力新增）。

## 3. 数据流（追问一轮）

```mermaid
sequenceDiagram
  participant U as 用户
  participant V as ResultView(追问区)
  participant S as FollowUpSession(@MainActor)
  participant C as AIClient.followUpStreaming
  participant EP as 用户配置端点(HTTPS)

  U->>V: 输入问题(可引用「修正 N」) + 回车
  V->>S: ask(question)
  S->>S: 校验引用序号(越界→本地报错,不调 AI,不写 turns)
  S->>S: askGeneration+=1; 组装 base+history(预算裁剪/fail loud)
  alt 引用越界 或 base 超预算
    S-->>V: 明确中文错误(该轮不入 turns, 可重试)
  else 预算内
    S->>C: [system, 上下文包(带序号,data), 历史轮, 当前问题(data)]
    C->>EP: POST /chat/completions (stream:true, 无 response_format)
    loop SSE delta
      EP-->>C: delta.content
      C-->>S: onDelta(delta)  (guard askGeneration==myAsk)
      S-->>V: 增量渲染(Markdown best-effort, 自动滚底)
    end
    C-->>S: 完整答案(应用层输出护栏 D6 检测越界改写)
    S->>S: 成功轮 {question,answer} 入 turns; 清 streaming
  end
  Note over S: 取消在途轮→丢弃半截不入 turns；关窗/新纠错→cancelInFlight(.sessionEnd)清全会话；旧响应晚到 guard 失败丢弃
```

## 4. 交互与视觉设计（Codex 主笔并已定稿，需与当前主题相搭、有艺术感）

> 用户明确：「UI 的部分让 Codex 去设计，要有艺术感一点，要和当前的主题比较搭」；且「在窗口最下方两个按钮之间加输入框」为**提议**，Codex 可给更佳方案。以下**约束边界**（WHAT）为技术方案官所定，**Codex 定稿的具体形态见下方 [UI-1]…[UI-7]**（已过对抗式评审，UI-6 取消语义已按 spec 修正）：

**硬约束（不可违反）**：
1. 追问区仅在 `.result` 态出现；复用 `ReviewTheme` token（`accent`/`cardFill`/`cardStroke`/`primaryText`/`secondaryText`/`material` 等）与既有 `ThemedCard`/`ActionChip`/`ReviewActionBar`，四套主题下都协调（默认 Aurora Glass）。
2. 每处修正展示稳定序号「修正 N」（D1），且提供**低摩擦引用**方式（如点击修正卡片把「修正 N」注入输入框 / 生成引用 chip），引用编号必须与 D1 同源。
3. 输入框位置遵循用户提议（底部操作栏「隐藏」与「关闭」之间）或 Codex 更优且经评审的替代；发送 = 回车，需有取消在途、错误+重试的可视入口。
4. 问答以对话气泡列表呈现（用户问 / AI 答分列），AI 答**流式打字机 + Markdown 渲染**（D8）；列表在 `ScrollView` 内自动滚底（D9）。
5. 空态（未追问）不喧宾夺主，不挤占主结果区视觉重心；「可信优于花哨」（宪法治理原则 3）。
6. Esc / 失焦折叠语义需与输入框聚焦协调（**交互风险**，Codex + 开发注意）：建议输入框聚焦且有草稿/流答在途时，Esc 优先失焦/清草稿而非直接折叠窗口；失焦折叠不取消在途流答（折叠不销毁 state，流可后台续，展开后可见）。

**Codex 定稿（艺术化、与主题相搭；已复用现有 token/组件）**：

> 定调：追问区是「玻璃下的一层蓝色注释层」，不是聊天软件；主结果永远是第一视觉层，追问是**结果附属层**。默认 Aurora Glass 定调，其余三套按 token 自适应。

- **[UI-1] 布局**：追问区插入 `ResultView` 的 `.result` 内容，位于 `alternativeBlock` 之后、底部 `Divider + footer` 之前。空态只在 footer 上方显示一条 1px `cardStroke.opacity(0.55)` 分隔线 + 28–32pt 淡标题行（`sparkles` + `AI 追问`，opacity 0.72），不做醒目 section header；有消息后展开为 `ThemedCard` 风格对话容器（`maxHeight: 220`，`ScrollViewReader + ScrollView` 自动滚底，气泡间距 8）。
- **[UI-2] 输入框（采用用户提议）**：置于 footer「隐藏」与「关闭」之间（footer 是定稿后唯一稳定操作区，不挤占正文可信阅读空间）。高 32pt（最多 76pt），单行优先，`Enter` 发送 / `Shift+Enter` 换行；圆角 **8**（与 `ActionChip` 一致，不用 18 以免变搜索框）；背景 `cardFill.opacity(0.58)`，聚焦描边 `accent.opacity(0.55)`；占位「追问本次修正，或输入"修正 2 …"」。右侧按钮随态切换：可发送 `paperplane.fill`(accent) / 流式在途 `stop.fill`(warning) / 错误后 `arrow.clockwise`(error) / 硬超限 disabled。
- **[UI-3] 「修正 N」序号 + 引用**：`IssueCard` 新增 `index` 参数，第一行最左显示 `修正 N` badge（高 20、圆角 5、fill `accent.opacity(0.16)`、stroke `accent.opacity(0.36)`、文本 `caption2.bold()`/accent），category badge 降为次级。单击卡片把「修正 N 」注入输入框并聚焦（已有草稿则追加为引用 chip，不覆盖）；hover 右上 `quote.bubble`；被引用卡片 0.6s 高亮（描边→`accent.opacity(0.75)` + glow 半径 10）；用户/AI 气泡顶部显示「修正 N」引用 chip，点击滚动到对应卡片并再次 pulse。序号与 D1 同源。
- **[UI-4] 气泡 + 流式 Markdown**：用户气泡右对齐(≤78%，fill `accent.opacity(0.16)`)、AI 气泡左对齐(≤88%，复用 `ThemedCard`，fill `cardFill.opacity(0.68)`)；全 `textSelection(.enabled)` + hover `doc.on.doc` 复制。Markdown 尽力 `AttributedString(markdown:)`、失败回退纯文本；标题降级 `.callout.bold()`（不出大标题）、行内代码 `.monospaced()` + 小底色、代码块 6px 圆角 + `cardStroke` 描边（避免大黑块破玻璃感）。流式：末条气泡尾部打字机光标（2×14pt、accent.opacity(0.9)、0.8s blink），增量只对新增尾部轻微 opacity 过渡，不整段 fade（防 Markdown 重排眩目）。
- **[UI-5] 艺术化点缀（克制）**：主色仅用 `accent` 低透明描边/引用 chip/光标；容器顶可加 1px 发光线 `glow.opacity(glowOpacity*0.7)`；动效只三类——IssueCard pulse、光标 blink、发送按钮状态 morph。主题自适应：Neon Noir 允许 glow 半径 12（opacity 仍用 `glowOpacity` 防过曝）、Solar Ink 引用 badge 更像金墨批注（fill 降 `accent.opacity(0.12)`）、Arctic Circuit 用系统 `.primary/.secondary`、阴影减半靠 stroke。
- **[UI-6] 边界态**：空态只留输入框 + 淡标题行（无「试试问我」大提示）；发送中用户气泡即入列、AI 气泡「正在回答…」+ 光标、发送按钮变取消；错误在末条 AI 气泡位显示 error tint 小卡（`回答中断` + 摘要 + `重试` chip，不弹全局错误页）；上下文超预算 → composer 上沿 24pt warning strip「本次结果过长，追问可用上下文不足」（软超限仍可发、硬超限 disabled + tooltip 原因，对应 D5）；引用不存在序号 → composer 上沿即时提示「修正 N 不存在」，不发请求（D4）。**取消在途一轮（修正评审#3 与 spec 对齐）**：中止请求并**丢弃该轮半截回答、不写入历史**（spec `追问进行中取消`）；**已成功完成的历史轮保留**；可短暂显示"已停止"过渡但不 commit 到 `turns`。（原 Codex UI 稿"保留半截 + 不删历史"与 spec「取消轮不写历史」冲突，此处以 spec 为准修正。）
- **[UI-7] 交互边界（Esc/失焦/关闭）**：① 输入框 IME 组合态 Esc 交文本系统；② 聚焦有草稿 Esc 仅失焦保留草稿（清草稿用框内 `xmark.circle.fill`，不用 Esc 隐式丢）；③ 聚焦空草稿 Esc 先失焦、再 Esc 才走既有 `.esc→collapsed`；④ AI 流式在途 Esc **不取消**回答只折叠（取消须点 `stop.fill`）；⑤ 失焦折叠仍生效但**持久保留草稿/消息/流式任务**，展开胶囊恢复滚动到底；⑥ 只有 `xmark`「关闭」是销毁语义（`cancelInFlight(.sessionEnd)` + 随 ReviewState 清理，接 D3）。
  - **实现桥接（评审#6：现状 `escMonitor` 无条件 `handle(.esc)` 并吞事件 `AppCoordinator.swift:423-429`；`ReviewWindowMode` Esc 恒折叠 `:93-94`；`windowDidResignKey` 延迟折叠 `:680-687`）**：必须把 **composer 焦点态 / 是否有草稿 / IME 组合态**暴露为**可查询状态**（挂在 `ReviewState` 或共享 observable）；`escMonitor` 在 `handle(.esc)` 前先查该状态，据此决定"透传给文本系统 / 仅失焦 / 折叠"，**不再无条件吞 Esc**。此为 escMonitor 与 SwiftUI 输入焦点的桥接改造点，开发阶段须落地并测试。

## 5. 影响面

| 文件 | 变更 | 说明 |
|---|---|---|
| `Models.swift` | ADD/MOD | `FollowUpTurn` / `StreamingAnswer` / `FollowUpContext` / `FollowUpConfigSnapshot`(无 key,评审#5) 值类型；`ReviewError` 增 `.contextLengthExceeded`(评审#7)；`Issue` **不**加序号字段（下标派生） |
| `FollowUpSession.swift` | NEW | `@MainActor` 会话状态机：turns/streaming/askGeneration/**isClosed**/inFlightTask + `ask()`（含引用序号本地校验,评审#2） / `cancelInFlight(reason:)`（原子推代次+清streaming+cancel,评审#4） |
| `ReviewState.swift` | MOD | `@Published var followUp: FollowUpSession?`；暴露 composer 焦点/草稿/IME 可查询态供 escMonitor 桥接（评审#6） |
| `AppCoordinator.swift` | MOD | `.result` 时创建注入 `FollowUpSession`；新增 `weak var currentState`；`closeReviewAndCancel()` 增 `currentState?.followUp?.cancelInFlight(.sessionEnd)`（评审#4）；escMonitor 查焦点态再决定透传/失焦/折叠（评审#6） |
| `AIClient.swift` | MOD | `followUpStreaming` / `followUp`（纯文本 SSE，复用骨架 + StreamCache）；发请求瞬取 Keychain key；读 400/413 body 映射 `.contextLengthExceeded`；流→非流回退**整体替换** partial 不 append（评审#7） |
| `Prompt.swift` | MOD | `followUpSystem`（含"不得吐替代全文"约束,评审#1） / `followUpContext(...)`（含序号、data 化、注入防御、Markdown 许可） |
| `ReviewView.swift` | MOD | `ResultView` 内嵌追问区（Codex 定稿 §4）；`IssueCard` 加 `index` 「修正 N」序号；应用层输出护栏渲染（D6/评审#1） |
| `SettingsView.swift` | MOD | 隐私说明（`SettingsView.swift:130` 现有文案）补「**追问内容同样**经 HTTPS 发往端点」 |
| `docs/decisions/0006-bounded-followup.md` | NEW | ADR-0006 |

## 6. 测试建议（对应 spec 覆盖测试 TBD，落地由开发/ MR 阶段补真实路径）

- **序号同源/稳定**：3 条 issues → 断言展示序号 1..N 与上下文编号同源；预览态无可引用序号；strict 覆盖前后序号不漂移；空 issues 无序号。
- **答疑不改主结果**：引用「修正 2」追问 → 断言上下文序号绑定正确 + `corrected`/`issues` 不变；改写型追问 → 断言主结果不变、未生成替代 corrected。
- **越界引用（评审#2）**：引用「修正 9」/ 空 issues 时引用「修正 1」→ 断言**不发起 AI 请求**、本地明确提示、不写 turns、主结果不变。
- **模型实际吐整段替代全文（评审#1）**：mock AI 回答里含与 `corrected` 高相似整段改写 → 断言主结果不变 + 该越界全文未作为可采纳结果呈现 + 未生成替代 corrected。
- **注入防御**：追问/原文含「忽略以上指令」→ 断言仅作数据、不越权、主结果不变。
- **取消语义分层（评审#3）**：① 在途取消一轮 → 断言请求中止、**该轮半截丢弃不入 turns、已完成历史轮保留**；② 关窗/新纠错 → 断言 `cancelInFlight(.sessionEnd)` 清空整个会话内存。
- **旧响应隔离（评审#4）**：`cancelInFlight` 后旧 delta/完成响应晚到 → 断言 guard（`askGeneration`+`isClosed`）失败丢弃、无副作用、不写 turns。
- **上下文预算**：构造超预算 + 引用某修正 → 断言被引用修正保留**或**明确报错，无静默错位；超限失败该轮不写 history、可重试复用绑定。
- **服务端超限映射（评审#7）**：mock 400/413 body 含 `context_length` → 断言映射 `.contextLengthExceeded` 可重试；流→非流回退后 partial 被**整体替换**（无"半截+完整"重复）；cancelled 直接结束不回退。
- **隐私零落盘**：断言追问路径 UserDefaults/plist/文件/剪贴板/日志均不含原文/修正/问题/回答子串，日志仅 requestId/耗时/token/状态码；`FollowUpSession` **不持有 apiKey**（评审#5）。
- **失败可恢复**：追问 401/超时/429/5xx → 断言中文错误 + 重试入口、主结果不变、该轮不入 history。
- **回归**：既有 loading/streaming/result/error 状态机与取消语义全绿（追问态作为 result 态之上叠加，不破坏既有 Requirement）。

## 7. 风险与回滚

| 风险 | 缓解 |
|---|---|
| 上下文预算静默截断致「修正 N」错位（正确性红线） | D5：base 恒保留被引用修正，超限 fail loud；测试固化 |
| 追问回答绕过最小改动护栏（Constraint-3） | D6：结构不可变（硬）+ prompt（软）+ **应用层输出护栏**拦替代全文（评审#1） |
| 含糊/越界引用发给 AI（正确性） | D4：发问前本地校验引用序号，越界不调 AI（评审#2） |
| 追问内容落盘/上报破隐私（Constraint-2） | D7：易失内存、枚举禁止落点、日志零内容；session **不持有 key**（评审#5） |
| 旧追问响应晚到污染新窗口（正确性） | D3：`cancelInFlight` 原子推代次+`isClosed`+清 streaming，Coordinator 持 currentState 在关闭前调用（评审#3/#4） |
| 服务端上下文超限被当普通 400 吞 body | D4：追问层读 400/413 body 映射 `.contextLengthExceeded`（评审#7） |
| 流→非流回退造成"半截+完整"重复 | D4：回退整体替换 partial 不 append（评审#7） |
| 流式 Markdown 每帧重解析性能/闪动 | D8/D9：帧节流、半截 Markdown 回退纯文本 |
| Esc/失焦折叠与输入框聚焦冲突 | UI-7 + 实现桥接：escMonitor 查 composer 焦点/草稿/IME 态再决定，不再无条件吞 Esc（评审#6） |
| 追问偏离为通用聊天，稀释定位 | prompt 范围锚定本次结果（跑题不保证，spec Q5） |

**回滚**：追问为 result 态之上的**纯叠加**，不改首轮纠错链路；回滚 = 移除追问区 UI + `FollowUpSession` 注入 + AIClient 追问方法，首轮纠错行为不受影响。

## 8. 关联

- [proposal.md](./proposal.md) · [spec-delta](./specs/grammar-review/spec.md)
- 宪法红线 [constitution.md](../../overview/constitution.md)（Constraint-2/3）
- [ADR-0004 最小改动护栏](../../decisions/0004-minimal-edit-guard.md) · [ADR-0005 V1 范围](../../decisions/0005-v1-scope.md) · **ADR-0006（本 change 新增）**
- 关联 change [streaming-incremental-render](../streaming-incremental-render/)（序号与「预览→定稿」时序）、[33-adaptive-window-ui](../33-adaptive-window-ui/)（主题 token 与自适应窗口，追问 UI 复用）

## 9. 变更历史

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-07-14 | 初稿（技术架构 D1–D10 + 影响面 + 测试） | 技术方案官 |
| 2026-07-14 | Codex 定稿 §4 UI/交互设计（艺术化、四主题自适应） | Codex（技术方案官整合） |
| 2026-07-14 | Codex 对抗式评审 1 轮返回 `需改`（5 高 2 中），逐条采纳整合：D6 加应用层输出护栏、D4 加越界引用校验与错误映射/回退语义、D3 修正取消语义分层+强化旧响应隔离、D2 拆 key-free config 快照、UI-7 补 escMonitor 焦点桥接 | 技术方案官 |
| 2026-07-15 | 开发落地（开发官）：实现 FollowUpSession/AIClient 追问层/Prompt/ReviewView UI + 165 单测。开发阶段 Codex 对抗式评审 3 轮收敛（6→2→0，最终「通过」），额外硬化：①截断(finish=length)/空回答/无完成信号(缺 [DONE] 且缺 finish_reason)一律 fail loud 回退非流式，绝不当完整（新增 `ReviewError.truncated`）；②流式边流边过输出护栏，替代全文不在流式阶段原样露出；③输出护栏加 verbatim 子串检测（单遍替换，防自替换死循环）；④Prompt.sanitizeDelimiter 中和 `<<<RESULT`/`RESULT>>>` delimiter 碰撞；⑤inFlightTask 完成即释放（含 key 的 cfg 不驻留）；⑥IME Esc 改查 field editor `hasMarkedText` 真状态 | 开发官 |
| 2026-07-15 | 用户 review PR#4 三条修订（开发官）：①序号改由 LLM 输出 `index` + 应用 `ReviewResult.numberedIssues` 强校验兜底同源（D1 更新）；②追问区并入主结果同一滚动流、去内层 `maxHeight:220` 固定容器、自动滚底改外层 `ScrollViewReader` proxy 下传；③AI/失败气泡固定对齐宽度 `maxWidth:.infinity`。+3 单测（168 全绿）。Codex 对抗式评审 2 轮收敛（1中1低→通过） | 开发官 |
