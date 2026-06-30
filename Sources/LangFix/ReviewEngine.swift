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

        // 短句豁免：短消息一个必要替换比例天然高，按比例拦截会误伤。
        let exempt = s0.origWords < cfg.minWordsForGuard || s0.editedWords <= cfg.minAbsEdits
        guard !exempt, s0.ratio > cfg.diffThreshold else {
            return result
        }

        // 超阈值 → 严格重试一次。
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

        if s1.ratio <= cfg.diffThreshold {
            return strict
        }
        // 两轮都超阈值 → 取改动较小的一版，并标记 overEdited（不阻断出结果）。
        result = (s1.ratio < s0.ratio) ? strict : result
        result.overEdited = true
        return result
    }

    /// 流式版：流式 firstPass（增量 preview）+ 既有护栏定稿。护栏算法与 `review` 完全一致，
    /// 唯一差异是 firstPass 走 `client.reviewStreaming` 以驱动「预览→定稿」。strict 轮**不流式**
    /// （冻结预览、切 .finalizing 后走既有非流式），避免双打字机交叉闪烁（design D5）。
    func reviewStreaming(text localInput: String, config cfg: AppConfig,
                         onPreview: @MainActor @Sendable (StreamingPreview) async -> Void) async throws -> ReviewResult {
        var result = try await client.reviewStreaming(text: localInput, config: cfg, mode: .firstPass, onPreview: onPreview)

        let s0 = DiffEngine.editStats(orig: localInput, corrected: result.corrected)
        let exempt = s0.origWords < cfg.minWordsForGuard || s0.editedWords <= cfg.minAbsEdits
        guard !exempt, s0.ratio > cfg.diffThreshold else {
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
        if s1.ratio <= cfg.diffThreshold {
            return strict
        }
        result = (s1.ratio < s0.ratio) ? strict : result
        result.overEdited = true
        return result
    }
}
