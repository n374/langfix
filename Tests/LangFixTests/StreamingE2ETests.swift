import XCTest
@testable import LangFix

/// 端到端（真实 URLSession + URLProtocol + AsyncBytes，经 ReviewEngine→AIClient 全链路）：
/// 首字早于末字（顺序断言，非时钟）、流式与非流式最终一致、静默回退无可见报错、开关不经 streaming。
/// 真实 socket 的非流式链路由 MockServerE2ETests 覆盖；此处聚焦流式增量解析路径。
@MainActor
final class StreamingE2ETests: XCTestCase {

    override func setUp() { StreamingStubURLProtocol.reset() }
    override func tearDown() { StreamingStubURLProtocol.reset() }

    /// AC-1：断言事件序列中 `.streaming(corrected 非空)` 早于 `.result`（顺序断言）。
    func testFirstCharStreamsBeforeFinalResult() async throws {
        let content = reviewResultContent(original: "x", corrected: "I went there yesterday")
        StreamingStubURLProtocol.handler = { _, _ in StreamStubResponse(chunks: sseFrames(content: content, chunkSize: 4)) }
        let engine = ReviewEngine(client: AIClient(session: streamingStubbedSession()))
        let cfg = testConfig(structured: .jsonObject, model: "e2e-order")

        let phases = PhaseRecorder()
        let r = try await engine.reviewStreaming(text: "I have went there yesterday", config: cfg) { p in
            if !p.corrected.isEmpty { phases.record(.streaming(p)) }   // 模拟 Coordinator 进入 streaming 态
        }
        phases.record(.result(r))   // 终态

        XCTAssertEqual(r.corrected, "I went there yesterday")
        let firstStreaming = phases.marks.firstIndex(of: .streaming)
        let resultIdx = phases.marks.firstIndex(of: .result)
        XCTAssertNotNil(firstStreaming, "应出现 streaming 态（首字早于末字）")
        XCTAssertNotNil(resultIdx)
        XCTAssertLessThan(firstStreaming!, resultIdx!, "streaming 必须早于 result")
    }

    /// AC-1/AC-2：流式与非流式对同一内容的最终 corrected 必须一致。
    func testStreamingAndNonStreamingSameCorrected() async throws {
        let content = reviewResultContent(original: "x", corrected: "the final corrected text")

        StreamingStubURLProtocol.handler = { _, _ in StreamStubResponse(chunks: sseFrames(content: content)) }
        let streamClient = AIClient(session: streamingStubbedSession())
        let streamed = try await streamClient.reviewStreaming(text: "raw input text here please", config: testConfig(model: "e2e-cmp-s"), mode: .firstPass) { _ in }

        StreamingStubURLProtocol.reset()
        StreamingStubURLProtocol.handler = { _, _ in StreamStubResponse(contentType: "application/json", chunks: [chatResponseJSON(content: content)]) }
        let plainClient = AIClient(session: streamingStubbedSession())
        let plain = try await plainClient.review(text: "raw input text here please", config: testConfig(model: "e2e-cmp-p"), mode: .firstPass)

        XCTAssertEqual(streamed.corrected, plain.corrected)
        XCTAssertEqual(streamed.corrected, "the final corrected text")
    }

    /// AC-4：端点不支持流式 → 静默回退，终态为 .result，绝不出现 .error。
    func testSilentFallbackNoErrorPhase() async throws {
        let content = reviewResultContent(original: "x", corrected: "silent fallback result")
        StreamingStubURLProtocol.handler = { _, _ in
            StreamStubResponse(contentType: "application/json", chunks: [chatResponseJSON(content: content)])
        }
        let engine = ReviewEngine(client: AIClient(session: streamingStubbedSession()))
        let cfg = testConfig(structured: .jsonObject, model: "e2e-fallback")

        let phases = PhaseRecorder()
        do {
            let r = try await engine.reviewStreaming(text: "fallback path input ok", config: cfg) { p in phases.record(.streaming(p)) }
            phases.record(.result(r))
            XCTAssertEqual(r.corrected, "silent fallback result")
        } catch { phases.record(.error("\(error)")) }

        XCTAssertFalse(phases.marks.contains(.error), "静默回退不得出现 error 态")
        XCTAssertEqual(phases.marks.last, .result)
    }

    /// AC-5：关开关 → 走 engine.review（非流式），请求体不带 stream:true。
    func testSwitchOffUsesNonStreaming() async throws {
        let content = reviewResultContent(original: "x", corrected: "switch off result")
        StreamingStubURLProtocol.handler = { _, _ in
            StreamStubResponse(contentType: "application/json", chunks: [chatResponseJSON(content: content)])
        }
        let engine = ReviewEngine(client: AIClient(session: streamingStubbedSession()))
        let cfg = testConfig(structured: .jsonObject, model: "e2e-off", streaming: false)

        // Coordinator 在关开关时直接调 engine.review（见 AppCoordinator.start）。此处直接验证 review 路径。
        let r = try await engine.review(text: "switch off input here ok", config: cfg)
        XCTAssertEqual(r.corrected, "switch off result")
        XCTAssertFalse(StreamingStubURLProtocol.capturedBodies.first?.contains("\"stream\":true") ?? false,
                       "非流式路径请求体不得带 stream:true")
    }
}
