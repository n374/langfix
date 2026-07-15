import Foundation

/// 编排 AIClient + 最小改动护栏（短句豁免 / 超阈值 strict 重试 / 取较小改动版 / overEdited）。
/// 参见 docs/architecture/modules/ai-client.md §5 与 docs/decisions/0004-minimal-edit-guard.md。
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
        // 触发 strict 重试：改动超阈（非豁免）**或** 换行结构被破坏（多行输入被合并/删空行，Adj2/Adj3 闭环）。
        guard (!exempt && s0.ratio > cfg.diffThreshold) || lostNL0 else {
            return result
        }

        // 超阈值 / 换行被破坏 → 严格重试一次（strict 明确要求逐字保留，含换行）。
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

        // strict 达标：改动回落阈值内 **且** 未破坏换行结构 → 采用 strict。
        if s1.ratio <= cfg.diffThreshold && !lostNL1 {
            return strict
        }
        // 否则取更优的一版并 overEdited 警示（不阻断出结果、不静默把结构违规当干净结果）：
        // 换行保真优先于改动比例——谁保住换行选谁；都保/都丢则按改动小的选。
        result = Self.pickBetter(first: result, firstRatio: s0.ratio, firstLostNL: lostNL0,
                                 strict: strict, strictRatio: s1.ratio, strictLostNL: lostNL1)
        result.overEdited = true
        return result
    }

    /// 换行结构是否被破坏：原文含换行、而 corrected 的换行数**变少**（合并成一行 / 删空行）。
    /// 纯计数启发式，用于「多行输入被规范化」的闭环检测（Adj2/Adj3）。原文无换行则恒 false。
    /// 两侧都先规范化换行（CRLF/CR/U+2028/U+2029→LF），使模型返回 CRLF 等异体换行时也能正确比对（评审复审）。
    static func collapsedNewlines(orig: String, corrected: String) -> Bool {
        let o = orig.normalizedLineEndings.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        guard o > 0 else { return false }
        let c = corrected.normalizedLineEndings.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return c < o
    }

    /// 在 firstPass 与 strict 两版里选更优：**保留换行**优先，其次改动比例更小。
    static func pickBetter(first: ReviewResult, firstRatio: Double, firstLostNL: Bool,
                           strict: ReviewResult, strictRatio: Double, strictLostNL: Bool) -> ReviewResult {
        if firstLostNL != strictLostNL { return strictLostNL ? first : strict }   // 谁没丢换行选谁
        return strictRatio < firstRatio ? strict : first                          // 都保/都丢 → 改动小的
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
        // 触发 strict：改动超阈（非豁免）或 换行结构被破坏（Adj2/Adj3 闭环，同 review）。
        guard (!exempt && s0.ratio > cfg.diffThreshold) || lostNL0 else {
            return result
        }

        // 护栏触发 → 冻结预览第一版为 .finalizing，再走既有非流式 strict。
        await onPreview(StreamingPreview(corrected: result.corrected, summaryZh: result.summaryZh,
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
        if s1.ratio <= cfg.diffThreshold && !lostNL1 {
            return strict
        }
        result = Self.pickBetter(first: result, firstRatio: s0.ratio, firstLostNL: lostNL0,
                                 strict: strict, strictRatio: s1.ratio, strictLostNL: lostNL1)
        result.overEdited = true
        return result
    }
}
