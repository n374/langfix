<!-- doc-init template version: v1.0 -->
# Capability Delta: review-window

- **Change**: 33-adaptive-window-ui
- **Owner**: by 需求官 on behalf of wu.nerd
- **基于 living spec 版本**: 新建（review-window 首个 change，archive 时创建 `docs/specs/review-window/spec.md`）

> `review-window` 为本 change 新建 capability（弹窗容器/交互/视觉外壳，与 grammar-review 纠错逻辑正交）。若 Reviewer 决定沿用单 capability，可平移回 grammar-review（见 proposal §6 D0）。
> 本 change 分三轮：round1 已交付并有 OPEN PR #2；**round2** 增量修 2 个 bug 并改写默认交互模型（详见 proposal §9）；**round3**（本次）修高度测量根因（H1 初始空白 / H2 加载中暴涨到最大）并新增「窗口初始屏幕定位」需求（详见 proposal §10）。
> 「覆盖测试」：round1 与 round2 的 Scenario 均已用真实测试路径（`Tests/LangFixTests/*`）标注；**round3 新增的对抗验收 Scenario 处 spec-delta 阶段挂 `TBD(...)`，且要求 TBD 描述的测试必须驱动真实测量路径（`ReviewMeasurementView` / `measurementHosting.fittingSize`）、逐帧断言、含必测失败路径——不得复用「直接喂入正确自然高度」的算术级单测充数**（用户 `e698b62a` 明确「修到对抗评审通过为止」）。
> 注：SwiftUI View body / NSPanel 面板机械等 UI 层无法在 SPM 无头单测中覆盖，由手工 UI 验收兜底（见 tasks.md 覆盖率说明）。
> 本 change（含 round2/round3）不触碰 constitution 4 条红线：窗口行为模式与主题一样属**非敏感偏好**，持久化到 UserDefaults（非 Keychain、非消息内容），不涉及 Constraint-1/2/3/4；round3 的初始定位/留白为纯 UI 布局，无红线接触。

## ADDED Requirements

### Requirement: 弹窗尺寸随内容实时自适应
THE SYSTEM SHALL 令弹窗宽度与高度均等于当前内容的自然尺寸，并各自 clamp 到屏幕相对范围——宽度 clamp 到 `[minW, maxW]`（`minW = 336pt`，`maxW = 弹窗所在屏 visibleFrame 宽度 × 0.28`），高度 clamp 到 `[minH, maxH]`（`minH` 为容纳标题栏与首行状态的内容自然高度，`maxH = 同屏 visibleFrame 高度 × 0.7`）。WHILE 流式内容持续增长 THE SYSTEM SHALL 令弹窗高度随内容**实时**增长。WHILE 内容自然高度 ≤ `maxH` THE SYSTEM SHALL 令弹窗完整容纳内容且内容区**不出现纵向滚动条/滑块**。IF 内容自然高度 > `maxH` THEN THE SYSTEM SHALL 将高度封顶为 `maxH` 并由内容区内部滚动承载超出部分。

> 约束：宽、高上限**均以屏幕相对尺寸计算**（不得用固定像素上限），使不同分辨率下上限比例一致。round3 用户实测反馈要求「宽度再减少 30%」，故 round2 的 `480pt / 0.4` 同步收窄为 `336pt / 0.28`。
>
> **round2 正确性红线（Bug1）**：滚动条只在「内容真正超过 `maxH`」这一唯一条件下出现。任何「内容 ≤ `maxH` 却出现纵向滚动条/滑块」都是正确性缺陷（窗口没有把自己撑到内容高度），happy-path 出现即验收不通过。参见 proposal §9。
>
> **实现备注（非规范性，来自 design.md §8 Q1 + round3 用户实测反馈）**：当屏 `visibleFrame.width < 1200pt` 时 `maxW = visibleW×0.28 < minW=336`，`[336, maxW]` 数学非法。落地采用 `maxW = max(336, visibleW×0.28)`——常规屏遵守 28% 相对上限，极窄屏以 336pt 最小可用宽兜底（此时字面超过屏 28%）。若需「任何情况绝不超 28%」，改为窄屏允许低于 336 即可。

#### Scenario: 短内容出小窗
- **GIVEN** 弹窗展示的内容仅一行修正结果（自然宽/高均 < 各自上限）
- **WHEN** 弹窗渲染完成
- **THEN** 弹窗宽高贴合内容自然尺寸（高接近 `minH`、宽不小于 `minW`），不撑到固定满高、无大量留白

