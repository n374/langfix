import XCTest
@testable import LangFix

final class ReviewEngineGuardTests: XCTestCase {

    // 6 词输入，满足护栏生效条件（origWords ≥ minWordsForGuard）。
    private let input = "the quick brown fox jumps over"

    func testStrictRetryResolvesUnderThreshold() async throws {
        // 首轮大改（替换全部）→ 超阈值 → strict 重试；strict 仅改 1 词 → 低于阈值 → 采用 strict。
        let stub = StubProvider(first: "AA BB CC DD EE FF",
                                strict: "the quick brown fox jumps now")
        let engine = ReviewEngine(client: stub)
        let r = try await engine.review(text: input, config: testConfig())
        XCTAssertEqual(stub.calls, ["firstPass", "strict"])
        XCTAssertEqual(r.corrected, "the quick brown fox jumps now")
        XCTAssertFalse(r.overEdited)
    }

    func testShortSentenceExemptsGuard() async throws {
        // 3 词输入 < minWordsForGuard(6) → 跳过护栏，即使首轮大改也不重试。
        let stub = StubProvider(first: "completely different rewritten text here now")
        let engine = ReviewEngine(client: stub)
        let r = try await engine.review(text: "I has went", config: testConfig())
        XCTAssertEqual(stub.calls, ["firstPass"])
        XCTAssertEqual(r.corrected, "completely different rewritten text here now")
        XCTAssertFalse(r.overEdited)
    }

    func testBothRoundsOverThresholdMarksOverEditedAndPicksSmaller() async throws {
        // 首轮替换全部(ratio 大)，strict 替换 3 词(ratio 较小但仍>阈值) → 取较小版 + overEdited。
        let stub = StubProvider(first: "AA BB CC DD EE FF",
                                strict: "the quick brown DD EE FF")
        let engine = ReviewEngine(client: stub)
        let r = try await engine.review(text: input, config: testConfig())
        XCTAssertEqual(stub.calls, ["firstPass", "strict"])
        XCTAssertTrue(r.overEdited)
        XCTAssertEqual(r.corrected, "the quick brown DD EE FF")
    }

    func testMinAbsEditsExemption() async throws {
        // 6 词输入，但只改 1 词（editedWords=2 不成立——replace=2）。用 minAbs 较大触发豁免。
        let stub = StubProvider(first: "the quick brown fox jumps NOW")
        let engine = ReviewEngine(client: stub)
        // minAbsEdits=3：editedWords(替换1词=2) <= 3 → 豁免，不重试。
        let r = try await engine.review(text: input, config: testConfig(minAbs: 3))
        XCTAssertEqual(stub.calls, ["firstPass"])
        XCTAssertEqual(r.corrected, "the quick brown fox jumps NOW")
    }
}
