<!-- doc-init template version: v1.0 -->
# Proposal: streaming-incremental-render

- **Owner**: by 需求官 on behalf of wu.nerd
- **Reviewers**: 编排官、wu.nerd
- **创建日期**: 2026-06-29
- **状态**: Clarify
- **关联 Issue**: RAS-18
- **共享分支**: `feat/16-streaming-incremental-render`

## 1. Why（动机）

LangFix 当前是「**等 AI 返回完整 `ReviewResult` 再一次性展示**」（状态机 `loading → result`）。在所配端点/模型较慢时，用户从触发到「看到修正结果」存在明显的首字延迟（AI 往返 P50 目标 < 2.5s，慢端点更久），等待期只有一个 spinner，体验阻塞。

期望状态：**边返回边渲染**——后端开启 `stream:true`，前端增量解析并**优先把 `corrected` 字段逐字渲染**（打字机效果），显著降低「看到修正结果」的首字延迟，`issues[] / summary_zh / alternative` 随解析进度补齐。

为什么现在做：核心质量机制（三级降级、repair 重试、截断重发、**最小改动护栏 ADR-0004**、基准一致性校验）已稳定落地，全部依赖「完整内容」。真流式与它们直接冲突，需要在**需求阶段先把「护栏与流式如何共存」的用户可见语义约束定清楚**，作为技术方案阶段（技术方案官 + Codex 交叉评审）的输入约束，避免实现期反复返工或破坏红线 Constraint-3。

> 本 change 属路线②「真流式 corrected」（用户已在父 Issue 三方案对比中拍板）。本阶段**只产出需求约束，不定实现、不写代码**。

## 2. What's Changing（高层变更）

| Capability | 变化类型 | 简述 |
|---|---|---|
| grammar-review | MODIFIED | 在 `loading` 与 `result` 之间新增 `streaming` 态：corrected 优先逐字渲染、其余结构化字段增量补齐；最终展示契约不变（完整 corrected 才出词级 diff） |
| grammar-review | ADDED | 新增「流式渲染开关」「流式能力探测与静默回退」「流式预览→定稿（与最小改动护栏共存）」「流式态可取消」等 Requirement（见 spec-delta） |

**新增 capability**：无（grammar-review 是本项目唯一 capability）。

## 3. Out of Scope（明确不做）

- **不做词级 diff 的流式**：diff 高亮依赖完整 `corrected`，仅在定稿时渲染。
- **不改最小改动护栏的判定逻辑**（ADR-0004）：`editRatio` 仍在完整 corrected 上算、strict 重试机制不变；本 change 只定义护栏触发时的**用户可见渲染语义**，不动护栏算法。
- **不改基准一致性校验**：仍以本地输入为 `original` 基准（data-flow §3）。
- **不在本阶段定增量 JSON 解析的具体实现**（自研容错 parser / 字段顺序约定等 HOW 归技术方案阶段）。
- **不写代码**：本阶段只产出 proposal + spec-delta。

## 4. Stakeholders

| 角色 | 关注点 | Review 必需 |
|---|---|---|
| wu.nerd（Owner / 用户） | 首字延迟体验、不破坏「可信可核对」 | 是 |
| 编排官 | 阶段流转、约束完整性 | 是 |
| 技术方案官 + Codex | 把本约束转成可实现设计（护栏×流式共存、增量解析容错） | 设计阶段 |

## 5. Success Metrics（成功指标）

- **首字延迟**：流式开启且端点支持流式时，「触发 → 屏幕出现首批 `corrected` 字符」的时间显著低于「触发 → 完整结果」的时间（首字延迟 < 完整往返延迟，确定性可测：mock 端点分段吐 token 断言首字早于末字）。
- **护栏不被破坏**：流式路径下最小改动护栏（ADR-0004）仍生效，最终展示的 corrected 与非流式路径一致（确定性可测）。
- **零打扰回退**：端点不支持流式时静默回退非流式，用户无可见报错/弹窗（确定性可测）。
- **格式一致**：流式期间内容按 `ReviewResult` 结构化分区展示，不退化为纯文本糊屏（确定性可测）。

## 6. Clarifications（Clarify 阶段已收敛）

### Q1: 最小改动护栏（ADR-0004）与流式如何共存？
**背景矛盾**: `editRatio` 只能在**完整 corrected 收到后**才能计算，到那时流式已把第一版 corrected 显示给用户；若随后 strict 重试取了更小改动版替换，存在「闪烁/回退」风险。「流式仅在不触发护栏的路径生效」在物理上不可达（触发与否是事后才知道的）。