**覆盖测试**: `Tests/LangFixTests/ReviewWindowSizingTests.swift::testShortContentYieldsSmallWindow`

#### Scenario: 宽度按屏幕相对范围 clamp
- **GIVEN** 内容自然宽度分别小于 `minW`、位于范围内、大于 `maxW`
- **WHEN** 弹窗渲染
- **THEN** 窗口宽度分别被夹到 `minW(=336)`、取内容自然宽、夹到 `maxW(=屏宽×0.28)`；超 `maxW` 时内容横向由内部布局承载而非撑破窗口

**覆盖测试**: `Tests/LangFixTests/ReviewWindowSizingTests.swift::testWidthClampThreeBuckets`

#### Scenario: 未达 maxH 时窗口实时贴合内容且无纵向滚动条（Bug1）
- **GIVEN** 流式逐帧产出内容，其自然高度持续增长但始终 ≤ `maxH`（屏高×70%）
- **WHEN** 每一帧流式增量到达
- **THEN** 弹窗高度实时增长为当刻内容自然高度、完整容纳内容；内容区**不出现纵向滚动条/滑块**（任一帧在 ≤ `maxH` 时出现滚动条即判不通过）

**覆盖测试**: `Tests/LangFixTests/ReviewWindowSizingTests.swift::testFrameByFrameNaturalUnderMaxMatchesWindowHeight`、`Tests/LangFixTests/ReviewWindowSizingTests.swift::testNoOverflowUntilNaturalHeightExceedsMaxH`

> ⚠️ round3 补充：上面这两个测试是**算术级**（直接喂入自然高度验 clamp），已全绿；但用户第 3 次仍报「内容没写满一行、窗口就涨到最大」——说明真实 bug 在**测量**而非算术。故新增独立 Requirement「内容自然高度按内在尺寸测量」承接根因对抗验收，本 Scenario 保留但**不足以判定 H2 通过**。

#### Scenario: 初始加载态贴合内容、按钮下方无失控空白（Bug-H1）
- **GIVEN** 弹窗刚进入加载态（转圈 + 首行状态 + 「取消」按钮，尚无正文），经真实测量路径测量
- **WHEN** 计算并应用初始窗口尺寸
- **THEN** 窗口内容区高度 ≈ 加载态元素的**固有高度**（下夹到 `minH`）；「取消」按钮下方**不出现失控的多余空行**（不得因测量把加载态容器撑到接近 `maxH` 而留大片空白）。允许 Codex 按 UI/UX 规范设计的**少量、克制留白**，但不得是内容缺失导致的大片空白

**覆盖测试**: TBD(unit/UI: 加载态经真实测量宿主，断言 window.contentHeight ≈ max(loading 元素固有高度, minH) 且 ≤ 该值 + 设计留白阈值；回归 = 加载态高度 ≥ 0.9·maxH 即 fail)

#### Scenario: 流式增高到屏幕相对上限后滚动
- **GIVEN** 流式逐字产出内容，自然高度持续增长
- **WHEN** 内容自然高度超过 `maxH`（= 所在屏 visibleFrame 高度 × 比例）
- **THEN** 弹窗高度封顶为 `maxH`，超出部分由内容区内部滚动承载；封顶前高度随内容单调增

**覆盖测试**: `Tests/LangFixTests/ReviewWindowSizingTests.swift::testHeightGrowsThenCapsAtMaxH`、`Tests/LangFixTests/ReviewWindowSizingTests.swift::testHeightMonotonicWhenStreaming`

#### Scenario: 上限随分辨率按比例缩放
- **GIVEN** 两个不同分辨率/尺寸的屏幕
- **WHEN** 在各自屏幕上撑满内容触发封顶
- **THEN** 两者的 `maxH` 均为「该屏 visibleFrame 高度 × 同一固定比例」，而非同一固定像素

**覆盖测试**: `Tests/LangFixTests/ReviewWindowSizingTests.swift::testMaxHeightScalesWithResolution`

### Requirement: 内容自然高度按内在尺寸测量（H2 根因 · 对抗验收）
THE SYSTEM SHALL 在计算弹窗目标尺寸前，将内容自然高度按**内容固有（intrinsic）高度**测量，而非按测量宿主/布局的可用最大高度撑开（greedy fill）；IF 测量宿主被赋予接近 `maxH` 的可用高度 THEN THE SYSTEM SHALL 仍返回等于内容固有高度的自然高度（不得因可用空间大而虚高）。

