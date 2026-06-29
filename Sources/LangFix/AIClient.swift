import Foundation

/// 供 ReviewEngine 依赖与测试注入的抽象：输入文本 → 校验过的 ReviewResult。
protocol ReviewProviding: Sendable {
    func review(text: String, config: AppConfig, mode: AIClient.Mode) async throws -> ReviewResult
}

/// 调 OpenAI 兼容 Chat Completions，做结构化输出三级降级 + 客户端校验 + 基准一致性。
/// 对上层只暴露「输入文本 → 校验过的 ReviewResult」，屏蔽端点能力差异。
/// 无可变实例状态（探测缓存放在 actor），故 Sendable，可跨并发安全使用。
/// 参见 docs/architecture/modules/ai-client.md。
final class AIClient: ReviewProviding, Sendable {

    enum Mode: Sendable { case firstPass, strict }

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    // 端点能力探测缓存（actor 保证并发安全）：key = "baseURL|model" → 已知可用的最高 tier。
    private actor CapabilityCache {
        private var map: [String: StructuredMode] = [:]
        func get(_ key: String) -> StructuredMode? { map[key] }
        func set(_ key: String, _ mode: StructuredMode) { map[key] = mode }
    }
    private static let cap = CapabilityCache()
    private static func cacheKey(_ cfg: AppConfig) -> String { "\(cfg.baseURL)|\(cfg.model)" }

    // MARK: - 对外入口

    /// 返回已用本地输入校正过 original / 跑过 schema 校验的结果。失败抛 ReviewError。
    func review(text localInput: String, config cfg: AppConfig, mode: Mode) async throws -> ReviewResult {
        let cachedMode = await Self.cap.get(Self.cacheKey(cfg))
        let tiers = tierPlan(for: cfg, cached: cachedMode)
        var lastError: Error?

        for tier in tiers {
            do {
                let (content, finish) = try await chat(input: localInput, cfg: cfg, tier: tier, mode: mode)

                // 截断：提高 max_tokens 重发一次。
                if finish == "length" {
                    let (content2, finish2) = try await chat(input: localInput, cfg: cfg, tier: tier, mode: mode, bumpTokens: true)
                    if finish2 != "length", let r = try? parseAndValidate(content2, localInput: localInput) {
                        await Self.cap.set(Self.cacheKey(cfg), tier)
                        return r
                    }
                    // 仍截断 → 纯文本兜底。
                    return ReviewResult.fallback(localInput: localInput, note: "结果被截断，已尽力展示原文")
                }

                if let r = try? parseAndValidate(content, localInput: localInput) {
                    await Self.cap.set(Self.cacheKey(cfg), tier)
                    return r
                }
                // 解析失败 → 一次修复重试（仅在当前 tier）。
                if let repaired = try? await repair(input: localInput, cfg: cfg, tier: tier, badContent: content),
                   let r = try? parseAndValidate(repaired, localInput: localInput) {
                    await Self.cap.set(Self.cacheKey(cfg), tier)
                    return r
                }
                // 当前 tier 解析不出来 → 降级到下一 tier。
                lastError = ReviewError.decode("tier \(tier.rawValue) 无法解析为合法 ReviewResult")
            } catch let e as ReviewError {
                switch e {
                case .server(let code) where code == 400:
                    // 极可能是该端点不支持此 response_format → 降级。
                    lastError = e
                    continue
                default:
                    throw e   // 鉴权/网络/限流等直接上抛
                }
            }
        }

        // 所有 tier 都没成功：若是纯解析问题，给纯文本兜底；否则抛错。
        if let re = lastError as? ReviewError, case .decode = re {
            return ReviewResult.fallback(localInput: localInput, note: "解析失败，已尽力展示原文")
        }
        throw lastError ?? ReviewError.decode("未知错误")
    }

    // MARK: - 测试连接

    /// 用当前 baseURL+apiKey+model 发最小请求，验证端点与 model 可用性。返回 (ok, 中文消息)。
    func probe(config cfg: AppConfig) async -> (ok: Bool, message: String) {
        guard cfg.isComplete else { return (false, "缺少：\(cfg.missingFields.joined(separator: "、"))") }
        do {
            var req = try makeRequest(cfg: cfg)
            let body: [String: Any] = [
                "model": cfg.model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1,
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return (false, "无 HTTP 响应") }
            switch http.statusCode {
            case 200...299: return (true, "连接成功，模型 \(cfg.model) 可用")
            case 401, 403: return (false, "鉴权失败：请检查 API key")
            case 404: return (false, "404：请检查 baseURL 或 model 是否存在")
            case 400:
                let msg = (String(data: data, encoding: .utf8) ?? "").lowercased()
                return (false, msg.contains("model") ? "模型不可用：\(cfg.model)" : "请求被拒（400）")
            case 429: return (false, "限流（429），请稍后再试")
            default: return (false, "HTTP \(http.statusCode)")
            }
        } catch {
            return (false, "网络错误：\(error.localizedDescription)")
        }
    }

