<!-- doc-init template version: v1.0 -->
# Proposal: font-size-setting

- **Owner**: by 需求官 on behalf of wu.nerd
- **Reviewers**: wu.nerd、技术方案官
- **创建日期**: 2026-07-16
- **状态**: Approved（用户已确认「按推荐来」）
- **关联 Issue**: RAS-54（从 RAS-53 讨论拆出）
- **共享分支**: `feat/font-size-setting`（基于 `feat/53-ai-followup`）
- **设计者**: 技术方案官（Claude / Fable）；交互细节由其设计，Codex 作对抗式评审

## 1. Why（动机）

当前结果浮窗各处字号**硬编码散落**（`.body`/`.caption`/`.callout` 与多个 `.system(size:)`，11–13pt，见 `ReviewView.swift` 多处），无统一字体来源，也无用户可调字号。用户反馈**默认字号偏小**，希望「调大一号」并能在设置中自行调节。

期望状态：① 默认字号比现状大一档；② 设置页新增「字号」选项，用户可调，改动即时生效于结果浮窗（修正结果 / 追问气泡 / issue 卡片 / diff 等文本区）。

## 2. What's Changing（高层变更）

| Capability | 变化类型 | 简述 |
|---|---|---|
| grammar-review | ADDED | 「字号配置」：设置页新增用户可调字号档位，写入 UserDefaults（非敏感），默认比现状大一档 |
| grammar-review | ADDED | 「字号即时生效与窗口自适应联动」：字号变更后结果浮窗文本随之缩放，并触发既有窗口重测量（`maxH` 封顶 + 溢出滚动兜住变高内容） |

**新增 capability**：无。

## 3. Out of Scope（明确不做）

- **不做全 App 逐控件独立字号**：字号是一个统一档位/缩放，作用于结果浮窗文本区；不为每个控件单独设字号。
- **不改窗口尺寸 clamp 数学**（`ReviewWindowSizing`）：字号变大→内容变高，由既有 `maxH` 封顶 + 溢出内部滚动兜住（RAS-53 已修复嵌套会话驱动重测量）；本 change 只需保证**字号变更也触发一次重测量**。
- **不定档位具体取值与交互形态**（预设档 vs 滑块、档数、各档 pt 值）——归技术方案阶段（HOW）。
- **不做 i18n/语言**（属 RAS-55）。
- **不写代码**：本阶段只产出 proposal + spec-delta。

## 4. Success Metrics（成功指标）

- **默认变大**：全新安装默认字号档位高于现状一档（确定性可测：读默认值断言 > 旧基准）。
- **可调即时生效**：改字号设置后，结果浮窗文本字号随之变化（确定性可测：改设置 → 断言文本字号缩放）。
- **不破窗口封顶**：字号调到最大档、内容超屏时，窗口高度仍封顶 `maxH`、中部滚动、底栏固定，不超屏（确定性可测：大字号 + 长内容 → 断言 `isOverflowing==true` 且内容高 `==maxH`）。

## 5. 依赖与排期约束

- 🔴 **依赖 PR #4 合并**：本分支基于 `feat/53-ai-followup`（含 ai-followup 全部代码，字号需作用于追问气泡等新 UI）。**开发阶段前须先合并 PR #4 到 master**，否则本分支 PR 会带上 ai-followup 提交。设计阶段（技术方案官）可先行，与合并无关。
- ⚠️ **与 RAS-55（语言/i18n）文件重叠、须串行开发**：两者都改 `SettingsStore`/`SettingsView`/`ReviewView`。**推荐 RAS-54 先合并**（小、低风险），RAS-55 在其之上 rebase；避免并行开发冲突。

## 6. 风险

| 风险 | 可能性 | 影响 | 缓解 |
|---|---|---|---|
| 字号变更未触发窗口重测量，导致内容溢出不封顶 | 中 | 中 | spec 明确「字号变更触发重测量」；复用 RAS-53 已建的 `refreshMeasurement` 链路 + 回归用例 |
| 与 RAS-55 并行开发冲突（同改 Settings/ReviewView） | 中 | 中 | §5 串行约束：RAS-54 先合、RAS-55 后 rebase |
| 硬编码字号点遗漏，部分文本不随档位缩放 | 中 | 低 | 设计阶段收敛为统一字体来源（缩放基准），逐点接入 |

## 7. 关联资源

- spec-delta：[specs/grammar-review/spec.md](./specs/grammar-review/spec.md)
- 现状 Living spec：[../../specs/grammar-review/spec.md](../../specs/grammar-review/spec.md)
- 关联 Issue：RAS-53（AI 追问，PR #4）、RAS-55（语言配置/i18n）