> **根因与验收纪律（正确性红线）**：round2（`1a0c974`）、round2.5（`1ee16b5`）两次「修复」后用户第 3 次仍报「内容没写满一行、窗口就迅速涨到最大、内容再在里面慢慢加」。定位：`ReviewWindowSizing` 纯算术**正确**且单测全绿，但那些单测**直接喂入正确的自然高度**、绕过真实测量路径（`ReviewMeasurementView` / `AppCoordinator.refreshMeasurement()` 的 `measurementHosting.fittingSize`）。真实 bug 高概率是测量把内容容器按可用最大高度 greedy-fill 撑开、或上一帧 `maxH` 状态污染后续测量。
> 因此本 Requirement 的覆盖测试**必须驱动真实测量路径、禁止预先塞入自然高度**，并**必测失败路径**；「`swift test` 全绿」不构成 H2 验收通过（用户 `e698b62a`：「修到对抗评审通过为止」）。

#### Scenario: 短内容测量不被撑到最大（失败路径必测）
- **GIVEN** 一段固有高度 `h` 远小于 `maxH` 的内容，交给真实测量宿主，且宿主可用高度上限被设为 `maxH`（模拟大窗/上一帧撑满）
- **WHEN** 经真实测量路径测量该内容自然高度
- **THEN** 测得自然高度 ≈ `h`（误差在一个布局行高内）且明显 < `maxH`；据此算出的窗口内容区高度 ≈ `h`。**失败路径**：若测得自然高度 ≈ `maxH`（内容少却顶满）→ **判不通过**

**覆盖测试**: TBD(unit/UI: 驱动 ReviewMeasurementView/fittingSize 测短内容且宿主可用高度=maxH，断言 measured ≈ h 且 < 0.5·maxH；构造 greedy-fill 回归即 measured ≈ maxH 时必须 fail)

#### Scenario: 流式逐帧测量贴合内容、未满不到顶（Bug-H2 主场景）
- **GIVEN** 流式逐块注入内容，第 N 块后内容固有高度为 `h_N`（`h_N < maxH`）
- **WHEN** 每块到达后经真实测量路径重新测量并 resize
- **THEN** 每一帧测得自然高度 ≈ `h_N`、窗口内容区高度 ≈ `h_N` 且 < `maxH`，窗口随 `h_N` 小步单调增长；**绝不出现「先跳到/接近 `maxH`、内容再在其中慢慢填」的形态**

**覆盖测试**: TBD(unit/UI: 逐帧驱动真实测量，对序列断言 window.contentHeight ≈ h_N 且 < maxH；任一帧 h_N < 0.5·maxH 却 window.contentHeight ≥ 0.9·maxH 即 fail)

#### Scenario: 上一帧撑满不污染下一帧测量
- **GIVEN** 某帧内容曾触达 `maxH`（窗口封顶），随后一帧内容回落到固有高度 `h' < maxH`（或换一次新的短内容会话）
- **WHEN** 经真实测量路径重新测量
- **THEN** 测得自然高度 ≈ `h'`，窗口回落贴合 `h'`，不被上一帧的 `maxH` 状态锁死在最大

**覆盖测试**: TBD(unit/UI: 先喂超 maxH 内容再喂短内容，断言第二次 measured ≈ h' 且窗口回落到 ≈ h'，未被 maxH 污染)

### Requirement: 窗口初始屏幕定位（Codex 设计）
THE SYSTEM SHALL 令弹窗首次出现时的屏幕位置相对「水平/垂直居中」基线**上移**（顶部更靠近屏幕上缘，可含适度右移），以贴近划词工具的使用视线；WHERE 计算初始位置 THE SYSTEM SHALL 保证整窗完整落在弹窗所在屏 `visibleFrame` 内（不越界）。具体偏移量、定位规则与留白量由下游 Codex 按 UI/UX 规范设计定稿。

> 来源：用户 `fbef2c90` 澄清——round3 handoff 一度把它读成「初始高度更高」，用户澄清**真实诉求是「窗口整体在屏幕上往上挪（也可往右挪）」的定位**，非尺寸；用户无具体数值感知，授权 Codex 按经验/规范设计。此为初始**位置**需求，与初始**尺寸**（贴合内容，见上）正交——初始不追求更高的窗口，只把窗口在屏上摆得更靠上/靠右。

