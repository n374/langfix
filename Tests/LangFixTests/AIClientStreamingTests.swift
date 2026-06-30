import XCTest
@testable import LangFix

/// AIClient 流式层：SSE 解析、200-非 SSE / 400-stream / 400-response_format 分类、
/// finish_reason==length 定稿、半截流瞬时回退（不缓存）、开关关闭不带 stream。
/// 用唯一 model 名隔离静态缓存（流式能力 / tier），避免跨用例污染。
@MainActor
final class AIClientStreamingTests: XCTestCase {

    override func setUp() { StreamingStubURLProtocol.reset() }
    override func tearDown() { StreamingStubURLProtocol.reset() }

    private func sseDelta(_ s: String) -> Data {
        let obj: [String: Any] = ["choices": [["delta": ["content": s]]]]
        let d = try! JSONSerialization.data(withJSONObject: obj)
        return Data("data: \(String(decoding: d, as: UTF8.self))\n\n".utf8)
    }

    func testStreamingHappyPathParsesSSE() async throws {
        let content = reviewResultContent(original: "x", corrected: "I went there yesterday")
        StreamingStubURLProtocol.handler = { _, _ in StreamStubResponse(chunks: sseFrames(content: content)) }
        let client = AIClient(session: streamingStubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "s-happy")
        let rec = PreviewRecorder()

        let r = try await client.reviewStreaming(text: "I have went there yesterday", config: cfg, mode: .firstPass) { p in
            rec.record(p)
        }
        XCTAssertEqual(r.corrected, "I went there yesterday")
        XCTAssertTrue(rec.sawReceivingNonEmptyCorrected, "应在接收期发出非空 corrected 预览")
        XCTAssertTrue(StreamingStubURLProtocol.capturedBodies.first?.contains("\"stream\":true") ?? false,
                      "流式请求体应带 stream:true")
    }

    func test200NonSSEFallsBackSilently() async throws {
        let content = reviewResultContent(original: "x", corrected: "fallback ok")
        StreamingStubURLProtocol.handler = { _, _ in
            // 200 但非 SSE（普通 JSON，无 data: 帧）→ 流式不支持，回退非流式；非流式请求同样返回普通 JSON。
            StreamStubResponse(contentType: "application/json", chunks: [chatResponseJSON(content: content)])
        }
        let client = AIClient(session: streamingStubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "s-nonsse")
        let rec = PreviewRecorder()

        let r = try await client.reviewStreaming(text: "some input text here", config: cfg, mode: .firstPass) { p in rec.record(p) }
        XCTAssertEqual(r.corrected, "fallback ok")
        XCTAssertGreaterThanOrEqual(StreamingStubURLProtocol.requestCount, 2, "应在回退后发起非流式第二请求")
        XCTAssertTrue(rec.previews.isEmpty, "preview 尚未发出即回退 → 用户无感，无预览帧")
    }

