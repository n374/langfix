import XCTest
@testable import LangFix

final class DiffEngineTests: XCTestCase {

    func testTokenizePreservesWordsAndSeparators() {
        let toks = DiffEngine.tokenize("I have went.")
        // 词与非词交替
        XCTAssertEqual(toks.joined(), "I have went.")
        XCTAssertEqual(DiffEngine.wordCount("I have went."), 3)
    }

    func testIdenticalHasNoEdits() {
        let stats = DiffEngine.editStats(orig: "Thanks, I'll take a look.", corrected: "Thanks, I'll take a look.")
        XCTAssertEqual(stats.editedWords, 0)
        XCTAssertEqual(stats.ratio, 0, accuracy: 0.0001)
        let segs = DiffEngine.segments("hello world", "hello world")
        XCTAssertTrue(segs.allSatisfy { if case .same = $0 { return true } else { return false } })
    }

    func testSingleWordReplacement() {
        // "have went" → "went"：删 1 词（have，可能与相邻空格合并成一个 delete 片段）
        let segs = DiffEngine.segments("I have went there", "I went there")
        let hasDeleteWithHave = segs.contains { seg in
            if case .delete(let s) = seg { return s.contains("have") } else { return false }
        }
        XCTAssertTrue(hasDeleteWithHave)
        let stats = DiffEngine.editStats(orig: "I have went there", corrected: "I went there")
        XCTAssertEqual(stats.origWords, 4)
        XCTAssertEqual(stats.editedWords, 1)
    }

    func testInsertionAndDeletionCounted() {
        // "a big house" → "a huge home"：big→huge(替换=删+插), house→home(替换)
        let stats = DiffEngine.editStats(orig: "a big house", corrected: "a huge home")
        XCTAssertGreaterThanOrEqual(stats.editedWords, 2)
        XCTAssertGreaterThan(stats.ratio, 0)
    }
}
