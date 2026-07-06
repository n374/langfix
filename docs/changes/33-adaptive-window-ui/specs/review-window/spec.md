<!-- doc-init template version: v1.0 -->
# Capability Delta: review-window

- **Change**: 33-adaptive-window-ui
- **Owner**: by 需求官 on behalf of wu.nerd
- **基于 living spec 版本**: 新建（review-window 首个 change，archive 时创建 `docs/specs/review-window/spec.md`）

> `review-window` 为本 change 新建 capability（弹窗容器/交互/视觉外壳，与 grammar-review 纠错逻辑正交）。若 Reviewer 决定沿用单 capability，可平移回 grammar-review（见 proposal §6 D0）。
> 本 change 分两轮：round1 已交付并有 OPEN PR #2；**round2**（本次）在同一分支增量修 2 个 bug 并改写默认交互模型（详见 proposal §9）。
> 「覆盖测试」：round1 的 Scenario 已用真实测试路径（`Tests/LangFixTests/*`）；**round2 新增/改写的 Scenario 处于 spec-delta 阶段，暂挂 `TBD(<描述>)`，由下游开发测试阶段替换为真实路径**（archive checklist 强制）。
> 注：SwiftUI View body / NSPanel 面板机械等 UI 层无法在 SPM 无头单测中覆盖，由手工 UI 验收兜底（见 tasks.md 覆盖率说明）。
> 本 change（含 round2）不触碰 constitution 4 条红线：窗口行为模式与主题一样属**非敏感偏好**，持久化到 UserDefaults（非 Keychain、非消息内容），不涉及 Constraint-1/2/3/4。

## ADDED Requirements

### Requirement: 弹窗尺寸随内容实时自适应
THE SYSTEM SHALL 令弹窗宽度与高度均等于当前内容的自然尺寸，并各自 clamp 到屏幕相对范围——宽度 clamp 到 `[minW, maxW]`（`minW = 480pt`，`maxW = 弹窗所在屏 visibleFrame 宽度 × 0.4`），高度 clamp 到 `[minH, maxH]`（`minH` 为容纳标题栏与首行状态的内容自然高度，`maxH = 同屏 visibleFrame 高度 × 0.7`）。WHILE 流式内容持续增长 THE SYSTEM SHALL 令弹窗高度随内容**实时**增长。WHILE 内容自然高度 ≤ `maxH` THE SYSTEM SHALL 令弹窗完整容纳内容且内容区**不出现纵向滚动条/滑块**。IF 内容自然高度 > `maxH` THEN THE SYSTEM SHALL 将高度封顶为 `maxH` 并由内容区内部滚动承载超出部分。

> 约束：宽、高上限**均以屏幕相对尺寸计算**（不得用固定像素上限），使不同分辨率下上限比例一致。`minW` 用户原话「不小于 48」判读为 480pt（见 proposal §6 Q1）。
>
> **round2 正确性红线（Bug1）**：滚动条只在「内容真正超过 `maxH`」这一唯一条件下出现。任何「内容 ≤ `maxH` 却出现纵向滚动条/滑块」都是正确性缺陷（窗口没有把自己撑到内容高度），happy-path 出现即验收不通过。参见 proposal §9。
>
> **实现备注（非规范性，来自 design.md §8 Q1 + Codex 交叉评审）**：当屏 `visibleFrame.width < 1200pt` 时 `maxW = visibleW×0.4 < minW=480`，`[480, maxW]` 数学非法。落地采用 `maxW = max(480, visibleW×0.4)`——常规屏遵守 40% 相对上限，极窄屏以 480pt 最小可用宽兜底（此时字面超过屏 40%）。判为实现层合理降级，未改动本 Requirement 的规范语义；个人 macOS 划词工具窄于 1200pt 极罕见。若需「任何情况绝不超 40%」，改为窄屏允许低于 480 即可。

#### Scenario: 短内容出小窗
- **GIVEN** 弹窗展示的内容仅一行修正结果（自然宽/高均 < 各自上限）
- **WHEN** 弹窗渲染完成
- **THEN** 弹窗宽高贴合内容自然尺寸（高接近 `minH`、宽不小于 `minW`），不撑到固定满高、无大量留白

**覆盖测试**: `Tests/LangFixTests/ReviewWindowSizingTests.swift::testShortContentYieldsSmallWindow`

#### Scenario: 宽度按屏幕相对范围 clamp
- **GIVEN** 内容自然宽度分别小于 `minW`、位于范围内、大于 `maxW`
- **WHEN** 弹窗渲染
- **THEN** 窗口宽度分别被夹到 `minW(=480)`、取内容自然宽、夹到 `maxW(=屏宽×0.4)`；超 `maxW` 时内容横向由内部布局承载而非撑破窗口

**覆盖测试**: `Tests/LangFixTests/ReviewWindowSizingTests.swift::testWidthClampThreeBuckets`

#### Scenario: 未达 maxH 时窗口实时贴合内容且无纵向滚动条（Bug1）
- **GIVEN** 流式逐帧产出内容，其自然高度持续增长但始终 ≤ `maxH`（屏高×70%）
- **WHEN** 每一帧流式增量到达
- **THEN** 弹窗高度实时增长为当刻内容自然高度、完整容纳内容；内容区**不出现纵向滚动条/滑块**（任一帧在 ≤ `maxH` 时出现滚动条即判不通过）

