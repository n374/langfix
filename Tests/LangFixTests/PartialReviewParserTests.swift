import XCTest
@testable import LangFix

/// PartialReviewParser：预览专用容错扫描器。覆盖跨任意 chunk 切分、escape、代理对、
/// issues 半截/闭合、字段乱序、malformed 不产 preview。铁律：永不参与正确性。
final class PartialReviewParserTests: XCTestCase {

    /// 把完整字符串按给定切点喂入 parser，返回最后一次非 nil 的快照（或末尾 snapshot）。
    private func feedChunks(_ full: String, splits: [Int]) -> StreamingPreview {
        var parser = PartialReviewParser()
        var last: StreamingPreview? = nil
        let chars = Array(full)
        var prev = 0
        var points = splits.filter { $0 > 0 && $0 < chars.count }.sorted()
        points.append(chars.count)
        for p in points {
            let chunk = String(chars[prev..<p])
            if let s = parser.feed(chunk) { last = s }
            prev = p
        }
        return last ?? parser.snapshot(stage: .receiving)
    }

    // MARK: - corrected 逐字稳定前缀

    func testCorrectedPrefixAcrossChunks() {
        let full = #"{"has_issues": true, "corrected": "I went there", "summary_zh": "ok"}"#
        // 任意切点：逐字符切
        var parser = PartialReviewParser()
        var prefixes: [String] = []
        for ch in full {
            if let p = parser.feed(String(ch)) { prefixes.append(p.corrected) }
        }
        let final = parser.snapshot(stage: .receiving)
        XCTAssertEqual(final.corrected, "I went there")
        // 单调：每个新前缀都以前一个为前缀（永不回退）
        for i in 1..<prefixes.count {
            XCTAssertTrue(prefixes[i].hasPrefix(prefixes[i - 1]) || prefixes[i - 1].hasPrefix(prefixes[i]))
            XCTAssertGreaterThanOrEqual(prefixes[i].count, prefixes[i - 1].count)
        }
    }

    func testCorrectedUnclosedStillStreams() {
        // corrected 字符串未闭合（半截流）→ 已收到的部分照常输出。
        let buffer = #"{"corrected": "Hello wor"#
        let p = feedChunks(buffer, splits: [10, 20])
        XCTAssertEqual(p.corrected, "Hello wor")
    }

