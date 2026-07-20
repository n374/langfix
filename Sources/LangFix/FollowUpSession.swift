import Foundation

/// 追问会话状态机（ai-followup change · design D2/D3/D4/D5/D6）。
///
/// **归属**：挂在 `ReviewState.followUp`，随 ReviewState 生命周期自然清理（关窗/新纠错即随 state 释放）。
/// **红线**：
/// - 隐私（Constraint-2 / design D7）：只存易失内存；不持有 apiKey（评审#5，只持 key-free 快照，发请求瞬取 Keychain）。
/// - 取消隔离（design D3）：`askGeneration` + `isClosed` 做屏障；`cancelInFlight` 原子推代次 + 清 streaming + cancel。
/// - 护栏（Constraint-3 / design D6）：回答**永不写回** result；应用层输出护栏拦「整段替代全文」。
/// - 上下文预算（design D5）：base（原文+完整带序号修正+当前问题）恒保留，仅裁剪非关键历史，放不下 fail loud。
@MainActor
final class FollowUpSession: ObservableObject {

    enum CancelReason { case userStop, sessionEnd }

    /// 定稿结果（追问上下文来源；追问**绝不**改它 —— design D6 ① 硬保证）。
    let boundResult: ReviewResult
    /// 原文（= boundResult.original，冗余持有便于组装）。
    let original: String
    /// 不含密钥的配置快照（评审#5）。
    let configSnapshot: FollowUpConfigSnapshot

    /// 已成功完成的问答轮（进入历史）。取消/失败轮**不入**此列表（design D3）。
    @Published private(set) var turns: [FollowUpTurn] = []
    /// 当前在途一轮（receiving/finalizing）或失败轮（failed）。取消/关窗即丢弃。
    @Published private(set) var streaming: StreamingAnswer?
    /// composer 上沿即时提示（引用越界 / 硬超预算），不发请求（design UI-6 / D4 / D5）。
    @Published private(set) var composerNotice: String?

    /// 追问代次（每次发问自增）：delta/完成/错误回调仅当 `askGeneration == myAsk` 才应用（design D3）。
    private(set) var askGeneration = 0
    /// 会话是否已终结（sessionEnd 后置位）：置位后 ask 一律拒绝、在途回调 guard 失败丢弃。
    private(set) var isClosed = false
    private var inFlightTask: Task<Void, Never>?

    private let provider: FollowUpProviding
    /// 发请求瞬取 API key（默认 Keychain；测试可注入）。
    private let keyProvider: @Sendable () -> String?

    init(boundResult: ReviewResult,
         configSnapshot: FollowUpConfigSnapshot,
         provider: FollowUpProviding = AIClient(),
         keyProvider: @escaping @Sendable () -> String? = { KeychainStore.apiKey() }) {
        self.boundResult = boundResult
        self.original = boundResult.original
        self.configSnapshot = configSnapshot
        self.provider = provider
        self.keyProvider = keyProvider
    }

    /// 完整带序号的修正清单（与 UI「修正 N」同源 —— design D1；序号来源 = ReviewResult.numberedIssues 单一解析）。
    var numberedIssues: [FollowUpContext.NumberedIssue] {
        boundResult.numberedIssues.map { (idx, issue) in
            FollowUpContext.NumberedIssue(
                index: idx, before: issue.before, after: issue.after,
                category: issue.category.rawValue, severity: issue.severity.rawValue,
                reason: issue.reason)
        }
    }

    var isBusy: Bool { streaming?.stage == .receiving || streaming?.stage == .finalizing }

    // MARK: - 发问

    /// 发起一轮追问：本地校验引用序号（越界不调 AI）→ 预算裁剪/fail loud → 流式请求。
    func ask(_ raw: String) {
        guard !isClosed else { return }
        composerNotice = nil
        let question = raw.trimmed
        guard !question.isEmpty else { return }
        guard !isBusy else { return }   // 一次只允许一轮在途（UI 也会把发送键切成停止）

        // 引用序号本地校验（design D4，spec「引用不存在的序号」）：越界 → 不调 AI、不写 turns。
        let lang = configSnapshot.userLanguage
        let refs = Self.parseReferences(question, language: lang)
        let count = boundResult.issues.count
        let invalid = refs.filter { $0 < 1 || $0 > count }
        if !invalid.isEmpty {
            composerNotice = count == 0
                ? L10n.t(.followUpNoReferencable, lang)
                : L10n.invalidReference(invalid, count: count, lang)
            return
        }
        startTurn(question: question, refs: refs)
    }