    // MARK: - tier 计划

    private func tierPlan(for cfg: AppConfig, cached: StructuredMode?) -> [StructuredMode] {
        switch cfg.structuredMode {
        case .jsonSchema: return [.jsonSchema]
        case .jsonObject: return [.jsonObject]
        case .text: return [.text]
        case .auto:
            if let cached { return [cached] }
            return [.jsonSchema, .jsonObject, .text]
        }
    }

    // MARK: - 单次请求

    private func chat(input: String, cfg: AppConfig, tier: StructuredMode,
                      mode: Mode, bumpTokens: Bool = false) async throws -> (content: String, finish: String?) {
        var req = try makeRequest(cfg: cfg)
        var body: [String: Any] = [
            "model": cfg.model,
            "temperature": cfg.temperature,
            "messages": [
                ["role": "system", "content": Prompt.system(mode: mode)],
                ["role": "user", "content": Prompt.user(input)],
            ],
        ]
        if bumpTokens { body["max_tokens"] = 2048 }
        switch tier {
        case .jsonSchema:
            body["response_format"] = ["type": "json_schema", "json_schema": Prompt.jsonSchema]
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .text, .auto:
            break
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch is CancellationError {
            throw ReviewError.cancelled
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw ReviewError.cancelled
        } catch {
            throw ReviewError.network(error.localizedDescription)
        }

        guard let http = resp as? HTTPURLResponse else {
            throw ReviewError.network("无 HTTP 响应")
        }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw ReviewError.auth
        case 429: throw ReviewError.rateLimited
        case 400: throw ReviewError.server(400)
        default: throw ReviewError.server(http.statusCode)
        }

        guard let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let choice = parsed.choices.first else {
            throw ReviewError.decode("无法解析 chat 响应外层")
        }
        // refusal：当作空内容，交由上层走修复/降级。
        let content = choice.message.content ?? choice.message.refusal ?? ""
        return (content, choice.finishReason)
    }

    private func repair(input: String, cfg: AppConfig, tier: StructuredMode, badContent: String) async throws -> String {
        var req = try makeRequest(cfg: cfg)
        var body: [String: Any] = [
            "model": cfg.model,
            "temperature": cfg.temperature,
            "messages": [
                ["role": "system", "content": Prompt.system(mode: .firstPass)],
                ["role": "user", "content": Prompt.user(input)],
                ["role": "assistant", "content": badContent],
                ["role": "user", "content": Prompt.repairHint],
            ],
        ]
        if tier == .jsonObject { body["response_format"] = ["type": "json_object"] }
        if tier == .jsonSchema { body["response_format"] = ["type": "json_schema", "json_schema": Prompt.jsonSchema] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: req)
        guard let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = parsed.choices.first?.message.content else {
            throw ReviewError.decode("修复重试无内容")
        }
        return content
    }

    private func makeRequest(cfg: AppConfig) throws -> URLRequest {
        let base = cfg.baseURL.trimmed.hasSuffix("/") ? String(cfg.baseURL.trimmed.dropLast()) : cfg.baseURL.trimmed
        guard let url = URL(string: base + "/chat/completions") else {
            throw ReviewError.network("无效的 baseURL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        return req
    }

    // MARK: - 解析与校验（含基准一致性）

    private func parseAndValidate(_ content: String, localInput: String) throws -> ReviewResult {
        let json = Self.extractJSON(content)
        guard let data = json.data(using: .utf8),
              var result = try? JSONDecoder().decode(ReviewResult.self, from: data) else {
            throw ReviewError.decode("内容非合法 ReviewResult JSON")
        }
        // 基准一致性：不信任模型回显的 original，一律以本地输入为准。
        result.original = localInput
        // has_issues=false 时 corrected 必须等于本地输入。
        if !result.hasIssues { result.corrected = localInput }
        // corrected 为空兜底。
        if result.corrected.trimmed.isEmpty { result.corrected = localInput }
        return result
    }

    /// 从可能包裹 ```json fenced``` 或前后有杂字的文本里提取 JSON 主体。
    static func extractJSON(_ s: String) -> String {
        var t = s.trimmed
        if t.hasPrefix("```") {
            // 去掉 ```json ... ``` 围栏
            if let firstNL = t.firstIndex(of: "\n") { t = String(t[t.index(after: firstNL)...]) }
            if let fence = t.range(of: "```", options: .backwards) { t = String(t[..<fence.lowerBound]) }
            t = t.trimmed
        }
        // 截取第一个 { 到最后一个 }
        if let lo = t.firstIndex(of: "{"), let hi = t.lastIndex(of: "}"), lo < hi {
            return String(t[lo...hi])
        }
        return t
    }
}

// MARK: - Chat 响应外层

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let refusal: String?
        }
        let message: Message
        let finishReason: String?
        enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
    }
    let choices: [Choice]
}
