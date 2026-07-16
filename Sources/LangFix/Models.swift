import Foundation

// MARK: - 结构化输出模型（对应 docs/architecture/data-flow.md §3 ReviewResult）

enum IssueCategory: String, Codable, CaseIterable, Sendable {
    case grammar, spelling, word_choice, naturalness, tone, punctuation

    /// 未知类别一律落到 naturalness，保证解析不因模型乱填类别而失败。
    static func lenient(_ s: String) -> IssueCategory {
        IssueCategory(rawValue: s) ?? .naturalness
    }

    var badge: String {
        switch self {
        case .grammar: return "语法"
        case .spelling: return "拼写"
        case .word_choice: return "用词"
        case .naturalness: return "地道度"
        case .tone: return "语气"
        case .punctuation: return "标点"
        }
    }
}

enum IssueSeverity: String, Codable, Sendable {
    case error, improvement, optional

    static func lenient(_ s: String) -> IssueSeverity {
        IssueSeverity(rawValue: s) ?? .improvement
    }

    var badge: String {
        switch self {
        case .error: return "error"
        case .improvement: return "improvement"
        case .optional: return "optional"
        }
    }
}

struct Issue: Codable, Identifiable, Sendable {
    let id = UUID()
    /// 模型输出的 1-based 序号（「修正 N」）。缺省/非法为 0 → 由 `ReviewResult.numberedIssues` 按位置兜底重排。
    /// 权威序号解析在 `ReviewResult.numberedIssues` 单一来源，保证 UI 显示与追问上下文同源（design D1）。
    var index: Int
    var category: IssueCategory
    var severity: IssueSeverity
    var before: String
    var after: String
    var reasonZh: String

    enum CodingKeys: String, CodingKey {
        case index, category, severity, before, after
        case reasonZh = "reason_zh"
    }

    init(index: Int = 0, category: IssueCategory, severity: IssueSeverity, before: String, after: String, reasonZh: String) {
        self.index = index
        self.category = category
        self.severity = severity
        self.before = before
        self.after = after
        self.reasonZh = reasonZh
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.index = (try? c.decode(Int.self, forKey: .index)) ?? 0
        self.category = IssueCategory.lenient((try? c.decode(String.self, forKey: .category)) ?? "")
        self.severity = IssueSeverity.lenient((try? c.decode(String.self, forKey: .severity)) ?? "")
        self.before = (try? c.decode(String.self, forKey: .before)) ?? ""
        self.after = (try? c.decode(String.self, forKey: .after)) ?? ""
        self.reasonZh = (try? c.decode(String.self, forKey: .reasonZh)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(category.rawValue, forKey: .category)
        try c.encode(severity.rawValue, forKey: .severity)
        try c.encode(before, forKey: .before)
        try c.encode(after, forKey: .after)
        try c.encode(reasonZh, forKey: .reasonZh)
    }
}

struct ReviewResult: Codable, Sendable {
    var hasIssues: Bool
    var original: String
    var corrected: String
    /// corrected 的简体中文直译（帮助中文母语用户核对修正后含义与本意一致）。模型可能不返回，缺省为空串。
    var translationZh: String
    var summaryZh: String
    var issues: [Issue]
    var alternative: String?
    /// alternative（更地道整体说法）的一句中文说明：为什么这样更地道。模型可能不返回，缺省空串。
    var alternativeReasonZh: String

    /// 应用侧标记：护栏判定两轮都超阈值，提示用户改动较大（不参与 JSON 编解码）。
    var overEdited: Bool = false

    enum CodingKeys: String, CodingKey {
        case hasIssues = "has_issues"
        case original
        case corrected
        case translationZh = "translation_zh"
        case summaryZh = "summary_zh"
        case issues
        case alternative
        case alternativeReasonZh = "alternative_reason_zh"
    }