**覆盖测试**: TBD(unit: 逐帧喂增量且 naturalHeight ≤ maxH，断言 window.height == 内容自然高度 且 scrollView 纵向不可滚动/无 vertical scroller)

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

**覆盖测试**: TBD(unit: 未写入偏好时 windowMode 读出 == .default(C))

#### Scenario: 模式选择持久化
- **GIVEN** 用户在设置中把模式从 C 改为 B
- **WHEN** 写入后重新读取（含跨实例/重启模拟）
- **THEN** 当前模式为 B，且该选择从 UserDefaults 读回一致

**覆盖测试**: TBD(unit: set(.alwaysOnTop) → 读回 == B，跨新实例仍为 B)

#### Scenario: 失焦行为随模式差分
- **GIVEN** 弹窗展开、流式进行中
- **WHEN** 弹窗失去焦点，且当前模式分别为 A / B / C
- **THEN** A：折叠为胶囊并后台续流；B：不折叠、不隐藏、保持置顶；C：不折叠，普通层级可被其他窗口遮挡

**覆盖测试**: TBD(unit: 三模式下模拟 resignKey，断言 A→collapsed、B→expanded&onTop、C→expanded&normalLevel)

#### Scenario: 窗口层级随模式差分
- **GIVEN** 弹窗显示中
- **WHEN** 当前模式分别为 A / B / C
- **THEN** B 模式弹窗（展开态与胶囊态）均置于最上层（floating / always-on-top）；A、C 模式为普通窗口层级、可被其他窗口遮挡

**覆盖测试**: TBD(unit: 断言 B 模式 window.level 为 floating 且胶囊态同级；A/C 为 normal level)

### Requirement: 折叠/展开统一交互（三模式一致）
THE SYSTEM SHALL 在 A/B/C 三种模式下提供**完全一致**的折叠/展开交互：WHEN 用户按下 Esc OR 点击隐藏图标 THE SYSTEM SHALL 将弹窗折叠为一个极简胶囊入口（不销毁窗口，进行中的流式/请求在后台继续）；WHEN 用户点击胶囊入口 THE SYSTEM SHALL 展开弹窗并**按展开当刻的实际内容重新计算尺寸**（禁止复用折叠前冻结的旧尺寸）。THE SYSTEM SHALL 令胶囊态的窗口层级跟随其所在模式（B 模式胶囊置顶，A/C 模式胶囊为普通层级）。Esc **不承担关闭语义**（关闭仅由关闭按钮/取消触发，见「关闭销毁并取消请求」）。

> 与 round1 差异：round1 里「Esc/失焦 = 全局折叠」是所有场景的默认语义；round2 将「失焦→折叠」**下沉为模式 A 专属**，而 Esc / 隐藏图标 / 点击胶囊三种手动折叠-展开动作对 A/B/C **统一**（用户拍板 `fc90708a`：「行为比较统一」）。

#### Scenario: Esc 三模式一律折叠为胶囊
- **GIVEN** 弹窗处于展开态，当前模式分别为 A / B / C
- **WHEN** 用户按下 Esc
- **THEN** 三模式均折叠为胶囊入口，不销毁窗口、不取消请求；后台流式继续

**覆盖测试**: TBD(unit: 三模式下按 Esc，断言 state==collapsed 且 currentTask 未 cancel)

#### Scenario: 隐藏图标三模式一律折叠为胶囊
- **GIVEN** 弹窗处于展开态，当前模式分别为 A / B / C
- **WHEN** 用户点击隐藏图标
- **THEN** 三模式均折叠为胶囊入口，不销毁窗口、不取消请求；后台流式继续

**覆盖测试**: TBD(unit: 三模式下触发 hideIcon action，断言 state==collapsed 且 currentTask 未 cancel)

#### Scenario: 点击胶囊展开并按当刻内容重算尺寸（Bug2）
- **GIVEN** 弹窗折叠为胶囊，折叠期间流式继续注入增量使内容增长（当前模式任一）
- **WHEN** 用户点击胶囊入口
- **THEN** 弹窗展开，尺寸按**展开当刻的实际内容**重新计算（= 当刻内容自然尺寸经同一 clamp 规则的结果），绝不复用折叠前的旧尺寸

**覆盖测试**: TBD(unit: 记折叠前尺寸 S0；折叠期间喂增量；展开后断言尺寸 == recompute(当刻内容) 且 != S0)

#### Scenario: 折叠期间后台续流
- **GIVEN** 弹窗折叠为胶囊，流式正在进行
- **WHEN** 折叠期间到达流式增量
- **THEN** 底层流式/请求继续运行、增量被应用到内容；展开后展示的是折叠期间累积的最新内容

**覆盖测试**: `Tests/LangFixTests/ReviewWindowModeTests.swift::testStateStillUpdatesWhileConceptuallyCollapsed`、TBD(unit: 折叠期间喂增量，展开后内容 == 最新累积内容)

#### Scenario: 胶囊态窗口层级跟随模式
- **GIVEN** 弹窗折叠为胶囊
- **WHEN** 当前模式分别为 B 与 A/C
- **THEN** B 模式胶囊始终置顶（可被点开）；A/C 模式胶囊为普通窗口层级

**覆盖测试**: TBD(unit: 断言胶囊 window.level：B==floating、A/C==normal)

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

**覆盖测试**: `Tests/LangFixTests/CloseSemanticsTests.swift::testEscAndResignDoNotCancel`、TBD(unit: B/C 模式按 Esc 后 currentTask 未 cancel 且窗口未销毁)

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
