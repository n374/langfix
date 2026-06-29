import XCTest
@testable import LangFix

final class AIClientTests: XCTestCase {

    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    func testJSONObjectHappyPath() async throws {
        StubURLProtocol.handler = { _ in
            (200, chatResponseJSON(content: reviewResultContent(original: "irrelevant", corrected: "I went there")))
        }
        let client = AIClient(session: stubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "m-happy")
        let r = try await client.review(text: "I have went there", config: cfg, mode: .firstPass)
        XCTAssertEqual(r.corrected, "I went there")
    }

    func testBaselineOriginalOverriddenByLocalInput() async throws {
        // 模型回显的 original 是错的，结果必须以本地输入为准。
        StubURLProtocol.handler = { _ in
            (200, chatResponseJSON(content: reviewResultContent(original: "MODEL WRONG ECHO", corrected: "fixed text")))
        }
        let client = AIClient(session: stubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "m-baseline")
        let r = try await client.review(text: "my real input", config: cfg, mode: .firstPass)
        XCTAssertEqual(r.original, "my real input")
    }

    func testAuthErrorThrows() async {
        StubURLProtocol.handler = { _ in (401, Data("{\"error\":\"bad key\"}".utf8)) }
        let client = AIClient(session: stubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "m-auth")
        do {
            _ = try await client.review(text: "hello world here", config: cfg, mode: .firstPass)
            XCTFail("应抛 auth 错误")
        } catch let e as ReviewError {
            if case .auth = e {} else { XCTFail("期望 .auth，实际 \(e)") }
        } catch { XCTFail("期望 ReviewError.auth") }
    }

    func testAutoDegradesFrom400ToSuccess() async throws {
        // auto：第一次（json_schema）返回 400 → 降级；第二次（json_object）返回 200 合法。
        StubURLProtocol.handler = { _ in
            if StubURLProtocol.requestCount == 1 {
                return (400, Data("{\"error\":\"response_format not supported\"}".utf8))
            }
            return (200, chatResponseJSON(content: reviewResultContent(original: "x", corrected: "degraded ok")))
        }
        let client = AIClient(session: stubbedSession())
        let cfg = testConfig(structured: .auto, model: "m-degrade")
        let r = try await client.review(text: "some input text here", config: cfg, mode: .firstPass)
        XCTAssertEqual(r.corrected, "degraded ok")
        XCTAssertGreaterThanOrEqual(StubURLProtocol.requestCount, 2)
    }

    func testFinishReasonLengthTriggersBumpRetry() async throws {
        // 第一次 finish_reason=length（截断）→ 提高 max_tokens 重发；第二次 stop + 合法。
        StubURLProtocol.handler = { _ in
            if StubURLProtocol.requestCount == 1 {
                return (200, chatResponseJSON(content: "{partial", finishReason: "length"))
            }
            return (200, chatResponseJSON(content: reviewResultContent(original: "x", corrected: "full result"), finishReason: "stop"))
        }
        let client = AIClient(session: stubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "m-length")
        let r = try await client.review(text: "another input here please", config: cfg, mode: .firstPass)
        XCTAssertEqual(r.corrected, "full result")
        XCTAssertGreaterThanOrEqual(StubURLProtocol.requestCount, 2)
    }
}