    init(hasIssues: Bool, original: String, corrected: String,
         translationZh: String = "", summaryZh: String, issues: [Issue],
         alternative: String? = nil, alternativeReasonZh: String = "") {
        self.hasIssues = hasIssues
        self.original = original
        self.corrected = corrected
        self.translationZh = translationZh
        self.summaryZh = summaryZh
        self.issues = issues
        self.alternative = alternative
        self.alternativeReasonZh = alternativeReasonZh
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hasIssues = (try? c.decode(Bool.self, forKey: .hasIssues)) ?? false
        self.original = (try? c.decode(String.self, forKey: .original)) ?? ""
        self.corrected = (try? c.decode(String.self, forKey: .corrected)) ?? ""
        self.translationZh = (try? c.decode(String.self, forKey: .translationZh)) ?? ""
        self.summaryZh = (try? c.decode(String.self, forKey: .summaryZh)) ?? ""
        self.issues = (try? c.decode([Issue].self, forKey: .issues)) ?? []
        self.alternative = try? c.decodeIfPresent(String.self, forKey: .alternative)
        self.alternativeReasonZh = (try? c.decode(String.self, forKey: .alternativeReasonZh)) ?? ""
    }

    /// 纯文本/解析失败时的兜底结果：以本地输入为 corrected（无翻译）。
    static func fallback(localInput: String, note: String) -> ReviewResult {
        ReviewResult(hasIssues: false, original: localInput, corrected: localInput,
                     translationZh: "", summaryZh: note, issues: [])
    }

    /// **权威带序号修正（单一来源，design D1 同源）**：UI 显示「修正 N」与追问上下文编号都读这里，杜绝漂移。
    /// - 模型输出的 `index` 若构成严格 1..N 排列（连续、无重、无缺）→ **采用模型序号**并按其升序排列（满足用户「让 LLM 输出该格式」）。
    /// - 否则（缺省/跳号/重号/越界）→ **应用按位置重排** 1..N 兜底（正确性优先，绝不让「修正 N」指错条目）。
    /// 返回 (序号, issue) 且序号必为连续 1..N，与数组顺序一致。
    var numberedIssues: [(index: Int, issue: Issue)] {
        let n = issues.count
        guard n > 0 else { return [] }
        let idxs = issues.map { $0.index }
        if Set(idxs) == Set(1...n) {                       // 严格 1..N 排列 → 采用模型序号，按其排序
            let ordered = issues.sorted { $0.index < $1.index }
            return ordered.map { ($0.index, $0) }
        }
        return issues.enumerated().map { ($0.offset + 1, $0.element) }   // 兜底：按位置重排
    }
}

// MARK: - 流式预览值（独立于 ReviewResult，不污染其 hasIssues/overEdited 不变式）

/// 流式期间的「校对预览」快照：仅供 UI 渲染，永不参与正确性判定（最终真相恒为 parseAndValidate）。
/// 见 docs/changes/streaming-incremental-render/design.md §2.3 / §2.4。
struct StreamingPreview: Sendable {
    /// corrected 稳定前缀（打字机逐字输出，单调不回退）。
    var corrected: String
    /// translation_zh：corrected 的中文直译，字符串闭合后整体填充（不逐字）。
    var translationZh: String?
    /// summary_zh：字符串闭合后整体填充（不逐字）。
    var summaryZh: String?
    /// 仅「已完整闭合」的 issue object（避免半张卡片乱跳）。
    var issues: [Issue]
    /// alternative：字符串闭合后整体填充。
    var alternative: String?
    /// 阶段：接收中 / 定稿中（含护栏 strict 冻结、瞬时回退定稿）。
    var stage: Stage

    enum Stage: Sendable { case receiving, finalizing }