    /// 重试上一轮失败/取消的追问：复用同一问题与同一结果绑定（design「追问失败可恢复」）。
    func retry() {
        guard !isClosed, let s = streaming, s.stage == .failed else { return }
        startTurn(question: s.question, refs: s.referencedIndices)
    }

    /// 取消当前在途一轮（追问区 stop 按钮，design D3）：丢弃半截、不写 turns；历史轮保留。
    func stopCurrent() {
        guard isBusy else { return }
        cancelInFlight(.userStop)
    }

    /// 清空 composer 提示（输入变化时由 UI 调用）。
    func clearNotice() { composerNotice = nil }

    // MARK: - 取消隔离（design D3，统一幂等屏障）

    /// 幂等取消屏障。**原子三步**（顺序固定）：① 前移代次让在途回调 guard 立即失效 →
    /// ② 清 streaming（丢弃半截，不写 turns）→ ③ cancel Task。sessionEnd 额外清空整会话 + 置 isClosed。
    func cancelInFlight(_ reason: CancelReason) {
        askGeneration += 1                    // ①
        let task = inFlightTask
        inFlightTask = nil
        streaming = nil                       // ②（丢弃半截回答，不入 turns）
        composerNotice = nil
        if reason == .sessionEnd {
            isClosed = true
            turns.removeAll()                 // 关窗/新纠错/退出 → 清空整个会话历史
        }
        task?.cancel()                        // ③
    }

    // MARK: - 内部：组装 + 请求

    private func startTurn(question: String, refs: [Int]) {
        // 预算裁剪：base 恒保留（含完整带序号修正 + 当前问题）；仅裁剪最旧历史；base 超预算 → fail loud。
        let lang = configSnapshot.userLanguage
        guard let ctx = Self.assembleWithinBudget(
            original: original, corrected: boundResult.corrected, summary: boundResult.summary,
            numberedIssues: numberedIssues, allHistory: turns, question: question,
            budgetTokens: configSnapshot.followUpBudgetTokens, user: lang
        ) else {
            // fail loud（正确性红线 design D5）：绝不静默截断致「修正 N」失去绑定。
            composerNotice = L10n.t(.followUpBudgetOverflow, lang)
            return
        }

        askGeneration += 1
        let myAsk = askGeneration
        streaming = StreamingAnswer(question: question, referencedIndices: refs, stage: .receiving)

        let cfg = configSnapshot.appConfig(apiKey: keyProvider() ?? "")   // 瞬取现用，不驻留 session
        let provider = self.provider
        let corrected = boundResult.corrected

        inFlightTask = Task { [weak self] in
            // 原始增量累积（未护栏）；展示前每帧过一次输出护栏，避免流式阶段原样露出整段替代全文（评审#2）。
            let rawBox = RawAccumulator()
            let onDelta: @MainActor @Sendable (String) async -> Void = { [weak self] delta in
                guard let self, self.askGeneration == myAsk, !self.isClosed, !Task.isCancelled else { return }
                guard var s = self.streaming, s.stage == .receiving else { return }
                rawBox.value += delta
                // 边流边护栏（评审#2；D10 增强：同时比对追问内长文本块）。
                s.answer = Self.applyOutputGuard(answer: rawBox.value, corrected: corrected,
                                                 question: question, language: lang)
                self.streaming = s
            }
            do {
                let answer = try await provider.followUpStreaming(context: ctx, config: cfg, onDelta: onDelta)
                guard let self, self.askGeneration == myAsk, !self.isClosed, !Task.isCancelled else { return }
                self.inFlightTask = nil         // 完成即释放 Task（连带释放捕获的含 key 的 cfg，评审#5）
                // 应用层输出护栏（design D6 ③；D10 增强：同时比对追问内长文本块）：拦「整段替代全文」。
                let guarded = Self.applyOutputGuard(answer: answer, corrected: corrected,
                                                    question: question, language: lang)
                // 正确性红线（评审#1）：空回答不当成功提交。
                guard !guarded.trimmed.isEmpty else {
                    self.streaming = StreamingAnswer(question: question, answer: "", referencedIndices: refs,
                                                     stage: .failed, errorText: ReviewError.truncated.localizedText(lang))
                    return
                }
                self.turns.append(FollowUpTurn(question: question, answer: guarded, referencedIndices: refs))
                self.streaming = nil            // 成功 → 清在途，本轮已入历史
            } catch {
                guard let self, self.askGeneration == myAsk, !self.isClosed, !Task.isCancelled else { return }
                self.inFlightTask = nil         // 失败即释放 Task（同上）
                if case ReviewError.cancelled = error { return }   // cancel 由 cancelInFlight 处理，不覆盖
                let msg = (error as? ReviewError)?.localizedText(lang) ?? error.localizedDescription
                // 失败轮：保留问题（不留 partial，避免半截替代全文残留），标 failed + 错误文案；**不入 turns**、可重试。
                self.streaming = StreamingAnswer(question: question, answer: "",
                                                 referencedIndices: refs, stage: .failed, errorText: msg)
            }
        }
    }

