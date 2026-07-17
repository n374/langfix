import Foundation

/// 编排 AIClient + 最小改动护栏（短句豁免 / 超阈值 strict 重试 / 取较小改动版 / overEdited）。
/// 参见 docs/architecture/modules/ai-client.md §5 与 docs/decisions/0004-minimal-edit-guard.md。
///
/// **language-config design D8/D9**：护栏**流程**零改动（触发条件 / strict 重试一次 / 始终出结果全部原样）；
/// 唯一变化是两个**结果采纳点**接入「混排统一回退检测」——拒绝采纳撤销了混排转写的 strict 版
///（择优优先级：换行保留 > 统一不回退 > ratio 小），方向上只会更严，Constraint-3 不弱化。
final class ReviewEngine: Sendable {

    private let client: ReviewProviding
    init(client: ReviewProviding = AIClient()) { self.client = client }

    /// 输入边界校验 + 配置完整性校验在调用前由 Controller 完成；此处专注 AI + 护栏。
    func review(text localInput: String, config cfg: AppConfig) async throws -> ReviewResult {
        var result = try await client.review(text: localInput, config: cfg, mode: .firstPass)

        let s0 = DiffEngine.editStats(orig: localInput, corrected: result.corrected)
        let lostNL0 = Self.collapsedNewlines(orig: localInput, corrected: result.corrected)

        // 短句豁免：短消息一个必要替换比例天然高，按比例拦截会误伤。
        let exempt = s0.origWords < cfg.minWordsForGuard || s0.editedWords <= cfg.minAbsEdits
        // 触发 strict 重试：改动超阈（非豁免）**或** 内容换行丢失（多行内容被合并成更少行，Adj2/Adj3 闭环；空行收缩不算）。
        guard (!exempt && s0.ratio > cfg.diffThreshold) || lostNL0 else {
            return result
        }

        // 超阈值 / 换行被破坏 → 严格重试一次（strict 明确要求逐字保留，含换行；混排转写不得回退）。
        let strict: ReviewResult
        do {
            strict = try await client.review(text: localInput, config: cfg, mode: .strict)
        } catch {
            // D6（用户拍板选项 A，统一硬化）：strict 请求自身 throw（网络失败等）时，
            // 按「护栏不阻断出结果」定稿 firstPass + overEdited，而非把错误抛给用户。
            // 仅兜底 strict-throw 路径；firstPass 的错误仍正常上抛。取消语义不吞。
            if case ReviewError.cancelled = error { throw error }
            result.overEdited = true
            return result
        }
        let s1 = DiffEngine.editStats(orig: localInput, corrected: strict.corrected)
        let lostNL1 = Self.collapsedNewlines(orig: localInput, corrected: strict.corrected)
        return Self.finalize(first: result, s0: s0.ratio, lostNL0: lostNL0,
                             strict: strict, s1: s1.ratio, lostNL1: lostNL1,
                             input: localInput, cfg: cfg)
    }

    /// 结果采纳（review / reviewStreaming 共用同一份逻辑，杜绝两份漂移；language-config design D8/D9）：
    /// strict 干净达标（回落阈内 + 换行完好 + 未回退混排统一）→ 采用 strict；否则按
    /// 「换行保留 > 统一不回退 > ratio 小」择优，并落 overEdited 不变式（评审 R2-3）：
    /// **最终采纳候选超阈 ∨ 换行破坏 ⇒ overEdited=true 恒成立**，绝不静默展示大改写结果。
    static func finalize(first: ReviewResult, s0: Double, lostNL0: Bool,
                         strict: ReviewResult, s1: Double, lostNL1: Bool,
                         input: String, cfg: AppConfig) -> ReviewResult {
        let regressed = unificationRegressed(input: input, first: first.corrected,
                                             strict: strict.corrected, target: cfg.targetLanguage)
        if s1 <= cfg.diffThreshold && !lostNL1 && !regressed {
            return strict
        }
        let useStrict = pickStrict(firstRatio: s0, firstLostNL: lostNL0,
                                   strictRatio: s1, strictLostNL: lostNL1,
                                   strictUnificationRegressed: regressed)
        var result = useStrict ? strict : first
        result.overEdited = (useStrict ? s1 : s0) > cfg.diffThreshold || (useStrict ? lostNL1 : lostNL0)
        return result
    }

