<!-- doc-init template version: v1.0 -->
# Capability Delta: grammar-review

- **Change**: streaming-incremental-render
- **Owner**: by 需求官 on behalf of wu.nerd
- **基于 living spec 版本**: 2026-06-29（初始化）

> Delta 按 Requirement 粒度区分动作。本 change 在 grammar-review 上 ADDED 4 条流式相关 Requirement，MODIFIED 1 条展示契约。
> 「覆盖测试」用 `TBD(<描述>)` 占位，落地实现并归档前由 MR 阶段替换为真实路径。
> 关联 ADR-0004（最小改动护栏）、constitution Constraint-3（护栏不可破坏，红线）。

## ADDED Requirements

### Requirement: 流式增量渲染
WHEN 流式开关为开 AND 端点支持流式 THE SYSTEM SHALL 在收到首批 `corrected` 增量后进入 `streaming` 态，优先逐字渲染 `corrected`，并对 `issues[] / summary_zh / alternative` 按增量解析进度填充对应结构化分区，全程显示「校对预览中」标记。

> 约束：流式期间内容**按 `ReviewResult` 结构化格式分区展示**，不得退化为纯文本糊屏；词级 diff 依赖完整 corrected，**不在流式期间渲染**（见 MODIFIED「展示结构化修正」）。

#### Scenario: corrected 优先逐字流式
- **GIVEN** 流式开关开、端点支持流式，AI 分批吐出 `corrected` 字符
- **WHEN** 客户端收到首批 `corrected` 增量
- **THEN** 浮窗进入 `streaming` 态、显示「校对预览中」标记，并逐字追加渲染 `corrected`；首字出现时间早于完整结果到达时间

**覆盖测试**: TBD(unit/e2e: mock 端点分段吐 corrected token → 断言进入 streaming 态、corrected 增量渲染、首字时间戳 < 末字时间戳、全程有预览标记)

#### Scenario: 其余字段增量补齐
- **GIVEN** 流式进行中，`corrected` 已渲染若干字符，后续到达 `summary_zh` / `issues[]` 增量
- **WHEN** 增量解析到某结构化字段
- **THEN** 该字段按其分区（总评 / issue 列表）增量填充，仍保持「校对预览中」标记，不退化为纯文本

**覆盖测试**: TBD(unit: 构造按字段顺序吐出的流 → 断言 summary/issues 分区按结构化格式逐步填充)

#### Scenario: 纯文本模式下仍流式
- **GIVEN** 端点仅支持纯文本（结构化降级到 text）但**支持流式**，流式开关开
- **WHEN** 端点流式吐出纯文本
- **THEN** 系统仍进入 `streaming` 态，把流式文本增量直接当 `corrected` 渲染；`issues` 等结构化分区可为空（符合预期），不报错、不回退

**覆盖测试**: TBD(unit/e2e: text 模式 + 流式 mock → 断言文本增量当 corrected 渲染、未回退非流式、issues 空不报错)

### Requirement: 流式渲染配置开关
THE SYSTEM SHALL 在设置中提供「流式渲染：开 / 关」开关，默认为**开**，其值写入 UserDefaults（非敏感，不进 Keychain），用于决定是否对请求开启 `stream:true`。

#### Scenario: 默认开
- **GIVEN** 全新安装、用户未改动流式设置
- **WHEN** 读取流式开关
- **THEN** 其值为「开」

**覆盖测试**: TBD(unit: 默认 AppConfig/SettingsStore → 断言流式开关默认 true 且来源为 UserDefaults)

#### Scenario: 关闭开关走非流式
- **GIVEN** 用户在设置中关闭「流式渲染」
- **WHEN** 触发 review
- **THEN** 请求不开启 `stream:true`，直接走非流式完整渲染（`loading → result`，无 `streaming` 态）

**覆盖测试**: TBD(unit/e2e: 关闭开关 → 断言请求未带 stream:true、状态机不经过 streaming)

### Requirement: 流式能力探测与静默回退
IF 流式开关为开但端点不支持流式（探测失败或运行时 SSE 行为异常）THEN THE SYSTEM SHALL 静默回退到非流式完整渲染，不向用户显示报错或弹窗。

> 「是否开流式」的判据仅此两点：流式开关为开 AND 端点支持流式。结构化降级层级（json_schema→json_object→text）**不影响**是否流式。

#### Scenario: 端点不支持流式
- **GIVEN** 流式开关开，端点对 `stream:true` 不支持（返回非 SSE / 报错 / 半截断流）
- **WHEN** AIClient 发起流式请求并识别到不支持
- **THEN** 自动回退非流式完整渲染并正常出结果；用户无可见报错，体验与原非流式一致

**覆盖测试**: TBD(unit/e2e: mock 端点对 stream 返回非 SSE/错误 → 断言静默回退非流式、最终出结果、无错误 UI)