**A（用户拍板：方案 A+B 集合）**:
- 流式全程带**明显的「校对预览中…」标记**（视觉降级，明确不是终版）；
- 流式期间**仍按 `ReviewResult` 定义的结构化格式增量展示**（corrected 优先逐字，其余字段解析到即按分区填充，**不**退化为纯文本）；
- 流式结束 + 护栏复核（含可能的 strict 重试）完成后，**去掉标记、标为「最终结果」**；
- 护栏 strict 重试覆盖第一版 → 归入「预览→定稿」的正常收敛，**不视为错误闪烁**。

**影响**: 决定 spec-delta 中「流式增量渲染」「流式预览→定稿」两条 Requirement 的可观测行为；把「流式仅在非护栏路径生效」从「事前判定」重构为「事后定稿」。HOW（草稿态管理、二次往返是否也流式、平滑过渡动画）归技术方案阶段。

### Q2: 端点降级到纯文本模式时是否仍流式？
**A（用户拍板，否决「纯文本一律回退非流式」的保守提议）**: **是否开流式的唯一判据 = 流式开关为开 AND 端点支持流式**。结构化降级层级（`json_schema → json_object → text`）**不影响**是否流式——纯文本模式只要端点支持流式照样流式，把流式文本增量直接当 `corrected` 渲染（此时 `issues` 等结构化分区可能为空，符合预期）。仅「开关关」或「端点不支持流式」才回退非流式。

**影响**: spec-delta 中「流式能力探测与回退」Requirement 的回退触发集合从 6 条收敛为 2 条（开关关 / 端点不支持流式）；结构化降级、护栏 strict 重试、repair 重试、截断重发**均不再是回退理由**（后三者归「预览→定稿」收敛）。

### 回退/收敛清单（最终）
| 情形 | 行为 |
|---|---|
| 流式开关关闭 | 非流式完整渲染 |
| 端点不支持流式（探测 / SSE 失败） | 静默回退非流式，不打扰用户 |
| 结构化降级 `json_schema→json_object→text` | **不影响流式**；端点支持流式则照流 |
| 护栏 strict 重试 / repair 重试 / 截断 max_tokens 重发 | **不是回退**；维持「校对预览中」标记，二次往返结果定稿后再标「最终结果」 |
| 增量解析暂未就绪（字段未闭合） | 不崩、不乱显，等更多 token；最坏完整后一次性渲染（HOW 归设计） |

## 7. 风险

| 风险 | 可能性 | 影响 | 缓解 |
|---|---|---|---|
| 护栏 strict 重试替换已显示的第一版，被用户感知为「闪烁/结果变了」 | 中 | 中（伤「可信」体验） | 全程「校对预览中」标记 + 定稿才标「最终结果」，把替换框定为正常收敛（Q1 方案） |
| Swift 生态无现成增量 JSON 解析，自研容错 parser 出 bug 导致乱渲染 | 中 | 中 | 需求层约束「未就绪不乱显、最坏退化为完整后一次性渲染」；具体容错方案 + 测试归技术方案阶段 |
| 端点「声称支持但流式行为异常」（半截断流、非标准 SSE） | 中 | 中 | 运行时识别异常即静默回退非流式完整渲染（与「端点不支持」同路径） |
| 流式态新增导致状态机/取消语义回归（loading/result/error 既有行为被破坏） | 低 | 高 | 红线①：streaming 态继承 loading 可取消语义；既有 Requirement 的覆盖测试必须仍全绿 |
| 误把结构化降级当作回退理由，削弱流式覆盖面 | 低 | 低 | Q2 已明确：降级层级不影响是否流式 |

## 8. 关联资源

- spec-delta：[specs/grammar-review/spec.md](./specs/grammar-review/spec.md)
- 设计（技术方案阶段产出）：`./design.md`（待技术方案官 + Codex 落地）
- 现状 Living spec：[../../specs/grammar-review/spec.md](../../specs/grammar-review/spec.md)
- 数据流与护栏：[../../architecture/data-flow.md](../../architecture/data-flow.md)、[ADR-0004](../../decisions/0004-minimal-edit-guard.md)
- 宪法红线：[../../overview/constitution.md](../../overview/constitution.md)（Constraint-3 最小改动护栏不可破坏）