    func test400StreamUnsupportedFallsBack() async throws {
        let content = reviewResultContent(original: "x", corrected: "after fallback")
        StreamingStubURLProtocol.handler = { _, n in
            if n == 1 {
                return StreamStubResponse(status: 400, contentType: "application/json",
                                          chunks: [Data(#"{"error":"stream is not supported by this endpoint"}"#.utf8)])
            }
            return StreamStubResponse(contentType: "application/json", chunks: [chatResponseJSON(content: content)])
        }
        let client = AIClient(session: streamingStubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "s-400stream")

        let r = try await client.reviewStreaming(text: "another input here ok", config: cfg, mode: .firstPass) { _ in }
        XCTAssertEqual(r.corrected, "after fallback")
        XCTAssertGreaterThanOrEqual(StreamingStubURLProtocol.requestCount, 2)
    }

    func test400ResponseFormatDegradesTierStaysStreaming() async throws {
        let content = reviewResultContent(original: "x", corrected: "degraded streaming")
        StreamingStubURLProtocol.handler = { _, n in
            if n == 1 {
                // json_schema tier 的 400：response_format 不支持（非 stream）→ tier 降级，仍流式。
                return StreamStubResponse(status: 400, contentType: "application/json",
                                          chunks: [Data(#"{"error":"response_format is not supported"}"#.utf8)])
            }
            return StreamStubResponse(chunks: sseFrames(content: content))   // json_object 流式成功
        }
        let client = AIClient(session: streamingStubbedSession())
        let cfg = testConfig(structured: .auto, model: "s-400rf")

        let r = try await client.reviewStreaming(text: "input text to degrade", config: cfg, mode: .firstPass) { _ in }
        XCTAssertEqual(r.corrected, "degraded streaming")
        XCTAssertGreaterThanOrEqual(StreamingStubURLProtocol.requestCount, 2)
        // 第二请求仍是流式（tier 降级而非回退非流式）。
        XCTAssertTrue(StreamingStubURLProtocol.capturedBodies.last?.contains("\"stream\":true") ?? false)
    }

    func testSingleTierStream400FallsBackNonStreaming() async throws {
        // 单 tier（jsonSchema）下流式请求吃非 stream 的 400（response_format 与 stream 组合不支持），
        // 无可降级 tier → 不应把 .server(400) 抛给用户，而是回退非流式重试并成功（Codex 高-1 修复）。
        let content = reviewResultContent(original: "x", corrected: "nonstream recovered")
        StreamingStubURLProtocol.handler = { _, n in
            if n == 1 {
                return StreamStubResponse(status: 400, contentType: "application/json",
                                          chunks: [Data(#"{"error":"response_format is not supported when streaming"}"#.utf8)])
            }
            return StreamStubResponse(contentType: "application/json", chunks: [chatResponseJSON(content: content)])
        }
        let client = AIClient(session: streamingStubbedSession())
        let cfg = testConfig(structured: .jsonSchema, model: "s-single400")
        let r = try await client.reviewStreaming(text: "single tier stream input", config: cfg, mode: .firstPass) { _ in }
        XCTAssertEqual(r.corrected, "nonstream recovered", "单 tier 流式 400 应回退非流式而非报错")
        XCTAssertGreaterThanOrEqual(StreamingStubURLProtocol.requestCount, 2)
    }

    func testAmbiguous400NotCachedSoStreamingRetried() async throws {
        // 含 response_format 的歧义 400（同时含 stream 字样）不得永久缓存 unsupported（Codex 中-2 修复）：
        // 第一次回退非流式恢复；第二次 review 仍应尝试流式（有 preview）。
        let content = reviewResultContent(original: "x", corrected: "ambiguous case ok")
        StreamingStubURLProtocol.handler = { _, n in
            switch n {
            case 1:
                return StreamStubResponse(status: 400, contentType: "application/json",
                                          chunks: [Data(#"{"error":"response_format is not supported when stream=true"}"#.utf8)])
            case 2:
                return StreamStubResponse(contentType: "application/json", chunks: [chatResponseJSON(content: content)])
            default:
                return StreamStubResponse(chunks: sseFrames(content: content))
            }
        }
        let client = AIClient(session: streamingStubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "s-ambig400")

        let rec1 = PreviewRecorder()
        let r1 = try await client.reviewStreaming(text: "ambiguous input one", config: cfg, mode: .firstPass) { p in rec1.record(p) }
        XCTAssertEqual(r1.corrected, "ambiguous case ok")
        XCTAssertTrue(rec1.previews.isEmpty, "首次 400 即回退，无预览")

        let rec2 = PreviewRecorder()
        let r2 = try await client.reviewStreaming(text: "ambiguous input two", config: cfg, mode: .firstPass) { p in rec2.record(p) }
        XCTAssertEqual(r2.corrected, "ambiguous case ok")
        XCTAssertTrue(rec2.sawReceivingNonEmptyCorrected, "未缓存 unsupported → 第二次仍尝试流式（有预览）")
    }

    func testFinishReasonLengthBumpsNonStreaming() async throws {
        let full = reviewResultContent(original: "x", corrected: "full result text")
        StreamingStubURLProtocol.handler = { _, n in
            if n == 1 {
                return StreamStubResponse(chunks: sseFrames(content: "{\"corrected\": \"partia", finish: "length"))
            }
            return StreamStubResponse(contentType: "application/json", chunks: [chatResponseJSON(content: full, finishReason: "stop")])
        }
        let client = AIClient(session: streamingStubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "s-length")
        let rec = PreviewRecorder()

        let r = try await client.reviewStreaming(text: "yet another input here", config: cfg, mode: .firstPass) { p in rec.record(p) }
        XCTAssertEqual(r.corrected, "full result text")
        XCTAssertTrue(rec.sawFinalizing, "截断后应切 .finalizing 冻结预览")
        XCTAssertGreaterThanOrEqual(StreamingStubURLProtocol.requestCount, 2)
    }

    func testMidStreamErrorFallsBackAndRecovers() async throws {
        // 流读取中途 didFailWithError（半截流）→ 静默回退非流式定稿，结果正确。
        // 注：URLSession 在 error 时会丢弃已缓冲未投递的字节，故此桩下 .finalizing 帧不保证可见；
        // 「冻结预览」行为由 testFinishReasonLengthBumpsNonStreaming 确定性覆盖。
        let full = reviewResultContent(original: "x", corrected: "recovered via nonstream")
        StreamingStubURLProtocol.handler = { [self] _, n in
            if n == 1 {
                return StreamStubResponse(chunks: [sseDelta(#"{"corrected": "stream par"#)], failAtEnd: true)
            }
            return StreamStubResponse(contentType: "application/json", chunks: [chatResponseJSON(content: full)])
        }
        let client = AIClient(session: streamingStubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "s-transient")

        let r = try await client.reviewStreaming(text: "transient stream input ok", config: cfg, mode: .firstPass) { _ in }
        XCTAssertEqual(r.corrected, "recovered via nonstream", "中途出错应回退非流式并正常出结果")
        XCTAssertGreaterThanOrEqual(StreamingStubURLProtocol.requestCount, 2, "应发起非流式第二请求")
    }

    func testStreamingDisabledSilentNonStreaming() async throws {
        let content = reviewResultContent(original: "x", corrected: "plain non stream")
        StreamingStubURLProtocol.handler = { _, _ in
            StreamStubResponse(contentType: "application/json", chunks: [chatResponseJSON(content: content)])
        }
        let client = AIClient(session: streamingStubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "s-off", streaming: false)
        let rec = PreviewRecorder()

        let r = try await client.reviewStreaming(text: "switch off input here", config: cfg, mode: .firstPass) { p in rec.record(p) }
        XCTAssertEqual(r.corrected, "plain non stream")
        XCTAssertTrue(rec.previews.isEmpty, "关开关 → 无任何 preview")
        XCTAssertFalse(StreamingStubURLProtocol.capturedBodies.first?.contains("\"stream\":true") ?? false,
                       "关开关 → 请求体不得带 stream:true")
    }

    func testStreamingAuthErrorPropagates() async {
        StreamingStubURLProtocol.handler = { _, _ in
            StreamStubResponse(status: 401, contentType: "application/json", chunks: [Data(#"{"error":"bad key"}"#.utf8)])
        }
        let client = AIClient(session: streamingStubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "s-auth")
        do {
            _ = try await client.reviewStreaming(text: "auth fail input here", config: cfg, mode: .firstPass) { _ in }
            XCTFail("应抛 auth 错误，不当流式不支持")
        } catch let e as ReviewError {
            if case .auth = e {} else { XCTFail("期望 .auth，实际 \(e)") }
        } catch { XCTFail("期望 ReviewError.auth") }
    }
}
