import Foundation

/// 词级 diff：tokenize → LCS → same/delete/insert 片段；并提供最小改动护栏所需的编辑统计。
enum DiffEngine {

    enum Seg: Equatable {
        case same(String)
        case delete(String)
        case insert(String)
    }

    /// 把字符串切成 token 序列：每个 token 要么是「词」(字母数字连续段)，要么是「非词」(空白/标点连续段)。
    /// 保留非词 token 以便还原渲染。
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var curIsWord: Bool? = nil
        for ch in s {
            let isWord = ch.isLetter || ch.isNumber
            if curIsWord == nil { curIsWord = isWord }
            if isWord == curIsWord {
                cur.append(ch)
            } else {
                tokens.append(cur)
                cur = String(ch)
                curIsWord = isWord
            }
        }
        if !cur.isEmpty { tokens.append(cur) }
        return tokens
    }

    private static func isWordToken(_ t: String) -> Bool {
        guard let f = t.first else { return false }
        return f.isLetter || f.isNumber
    }

    static func wordCount(_ s: String) -> Int {
        tokenize(s).filter(isWordToken).count
    }

    /// LCS（基于 token），返回对齐后的片段序列。
    static func segments(_ a: String, _ b: String) -> [Seg] {
        let at = tokenize(a)
        let bt = tokenize(b)
        let n = at.count, m = bt.count
        if n == 0 && m == 0 { return [] }

        // DP 表
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = at[i] == bt[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var segs: [Seg] = []
        var i = 0, j = 0
        func push(_ seg: Seg) {
            // 合并相邻同类片段，渲染更顺
            if let last = segs.last {
                switch (last, seg) {
                case let (.same(x), .same(y)): segs[segs.count - 1] = .same(x + y); return
                case let (.delete(x), .delete(y)): segs[segs.count - 1] = .delete(x + y); return
                case let (.insert(x), .insert(y)): segs[segs.count - 1] = .insert(x + y); return
                default: break
                }
            }
            segs.append(seg)
        }
        while i < n && j < m {
            if at[i] == bt[j] {
                push(.same(at[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                push(.delete(at[i])); i += 1
            } else {
                push(.insert(bt[j])); j += 1
            }
        }
        while i < n { push(.delete(at[i])); i += 1 }
        while j < m { push(.insert(bt[j])); j += 1 }
        return segs
    }

    /// 编辑统计：editedWords = 增删片段里的词 token 数；ratio = editedWords / max(origWords,1)。
    static func editStats(orig: String, corrected: String) -> (editedWords: Int, origWords: Int, ratio: Double) {
        let segs = segments(orig, corrected)
        var edited = 0
        for seg in segs {
            switch seg {
            case .delete(let s), .insert(let s):
                edited += tokenize(s).filter(isWordToken).count
            case .same:
                break
            }
        }
        let origWords = max(wordCount(orig), 1)
        return (edited, wordCount(orig), Double(edited) / Double(origWords))
    }
}
