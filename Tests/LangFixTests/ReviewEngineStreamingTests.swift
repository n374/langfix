import XCTest
@testable import LangFix

/// ReviewEngine 流式定稿 + D6 strict-throw 兜底。护栏算法与非流式一致，仅 firstPass 走流式。
@MainActor
final class ReviewEngineStreamingTests: XCTestCase {

    private let input = "the quick brown fox jumps over"

    // MARK: - 流式预览→定稿

    func testReviewStreamingNoGuardReturnsFirstPass() async throws {
        // 仅改 1 词（editedWords=2 <= minAbs 2）→ 短句/最小编辑豁免，无 strict。
        let stub = StubProvider(first: "the quick brown fox jumps now")
        let engine = ReviewEngine(client: stub)
        let rec = PreviewRecorder()
        let r = try await engine.reviewStreaming(text: input, config: testConfig()) { p in rec.record(p) }
        XCTAssertEqual(stub.calls, ["firstPass"])
        XCTAssertEqual(r.corrected, "the quick brown fox jumps now")
        XCTAssertFalse(r.overEdited)
    }

    func testReviewStreamingGuardTriggersStrictAndFinalizes() async throws {
        // firstPass 大改 → 护栏触发 → 冻结预览（.finalizing）→ strict 小改 → 采用 strict。
        let stub = StubProvider(first: "AA BB CC DD EE FF", strict: "the quick brown fox jumps now")
        let engine = ReviewEngine(client: stub)
        let rec = PreviewRecorder()
        let r = try await engine.reviewStreaming(text: input, config: testConfig()) { p in rec.record(p) }
        XCTAssertEqual(stub.calls, ["firstPass", "strict"])
        XCTAssertEqual(r.corrected, "the quick brown fox jumps now")
        XCTAssertFalse(r.overEdited)
        XCTAssertTrue(rec.sawFinalizing, "护栏触发后应发出 .finalizing 冻结预览")
    }

    func testReviewStreamingBothOverThresholdMarksOverEdited() async throws {
        let stub = StubProvider(first: "AA BB CC DD EE FF", strict: "the quick brown DD EE FF")
        let engine = ReviewEngine(client: stub)
        let r = try await engine.reviewStreaming(text: input, config: testConfig()) { _ in }
        XCTAssertEqual(stub.calls, ["firstPass", "strict"])
        XCTAssertTrue(r.overEdited)
        XCTAssertEqual(r.corrected, "the quick brown DD EE FF")
    }

    // MARK: - D6 strict-throw 兜底（统一应用于 review 与 reviewStreaming）

    func testD6ReviewStrictThrowFinalizesFirstPass() async throws {
        let stub = ThrowingStrictStub(first: "AA BB CC DD EE FF", strictError: .network("boom"))
        let engine = ReviewEngine(client: stub)
        let r = try await engine.review(text: input, config: testConfig())
        XCTAssertEqual(stub.calls, ["firstPass", "strict"])
        XCTAssertTrue(r.overEdited)
        XCTAssertEqual(r.corrected, "AA BB CC DD EE FF", "strict throw → 定稿 firstPass")
    }

    func testD6ReviewStreamingStrictThrowFinalizesFirstPass() async throws {
        let stub = ThrowingStrictStub(first: "AA BB CC DD EE FF", strictError: .network("boom"))
        let engine = ReviewEngine(client: stub)
        let r = try await engine.reviewStreaming(text: input, config: testConfig()) { _ in }
        XCTAssertEqual(stub.calls, ["firstPass", "strict"])
        XCTAssertTrue(r.overEdited)
        XCTAssertEqual(r.corrected, "AA BB CC DD EE FF")
    }

    func testD6DoesNotSwallowCancellation() async {
        // strict 抛 .cancelled 时不走 D6 兜底，原样上抛（保留取消语义）。
        let stub = ThrowingStrictStub(first: "AA BB CC DD EE FF", strictError: .cancelled)
        let engine = ReviewEngine(client: stub)
        do {
            _ = try await engine.review(text: input, config: testConfig())
            XCTFail("应上抛 cancelled")
        } catch let e as ReviewError {
            if case .cancelled = e {} else { XCTFail("期望 .cancelled，实际 \(e)") }
        } catch { XCTFail("期望 ReviewError.cancelled") }
    }
}