    func testCorrectedNotEmittingHalfEscape() {
        // 尾随单个反斜杠（半截 escape）不得输出。
        var parser = PartialReviewParser()
        _ = parser.feed(#"{"corrected": "abc\"#)   // 末尾孤立 '\'
        let p = parser.snapshot(stage: .receiving)
        XCTAssertEqual(p.corrected, "abc")          // '\' 之后不输出
        // 补上 'n' 形成 \n → 解码为换行
        _ = parser.feed("n more")
        let p2 = parser.snapshot(stage: .receiving)
        XCTAssertEqual(p2.corrected, "abc\n more")
    }

    func testCorrectedEscapeSequences() {
        let full = #"{"corrected": "line1\nline2\t\"quoted\" end"}"#
        let p = feedChunks(full, splits: [15, 25, 35])
        XCTAssertEqual(p.corrected, "line1\nline2\t\"quoted\" end")
    }

    func testCorrectedHalfUnicodeEscapeNotEmitted() {
        // 半截 \uXX（位数不足）不输出，补齐后输出。
        var parser = PartialReviewParser()
        _ = parser.feed(#"{"corrected": "A\u00"#)
        XCTAssertEqual(parser.snapshot(stage: .receiving).corrected, "A")   // \u00 不足 4 位 → 停在 A
        _ = parser.feed("e9 B")                                              // é = é
        XCTAssertEqual(parser.snapshot(stage: .receiving).corrected, "Aé B")
    }

    func testCorrectedSurrogatePairAcrossChunks() {
        // 😀 = 😀，跨 chunk 必须成对才输出，不显示孤立高代理。
        var parser = PartialReviewParser()
        _ = parser.feed(#"{"corrected": "hi \uD83D"#)
        XCTAssertEqual(parser.snapshot(stage: .receiving).corrected, "hi ")   // 高代理未配齐 → 不输出
        _ = parser.feed(#"\uDE00!"#)
        XCTAssertEqual(parser.snapshot(stage: .receiving).corrected, "hi 😀!")
    }

    func testCorrectedLoneLowSurrogateFailsClosed() {
        // 孤立低代理 → fail-closed，停在其前。
        var parser = PartialReviewParser()
        _ = parser.feed(#"{"corrected": "x\uDE00y"}"#)
        XCTAssertEqual(parser.snapshot(stage: .receiving).corrected, "x")
    }

    // MARK: - summary / alternative：闭合后整体填充

    func testSummaryFilledOnlyWhenClosed() {
        var parser = PartialReviewParser()
        _ = parser.feed(#"{"corrected": "ok", "summary_zh": "未闭合"#)
        XCTAssertNil(parser.snapshot(stage: .receiving).summaryZh)   // 字符串未闭合 → 不填
        _ = parser.feed(#""}"#)
        XCTAssertEqual(parser.snapshot(stage: .receiving).summaryZh, "未闭合")
    }

    func testAlternativeFilledWhenClosed() {
        let full = #"{"corrected": "ok", "alternative": "a better way"}"#
        let p = feedChunks(full, splits: [20, 35])
        XCTAssertEqual(p.alternative, "a better way")
    }

    // MARK: - issues：闭合才出，半截不出

    func testIssuesClosedObjectsOnly() {
        let full = #"""
        {"corrected": "ok", "issues": [{"category":"grammar","severity":"error","before":"a","after":"b","reason_zh":"r1"},{"category":"spelling","severity":"improvement","before":"c","after":"d","reason_zh":"r2"
        """#
        // 第二个 issue 未闭合 → 只出第一个。
        let p = feedChunks(full, splits: [40, 80, 120])
        XCTAssertEqual(p.issues.count, 1)
        XCTAssertEqual(p.issues[0].category, .grammar)
        XCTAssertEqual(p.issues[0].before, "a")
    }

    func testIssuesBothClosed() {
        let full = #"""
        {"issues": [{"category":"grammar","severity":"error","before":"a","after":"b","reason_zh":"r1"},{"category":"spelling","severity":"optional","before":"c","after":"d","reason_zh":"r2"}], "corrected": "z"}
        """#
        let p = feedChunks(full, splits: [30, 90, 150])
        XCTAssertEqual(p.issues.count, 2)
        XCTAssertEqual(p.issues[1].category, .spelling)
        XCTAssertEqual(p.corrected, "z")
    }

    // MARK: - 字段乱序 / .text tier JSON / malformed

    func testFieldsOutOfOrderCorrectedLate() {
        // corrected 晚到：先到 summary/issues，corrected 最后。preview 不崩，最终 corrected 正确。
        let full = #"{"summary_zh": "s", "has_issues": true, "corrected": "late text"}"#
        let p = feedChunks(full, splits: [10, 25, 40])
        XCTAssertEqual(p.corrected, "late text")
        XCTAssertEqual(p.summaryZh, "s")
    }

    func testTextTierJSONScannedNotRawDumped() {
        // .text tier 仍是 JSON（本仓库事实）：累积的 JSON 文本不能整段当 corrected，
        // 必须扫描出 corrected 字段值。
        let full = #"{"corrected": "just the field", "summary_zh": "x"}"#
        let p = feedChunks(full, splits: [12, 30])
        XCTAssertEqual(p.corrected, "just the field")
        XCTAssertFalse(p.corrected.contains("summary_zh"))
    }

    func testMalformedProducesNoCrashEmptyPreview() {
        // 完全非 JSON 的累积内容：不崩，corrected 空（交最终 parse 兜底）。
        var parser = PartialReviewParser()
        _ = parser.feed("this is not json at all")
        let p = parser.snapshot(stage: .receiving)
        XCTAssertEqual(p.corrected, "")
        XCTAssertTrue(p.issues.isEmpty)
        XCTAssertNil(p.summaryZh)
    }

    func testNoChangeReturnsNil() {
        // 喂入不改变可展示内容的片段（仍在读 original 字段）→ feed 返回 nil（去重）。
        var parser = PartialReviewParser()
        _ = parser.feed(#"{"original": "the input text here", "#)
        let again = parser.feed(#"more orig"#)   // 仍未触及 corrected → 无变化
        XCTAssertNil(again)
    }

    func testSnapshotStagePropagates() {
        var parser = PartialReviewParser()
        _ = parser.feed(#"{"corrected": "x"}"#)
        XCTAssertEqual(parser.snapshot(stage: .finalizing).stage, .finalizing)
        XCTAssertEqual(parser.snapshot(stage: .receiving).stage, .receiving)
    }
}