    /// 「内容换行」是否丢失：corrected 的**非空内容行数**比原文变少（两处内容被并到同一行）。
    /// 用于闭环检测「多行内容被合并成更少行」（Adj2/Adj3）。原文只有 ≤1 行内容则无从丢失，恒 false。
    ///
    /// **验收标准（用户 2026-07-16 明确）**：
    /// - ✅ **内容换行必须保留**：分隔两处内容的换行不得被合并 → 非空行数下降即判破坏，触发 strict / `overEdited`。
    /// - ✅ **多个空行合并成单行可接受**：连续空行被压缩**不**算破坏（`a\n\n\nb → a\nb` 非空行数不变 → 不报警）。
    ///
    /// **只数非空内容行（单一指标，结构性免疫补偿绕过）**：先规范化换行（CRLF/CR/U+2028/U+2029→LF），
    /// 空行不计入。故「合并两行 + 末尾/别处补空行」无法用「补空行」抬高非空行数来抵消绕过——补的都是空行。
    /// 即便词 token 不变（`editedWords=0`、ratio=0、短句豁免）、纯换行改动，只要内容行被合并也能检出
    /// （配合护栏触发条件 `|| lostNL0` 无视豁免与 ratio）。
    ///
    /// **已知残留（诚实标注，非隐藏取舍）**：**行数不变的断行位置重排**（如 `a\n(b c)`→`(a b)\nc`：
    /// 非空行数仍为 2、仅断点平移）任何行数/计数指标都无法区分——要检测须按内容对齐（模型同时改词时判哪个词属哪行），
    /// 而内容对齐会误判**合法的逐行最小改动**为违规。用户已知悉此残留并选择接受「非空行数」方案（覆盖实际场景）。
    static func collapsedNewlines(orig: String, corrected: String) -> Bool {
        let o = nonEmptyLineCount(orig)
        guard o > 1 else { return false }   // ≤1 行内容 → 无内容换行可丢
        return nonEmptyLineCount(corrected) < o
    }

