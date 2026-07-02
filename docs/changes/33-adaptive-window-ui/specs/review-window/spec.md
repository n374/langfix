<!-- doc-init template version: v1.0 -->
# Capability Delta: review-window

- **Change**: 33-adaptive-window-ui
- **Owner**: by 需求官 on behalf of wu.nerd
- **基于 living spec 版本**: 新建（review-window 首个 change，archive 时创建 `docs/specs/review-window/spec.md`）

> `review-window` 为本 change 新建 capability（弹窗容器/交互/视觉外壳，与 grammar-review 纠错逻辑正交）。若 Reviewer 决定沿用单 capability，可平移回 grammar-review（见 proposal §6 D0）。
> 「覆盖测试」用 `TBD(<描述>)` 占位，落地实现并归档前由 MR 阶段替换为真实路径。
> 本 change 不触碰 constitution 4 条红线（密钥/日志/最小改动/不改原选区）。

## ADDED Requirements

### Requirement: 弹窗高度随内容自适应
THE SYSTEM SHALL 固定弹窗宽度，并令弹窗高度等于当前内容的自然高度，且 clamp 到 `[minH, maxH]`——其中 `minH` 为容纳标题栏与首行状态的内容自然高度，`maxH = 弹窗所在屏幕 visibleFrame 高度 × 固定比例`；内容超过 `maxH` 时在内容区内部滚动。

> 约束：`maxH` **必须以屏幕相对高度计算**（不得用固定像素上限），使不同分辨率下上限比例一致。需求官建议比例 = 0.7，最终值由设计/用户确认。

#### Scenario: 短内容出小窗
- **GIVEN** 弹窗展示的内容仅一行修正结果（自然高度 < `maxH`）
- **WHEN** 弹窗渲染完成
- **THEN** 弹窗高度贴合内容自然高度（接近 `minH`），不撑到固定满高、无大量留白

**覆盖测试**: `TBD(短内容渲染后窗口高度接近内容自然高度且 ≤ maxH)`

#### Scenario: 流式增高到屏幕相对上限后滚动
- **GIVEN** 流式逐字产出内容，自然高度持续增长
- **WHEN** 内容自然高度超过 `maxH`（= 所在屏 visibleFrame 高度 × 比例）
- **THEN** 弹窗高度封顶为 `maxH`，超出部分由内容区内部滚动承载；封顶前高度随内容单调增

**覆盖测试**: `TBD(给定内容行数与屏幕 visibleFrame 断言高度 = clamp(内容自然高度, minH, visibleFrame.height×比例))`、`TBD(内容增长时高度单调不减)`

#### Scenario: 上限随分辨率按比例缩放
- **GIVEN** 两个不同分辨率/尺寸的屏幕
- **WHEN** 在各自屏幕上撑满内容触发封顶
- **THEN** 两者的 `maxH` 均为「该屏 visibleFrame 高度 × 同一固定比例」，而非同一固定像素

**覆盖测试**: `TBD(mock 两种 visibleFrame 断言 maxH 按比例而非固定 px)`

### Requirement: 三态窗体与失焦折叠
THE SYSTEM SHALL 维护弹窗的三种态——`展开` / `折叠` / `关闭`；WHEN 弹窗失去焦点 OR 用户按下 Esc THE SYSTEM SHALL 将弹窗折叠为一个极简入口（不销毁窗口，进行中的流式/请求在后台继续），而非关闭。

#### Scenario: 失焦折叠且后台继续
- **GIVEN** 弹窗处于展开态，流式正在进行
- **WHEN** 弹窗失去焦点（用户点到别处）
- **THEN** 弹窗折叠为极简入口、不销毁；底层流式/请求继续运行，折叠期间到达的增量被应用到内容

**覆盖测试**: `TBD(失焦后窗口未销毁且底层 Task 未取消)`、`TBD(折叠期间喂增量展开后内容为最新)`