#### Scenario: 初始位置相对居中上移且不越界
- **GIVEN** 给定所在屏 `visibleFrame` 与由内容算出的初始窗口尺寸
- **WHEN** 计算弹窗首次出现的屏幕位置
- **THEN** 弹窗顶边高于「居中」布局的顶边（`origin.y` 更靠上，可含右移），落在 Codex 设计的定位区间内，且整窗 `frame ⊆ visibleFrame`

**覆盖测试**: TBD(unit: 给定 visibleFrame 与窗口尺寸，断言初始 origin.y 高于居中 origin.y 且 frame ⊆ visibleFrame)

### Requirement: 窗口行为模式可配置（A/B/C）
THE SYSTEM SHALL 提供三种互斥的窗口行为模式——`A 失焦折叠` / `B 始终置顶` / `C 默认窗口`——供用户在设置中三选一；默认模式为 `C`；模式选择作为非敏感偏好持久化到 UserDefaults，跨启动保留。三种模式**仅在「失焦行为」与「窗口层级」上不同**，折叠/展开交互（Esc、隐藏图标、点击胶囊）三模式完全统一（见「折叠/展开统一交互」）。

> 差分权威表（proposal §9 用户拍板 `fc90708a`）：

| 触发 | A 失焦折叠 | B 始终置顶 | C 默认窗口（默认） |
|---|---|---|---|
| 失焦(resignKey) | 折叠为胶囊，后台续流 | 无操作（保持置顶） | 无操作（可被遮挡） |
| Esc | 折叠为胶囊 | 折叠为胶囊 | 折叠为胶囊 |
| 隐藏图标 | 提供，点击折叠为胶囊 | 提供，点击折叠为胶囊 | 提供，点击折叠为胶囊 |
| 点击胶囊 | 展开 + 按当刻内容重算尺寸 | 展开 + 重算尺寸 | 展开 + 重算尺寸 |
| 关闭按钮/取消 | 销毁窗口 + 取消底层请求 Task | 同左 | 同左 |
| 窗口层级 | 普通层级；失焦自动折叠 | 始终置顶（展开态与胶囊态都置顶） | 普通层级，可被遮挡；失焦不折叠 |

#### Scenario: 全新安装默认模式为 C
- **GIVEN** 全新安装、用户未改动窗口行为模式设置
- **WHEN** 读取当前窗口行为模式
- **THEN** 为 `C 默认窗口`

**覆盖测试**: `Tests/LangFixTests/ReviewWindowModeTests.swift::testWindowBehaviorDefaultAndRawValueFallback`

#### Scenario: 模式选择持久化
- **GIVEN** 用户在设置中把模式从 C 改为 B
- **WHEN** 写入后重新读取（含跨实例/重启模拟）
- **THEN** 当前模式为 B，且该选择从 UserDefaults 读回一致

**覆盖测试**: `Tests/LangFixTests/ReviewWindowModeTests.swift::testWindowBehaviorPersistenceViaUserDefaults`

#### Scenario: 失焦行为随模式差分
- **GIVEN** 弹窗展开、流式进行中
- **WHEN** 弹窗失去焦点，且当前模式分别为 A / B / C
- **THEN** A：折叠为胶囊并后台续流；B：不折叠、不隐藏、保持置顶；C：不折叠，普通层级可被其他窗口遮挡

**覆盖测试**: `Tests/LangFixTests/ReviewWindowModeTests.swift::testResignKeyOnlyFocusCollapseModeCollapses`、`Tests/LangFixTests/ReviewWindowStyleTests.swift::testWindowLevelPolicyFollowsBehavior`

#### Scenario: 窗口层级随模式差分
- **GIVEN** 弹窗显示中
- **WHEN** 当前模式分别为 A / B / C
- **THEN** B 模式弹窗（展开态与胶囊态）均置于最上层（floating / always-on-top）；A、C 模式为普通窗口层级、可被其他窗口遮挡

**覆盖测试**: `Tests/LangFixTests/ReviewWindowStyleTests.swift::testWindowLevelPolicyFollowsBehavior`

