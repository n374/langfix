import Foundation
@testable import LangFix

func testConfig(structured: StructuredMode = .jsonObject,
                threshold: Double = 0.35,
                minWords: Int = 6,
                minAbs: Int = 2,
                baseURL: String = "https://example.test/v1",
                apiKey: String = "test-key",
                model: String = "test-model",
                streaming: Bool = true) -> AppConfig {
    AppConfig(baseURL: baseURL, apiKey: apiKey, model: model,
              temperature: 0.2, maxChars: 4000,
              diffThreshold: threshold, minWordsForGuard: minWords, minAbsEdits: minAbs,
              structuredMode: structured, streamingEnabled: streaming)
}

/// ReviewEngine 测试用的桩：按 mode 返回预设 corrected，并记录调用顺序。
/// 测试串行 await 调用，calls 无并发访问，故 @unchecked Sendable。
final class StubProvider: ReviewProviding, @unchecked Sendable {
    let firstCorrected: String
    let strictCorrected: String?
    private(set) var calls: [String] = []   // "firstPass" / "strict"

    init(first: String, strict: String? = nil) {
        self.firstCorrected = first
        self.strictCorrected = strict
    }

    func review(text: String, config: AppConfig, mode: AIClient.Mode) async throws -> ReviewResult {
        let isStrict: Bool
        if case .strict = mode { isStrict = true } else { isStrict = false }
        calls.append(isStrict ? "strict" : "firstPass")
        let corrected = isStrict ? (strictCorrected ?? firstCorrected) : firstCorrected
        return ReviewResult(hasIssues: corrected != text, original: text,
                            corrected: corrected, summaryZh: "", issues: [])
    }
}

/// 桩：firstPass 返回预设 corrected，strict 一律 throw 指定错误（用于 D6 strict-throw 兜底测试）。
final class ThrowingStrictStub: ReviewProviding, @unchecked Sendable {
    let firstCorrected: String
    let strictError: ReviewError
    private(set) var calls: [String] = []

    init(first: String, strictError: ReviewError) {
        self.firstCorrected = first
        self.strictError = strictError
    }

    func review(text: String, config: AppConfig, mode: AIClient.Mode) async throws -> ReviewResult {
        if case .strict = mode {
            calls.append("strict")
            throw strictError
        }
        calls.append("firstPass")
        return ReviewResult(hasIssues: true, original: text, corrected: firstCorrected, summaryZh: "", issues: [])
    }
    // reviewStreaming 用协议默认实现（非流式 + 一次 finalizing preview）。
}

/// URLProtocol 桩：拦截 URLSession 请求，按注册的 handler 返回响应。
final class StubURLProtocol: URLProtocol {
    /// 返回 (statusCode, bodyData)。可用闭包内的计数器模拟多次调用的降级/截断。
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requestCount = 0

    static func reset() { handler = nil; requestCount = 0 }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let (code, data) = Self.handler?(request) ?? (200, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: code,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 构造一个走 StubURLProtocol 的 URLSession。
func stubbedSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: cfg)
}

/// 包装成 OpenAI Chat Completions 响应体。
func chatResponseJSON(content: String, finishReason: String = "stop") -> Data {
    let obj: [String: Any] = [
        "choices": [[
            "message": ["content": content],
            "finish_reason": finishReason,
        ]],
    ]
    return try! JSONSerialization.data(withJSONObject: obj)
}

/// 一个合法的 ReviewResult JSON 字符串（作为 message.content）。
func reviewResultContent(original: String, corrected: String, hasIssues: Bool = true) -> String {
    let obj: [String: Any] = [
        "has_issues": hasIssues,
        "original": original,
        "corrected": corrected,
        "summary_zh": "测试",
        "issues": [],
    ]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: data, encoding: .utf8)!
}
