<!-- doc-init template version: v1.0 -->
# ADR-0007: 语言配置与应用内 i18n 架构（含混排行为反转）

- **状态**: Proposed（随 language-config change 评审）
- **日期**: 2026-07-17
- **Owner（决策者）**: n374
- **Reviewers**: 技术方案官 + Codex（对抗式评审）
- **关联 change**: [language-config](../changes/language-config/)
- **影响 capability**: grammar-review

## 1. 上下文

LangFix 现网把用户母语写死为中文、目标语言假设为英文：prompt 硬编码「用户母语是中文」「用【中文】逐条解释」（`Prompt.swift`），结构化字段 `reason_zh`/`summary_zh`/`translation_zh` 与整套 UI 文案写死中文，多语言混排规则为「只修目标语言片段、不翻译其余」，且无语言配置与首启引导。RAS-53 讨论定稿（RAS-57 承载）：语言可配、首启强制配置、混排统一到目标语言、UI/解释随用户语言。

## 2. 决策

1. **双语言域模型**：`AppLanguage ∈ {中文, 英文}`；持久化 `userLanguage`（母语，驱动 UI 与解释/翻译）与 `targetLanguage`（被纠错语言）两个 UserDefaults 键 + `languageConfigured` 标记。**不变式：目标语言 ≠ 用户语言**，由 UI 自动翻转、读取归一化、纯函数 `LanguagePolicy` 三层保证。V1 目标语言由用户语言唯一确定，仍存双键为扩集留位。
2. **确定性默认与迁移 truth table**：locale `zh*`→(用户=中,目标=英)；`en*` 与其他→(用户=英,目标=中)；老用户升级（**存在任一 v1 持久化配置键或 Keychain API key**、且无语言键）→ 自动写入(中,英)并标记已配置、不打断；零痕迹新装 → 预填 + 首次触发前强制在设置页确认。
3. **应用内自研 L10n 表，不用系统 String Catalog**：UI 语言由应用内设置驱动而非系统 locale，系统 i18n 机制运行时覆盖需 AppleLanguages hack/重启；V1 双语言用 `L10n.Key` 枚举查表，编译期穷尽、即时切换、可单测。覆盖**全部用户可见字符串**（含追问会话提示、连接测试文案、窗口标题），以中文字符 grep 白名单核查兜底。
4. **结构化字段语言中立化**：`reason_zh`/`summary_zh`/`translation_zh`/`alternative_reason_zh` 去后缀为 `reason`/`summary`/`translation`/`alternative_reason`；解码兼容旧 `_zh` 名；**关键解释字段（issues 非空时的 reason、has_issues=true 时的 summary）新旧都缺 → fail loud**。为此新增 `ReviewError.contract` 错误类别与收口分叉：契约违规在 repair 重试与 tier 降级后**必须进错误态，禁止走「解析失败展示原文」的 fallback 成功路径**（该 fallback 仅保留给非 JSON 纯文本端点的既有兜底）。
5. **多语言混排行为反转**：由「只修目标语言片段、不翻译其余」反转为「非目标语言片段统一转写为目标语言，目标语言片段仍最小改动」。**护栏流程零改动**（editRatio → strict retry 一次 → 仍超才 `overEdited` 且始终出结果）；防 strict 轮撤销转写采取**双保险**：strict prompt 显式声明「转写不算过度改动、不得回退」+ 应用侧比较式检测 `unificationRegressed`（混排输入下，strict 相对 firstPass 非目标语言字符量显著回升即判回退）接入 ReviewEngine 两个结果采纳点，择优优先级为「换行保留 > 统一不回退 > editRatio 小」——只收紧不放松，Constraint-3 不弱化。
6. **Prompt 双模板：模板语言 = 用户语言**：中文用户模板逐字保留现网调优版（零回归）；英文用户模板为其同构英译，同构性由快照测试锚定；不做运行时输出语言校验（解释合法引用原文片段会被字符集检测误杀）。

## 3. 理由

- **正确性优先**：字段兼容 + fail loud 把「旧模型返回/回归样例解析失败或静默丢解释」这类正确性缺陷挡在解码层；混排反转不动 Constraint-3 的算法与重试，只改 prompt 语义，护栏对「过度改写」的兜底继续生效。
- **确定性可测**：语言默认、迁移、不变式全部落为纯函数与 truth table，逐行对应单测。
- **最小架构面**：不引入系统 i18n 运行时 hack、不新增 category 枚举、`DiffEngine` 零改动、`ReviewEngine` 仅两个结果采纳点接入统一回退维度（护栏触发/重试流程不动），改动集中在 prompt 双模板、解码兼容、设置存储与文案表。

## 4. 后果

- **正面**：语言能力从硬编码变为配置驱动；i18n 有了单一收口（L10n 表）；字段契约语言中立，后续扩语言不再动 JSON schema。
- **负面**：~110 处 UI 文案迁移工作量；中英双 prompt 模板需同构维护（同构性由快照测试锚定，change design D7）；混排输入 editRatio 偏高、`overEdited` 提示更常见（属预期，产品已接受）。
- **中立**：目标语言扩集（>2 语言）、转写专属 category 均列后续演进，届时按需修订本 ADR。

## 5. 备选方案

| 方案 | 优点 | 缺点 | 为什么不选 |
|---|---|---|---|
| String Catalog + AppleLanguages 覆盖 | 系统标准 | 运行时切换需重启/逐 bundle hack，UI 语言仍受系统 locale 干扰 | 需求是设置驱动、即时生效 |
| 只加目标语言、UI 保持中文 | 改动小 | 不满足「用户语言驱动 UI/解释」的已拍板需求 | 需求不符 |
| 字段保留 `_zh` 名、仅内容换语言 | 零解码改动 | 字段名与内容语言矛盾（`reason_zh` 装英文），契约撒谎 | 语义正确性 |
| 混排反转 + 转写片段豁免 editRatio | 减少 overEdited 提示 | 弱化护栏对过度改写的兜底 | 触碰 Constraint-3 红线 |

## 6. 实施

- 设计：[docs/changes/language-config/design.md](../changes/language-config/design.md)（D1–D12）。
- 验收：spec-delta（ADDED 4 + MODIFIED 4）全部 Scenario 覆盖测试 + 既有测试全绿。

## 7. 修订历史

| 日期 | 状态变更 | 摘要 |
|---|---|---|
| 2026-07-17 | → Proposed | 随 language-config 设计阶段创建 |
