import Foundation

/// 编排 AIClient + 最小改动护栏（短句豁免 / 超阈值 strict 重试 / 取较小改动版 / overEdited）。
/// 参见 docs/architecture/modules/ai-client.md §5 与 docs/decisions/0004-minimal-edit-guard.md。
final class ReviewEngine {

    private let client: AIClient
    init(client: AIClient = AIClient()) { self.client = client }

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
        let strict = try await client.review(text: localInput, config: cfg, mode: .strict)
        let s1 = DiffEngine.editStats(orig: localInput, corrected: strict.corrected)

        if s1.ratio <= cfg.diffThreshold {
            return strict
        }
        // 两轮都超阈值 → 取改动较小的一版，并标记 overEdited（不阻断出结果）。
        result = (s1.ratio < s0.ratio) ? strict : result
        result.overEdited = true
        return result
    }
}