    /// 流式原始文本累加器（Task 内 MainActor 独占，供 onDelta 累积未护栏原文）。
    private final class RawAccumulator { var value = "" }

    // MARK: - 纯函数（可单测）

    /// 解析问题中的修正引用，返回去重升序的 1-based 序号。token 集随用户语言（language-config design D11）：
    /// 中文识别「修正 N」；英文识别 "fix N" / "correction N"（大小写不敏感）。跨语言 token 不识别——
    /// UI badge、prompt 上下文编号标签、本解析器三者同源同语言，杜绝「输入 fix 2 却校验不到」的缺口。
    nonisolated static func parseReferences(_ q: String, language: AppLanguage) -> [Int] {
        language == .chinese ? parseReferencesZh(q) : parseReferencesEn(q)
    }

    nonisolated private static func parseReferencesZh(_ q: String) -> [Int] {
        var found = Set<Int>()
        // 匹配「修正」后可跟空白，再跟数字。
        let scalars = Array(q)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "修", i + 1 < scalars.count, scalars[i + 1] == "正" {
                var j = i + 2
                while j < scalars.count, scalars[j] == " " || scalars[j] == "\u{00A0}" { j += 1 }
                var num = ""
                while j < scalars.count, scalars[j].isNumber, scalars[j].isASCII { num.append(scalars[j]); j += 1 }
                if let n = Int(num) { found.insert(n) }
                i = j
            } else {
                i += 1
            }
        }
        return found.sorted()
    }

    nonisolated private static func parseReferencesEn(_ q: String) -> [Int] {
        // \b 词边界防 "prefix2"、"suffixfix 3" 误判；大小写不敏感。
        guard let re = try? NSRegularExpression(pattern: "\\b(?:fix|correction)\\s*(\\d+)",
                                                options: [.caseInsensitive]) else { return [] }
        var found = Set<Int>()
        let ns = q as NSString
        for m in re.matches(in: q, range: NSRange(location: 0, length: ns.length)) {
            if m.numberOfRanges > 1, let n = Int(ns.substring(with: m.range(at: 1))) { found.insert(n) }
        }
        return found.sorted()
    }

    /// 保守 token 估算（design D5）：utf8 字节 / K，K 取保守值使 CJK/混排偏保守（宁可更早 fail loud）。
    nonisolated static let estTokenDivisor = 2.5
    nonisolated static func estimateTokens(_ s: String) -> Int {
        Int((Double(s.utf8.count) / estTokenDivisor).rounded(.up))
    }

    /// 估算一份 ctx（含 system + 上下文包 + 历史 + 当前问题）拼出的总 token。
    nonisolated static func estimateContextTokens(_ ctx: FollowUpContext, user: AppLanguage) -> Int {
        let msgs = AIClient.followUpMessages(ctx, user: user)
        let joined = Prompt.followUpSystem(user: user) + "\n" + msgs.map { $0["content"] ?? "" }.joined(separator: "\n")
        return estimateTokens(joined)
    }

    /// 组装 base + 预算内历史（design D5）：
    /// - base（system + 原文 + 完整带序号修正 + 当前问题）**恒保留**；base 超预算 → 返回 nil（fail loud）。
    /// - 否则从**最旧**历史逐轮丢弃，直到放得下；被丢弃历史只影响连续性，不影响被引用修正绑定。
    nonisolated static func assembleWithinBudget(original: String, corrected: String, summary: String,
                                     numberedIssues: [FollowUpContext.NumberedIssue],
                                     allHistory: [FollowUpTurn], question: String,
                                     budgetTokens: Int, user: AppLanguage = .chinese) -> FollowUpContext? {
        func ctx(_ history: [FollowUpTurn]) -> FollowUpContext {
            FollowUpContext(original: original, corrected: corrected, summary: summary,
                            numberedIssues: numberedIssues, history: history, question: question)
        }
        // base（空历史）都放不下 → 无法在预算内保留必要上下文 → fail loud（绝不静默截断）。
        if estimateContextTokens(ctx([]), user: user) > budgetTokens { return nil }
        var history = allHistory
        while !history.isEmpty, estimateContextTokens(ctx(history), user: user) > budgetTokens {
            history.removeFirst()   // 丢最旧
        }
        return ctx(history)
    }

    /// 应用层输出护栏（design D6 ③；language-config design D10 增强）：检测回答里「与 corrected
    /// **或追问内长文本块**高度相似的整段替代文」并替换为约束说明，使其**不被当作可采纳结果**呈现。
    /// 硬保证（result 不变）已由「回答永不写回 result」达成，此为代码层确定性拦截（近拷贝/最小改动形态）；
    /// 翻译式整段输出与原文字面不相似、本地相似度无判别力，由 prompt 层约束兜底（design D10 三层诚实保证，风险 R6）。
    nonisolated static let outputGuardNote = L10n.t(.followUpOutputGuardNote, .chinese)

    /// 兼容旧签名（中文、无问题文本）：既有 corrected 拦截行为逐位保留。
    nonisolated static func applyOutputGuard(answer: String, corrected: String) -> String {
        applyOutputGuard(answer: answer, corrected: corrected, question: "", language: .chinese)
    }

    nonisolated static func applyOutputGuard(answer: String, corrected: String,
                                             question: String, language: AppLanguage) -> String {
        let note = L10n.t(.followUpOutputGuardNote, language)
        var result = guardAgainst(answer, target: corrected, note: note)
        // D10 护栏增强：话题放宽后用户会贴**新文本**，其整段改写与旧 corrected 无相似性——
        // 对追问内每个长文本块（粘贴样文本）做同一套拦截，堵住「贴新文本要全文」绕过。
        for block in pastedBlocks(in: question) {
            result = guardAgainst(result, target: block, note: note)
        }
        return result
    }

    /// 针对单个「不得整段替代输出」的目标文本跑三步拦截（corrected 与追问长文本块共用同一实现）。
    nonisolated private static func guardAgainst(_ answer: String, target: String, note: String) -> String {
        let c = target.trimmed
        // 目标太短（如单词级修正/短例句）不判：短串易在解释里被合法引用，避免误伤。
        guard c.count >= 12 else { return answer }
        let cWords = wordSet(c)
        guard cWords.count >= 3 else { return answer }

        // 极端自替换保护（评审#3 复审）：若目标恰是 guard note 的子串，替换后仍含 c，
        // 逐次替换永不收敛 → 直接整体返回 note，杜绝主线程挂死。
        if note.range(of: c, options: [.caseInsensitive]) != nil { return note }

        var result = answer
        // 1) verbatim：目标原文（含大小写差异）作为整段出现在回答任意位置（含普通段落，如
        //    「完整版本是：<目标>，解释…」）→ 替换该出现，杜绝普通段落夹带替代全文绕过（评审#3）。
        //    用单遍 replacingOccurrences（非重扫替换文本）避免 while 自替换死循环（评审#3 复审）。
        result = result.replacingOccurrences(of: c, with: note, options: [.caseInsensitive])
        // 2) fenced 代码块 / 引用块：整块与目标高覆盖且长度相当 → 判为越界全文，整块替换。
        for block in fencedBlocks(result) where isReplacementFullText(block.content, correctedWords: cWords, correctedLen: c.count) {
            result = result.replacingOccurrences(of: block.raw, with: note)
        }
        // 3) 无围栏、整条回答近似目标（直接吐一版全文/最小改动改写）→ 整体替换为约束说明。
        if isReplacementFullText(result.trimmed, correctedWords: cWords, correctedLen: c.count) {
            return note
        }
        return result
    }

    /// 追问内「长文本块」提取（design D10）：按行切分、trim 后长度 ≥ 阈值的行视为粘贴样文本；
    /// 无换行的整段长问题同样视为一个块。阈值为启发值：足以排除普通提问句，覆盖粘贴段落。
    nonisolated static let pastedBlockMinLength = 30
    nonisolated static func pastedBlocks(in question: String) -> [String] {
        var blocks = question.components(separatedBy: "\n").map { $0.trimmed }
            .filter { $0.count >= pastedBlockMinLength }
        let whole = question.trimmed
        if whole.count >= pastedBlockMinLength, !blocks.contains(whole) { blocks.append(whole) }
        return blocks
    }

    /// 判据：候选段与目标词覆盖 ≥0.85（**双向取 max**）且长度比在 [0.8, 1.3] → 视为「整段替代全文」（启发阈值，可调）。
    /// 双向覆盖（language-config D10）：目标→候选 抓「近拷贝引用」；候选→目标 抓「最小改动改写」——
    /// 改写会把目标里的错词换掉（正向覆盖被稀释），但候选的词几乎全来自目标（反向覆盖仍高）。
    /// 只会更严（多拦不少放），长度比窗口继续兜住「短例句/解释」不误伤。
    nonisolated private static func isReplacementFullText(_ candidate: String, correctedWords: Set<String>, correctedLen: Int) -> Bool {
        let cand = candidate.trimmed
        guard cand.count >= 12 else { return false }
        let lenRatio = Double(cand.count) / Double(max(correctedLen, 1))
        guard lenRatio >= 0.8, lenRatio <= 1.3 else { return false }
        let candWords = wordSet(cand)
        guard !candWords.isEmpty else { return false }
        let common = correctedWords.intersection(candWords).count
        let coverage = max(Double(common) / Double(correctedWords.count),
                           Double(common) / Double(candWords.count))
        return coverage >= 0.85
    }

    /// 提取 ```fenced``` 与 > 引用块的 (raw 原始片段, content 纯内容)。
    private struct Block { let raw: String; let content: String }
    nonisolated private static func fencedBlocks(_ s: String) -> [Block] {
        var blocks: [Block] = []
        // ``` fenced ```
        let parts = s.components(separatedBy: "```")
        if parts.count >= 3 {
            var i = 1
            while i < parts.count - 0 {
                if i < parts.count, i % 2 == 1 {   // 奇数段在围栏内
                    var content = parts[i]
                    if let nl = content.firstIndex(of: "\n") { content = String(content[content.index(after: nl)...]) } // 去掉语言标注行
                    blocks.append(Block(raw: "```\(parts[i])```", content: content.trimmed))
                }
                i += 1
            }
        }
        // > 引用块（连续以 > 开头的行合并）
        var quoteLines: [String] = []
        var quoteRaw: [String] = []
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") {
                quoteRaw.append(line)
                quoteLines.append(String(t.dropFirst()).trimmed)
            } else if !quoteLines.isEmpty {
                blocks.append(Block(raw: quoteRaw.joined(separator: "\n"), content: quoteLines.joined(separator: " ").trimmed))
                quoteLines.removeAll(); quoteRaw.removeAll()
            }
        }
        if !quoteLines.isEmpty {
            blocks.append(Block(raw: quoteRaw.joined(separator: "\n"), content: quoteLines.joined(separator: " ").trimmed))
        }
        return blocks
    }

    /// 归一化分词（小写、按非字母数字切分、过滤空词），用于覆盖率判定。CJK 逐字视作词。
    nonisolated private static func wordSet(_ s: String) -> Set<String> {
        var words = Set<String>()
        var cur = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                if ch.isASCII { cur.append(ch) }
                else { if !cur.isEmpty { words.insert(cur); cur = "" }; words.insert(String(ch)) }  // CJK 单字成词
            } else {
                if !cur.isEmpty { words.insert(cur); cur = "" }
            }
        }
        if !cur.isEmpty { words.insert(cur) }
        return words
    }
}
