import Foundation
import XCTest
@testable import LangFix

// MARK: - 流式 URLProtocol 桩

/// 一次流式请求的桩响应：状态码 + content-type + 分块 body（多次 didLoad 模拟增量）+ 是否末尾报错。
struct StreamStubResponse {
    var status: Int = 200
    var contentType: String = "text/event-stream"
    var chunks: [Data] = []
    /// true：交付完 chunks 后以 didFailWithError 收尾（模拟半截流 / 临时 EOF，无 [DONE]）。
    var failAtEnd: Bool = false
}

/// 流式桩协议：按请求序号返回 StreamStubResponse，分块交付以驱动 AsyncBytes 增量。
/// 同时捕获每次请求体（读 httpBodyStream），供断言 `stream:true` 是否存在。
final class StreamingStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Int) -> StreamStubResponse)?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var capturedBodies: [String] = []

    static func reset() { handler = nil; requestCount = 0; capturedBodies = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let n = Self.requestCount
        Self.capturedBodies.append(Self.bodyString(request))
        let r = Self.handler?(request, n) ?? StreamStubResponse()
        let resp = HTTPURLResponse(url: request.url!, statusCode: r.status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": r.contentType])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        for c in r.chunks { client?.urlProtocol(self, didLoad: c) }
        if r.failAtEnd {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// 读取请求体（URLProtocol 下 JSON body 常经 httpBodyStream 传递）。
    private static func bodyString(_ req: URLRequest) -> String {
        if let d = req.httpBody { return String(decoding: d, as: UTF8.self) }
        guard let stream = req.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 构造走 StreamingStubURLProtocol 的 URLSession。
func streamingStubbedSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StreamingStubURLProtocol.self]
    return URLSession(configuration: cfg)
}

// MARK: - SSE 帧构造

/// 把一段完整 content 文本切成多个 SSE `data:` 帧（每帧一小段 delta.content），末帧带 finish_reason + [DONE]。
func sseFrames(content: String, chunkSize: Int = 6, finish: String = "stop") -> [Data] {
    var frames: [Data] = []
    let chars = Array(content)
    var i = 0
    while i < chars.count {
        let piece = String(chars[i..<min(i + chunkSize, chars.count)])
        let obj: [String: Any] = ["choices": [["delta": ["content": piece]]]]
        let d = try! JSONSerialization.data(withJSONObject: obj)
        frames.append(Data("data: \(String(decoding: d, as: UTF8.self))\n\n".utf8))
        i += chunkSize
    }
    let fin: [String: Any] = ["choices": [["delta": [:], "finish_reason": finish]]]
    let fd = try! JSONSerialization.data(withJSONObject: fin)
    frames.append(Data("data: \(String(decoding: fd, as: UTF8.self))\n\n".utf8))
    frames.append(Data("data: [DONE]\n\n".utf8))
    return frames
}

// MARK: - preview / phase 记录器

/// 记录 reviewStreaming 过程中收到的 preview 帧（@MainActor 顺序追加）。
@MainActor
final class PreviewRecorder {
    private(set) var previews: [StreamingPreview] = []
    func record(_ p: StreamingPreview) { previews.append(p) }
    var sawReceivingNonEmptyCorrected: Bool {
        previews.contains { $0.stage == .receiving && !$0.corrected.isEmpty }
    }
    var sawFinalizing: Bool { previews.contains { $0.stage == .finalizing } }
}

/// 记录 ReviewState.Phase 跳转序列，用于「首字早于末字」「取消后不再更新」等顺序断言。
@MainActor
final class PhaseRecorder {
    enum Mark: Equatable { case loading, streaming, stopped, result, error }
    private(set) var marks: [Mark] = []
    func record(_ phase: ReviewState.Phase) {
        switch phase {
        case .loading: marks.append(.loading)
        case .streaming: marks.append(.streaming)
        case .stopped: marks.append(.stopped)
        case .result: marks.append(.result)
        case .error: marks.append(.error)
        }
    }
}
