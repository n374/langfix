import Foundation

/// 预览专用、schema-aware 的容错增量扫描器（见 design.md §2.4）。
///
/// **铁律：永不参与正确性。** 它有 bug 最多让预览不理想；流结束后完整 content 一律走
/// `AIClient.parseAndValidate` 作唯一真相。本类只为「首字提前」的打字机预览服务。
///
/// 设计取舍：维护完整 buffer，每次 `feed` 后对整段 buffer 做一次**前向宽容扫描**
/// （buffer 至多几 KB，O(n²) 总成本可忽略），比「跨 feed 持续态字符状态机」更健壮、更易测。
/// fail-closed：任何不确定（半截 escape / 未配齐代理对 / 未闭合字段）一律不输出，
/// 等待更多数据或交由最终 parse 兜底。
struct PartialReviewParser {

    /// 累积的完整原始 content（含 JSON 结构与转义，未解码）。
    private var buffer = ""

    /// 上次发出的预览快照指纹，用于去重（无变化时 feed 返回 nil，避免 MainActor 洪泛）。
    private var lastFingerprint = ""

    /// 喂入一段 delta，返回**有变化时**的最新预览快照；无可展示变化时返回 nil。
    mutating func feed(_ chunk: String) -> StreamingPreview? {
        buffer += chunk
        let preview = scan(stage: .receiving)
        let fp = fingerprint(preview)
        guard fp != lastFingerprint else { return nil }
        lastFingerprint = fp
        return preview
    }

    /// 取当前快照（不改去重指纹），用于把已显示内容「冻结」为指定 stage（如 .finalizing）。
    func snapshot(stage: StreamingPreview.Stage) -> StreamingPreview {
        scan(stage: stage)
    }

    // MARK: - 指纹（去重）

    private func fingerprint(_ p: StreamingPreview) -> String {
        "\(p.corrected.count)|\(p.translation ?? "")|\(p.summary ?? "")|\(p.issues.count)|\(p.alternative ?? "")"
    }

    // MARK: - 前向宽容扫描

    /// 扫描整段 buffer，提取顶层字段 → StreamingPreview。任何残缺一律 fail-closed。
    private func scan(stage: StreamingPreview.Stage) -> StreamingPreview {
        let chars = Array(buffer)
        let fields = topLevelFields(chars)

        var preview = StreamingPreview(stage: stage)

        // corrected：逐字输出稳定前缀（无论是否闭合都尽量输出已安全部分）。
        if let f = fields["corrected"], case let .string(raw, _) = f {
            preview.corrected = Self.decodeStablePrefix(raw)
        }
        // translation / summary / alternative：仅在字符串闭合后整体填充（新字段名，design D6；旧 _zh 名不扫——预览仅 UI 快照，定稿由兼容解码兜底）。
        if let f = fields["translation"], case let .string(raw, closed) = f, closed {
            preview.translation = Self.decodeStablePrefix(raw)
        }
        if let f = fields["summary"], case let .string(raw, closed) = f, closed {
            preview.summary = Self.decodeStablePrefix(raw)
        }
        if let f = fields["alternative"], case let .string(raw, closed) = f, closed {
            preview.alternative = Self.decodeStablePrefix(raw)
        }
        // issues：从数组原文里抽出已完整闭合的 object 逐个 decode。
        if let f = fields["issues"], case let .array(raw) = f {
            preview.issues = Self.decodeClosedIssues(raw)
        }
        return preview
    }

    /// 顶层字段值的形态。
    private enum FieldValue {
        case string(raw: String, closed: Bool)   // raw 为引号之间的原始（仍含转义）内容
        case array(raw: String)                   // raw 为 '[' 之后到 ']'（或 buffer 末）之间的原文
        case other                                // 数字 / bool / null 等（预览不关心）
    }