### Requirement: 折叠/展开统一交互（三模式一致）
THE SYSTEM SHALL 在 A/B/C 三种模式下提供**完全一致**的折叠/展开交互：WHEN 用户按下 Esc OR 点击隐藏图标 THE SYSTEM SHALL 将弹窗折叠为一个极简胶囊入口（不销毁窗口，进行中的流式/请求在后台继续）；WHEN 用户点击胶囊入口 THE SYSTEM SHALL 展开弹窗并**按展开当刻的实际内容重新计算尺寸**（禁止复用折叠前冻结的旧尺寸）。THE SYSTEM SHALL 令胶囊态的窗口层级跟随其所在模式（B 模式胶囊置顶，A/C 模式胶囊为普通层级）。Esc **不承担关闭语义**（关闭仅由关闭按钮/取消触发，见「关闭销毁并取消请求」）。

> 与 round1 差异：round1 里「Esc/失焦 = 全局折叠」是所有场景的默认语义；round2 将「失焦→折叠」**下沉为模式 A 专属**，而 Esc / 隐藏图标 / 点击胶囊三种手动折叠-展开动作对 A/B/C **统一**（用户拍板 `fc90708a`：「行为比较统一」）。

#### Scenario: Esc 三模式一律折叠为胶囊
- **GIVEN** 弹窗处于展开态，当前模式分别为 A / B / C
- **WHEN** 用户按下 Esc
- **THEN** 三模式均折叠为胶囊入口，不销毁窗口、不取消请求；后台流式继续

**覆盖测试**: `Tests/LangFixTests/ReviewWindowModeTests.swift::testEscAndHideIconCollapseAllModesWithoutCancel`、`Tests/LangFixTests/CloseSemanticsTests.swift::testEscAndResignDoNotCancel`

#### Scenario: 隐藏图标三模式一律折叠为胶囊
- **GIVEN** 弹窗处于展开态，当前模式分别为 A / B / C
- **WHEN** 用户点击隐藏图标
- **THEN** 三模式均折叠为胶囊入口，不销毁窗口、不取消请求；后台流式继续

**覆盖测试**: `Tests/LangFixTests/ReviewWindowModeTests.swift::testEscAndHideIconCollapseAllModesWithoutCancel`

#### Scenario: 点击胶囊展开并按当刻内容重算尺寸（Bug2）
- **GIVEN** 弹窗折叠为胶囊，折叠期间流式继续注入增量使内容增长（当前模式任一）
- **WHEN** 用户点击胶囊入口
- **THEN** 弹窗展开，尺寸按**展开当刻的实际内容**重新计算（= 当刻内容自然尺寸经同一 clamp 规则的结果），绝不复用折叠前的旧尺寸

**覆盖测试**: `Tests/LangFixTests/ReviewWindowModeTests.swift::testTapCapsuleAllModesExpandsAndRequestsRecompute`、`Tests/LangFixTests/ReviewWindowModeTests.swift::testRecomputeUsesCurrentNaturalSizeNotCollapsedOldSize`

#### Scenario: 折叠期间后台续流
- **GIVEN** 弹窗折叠为胶囊，流式正在进行
- **WHEN** 折叠期间到达流式增量
- **THEN** 底层流式/请求继续运行、增量被应用到内容；展开后展示的是折叠期间累积的最新内容

**覆盖测试**: `Tests/LangFixTests/ReviewWindowModeTests.swift::testStateStillUpdatesWhileConceptuallyCollapsed`

#### Scenario: 胶囊态窗口层级跟随模式
- **GIVEN** 弹窗折叠为胶囊
- **WHEN** 当前模式分别为 B 与 A/C
- **THEN** B 模式胶囊始终置顶（可被点开）；A/C 模式胶囊为普通窗口层级

**覆盖测试**: `Tests/LangFixTests/ReviewWindowStyleTests.swift::testWindowLevelPolicyFollowsBehavior`

### Requirement: 关闭销毁并取消请求
WHEN 用户触发关闭（关闭按钮或取消）THE SYSTEM SHALL 销毁弹窗并取消进行中的 AI 请求（cancel 底层 Task），使关闭后无后台请求继续运行。关闭是三模式共用语义，且**关闭只能由关闭按钮/取消触发**——Esc 与失焦均不销毁窗口、不取消请求。

#### Scenario: 关闭取消在途请求
- **GIVEN** 弹窗展开或折叠，流式请求在途
- **WHEN** 用户点击关闭按钮
- **THEN** 弹窗销毁，底层 `currentTask` 被 cancel，无后台请求继续

