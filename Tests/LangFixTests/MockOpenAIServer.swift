import Foundation
import Network

/// 一个最小的本地 OpenAI 兼容 HTTP server（仅供端到端测试）。
/// 监听 127.0.0.1 上 OS 分配的端口，解析 /chat/completions 请求体，按 responder 返回响应。
final class MockOpenAIServer {

    /// 入参：请求体字符串；返回：(HTTP 状态码, 响应 JSON 字符串)。
    typealias Responder = (String) -> (Int, String)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock.openai.server")
    private let responder: Responder
    private(set) var port: UInt16 = 0

    init(responder: @escaping Responder) throws {
        self.responder = responder
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port?.rawValue else {
            throw NSError(domain: "MockOpenAIServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "server 未就绪"])
        }
        port = p
    }

    func stop() { listener.cancel() }

    // MARK: - 连接处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }

            if self.isComplete(buf) || isComplete {
                let body = self.extractBody(buf)
                let (status, json) = self.responder(body)
                self.respond(conn, status: status, json: json)
            } else if error == nil {
                self.receive(conn, buffer: buf)
            } else {
                conn.cancel()
            }
        }
    }

    private func headerBodySplit(_ data: Data) -> (headerEnd: Int, contentLength: Int)? {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = data.range(of: sep) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<r.lowerBound)
        let header = String(decoding: headerData, as: UTF8.self)
        var len = 0
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                len = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return (r.upperBound, len)
    }

    private func isComplete(_ data: Data) -> Bool {
        guard let (bodyStart, len) = headerBodySplit(data) else { return false }
        return data.count - bodyStart >= len
    }

    private func extractBody(_ data: Data) -> String {
        guard let (bodyStart, len) = headerBodySplit(data), len > 0,
              bodyStart + len <= data.count else { return "" }
        return String(decoding: data.subdata(in: bodyStart..<(bodyStart + len)), as: UTF8.self)
    }

    private func respond(_ conn: NWConnection, status: Int, json: String) {
        let payload = Data(json.utf8)
        let header = "HTTP/1.1 \(status) OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