    /// 在顶层对象内扫描每个 `"key": value`，返回 key → FieldValue。
    /// 宽容 truncation：任何位置截断都不崩，已识别的字段照常返回。
    private func topLevelFields(_ chars: [Character]) -> [String: FieldValue] {
        var fields: [String: FieldValue] = [:]
        let n = chars.count
        guard let open = chars.firstIndex(of: "{") else { return fields }
        var i = open + 1

        func skipWS() { while i < n, chars[i] == " " || chars[i] == "\n" || chars[i] == "\r" || chars[i] == "\t" || chars[i] == "," { i += 1 } }

        while i < n {
            skipWS()
            guard i < n else { break }
            if chars[i] == "}" { break }                 // 顶层对象闭合
            guard chars[i] == "\"" else { i += 1; continue }  // 期望 key 起始引号；否则跳过杂字

            // 读 key（key 一律简单 ASCII，但仍按字符串规则处理转义找闭合引号）。
            guard let (keyRaw, keyEnd, keyClosed) = Self.scanString(chars, from: i) else { break }
            guard keyClosed else { break }               // key 未闭合 → 数据不足，停
            let key = Self.decodeStablePrefix(keyRaw)
            i = keyEnd                                    // keyEnd 指向闭合引号之后
            skipWSOnly(&i, chars, n)
            guard i < n, chars[i] == ":" else { break }
            i += 1
            skipWSOnly(&i, chars, n)
            guard i < n else { break }

            // 读 value
            let c = chars[i]
            if c == "\"" {
                guard let (raw, end, closed) = Self.scanString(chars, from: i) else { break }
                fields[key] = .string(raw: raw, closed: closed)
                i = closed ? end : n
            } else if c == "[" {
                let (raw, end, _) = Self.scanBracketed(chars, from: i, open: "[", close: "]")
                fields[key] = .array(raw: raw)
                i = end
            } else if c == "{" {
                let (_, end, _) = Self.scanBracketed(chars, from: i, open: "{", close: "}")
                fields[key] = .other
                i = end
            } else {
                // 字面量：读到 ',' / '}' / 空白 为止
                var j = i
                while j < n, chars[j] != ",", chars[j] != "}", chars[j] != "\n", chars[j] != "\r" { j += 1 }
                fields[key] = .other
                i = j
            }
        }
        return fields
    }

    private func skipWSOnly(_ i: inout Int, _ chars: [Character], _ n: Int) {
        while i < n, chars[i] == " " || chars[i] == "\n" || chars[i] == "\r" || chars[i] == "\t" { i += 1 }
    }

    // MARK: - 字符串扫描（边界判定）

    /// 从 `from`（必须指向开引号）扫描一个 JSON 字符串。
    /// 返回 (引号间原始内容, 闭合引号之后的下标, 是否闭合)。未闭合时 raw 含到 buffer 末的全部内容。
    /// 边界判定只需处理 `\` 转义下一字符（`\"` 不闭合）。
    static func scanString(_ chars: [Character], from: Int) -> (raw: String, end: Int, closed: Bool)? {
        let n = chars.count
        guard from < n, chars[from] == "\"" else { return nil }
        var i = from + 1
        var raw: [Character] = []
        while i < n {
            let c = chars[i]
            if c == "\\" {
                raw.append(c)
                if i + 1 < n { raw.append(chars[i + 1]); i += 2 } else { i += 1 }  // 尾随孤立 '\'，原样收集，解码层 fail-closed
                continue
            }
            if c == "\"" { return (String(raw), i + 1, true) }
            raw.append(c)
            i += 1
        }
        return (String(raw), n, false)   // 未闭合
    }