**覆盖测试**: `Tests/LangFixTests/CloseSemanticsTests.swift::testCloseCancelsUnderlyingTask`、`Tests/LangFixTests/CloseSemanticsTests.swift::testCollapseKeepsTaskCloseCancelsTask`

#### Scenario: Esc 与失焦不关闭、不取消（三模式）
- **GIVEN** 弹窗展开、流式在途，当前模式分别为 A / B / C
- **WHEN** 用户按下 Esc（或在模式 A 下失焦）
- **THEN** 弹窗折叠（模式 A 失焦亦折叠）而非销毁；底层 `currentTask` 未被 cancel

**覆盖测试**: `Tests/LangFixTests/CloseSemanticsTests.swift::testEscAndResignDoNotCancel`、`Tests/LangFixTests/ReviewWindowModeTests.swift::testEscAndHideIconCollapseAllModesWithoutCancel`

### Requirement: 折叠态状态可视化
WHILE 弹窗处于折叠态 THE SYSTEM SHALL 以可区分的颜色与图标表达当前阶段——`进行中`（loading / streaming）、`已完成`（result）、`出错`（error）——三态互不相同，并以极简动画呈现状态与折叠/展开的过渡。

#### Scenario: 进行中与完成的视觉区分
- **GIVEN** 弹窗折叠，流式进行中
- **WHEN** 流式完成进入 result 态
- **THEN** 折叠入口的颜色/图标由「进行中」标识切换为「已完成」标识，二者可区分，切换走极简动画

**覆盖测试**: `Tests/LangFixTests/CollapsedStatusTests.swift::testPhaseToStatusMapping`、`Tests/LangFixTests/CollapsedStatusTests.swift::testIconsAreDistinct`、`Tests/LangFixTests/CollapsedStatusTests.swift::testColorsAreDistinct`

#### Scenario: 出错态可辨识
- **GIVEN** 弹窗折叠
- **WHEN** 底层进入 error 态
- **THEN** 折叠入口显示与「进行中/已完成」均不同的「出错」标识

**覆盖测试**: `Tests/LangFixTests/CollapsedStatusTests.swift::testErrorStatusDistinctFromOthers`

### Requirement: 视觉主题可选
THE SYSTEM SHALL 提供不少于两套体现「科幻/艺术感」的视觉主题，在设置中可切换、切换即时生效，并有一个默认主题；主题选择作为非敏感偏好持久化到 UserDefaults（不进 Keychain）。

> 具体主题集合、配色、材质、图标与动效细节由下游 Codex 设计定稿（用户已授权「以 Codex 最终设计为准」）；本 Requirement 只约束「多主题可选 + 可切换 + 有默认 + 持久化位置」。

#### Scenario: 切换主题即时生效
- **GIVEN** 存在 ≥2 套主题，当前为默认主题
- **WHEN** 用户在设置中切换到另一主题
- **THEN** 弹窗视觉即时切换为所选主题，且该选择被持久化到 UserDefaults，下次启动仍生效

**覆盖测试**: `Tests/LangFixTests/ReviewThemeTests.swift::testThemePersistenceViaUserDefaults`（切换写入→读出新值→跨实例仍生效；UI 即时重绘由 @Published 保证，见手工 UI 验收）

#### Scenario: 默认主题
- **GIVEN** 全新安装、用户未改动主题设置
- **WHEN** 读取当前主题
- **THEN** 为设计指定的默认主题

**覆盖测试**: `Tests/LangFixTests/ReviewThemeTests.swift::testDefaultIsAuroraGlass`、`Tests/LangFixTests/ReviewThemeTests.swift::testRawValueFallback`

### Requirement: 取消手动 resize
THE SYSTEM SHALL 移除弹窗的手动缩放能力，弹窗尺寸完全由内容与流式自动决定，用户不可手动拉伸窗口。

#### Scenario: 无手动缩放
- **GIVEN** 弹窗显示中
- **WHEN** 用户尝试拖拽窗口边缘缩放
- **THEN** 窗口不响应手动缩放（styleMask 不含 `.resizable`），尺寸仍由内容/流式驱动

**覆盖测试**: `Tests/LangFixTests/ReviewWindowStyleTests.swift::testExpandedStyleHasNoResizable`