### Requirement: 流式预览到定稿（与最小改动护栏共存）
WHEN 流式输出结束且护栏复核（含 ADR-0004 可能的 strict 重试）完成 THE SYSTEM SHALL 去除「校对预览中」标记并标记为「最终结果」；护栏 strict 重试以更小改动版覆盖流式已显示的第一版时，THE SYSTEM SHALL 将其呈现为「预览→定稿」的收敛，而非错误闪烁。

> 本 Requirement 只约束**用户可见渲染语义**，不改护栏算法（ADR-0004 不变，红线 Constraint-3 不被破坏）。

#### Scenario: 无护栏触发，直接定稿
- **GIVEN** 流式完成，`editRatio` 未超阈值（或命中短句豁免），无需 strict 重试
- **WHEN** 完整 corrected 校验通过、词级 diff 计算完成
- **THEN** 去除「校对预览中」标记、标为「最终结果」，渲染完整 corrected + 词级 diff + issues

**覆盖测试**: TBD(e2e: 流式 + editRatio 未超阈值 → 断言无 strict 重试、最终态渲染 diff、预览标记消失)

#### Scenario: 护栏 strict 重试覆盖预览版
- **GIVEN** 流式已显示第一版 corrected，完整后算出 `editRatio` 超阈值，触发一次 strict 重试
- **WHEN** strict 重试返回更小改动版
- **THEN** 维持「校对预览中」标记直至定稿，用 strict 结果定稿替换第一版并标「最终结果」；若两轮均超阈值则按 ADR-0004 取较小版并置 `overEdited`、顶部加 banner

**覆盖测试**: TBD(e2e: 流式首版超阈值 → 断言触发 strict 重试、定稿替换、预览期间标记存在、overEdited 分支顶部 banner)

### Requirement: 流式态可取消
WHILE 处于 `streaming` 态 THE SYSTEM SHALL 显示可取消入口并允许用户取消（中止流式请求并关窗），语义与 `loading` 态一致。

#### Scenario: 流式中取消
- **GIVEN** 浮窗处于 `streaming` 态、corrected 正在逐字渲染
- **WHEN** 用户点取消
- **THEN** 流式请求被中止、窗口关闭，不残留预览内容或 spinner

**覆盖测试**: TBD(unit: streaming 态调用 cancel → 断言流式 URLSessionTask 被 cancel、窗口关闭)

## MODIFIED Requirements

### Requirement: 展示结构化修正

原:
> WHEN AIClient 返回校验通过的 ReviewResult THE SYSTEM SHALL 展示 `corrected` 全文、原文/修正文的词级 diff，以及每条 issue（含类型、严重度、`before→after`、中文解释）。

现:
> WHEN AIClient 返回校验通过的 ReviewResult THE SYSTEM SHALL 展示 `corrected` 全文、原文/修正文的词级 diff，以及每条 issue（含类型、严重度、`before→after`、中文解释）。WHERE 处于 `streaming` 态 THE SYSTEM SHALL 先增量展示结构化预览（corrected 优先逐字、其余字段按分区补齐、带「校对预览中」标记），**词级 diff 仍仅在完整 corrected 定稿时渲染**。

**变更原因**: 流式引入后，结构化内容的展示不再只由「完整校验通过的 ReviewResult」单点触发，需补充流式预览阶段的展示契约；但词级 diff 因依赖完整 corrected，展示时机不变（仅定稿渲染）。
**rename**: 不适用。

#### Scenario: 有问题文本（非流式，回归不变）
- **GIVEN** 流式关闭或端点不支持流式，输入 `"I have went there yesterday"`
- **WHEN** AI 返回 `corrected="I went there yesterday"` 与对应 issue
- **THEN** 浮窗显示 corrected、diff 高亮 `went`，并列出「语法·error: have went → went，中文解释」（行为与现状一致）

**覆盖测试**: TBD(ui: 给定 mock ReviewResult，流式关 → 断言 corrected/diff/issue 三区均渲染，与现状回归一致)

#### Scenario: 流式态先预览后定稿出 diff
- **GIVEN** 流式开启且端点支持流式
- **WHEN** corrected 在 streaming 态逐字渲染、定稿后计算词级 diff
- **THEN** 流式期间只见结构化预览（无 diff 高亮），定稿后才出现词级 diff 高亮

**覆盖测试**: TBD(e2e: 流式 mock → 断言 streaming 期间无 diff、定稿后出现 diff)

## REMOVED Requirements

无。

## 关联

- 关联 ADR: [ADR-0004 最小改动护栏](../../../../decisions/0004-minimal-edit-guard.md)
- 关联 design: [../../design.md](../../design.md)（技术方案阶段产出）
- 现状 Living spec: [../../../../specs/grammar-review/spec.md](../../../../specs/grammar-review/spec.md)
- 数据流: [../../../../architecture/data-flow.md](../../../../architecture/data-flow.md)