    /// 非空内容行数：规范化换行 → 按 `\n` 切行 → 数 trim 后非空的行（空行不计，故补空行无法抬高此指标）。
    static func nonEmptyLineCount(_ s: String) -> Int {
        s.normalizedLineEndings
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $1.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : $0 + 1 }
    }

    /// 择优决策（纯函数）：是否选 strict。优先级：**换行保留 > 统一不回退 > ratio 小**（design D8）。
    static func pickStrict(firstRatio: Double, firstLostNL: Bool,
                           strictRatio: Double, strictLostNL: Bool,
                           strictUnificationRegressed: Bool) -> Bool {
        if firstLostNL != strictLostNL { return firstLostNL }        // 谁没丢换行选谁
        if strictUnificationRegressed { return false }               // strict 回退混排统一 → 选 first
        return strictRatio < firstRatio                              // 都保/都丢 → 改动小的
    }

    /// 在 firstPass 与 strict 两版里选更优（含统一回退维度，design D8）。
    static func pickBetter(first: ReviewResult, firstRatio: Double, firstLostNL: Bool,
                           strict: ReviewResult, strictRatio: Double, strictLostNL: Bool,
                           strictUnificationRegressed: Bool = false) -> ReviewResult {
        pickStrict(firstRatio: firstRatio, firstLostNL: firstLostNL,
                   strictRatio: strictRatio, strictLostNL: strictLostNL,
                   strictUnificationRegressed: strictUnificationRegressed) ? strict : first
    }

    // MARK: - 混排统一回退检测（language-config design D8，比较式纯函数）

    /// CJK 统一表意区（基本区 + 扩展 A）字符数。
    static func cjkCount(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) {
            (0x4E00...0x9FFF).contains($1.value) || (0x3400...0x4DBF).contains($1.value) ? $0 + 1 : $0
        }
    }

    /// ASCII 字母（A-Za-z）字符数。
    static func asciiLetterCount(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) {
            (0x41...0x5A).contains($1.value) || (0x61...0x7A).contains($1.value) ? $0 + 1 : $0
        }
    }

    /// 非目标语言字符量 n(s)（评审 R2-5 定标口径）：target=en 数 CJK 统一表意字符；target=zh 数 ASCII 字母。
    static func nonTargetCount(_ s: String, target: AppLanguage) -> Int {
        target == .english ? cjkCount(s) : asciiLetterCount(s)
    }

    /// strict 是否**回退了混排统一**（评审 R1-2/R2-5）。比较式检测（两候选相对比较、非绝对语言判断），
    /// 天然规避专有名词/代码/URL 合法保留的误判——两版对它们处理一致时字符量差在容差内。
    ///
    /// - 激活条件：input（本地真实输入）同时含 ≥2 个 CJK 统一表意字符与 ≥2 个 ASCII 字母才视为混排、
    ///   启用检测；否则恒 false（单语言输入零影响）。
    /// - 判定（默认容差，fixture 标定可调，属**正确性参数**、改动须过测试）：
    ///   regressed ⇔ n(strict) - n(first) > max(2, ⌈0.2 × n(input)⌉)
    ///   即 strict 相对 firstPass 的非目标字符回升超过「2 个字符与输入混排量 20% 的较大者」。
    static func unificationRegressed(input: String, first: String, strict: String, target: AppLanguage) -> Bool {
        guard cjkCount(input) >= 2, asciiLetterCount(input) >= 2 else { return false }
        let nInput = nonTargetCount(input, target: target)
        let tolerance = max(2, Int((0.2 * Double(nInput)).rounded(.up)))
        return nonTargetCount(strict, target: target) - nonTargetCount(first, target: target) > tolerance
    }

    /// 流式版：流式 firstPass（增量 preview）+ 既有护栏定稿。护栏算法与 `review` 完全一致，
    /// 唯一差异是 firstPass 走 `client.reviewStreaming` 以驱动「预览→定稿」。strict 轮**不流式**
    /// （冻结预览、切 .finalizing 后走既有非流式），避免双打字机交叉闪烁（design D5）。
    func reviewStreaming(text localInput: String, config cfg: AppConfig,
                         onPreview: @MainActor @Sendable (StreamingPreview) async -> Void) async throws -> ReviewResult {
        var result = try await client.reviewStreaming(text: localInput, config: cfg, mode: .firstPass, onPreview: onPreview)

        let s0 = DiffEngine.editStats(orig: localInput, corrected: result.corrected)
        let lostNL0 = Self.collapsedNewlines(orig: localInput, corrected: result.corrected)
        let exempt = s0.origWords < cfg.minWordsForGuard || s0.editedWords <= cfg.minAbsEdits
        // 触发 strict：改动超阈（非豁免）或 内容换行丢失（内容行被合并，Adj2/Adj3 闭环，同 review；空行收缩不算）。
        guard (!exempt && s0.ratio > cfg.diffThreshold) || lostNL0 else {
            return result
        }

        // 护栏触发 → 冻结预览第一版为 .finalizing，再走既有非流式 strict。
        await onPreview(StreamingPreview(corrected: result.corrected, summary: result.summary,
                                         issues: result.issues, alternative: result.alternative, stage: .finalizing))
        let strict: ReviewResult
        do {
            strict = try await client.review(text: localInput, config: cfg, mode: .strict)
        } catch {
            // D6 统一兜底（同 review）。
            if case ReviewError.cancelled = error { throw error }
            result.overEdited = true
            return result
        }
        let s1 = DiffEngine.editStats(orig: localInput, corrected: strict.corrected)
        let lostNL1 = Self.collapsedNewlines(orig: localInput, corrected: strict.corrected)
        return Self.finalize(first: result, s0: s0.ratio, lostNL0: lostNL0,
                             strict: strict, s1: s1.ratio, lostNL1: lostNL1,
                             input: localInput, cfg: cfg)
    }
}