    /// 从 `from`（指向 open 括号）扫描配平的括号块，正确跳过其中的字符串。
    /// 返回 (open 之后到匹配 close 之前的原文, 结束下标=close 之后或 buffer 末, 是否闭合)。
    static func scanBracketed(_ chars: [Character], from: Int, open: Character, close: Character) -> (raw: String, end: Int, closed: Bool) {
        let n = chars.count
        var depth = 0
        var i = from
        var inString = false
        var content: [Character] = []
        while i < n {
            let c = chars[i]
            if inString {
                content.append(c)
                if c == "\\" { if i + 1 < n { content.append(chars[i + 1]); i += 2 } else { i += 1 }; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; content.append(c); i += 1; continue }
            if c == open { depth += 1; if depth > 1 { content.append(c) }; i += 1; continue }
            if c == close {
                depth -= 1
                if depth == 0 { return (String(content), i + 1, true) }
                content.append(c); i += 1; continue
            }
            content.append(c); i += 1
        }
        return (String(content), n, false)   // 未闭合：返回已有原文
    }

    // MARK: - 解码（稳定前缀 + 代理对）

    /// 把一段 JSON 字符串原始内容（引号之间、仍含转义）解码为**稳定前缀**：
    /// 只输出到最后一个安全边界——不输出半截 escape、半截 `\uXXXX`、未配齐的代理对。
    /// 对完整且合法的输入，返回完整解码串。fail-closed：遇不确定即停。
    static func decodeStablePrefix(_ raw: String) -> String {
        let s = Array(raw)
        let n = s.count
        var out = ""
        var i = 0
        while i < n {
            let c = s[i]
            if c != "\\" { out.append(c); i += 1; continue }

            // 转义：需要下一个字符
            guard i + 1 < n else { break }   // 尾随孤立 '\' → 停在此前
            let e = s[i + 1]
            switch e {
            case "\"": out.append("\""); i += 2
            case "\\": out.append("\\"); i += 2
            case "/": out.append("/"); i += 2
            case "b": out.append("\u{08}"); i += 2
            case "f": out.append("\u{0C}"); i += 2
            case "n": out.append("\n"); i += 2
            case "r": out.append("\r"); i += 2
            case "t": out.append("\t"); i += 2
            case "u":
                // 需要 4 位十六进制
                guard i + 5 < n, let hi = hex4(s, i + 2) else { return out }  // 不足/非法 → 停
                if (0xD800...0xDBFF).contains(hi) {
                    // 高代理：必须配齐紧随的 \uYYYY 低代理
                    guard i + 11 < n, s[i + 6] == "\\", s[i + 7] == "u", let lo = hex4(s, i + 8),
                          (0xDC00...0xDFFF).contains(lo) else { return out }   // 未配齐 → 停
                    let scalar = 0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00)
                    if let u = Unicode.Scalar(scalar) { out.unicodeScalars.append(u) }
                    i += 12
                } else if (0xDC00...0xDFFF).contains(hi) {
                    return out   // 孤立低代理 → 停（fail-closed）
                } else {
                    if let u = Unicode.Scalar(hi) { out.unicodeScalars.append(u) }
                    i += 6
                }
            default:
                // 未知转义：原样吐反斜杠后字符（宽容）
                out.append(e); i += 2
            }
        }
        return out
    }

    /// 读取 chars[start..<start+4] 为 16 进制码点。
    private static func hex4(_ s: [Character], _ start: Int) -> Int? {
        guard start + 4 <= s.count else { return nil }
        var v = 0
        for k in 0..<4 {
            guard let d = s[start + k].hexDigitValue else { return nil }
            v = v * 16 + d
        }
        return v
    }

    // MARK: - issues 抽取

    /// 从 issues 数组原文里抽出**已完整闭合**的 `{...}` object，逐个 decode 为 Issue。
    /// 半截 object 不输出；某个 object decode 失败则跳过（不影响其它已闭合项）。
    static func decodeClosedIssues(_ arrayRaw: String) -> [Issue] {
        let chars = Array(arrayRaw)
        let n = chars.count
        var issues: [Issue] = []
        var i = 0
        let dec = JSONDecoder()
        while i < n {
            // 找下一个 object 起始 '{'
            guard let openIdx = nextTopLevelBrace(chars, from: i) else { break }
            let (raw, end, closed) = scanBracketed(chars, from: openIdx, open: "{", close: "}")
            // 仅收已完整闭合的 object，再用「能被 decode 成 Issue」二次确认。
            if closed, let data = ("{" + raw + "}").data(using: .utf8),
               let issue = try? dec.decode(Issue.self, from: data) {
                issues.append(issue)
            }
            if !closed || end <= openIdx { break }   // 半截或无进展 → 停（余下都是半截）
            i = end
        }
        return issues
    }

    /// 在数组原文里找下一个不在字符串内的 '{'。
    private static func nextTopLevelBrace(_ chars: [Character], from: Int) -> Int? {
        let n = chars.count
        var i = from
        var inString = false
        while i < n {
            let c = chars[i]
            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
                i += 1; continue
            }
            if c == "\"" { inString = true; i += 1; continue }
            if c == "{" { return i }
            i += 1
        }
        return nil
    }
}