    init(corrected: String = "", translationZh: String? = nil, summaryZh: String? = nil,
         issues: [Issue] = [], alternative: String? = nil, stage: Stage = .receiving) {
        self.corrected = corrected
        self.translationZh = translationZh
        self.summaryZh = summaryZh
        self.issues = issues
        self.alternative = alternative
        self.stage = stage
    }
}

// MARK: - 追问答疑（ai-followup change · design D2/D4）

/// 一轮**已成功完成**的追问问答（进入会话历史）。取消/失败的轮次**不入** turns（design D3）。
/// 纯易失内存值类型，随 FollowUpSession（挂 ReviewState）生命周期释放，绝不落盘（Constraint-2 / design D7）。
struct FollowUpTurn: Identifiable, Sendable, Equatable {
    let id = UUID()
    /// 用户提问原文（发给 AI 时一律 data 化，不作指令）。
    var question: String
    /// AI 完整回答（纯文本，尽力 Markdown 渲染）。
    var answer: String
    /// 本轮问题引用到的修正 1-based 序号（与 D1 同源，仅用于 UI 引用 chip 与断言）。
    var referencedIndices: [Int]

    init(question: String, answer: String, referencedIndices: [Int] = []) {
        self.question = question
        self.answer = answer
        self.referencedIndices = referencedIndices
    }
}

/// 当前**在途一轮**的临时状态：问题 + 增量答案 + 阶段。取消/失败即丢弃、不转 turns（design D3）。
struct StreamingAnswer: Sendable, Equatable {
    var question: String
    /// 已流出的增量答案（best-effort Markdown 渲染的原始文本）。
    var answer: String
    var referencedIndices: [Int]
    var stage: Stage
    /// stage == .failed 时的中文错误说明（供失败气泡 + 重试展示）。
    var errorText: String?

    /// receiving：正在流式接收；finalizing：流→非流回退定稿中（answer 将被整体替换，见 design D4）；
    /// failed：本轮失败（展示错误 + 重试，不写 turns）。
    enum Stage: Sendable, Equatable { case receiving, finalizing, failed }

    init(question: String, answer: String = "", referencedIndices: [Int] = [],
         stage: Stage = .receiving, errorText: String? = nil) {
        self.question = question
        self.answer = answer
        self.referencedIndices = referencedIndices
        self.stage = stage
        self.errorText = errorText
    }
}

/// 组装好、可直接交给 AIClient 拼消息的追问上下文快照（纯数据，注入防御在 Prompt 层做 data 化）。
/// design D4：base = 原文 + 完整带序号修正结果 + 当前问题（**恒保留**）；history 可被预算裁剪（design D5）。
struct FollowUpContext: Sendable, Equatable {
    var original: String
    var corrected: String
    var summaryZh: String
    /// 完整带 1-based 序号的修正清单（与 D1 同源；预算裁剪**绝不**丢弃，含被引用修正）。
    var numberedIssues: [NumberedIssue]
    /// 经预算裁剪后**保留**的历史问答轮（可能少于会话全部 turns）。
    var history: [FollowUpTurn]
    /// 当前这轮用户问题。
    var question: String

    struct NumberedIssue: Sendable, Equatable {
        var index: Int          // 1-based，与 UI「修正 N」同源
        var before: String
        var after: String
        var category: String
        var severity: String
        var reasonZh: String
    }
}

/// **不含 apiKey** 的配置快照（评审#5）：绝不把密钥挂在窗口存续期的会话对象上。
/// API key 在发请求瞬间由 KeychainStore.apiKey() 现取现用，组装完即释放，不驻留 session（design D2）。
struct FollowUpConfigSnapshot: Sendable, Equatable {
    var baseURL: String
    var model: String
    var temperature: Double
    var streamingEnabled: Bool
    /// 追问上下文预算上限（token 估算，保守启发值；design D5）。
    var followUpBudgetTokens: Int

    /// 从完整 AppConfig 派生（丢弃 apiKey 等 review 专属字段）。
    init(from cfg: AppConfig, followUpBudgetTokens: Int) {
        self.baseURL = cfg.baseURL
        self.model = cfg.model
        self.temperature = cfg.temperature
        self.streamingEnabled = cfg.streamingEnabled
        self.followUpBudgetTokens = followUpBudgetTokens
    }

