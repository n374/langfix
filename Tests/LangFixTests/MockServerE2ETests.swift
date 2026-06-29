import XCTest
@testable import LangFix

/// 端到端：真实 URLSession 经 ReviewEngine → AIClient → HTTP → 本地 mock server，验证整条链路打通。
final class MockServerE2ETests: XCTestCase {

    private func chatBody(corrected: String, hasIssues: Bool = true) -> String {
        let content = reviewResultContent(original: "echo", corrected: corrected, hasIssues: hasIssues)
        // 经 JSON 转义嵌入 message.content
        let outer: [String: Any] = [
            "choices": [["message": ["content": content], "finish_reason": "stop"]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: outer)
        return String(decoding: data, as: UTF8.self)
    }

    func testHappyPathOverRealSocket() async throws {
        let server = try MockOpenAIServer { _ in
            (200, self.chatBody(corrected: "I went there yesterday"))
        }
        try server.start()
        defer { server.stop() }

        let cfg = testConfig(structured: .jsonObject, baseURL: server.baseURL, model: "mock")
        let engine = ReviewEngine()   // 真实 AIClient + 真实 URLSession
        let r = try await engine.review(text: "I have went there yesterday", config: cfg)

        XCTAssertEqual(r.corrected, "I went there yesterday")
        XCTAssertEqual(r.original, "I have went there yesterday")   // 基准一致性

        let segs = DiffEngine.segments(r.original, r.corrected)
        XCTAssertTrue(segs.contains { if case .delete = $0 { return true } else { return false } },
                      "diff 应包含删除片段")
    }

    func testGuardTriggersStrictRetryOverRealSocket() async throws {
        // mock server 按请求体里是否含「严格重试」标记分别返回：
        //   首轮 → 大改（超阈值）；strict → 最小改动（低于阈值）。
        let server = try MockOpenAIServer { body in
            if body.contains("本轮为严格重试") {
                return (200, self.chatBody(corrected: "the quick brown fox jumps now"))   // 仅改 1 词
            } else {
                return (200, self.chatBody(corrected: "AA BB CC DD EE FF"))                // 全改
            }
        }
        try server.start()
        defer { server.stop() }

        let cfg = testConfig(structured: .jsonObject, baseURL: server.baseURL, model: "mock")
        let engine = ReviewEngine()
        let r = try await engine.review(text: "the quick brown fox jumps over", config: cfg)

        // 护栏应触发 strict 重试并采用最小改动版
        XCTAssertEqual(r.corrected, "the quick brown fox jumps now")
        XCTAssertFalse(r.overEdited)
    }

    func testAuthErrorOverRealSocket() async {
        let server: MockOpenAIServer
        do {
            server = try MockOpenAIServer { _ in (401, "{\"error\":\"unauthorized\"}") }
            try server.start()
        } catch { XCTFail("server 启动失败: \(error)"); return }
        defer { server.stop() }

        let cfg = testConfig(structured: .jsonObject, baseURL: server.baseURL, model: "mock")
        let engine = ReviewEngine()
        do {
            _ = try await engine.review(text: "hello world over socket", config: cfg)
            XCTFail("应抛 auth 错误")
        } catch let e as ReviewError {
            if case .auth = e {} else { XCTFail("期望 .auth，实际 \(e)") }
        } catch {
            XCTFail("期望 ReviewError.auth，实际 \(error)")
        }
    }
}
