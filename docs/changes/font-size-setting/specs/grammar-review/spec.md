<!-- doc-init template version: v1.0 -->
# Capability Delta: grammar-review

- **Change**: font-size-setting
- **Owner**: by 需求官 on behalf of wu.nerd
- **基于 living spec 版本**: 2026-06-29（初始化）+ ai-followup change（待归档）

> 本 change 在 grammar-review 上 ADDED 2 条 Requirement（字号配置 / 字号即时生效与窗口自适应联动）。
> 「覆盖测试」用 `TBD(<描述>)` 占位，落地实现并归档前由 MR 阶段替换为真实路径。
> HOW（档位取值、预设 vs 滑块、统一字体来源实现）归技术方案阶段。

## ADDED Requirements

### Requirement: 字号配置
THE SYSTEM SHALL 在设置页提供「字号」配置项，其值写入 UserDefaults（非敏感，不进 Keychain）；默认档位使结果浮窗正文字号**大于本 change 前结果正文的基准字号**（以现状正文字体角色 / pt 为基准锚点，具体档位值归技术方案阶段）。

#### Scenario: 默认大于旧正文基准
- **GIVEN** 全新安装、用户未改动字号设置
- **WHEN** 渲染结果浮窗正文
- **THEN** 正文字号严格大于本 change 前的正文基准字号（以基准锚点断言，不依赖具体 pt 硬值）

**覆盖测试**: `Tests/LangFixTests/ReviewTypographyTests.swift` — `testDefaultTierIsLargeWhenAbsent`（register 默认 → 未设置时档位 = 大）、`testDefaultTierBodyExceedsLegacyBaseline`（默认档正文 > `ReviewTypography.legacyBodyBaseline`）

#### Scenario: 用户调整并持久化
- **GIVEN** 用户在设置中改字号
- **WHEN** 保存后重启 App
- **THEN** 新字号档位被持久化并生效

**覆盖测试**: `Tests/LangFixTests/ReviewTypographyTests.swift` — `testTierPersistsAcrossReload`（独立 suite 写 rawValue → 重读还原）、`testInvalidRawValueFallsBackToLarge`（非法 rawValue fallback 默认）

### Requirement: 字号即时生效与窗口自适应联动
WHEN 用户变更字号配置 THE SYSTEM SHALL 使结果浮窗文本区（修正结果 / 词级 diff / issue 卡片 / 追问气泡 / 总评 / 直译等）按新字号缩放，并触发一次窗口重测量；WHERE 放大后自然内容高度超过 `maxH` THE SYSTEM SHALL 维持既有封顶行为（高度封顶 `maxH`、中部滚动、底栏固定），不超出屏幕。

> 需求层只要求「字号变更触发一次生产路径的窗口自适应测量」，保持既有封顶行为（`maxH` 封顶 / 中部滚动 / 底栏固定）不被破坏；不改窗口尺寸 clamp 数学。复用哪条测量链路（RAS-53 已建）属技术方案阶段。

#### Scenario: 调大字号文本随之缩放
- **GIVEN** 结果浮窗已展示
- **WHEN** 用户把字号调大
- **THEN** 结果 / issue / 追问气泡等文本字号随之增大

**覆盖测试**: `Tests/LangFixTests/ReviewTypographyTests.swift` — `testXLargeLongContentMeasuresTallerAndCapsAtMaxH`（同一内容 xLarge 档测量自然高显著大于 standard，即文本区随档位缩放的可测代理）+ 4 档手动走查（design §7-6）

#### Scenario: 大字号 + 长内容仍封顶不超屏
- **GIVEN** 字号调至最大档、内容自然高度超过 `maxH`
- **WHEN** 窗口重测量
- **THEN** `isOverflowing==true`、窗口内容高度封顶 `==maxH`、中部滚动、底栏固定，窗口不超屏

**覆盖测试**: `Tests/LangFixTests/ReviewTypographyTests.swift` — `testFontTierChangeTriggersRemeasureAndCapsViaProductionPath`（生产订阅链路：改 `reviewFontTierRaw` → 泵 runloop → 断言自然高变大、`isOverflowing` 翻转、内容高封顶 `==maxH`）、`testXLargeLongContentMeasuresTallerAndCapsAtMaxH`（测量路径 + sizing 封顶判定）

## MODIFIED Requirements

无（字号是新增配置，不改既有展示契约的语义，仅参数化字号来源）。

## REMOVED Requirements

无。

## 关联

- 现状 Living spec: [../../../../specs/grammar-review/spec.md](../../../../specs/grammar-review/spec.md)
- 关联窗口自适应: RAS-53 修复（`ReviewWindowController` 订阅 `followUp.objectWillChange → refreshMeasurement`）、`ReviewWindowSizing`（`maxH` 封顶 + `isOverflowing`）
- 关联 change: [language-config](../../../language-config/)（文件重叠，串行开发，见 proposal §5）