#### Scenario: Esc 等同失焦
- **GIVEN** 弹窗处于展开态
- **WHEN** 用户按下 Esc
- **THEN** 弹窗折叠（与失焦一致），不关闭、不取消请求

**覆盖测试**: `TBD(Esc 触发折叠而非 close，底层 Task 未取消)`

#### Scenario: 点击入口展开恢复
- **GIVEN** 弹窗处于折叠态
- **WHEN** 用户点击折叠入口
- **THEN** 弹窗展开恢复，展示折叠期间累积的最新内容

**覆盖测试**: `TBD(点击折叠入口后回到展开态且内容为最新)`

### Requirement: 关闭销毁并取消请求
WHEN 用户触发关闭（关闭按钮或取消）THE SYSTEM SHALL 销毁弹窗并取消进行中的 AI 请求（cancel 底层 Task），使关闭后无后台请求继续运行。

#### Scenario: 关闭取消在途请求
- **GIVEN** 弹窗展开或折叠，流式请求在途
- **WHEN** 用户点击关闭按钮
- **THEN** 弹窗销毁，底层 `currentTask` 被 cancel，无后台请求继续

**覆盖测试**: `TBD(关闭后断言底层 Task.isCancelled 且窗口已销毁)`

### Requirement: 折叠态状态可视化
WHILE 弹窗处于折叠态 THE SYSTEM SHALL 以可区分的颜色与图标表达当前阶段——`进行中`（loading / streaming）、`已完成`（result）、`出错`（error）——三态互不相同，并以极简动画呈现状态与折叠/展开的过渡。

#### Scenario: 进行中与完成的视觉区分
- **GIVEN** 弹窗折叠，流式进行中
- **WHEN** 流式完成进入 result 态
- **THEN** 折叠入口的颜色/图标由「进行中」标识切换为「已完成」标识，二者可区分，切换走极简动画

**覆盖测试**: `TBD(进行中/已完成映射到不同视觉标识)`

#### Scenario: 出错态可辨识
- **GIVEN** 弹窗折叠
- **WHEN** 底层进入 error 态
- **THEN** 折叠入口显示与「进行中/已完成」均不同的「出错」标识

**覆盖测试**: `TBD(error 态折叠标识区别于其余两态)`

### Requirement: 视觉主题可选
THE SYSTEM SHALL 提供不少于两套体现「科幻/艺术感」的视觉主题，在设置中可切换、切换即时生效，并有一个默认主题；主题选择作为非敏感偏好持久化到 UserDefaults（不进 Keychain）。

> 具体主题集合、配色、材质、图标与动效细节由下游 Codex 设计定稿（用户已授权「以 Codex 最终设计为准」）；本 Requirement 只约束「多主题可选 + 可切换 + 有默认 + 持久化位置」。

#### Scenario: 切换主题即时生效
- **GIVEN** 存在 ≥2 套主题，当前为默认主题
- **WHEN** 用户在设置中切换到另一主题
- **THEN** 弹窗视觉即时切换为所选主题，且该选择被持久化到 UserDefaults，下次启动仍生效

**覆盖测试**: `TBD(切换主题后当前主题标识变化并持久化)`

#### Scenario: 默认主题
- **GIVEN** 全新安装、用户未改动主题设置
- **WHEN** 读取当前主题
- **THEN** 为设计指定的默认主题

**覆盖测试**: `TBD(未设置时主题为默认值)`

### Requirement: 取消手动 resize
THE SYSTEM SHALL 移除弹窗的手动缩放能力，弹窗尺寸完全由内容与流式自动决定，用户不可手动拉伸窗口。

#### Scenario: 无手动缩放
- **GIVEN** 弹窗显示中
- **WHEN** 用户尝试拖拽窗口边缘缩放
- **THEN** 窗口不响应手动缩放（styleMask 不含 `.resizable`），尺寸仍由内容/流式驱动

**覆盖测试**: `TBD(窗口 styleMask 不含 .resizable)`