    init(baseURL: String, model: String, temperature: Double,
         streamingEnabled: Bool, followUpBudgetTokens: Int) {
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.streamingEnabled = streamingEnabled
        self.followUpBudgetTokens = followUpBudgetTokens
    }

    /// 发请求瞬间：把**瞬取的** Keychain key 与本快照拼成完整 AppConfig 交给 AIClient。
    /// review-only 字段（maxChars/diffThreshold/...）追问链路不用，填占位默认（design D2）。
    func appConfig(apiKey: String) -> AppConfig {
        AppConfig(baseURL: baseURL, apiKey: apiKey, model: model,
                  temperature: temperature, maxChars: 0,
                  diffThreshold: 0, minWordsForGuard: 0, minAbsEdits: 0,
                  structuredMode: .text, streamingEnabled: streamingEnabled)
    }
}

// MARK: - 引擎调用快照（从 SettingsStore + KeychainStore 组装，传给 AIClient）

struct AppConfig: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
    var temperature: Double
    var maxChars: Int
    var diffThreshold: Double
    var minWordsForGuard: Int
    var minAbsEdits: Int
    var structuredMode: StructuredMode
    /// 是否对请求开启 `stream:true`（真流式增量渲染）。默认 true，存于 UserDefaults（非敏感）。
    var streamingEnabled: Bool

    var isComplete: Bool {
        !baseURL.trimmed.isEmpty && !apiKey.trimmed.isEmpty && !model.trimmed.isEmpty
    }

    /// 返回缺失项中文名，用于「缺配置」提示。
    var missingFields: [String] {
        var m: [String] = []
        if baseURL.trimmed.isEmpty { m.append("端点 baseURL") }
        if apiKey.trimmed.isEmpty { m.append("API key") }
        if model.trimmed.isEmpty { m.append("模型 model") }
        return m
    }
}

enum StructuredMode: String, CaseIterable, Sendable {
    case auto, jsonSchema = "json_schema", jsonObject = "json_object", text
}

// MARK: - 错误

enum ReviewError: LocalizedError, Sendable {
    case notConfigured([String])     // 缺失字段
    case emptyInput
    case tooLong(Int, Int)           // 实际长度, 上限
    case auth
    case rateLimited
    case network(String)
    case server(Int)
    case decode(String)
    case cancelled
    /// 服务端上下文超限（400/413 body 含 context_length 等）：可重试的追问失败（design D4/D5）。
    case contextLengthExceeded
    /// 追问回答被截断（finish_reason == length）或为空：不得当作完整回答提交，fail loud 可重试（正确性红线）。
    case truncated

    var errorDescription: String? {
        switch self {
        case .notConfigured(let f): return "请先配置：\(f.joined(separator: "、"))"
        case .emptyInput: return "选区为空"
        case .tooLong(let n, let max): return "文本过长（\(n) 字符，上限 \(max)）"
        case .auth: return "鉴权失败，请检查 API key / 端点"
        case .rateLimited: return "请求过于频繁，请稍后重试"
        case .network(let m): return "网络异常：\(m)"
        case .server(let code): return "服务端错误（HTTP \(code)）"
        case .decode(let m): return "解析失败：\(m)"
        case .cancelled: return "已取消"
        case .contextLengthExceeded: return "本次结果与问答过长，超出模型上下文上限，请缩短问题或减少追问后重试"
        case .truncated: return "回答不完整（被截断或为空），请重试或换个更聚焦的问题"
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 把各种换行统一为 LF（`\n`）：CRLF、CR、Unicode 行分隔符(U+2028)/段分隔符(U+2029)。
    /// 用于输入边界规范化与换行结构检测，使跨来源（Windows/老 Mac/富文本）换行一致可比（Adj3 闭环，评审复审）。
    var normalizedLineEndings: String {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }
}
