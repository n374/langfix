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
    var category: IssueCategory
    var severity: IssueSeverity
    var before: String
    var after: String
    var reasonZh: String

    enum CodingKeys: String, CodingKey {
        case category, severity, before, after
        case reasonZh = "reason_zh"
    }

    init(category: IssueCategory, severity: IssueSeverity, before: String, after: String, reasonZh: String) {
        self.category = category
        self.severity = severity
        self.before = before
        self.after = after
        self.reasonZh = reasonZh
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.category = IssueCategory.lenient((try? c.decode(String.self, forKey: .category)) ?? "")
        self.severity = IssueSeverity.lenient((try? c.decode(String.self, forKey: .severity)) ?? "")
        self.before = (try? c.decode(String.self, forKey: .before)) ?? ""
        self.after = (try? c.decode(String.self, forKey: .after)) ?? ""
        self.reasonZh = (try? c.decode(String.self, forKey: .reasonZh)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
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
    }

    init(hasIssues: Bool, original: String, corrected: String,
         translationZh: String = "", summaryZh: String, issues: [Issue], alternative: String? = nil) {
        self.hasIssues = hasIssues
        self.original = original
        self.corrected = corrected
        self.translationZh = translationZh
        self.summaryZh = summaryZh
        self.issues = issues
        self.alternative = alternative
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
    }

    /// 纯文本/解析失败时的兜底结果：以本地输入为 corrected（无翻译）。
    static func fallback(localInput: String, note: String) -> ReviewResult {
        ReviewResult(hasIssues: false, original: localInput, corrected: localInput,
                     translationZh: "", summaryZh: note, issues: [])
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
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
