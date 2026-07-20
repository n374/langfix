import Foundation

/// 供 FollowUpSession 依赖与测试注入的抽象：追问上下文 → AI 纯文本回答（design D4）。
/// 与 ReviewProviding 正交：走**无 response_format 的纯文本通道**，不喂 PartialReviewParser。
protocol FollowUpProviding: Sendable {
    /// 流式追问：逐块 `onDelta` 回吐增量文本，返回**权威完整回答**（回退发生时返回值为整体替换后的定稿，
    /// 调用方应以返回值为该轮答案真相，onDelta 仅用于实时预览）。
    func followUpStreaming(context: FollowUpContext, config: AppConfig,
                           onDelta: @MainActor @Sendable (String) async -> Void) async throws -> String
    /// 非流式追问回退：一次性返回完整回答。
    func followUp(context: FollowUpContext, config: AppConfig) async throws -> String
}

/// 供 ReviewEngine 依赖与测试注入的抽象：输入文本 → 校验过的 ReviewResult。
protocol ReviewProviding: Sendable {
    func review(text: String, config: AppConfig, mode: AIClient.Mode) async throws -> ReviewResult

    /// 流式入口：增量解析时通过 `onPreview` 顺序回吐预览快照，返回最终（已校验）结果。
    /// 默认实现（见下方 extension）回落到非流式 `review`，发一次「整体作为终值」的 preview，
    /// 故既有 conformer（含 StubProvider）无需强改即可编译。AIClient override 提供真流式。
    func reviewStreaming(text: String, config: AppConfig, mode: AIClient.Mode,
                         onPreview: @MainActor @Sendable (StreamingPreview) async -> Void) async throws -> ReviewResult
}

extension ReviewProviding {
    /// 默认实现：非流式拿最终结果，再发一次 `.finalizing` 整体预览。
    func reviewStreaming(text: String, config: AppConfig, mode: AIClient.Mode,
                         onPreview: @MainActor @Sendable (StreamingPreview) async -> Void) async throws -> ReviewResult {
        let r = try await review(text: text, config: config, mode: mode)
        await onPreview(StreamingPreview(corrected: r.corrected, summary: r.summary,
                                         issues: r.issues, alternative: r.alternative, stage: .finalizing))
        return r
    }
}

/// 调 OpenAI 兼容 Chat Completions，做结构化输出三级降级 + 客户端校验 + 基准一致性。
/// 对上层只暴露「输入文本 → 校验过的 ReviewResult」，屏蔽端点能力差异。
/// 无可变实例状态（探测缓存放在 actor），故 Sendable，可跨并发安全使用。
/// 参见 docs/architecture/modules/ai-client.md。
final class AIClient: ReviewProviding, FollowUpProviding, Sendable {

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

    // 流式能力缓存（正交于结构化 tier 缓存）：决定是否加 `stream:true`。
    // 协议级不支持（200 非 SSE / 400-stream / 全程无 data: 帧）才缓存 unsupported；
    // 瞬时断流不污染（最多本次回退）。见 design §2.5。
    enum StreamSupport: Sendable { case unknown, supported, unsupported }
    private actor StreamCache {
        private var map: [String: StreamSupport] = [:]
        func get(_ key: String) -> StreamSupport { map[key] ?? .unknown }
        func set(_ key: String, _ v: StreamSupport) { map[key] = v }
    }
    private static let streamCap = StreamCache()

    /// 流式不可用的内部信号：`cacheUnsupported` 标记是否为「协议级不支持」需缓存。
    /// 仅在 AIClient 内部传递，最终被 reviewStreaming 捕获并回退非流式（对上层透明）。
    private struct StreamFallback: Error { let cacheUnsupported: Bool }

    // MARK: - 对外入口

    /// 解析失败的类别记录（design D5 评审 R2-2）：`.contract`（合法 JSON 但违反字段契约）优先级高于
    /// `.decode`（非合法 JSON / 纯文本），一旦出现不被后续 `.decode` 覆盖——收口处据此分叉：
    /// `.contract` → fail loud 进错误态（禁走 fallback）；`.decode` → 维持既有「展示原文」fallback。
    private static func note(_ e: ReviewError, into lastError: inout Error?) {
        if case .contract = e { lastError = e; return }
        if let cur = lastError as? ReviewError, case .contract = cur { return }
        lastError = e
    }

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
                    if finish2 != "length" {
                        switch parseAttempt(content2, localInput: localInput) {
                        case .success(let r):
                            await Self.cap.set(Self.cacheKey(cfg), tier)
                            return r
                        case .failure(let e):
                            // bump 后契约违规不得吞成「结果被截断」fallback（评审 R2-1）：归入 lastError 继续 tier 流程。
                            if case .contract = e { Self.note(e, into: &lastError); continue }
                            // .decode（bump 后仍非合法 JSON）→ 维持截断 fallback（现状语义）。
                        }
                    }
                    // 仍截断 / bump 后非合法 JSON → 纯文本兜底。
                    return ReviewResult.fallback(localInput: localInput, note: L10n.fallbackTruncated(cfg.userLanguage))
                }

                switch parseAttempt(content, localInput: localInput) {
                case .success(let r):
                    await Self.cap.set(Self.cacheKey(cfg), tier)
                    return r
                case .failure(let e):
                    Self.note(e, into: &lastError)
                }
                // 解析失败 → 一次修复重试（仅在当前 tier）。
                if let repaired = try? await repair(input: localInput, cfg: cfg, tier: tier, badContent: content) {
                    switch parseAttempt(repaired, localInput: localInput) {
                    case .success(let r):
                        await Self.cap.set(Self.cacheKey(cfg), tier)
                        return r
                    case .failure(let e):
                        Self.note(e, into: &lastError)
                    }
                }
                // 当前 tier 解析不出来 → 降级到下一 tier（lastError 已按类别记录）。
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

        // 所有 tier 都没成功：契约违规 fail loud 进错误态；纯解析问题给纯文本兜底；否则抛错（design D5）。
        if let re = lastError as? ReviewError {
            switch re {
            case .contract: throw re
            case .decode: return ReviewResult.fallback(localInput: localInput, note: L10n.fallbackParseFailed(cfg.userLanguage))
            default: break
            }
        }
        throw lastError ?? ReviewError.decode("unknown error")
    }

    // MARK: - 流式入口（override 协议默认实现，提供真流式）

    /// 真流式 review：内部镜像 `review` 的 tier 循环，但每次尝试走 SSE 流式；
    /// 增量 delta 经 PartialReviewParser 转预览，顺序 `await onPreview`。
    /// 流式不可用（协议级或瞬时）一律静默回退非流式 `review`，对上层透明（见 design §2.5）。
    func reviewStreaming(text localInput: String, config cfg: AppConfig, mode: Mode,
                         onPreview: @MainActor @Sendable (StreamingPreview) async -> Void) async throws -> ReviewResult {
        let key = Self.cacheKey(cfg)
        // 仅当开关开 AND 端点未知/已知支持流式才尝试；已知不支持 → 直接静默非流式（preview 未发出，用户无感）。
        guard cfg.streamingEnabled, await Self.streamCap.get(key) != .unsupported else {
            return try await review(text: localInput, config: cfg, mode: mode)
        }
        do {
            return try await streamingReview(input: localInput, cfg: cfg, mode: mode, onPreview: onPreview)
        } catch let fallback as StreamFallback {
            if fallback.cacheUnsupported { await Self.streamCap.set(key, .unsupported) }
            // 回退非流式定稿（preview 若已发出，UI 维持「校对预览中」，定稿后切最终结果，不弹错）。
            return try await review(text: localInput, config: cfg, mode: mode)
        }
        // 其余 ReviewError（auth/rateLimited/server/cancelled）按既有错误路径上抛。
    }

    /// 流式版 tier 循环：镜像 `review`，差异在于首次请求走 `streamChat`。
    private func streamingReview(input localInput: String, cfg: AppConfig, mode: Mode,
                                 onPreview: @MainActor @Sendable (StreamingPreview) async -> Void) async throws -> ReviewResult {
        let key = Self.cacheKey(cfg)
        let cachedMode = await Self.cap.get(key)
        let tiers = tierPlan(for: cfg, cached: cachedMode)
        var lastError: Error?

        for tier in tiers {
            do {
                var parser = PartialReviewParser()
                let (content, finish) = try await streamChat(input: localInput, cfg: cfg, tier: tier,
                                                             mode: mode, parser: &parser, onPreview: onPreview)

                // 截断：切 .finalizing 冻结预览，后台非流式 bump 重发一次（D7：不擦预览）。
                if finish == "length" {
                    await onPreview(parser.snapshot(stage: .finalizing))
                    let (content2, finish2) = try await chat(input: localInput, cfg: cfg, tier: tier, mode: mode, bumpTokens: true)
                    if finish2 != "length" {
                        switch parseAttempt(content2, localInput: localInput) {
                        case .success(let r):
                            await Self.cap.set(key, tier)
                            await Self.streamCap.set(key, .supported)
                            return r
                        case .failure(let e):
                            // bump 后契约违规不得吞成「结果被截断」fallback（评审 R2-1，与非流式入口同构）。
                            if case .contract = e { Self.note(e, into: &lastError); continue }
                        }
                    }
                    return ReviewResult.fallback(localInput: localInput, note: L10n.fallbackTruncated(cfg.userLanguage))
                }

                switch parseAttempt(content, localInput: localInput) {
                case .success(let r):
                    await Self.cap.set(key, tier)
                    await Self.streamCap.set(key, .supported)
                    return r
                case .failure(let e):
                    Self.note(e, into: &lastError)
                }
                // 解析失败 → 非流式修复重试（仅当前 tier）。
                if let repaired = try? await repair(input: localInput, cfg: cfg, tier: tier, badContent: content) {
                    switch parseAttempt(repaired, localInput: localInput) {
                    case .success(let r):
                        await Self.cap.set(key, tier)
                        return r
                    case .failure(let e):
                        Self.note(e, into: &lastError)
                    }
                }
            } catch let e as ReviewError {
                switch e {
                case .server(let code) where code == 400:
                    // response_format 结构化问题 → tier 降级（仍尝试流式）。
                    lastError = e
                    continue
                default:
                    throw e   // 鉴权/网络/限流/取消等上抛
                }
            }
            // StreamFallback 不在此 catch，故会冒泡到 reviewStreaming（协议级/瞬时回退）。
        }

        if let re = lastError as? ReviewError {
            switch re {
            case .contract:
                // 契约违规（合法 JSON 缺关键解释字段）→ fail loud 进错误态，禁走 fallback（design D5）。
                throw re
            case .decode:
                // 流式内容解析失败（流本身没问题）→ 纯文本兜底。
                return ReviewResult.fallback(localInput: localInput, note: L10n.fallbackParseFailed(cfg.userLanguage))
            case .server:
                // 所有可用 tier 的流式请求都吃 400（response_format/结构化与 stream 组合问题、或单 tier 无可降级）。
                // ≠ 端点不支持流式 → 回退非流式重试（不缓存 unsupported）。非流式 review 会用同样的 tier 体系
                // 自行成功或把真实错误抛给用户（design §2.5「模糊 400 → 先降级再回退非流式、不缓存」）。
                throw StreamFallback(cacheUnsupported: false)
            default:
                break
            }
        }
        throw lastError ?? ReviewError.decode("unknown error")
    }

    /// 单次流式请求：发 `stream:true`，逐行解析 SSE，累积 delta.content，喂 parser 触发 onPreview。
    /// 返回 (累积完整 content, 末帧 finish_reason)。流式不可用/瞬时异常抛 StreamFallback。
    private func streamChat(input: String, cfg: AppConfig, tier: StructuredMode, mode: Mode,
                            parser: inout PartialReviewParser,
                            onPreview: @MainActor @Sendable (StreamingPreview) async -> Void) async throws -> (content: String, finish: String?) {
        var req = try makeRequest(cfg: cfg)
        var body: [String: Any] = [
            "model": cfg.model,
            "temperature": cfg.temperature,
            "stream": true,
            "messages": [
                ["role": "system", "content": Prompt.system(mode: mode, target: cfg.targetLanguage, user: cfg.userLanguage)],
                ["role": "user", "content": Prompt.user(input)],
            ],
        ]
        switch tier {
        case .jsonSchema:
            body["response_format"] = ["type": "json_schema", "json_schema": Prompt.jsonSchema]
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .text, .auto:
            break
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let resp: URLResponse
        do {
            (bytes, resp) = try await session.bytes(for: req)
        } catch is CancellationError {
            throw ReviewError.cancelled
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw ReviewError.cancelled
        } catch {
            throw ReviewError.network(error.localizedDescription)
        }

        guard let http = resp as? HTTPURLResponse else { throw ReviewError.network(L10n.t(.noHTTPResponse, cfg.userLanguage)) }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw ReviewError.auth
        case 429: throw ReviewError.rateLimited
        case 400:
            // 保留并分类 400 body（既有 chat 抛 .server(400) 丢了 body，故流式路径单独读取分类）：
            // - 纯 stream 不支持 → 协议级，缓存 unsupported 并静默回退非流式；
            // - 提到 response_format/结构化（含「response_format 与 stream 组合不支持」这类同时含 stream 的歧义文案）
            //   → 当结构化 tier 问题降级，response_format 优先于 stream 判定，避免误把整体流式能力打死。
            //   降级耗尽后由 streamingReview 末尾统一回退非流式（不缓存）。
            let lower = ((try? await Self.collect(bytes)) ?? "").lowercased()
            let mentionsRF = lower.contains("response_format") || lower.contains("response format")
                || lower.contains("json_schema") || lower.contains("json_object")
                || lower.contains("json schema") || lower.contains("json object")
            let mentionsStream = lower.contains("stream")
            if mentionsStream && !mentionsRF { throw StreamFallback(cacheUnsupported: true) }
            throw ReviewError.server(400)
        default:
            throw ReviewError.server(http.statusCode)
        }

        // 200：逐行读 SSE。
        var accumulated = ""
        var finish: String? = nil
        var sawDataFrame = false
        do {
            for try await line in bytes.lines {
                if Task.isCancelled { throw ReviewError.cancelled }
                guard line.hasPrefix("data:") else { continue }   // 非 SSE 数据行忽略（注释/事件名等）
                sawDataFrame = true
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let pdata = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(StreamChunk.self, from: pdata),
                      let choice = chunk.choices.first else { continue }
                if let f = choice.finishReason { finish = f }
                if let delta = choice.delta?.content, !delta.isEmpty {
                    accumulated += delta
                    if let preview = parser.feed(delta) { await onPreview(preview) }
                }
            }
        } catch let e as ReviewError {
            throw e   // cancelled
        } catch is CancellationError {
            throw ReviewError.cancelled
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw ReviewError.cancelled
        } catch {
            // 流读取中途异常（半截流 / 临时 EOF / SSE 解码偶发失败）= 瞬时，非协议级。
            if sawDataFrame {
                await onPreview(parser.snapshot(stage: .finalizing))   // 冻结已显示预览
                throw StreamFallback(cacheUnsupported: false)          // 本次非流式定稿，不缓存
            }
            throw StreamFallback(cacheUnsupported: true)               // 从未拿到 SSE → 协议级不支持
        }

        if !sawDataFrame {
            // 200 但 body 非 SSE / 全程无 data: 帧 → 协议级不支持流式。
            throw StreamFallback(cacheUnsupported: true)
        }
        return (accumulated, finish)
    }

    /// 把 AsyncBytes 收集为完整字符串（仅用于读 400 错误 body 做分类）。
    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await b in bytes { data.append(b) }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 追问答疑（FollowUpProviding · design D4，纯文本 SSE，复用骨架）

    /// 流式追问：优先真流式，协议级/瞬时不可用静默回退非流式（对上层透明）。
    /// 上下文超限（400/413 body 含 context_length 等）→ 抛 `.contextLengthExceeded`（不回退，非流式也会超限）。
    func followUpStreaming(context ctx: FollowUpContext, config cfg: AppConfig,
                           onDelta: @MainActor @Sendable (String) async -> Void) async throws -> String {
        let key = Self.cacheKey(cfg)
        // 已知不支持流式 → 直接非流式（不触发 onDelta，用户由 UI「正在回答…」占位无感）。
        guard cfg.streamingEnabled, await Self.streamCap.get(key) != .unsupported else {
            return try await followUp(context: ctx, config: cfg)
        }
        do {
            let text = try await streamFollowUp(context: ctx, cfg: cfg, onDelta: onDelta)
            await Self.streamCap.set(key, .supported)
            return text
        } catch let fallback as StreamFallback {
            if fallback.cacheUnsupported { await Self.streamCap.set(key, .unsupported) }
            // 回退非流式定稿：返回值将由调用方**整体替换**已流出的 partial（design D4，不 append）。
            return try await followUp(context: ctx, config: cfg)
        }
        // 其余 ReviewError（auth/rateLimited/server/cancelled/contextLengthExceeded）按既有错误路径上抛。
    }

    /// 非流式追问：一次请求拿完整回答。
    func followUp(context ctx: FollowUpContext, config cfg: AppConfig) async throws -> String {
        var req = try makeRequest(cfg: cfg)
        let body: [String: Any] = [
            "model": cfg.model,
            "temperature": cfg.temperature,
            "messages": Self.followUpMessages(ctx, user: cfg.userLanguage),
        ]
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
        guard let http = resp as? HTTPURLResponse else { throw ReviewError.network(L10n.t(.noHTTPResponse, cfg.userLanguage)) }
        try Self.mapFollowUpStatus(http.statusCode, body: String(decoding: data, as: UTF8.self))
        guard let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let choice = parsed.choices.first else {
            throw ReviewError.decode("cannot parse follow-up response envelope")
        }
        // 正确性红线（评审#1）：截断 / 空回答不当成功。
        if choice.finishReason == "length" { throw ReviewError.truncated }
        let content = choice.message.content ?? choice.message.refusal ?? ""
        if content.trimmed.isEmpty { throw ReviewError.truncated }
        return content
    }

    /// 单次流式追问请求：发 `stream:true`（无 response_format），逐行解析 SSE，累积 delta.content，
    /// 每块 `await onDelta`。返回累积完整回答。流式不可用/瞬时异常抛 StreamFallback；上下文超限抛 ReviewError。
    private func streamFollowUp(context ctx: FollowUpContext, cfg: AppConfig,
                               onDelta: @MainActor @Sendable (String) async -> Void) async throws -> String {
        var req = try makeRequest(cfg: cfg)
        let body: [String: Any] = [
            "model": cfg.model,
            "temperature": cfg.temperature,
            "stream": true,
            "messages": Self.followUpMessages(ctx, user: cfg.userLanguage),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let resp: URLResponse
        do {
            (bytes, resp) = try await session.bytes(for: req)
        } catch is CancellationError {
            throw ReviewError.cancelled
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw ReviewError.cancelled
        } catch {
            throw ReviewError.network(error.localizedDescription)
        }

        guard let http = resp as? HTTPURLResponse else { throw ReviewError.network(L10n.t(.noHTTPResponse, cfg.userLanguage)) }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw ReviewError.auth
        case 429: throw ReviewError.rateLimited
        case 400, 413:
            // 读 body 分类：上下文超限 → 明确可重试错误（design D5 服务端路径）；
            // 纯 stream 不支持 → 协议级回退非流式；其余 400 归 .server(400)。
            let lower = ((try? await Self.collect(bytes)) ?? "").lowercased()
            if Self.mentionsContextLength(lower) { throw ReviewError.contextLengthExceeded }
            if http.statusCode == 413 { throw ReviewError.contextLengthExceeded }   // 413 语义即 payload 过大
            if lower.contains("stream") { throw StreamFallback(cacheUnsupported: true) }
            throw ReviewError.server(400)
        default:
            throw ReviewError.server(http.statusCode)
        }

        var accumulated = ""
        var sawDataFrame = false
        var sawDone = false
        var finish: String? = nil
        do {
            for try await line in bytes.lines {
                if Task.isCancelled { throw ReviewError.cancelled }
                guard line.hasPrefix("data:") else { continue }
                sawDataFrame = true
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { sawDone = true; break }
                guard let pdata = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(StreamChunk.self, from: pdata),
                      let choice = chunk.choices.first else { continue }
                if let f = choice.finishReason { finish = f }
                if let delta = choice.delta?.content, !delta.isEmpty {
                    accumulated += delta
                    await onDelta(delta)
                }
            }
        } catch let e as ReviewError {
            throw e   // cancelled
        } catch is CancellationError {
            throw ReviewError.cancelled
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw ReviewError.cancelled
        } catch {
            // 流读取中途异常 = 瞬时；已见帧 → 本次非流式定稿（不缓存），从未见帧 → 协议级不支持。
            throw StreamFallback(cacheUnsupported: !sawDataFrame)
        }
        if !sawDataFrame {
            // 200 但 body 非 SSE / 全程无 data: 帧 → 协议级不支持流式。
            throw StreamFallback(cacheUnsupported: true)
        }
        // 正确性红线（评审#1）：截断 / 空回答绝不当成功返回。
        if finish == "length" { throw ReviewError.truncated }
        if accumulated.trimmed.isEmpty {
            // 见帧但无有效内容（全是错误帧/空帧）→ 非流式重试一次拿真内容；仍空由 followUp/会话层 fail loud。
            throw StreamFallback(cacheUnsupported: false)
        }
        // 无完成信号（既无 [DONE] 也无 finish_reason）→ 流可能被中途干净截断（纯文本无结构校验兜底，
        // 评审#1 复审）→ 回退非流式拿有 finish_reason 的权威定稿，绝不把无终止标记的半截当完整。
        if !sawDone && finish == nil {
            throw StreamFallback(cacheUnsupported: false)
        }
        return accumulated
    }

    /// 追问消息序列：system + 上下文包(data) + 历史轮(user/assistant) + 当前问题(user, data)。
    /// history 已由调用方按预算裁剪（design D5）；上下文包与当前问题恒在。
    static func followUpMessages(_ ctx: FollowUpContext, user: AppLanguage) -> [[String: String]] {
        var msgs: [[String: String]] = [
            ["role": "system", "content": Prompt.followUpSystem(user: user)],
            ["role": "user", "content": Prompt.followUpContext(ctx, user: user)],
        ]
        for turn in ctx.history {
            msgs.append(["role": "user", "content": Prompt.followUpQuestion(turn.question, user: user)])
            msgs.append(["role": "assistant", "content": turn.answer])
        }
        msgs.append(["role": "user", "content": Prompt.followUpQuestion(ctx.question, user: user)])
        return msgs
    }

    /// 追问非流式响应状态码映射（含上下文超限分类）。
    static func mapFollowUpStatus(_ code: Int, body: String) throws {
        switch code {
        case 200...299: return
        case 401, 403: throw ReviewError.auth
        case 429: throw ReviewError.rateLimited
        case 400:
            if mentionsContextLength(body.lowercased()) { throw ReviewError.contextLengthExceeded }
            throw ReviewError.server(400)
        case 413: throw ReviewError.contextLengthExceeded
        default: throw ReviewError.server(code)
        }
    }

    /// 是否为上下文超限的 body 特征（design D4 关键词）。
    static func mentionsContextLength(_ lower: String) -> Bool {
        lower.contains("context_length") || lower.contains("context length")
            || lower.contains("maximum context") || lower.contains("too long")
            || lower.contains("maximum_context") || lower.contains("context_length_exceeded")
            || (lower.contains("token") && (lower.contains("exceed") || lower.contains("maximum") || lower.contains("limit")))
    }

    // MARK: - 测试连接

    /// 用当前 baseURL+apiKey+model 发最小请求，验证端点与 model 可用性。返回 (ok, 用户语言消息)。
    func probe(config cfg: AppConfig) async -> (ok: Bool, message: String) {
        let lang = cfg.userLanguage
        guard cfg.isComplete else { return (false, L10n.probeMissing(cfg.missingFields(lang), lang)) }
        do {
            var req = try makeRequest(cfg: cfg)
            let body: [String: Any] = [
                "model": cfg.model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1,
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return (false, L10n.t(.noHTTPResponse, lang)) }
            switch http.statusCode {
            case 200...299: return (true, L10n.probeOK(cfg.model, lang))
            case 401, 403: return (false, L10n.t(.probeAuth, lang))
            case 404: return (false, L10n.t(.probe404, lang))
            case 400:
                let msg = (String(data: data, encoding: .utf8) ?? "").lowercased()
                return (false, msg.contains("model") ? L10n.probeModelUnavailable(cfg.model, lang) : L10n.t(.probe400, lang))
            case 429: return (false, L10n.t(.probe429, lang))
            default: return (false, L10n.probeHTTP(http.statusCode, lang))
            }
        } catch {
            return (false, L10n.probeNetworkError(error.localizedDescription, lang))
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
                ["role": "system", "content": Prompt.system(mode: mode, target: cfg.targetLanguage, user: cfg.userLanguage)],
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
            throw ReviewError.network(L10n.t(.noHTTPResponse, cfg.userLanguage))
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
            throw ReviewError.decode("cannot parse chat response envelope")
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
                ["role": "system", "content": Prompt.system(mode: .firstPass, target: cfg.targetLanguage, user: cfg.userLanguage)],
                ["role": "user", "content": Prompt.user(input)],
                ["role": "assistant", "content": badContent],
                ["role": "user", "content": Prompt.repairHint(user: cfg.userLanguage)],
            ],
        ]
        if tier == .jsonObject { body["response_format"] = ["type": "json_object"] }
        if tier == .jsonSchema { body["response_format"] = ["type": "json_schema", "json_schema": Prompt.jsonSchema] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: req)
        guard let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = parsed.choices.first?.message.content else {
            throw ReviewError.decode("repair retry returned no content")
        }
        return content
    }

    private func makeRequest(cfg: AppConfig) throws -> URLRequest {
        let base = cfg.baseURL.trimmed.hasSuffix("/") ? String(cfg.baseURL.trimmed.dropLast()) : cfg.baseURL.trimmed
        guard let url = URL(string: base + "/chat/completions") else {
            throw ReviewError.network(L10n.t(.invalidBaseURL, cfg.userLanguage))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        return req
    }

    // MARK: - 解析与校验（含基准一致性）

    /// 单次解析尝试（design D5 评审 R2-2 规范形态）：返回 Result 保留错误**类别**，调用点不得用 try? 丢弃。
    /// - `.decode`：内容非合法 JSON（含纯文本端点回复）→ 收口处走既有「展示原文」fallback；
    /// - `.contract`：合法 JSON 但违反字段契约（关键解释字段缺失等，Issue/ReviewResult 解码 fail loud）
    ///   → 收口处 fail loud 进错误态，**禁止**走 fallback。
    private func parseAttempt(_ content: String, localInput: String) -> Result<ReviewResult, ReviewError> {
        let json = Self.extractJSON(content)
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return .failure(.decode("content is not valid JSON"))
        }
        do {
            var result = try JSONDecoder().decode(ReviewResult.self, from: data)
            // 基准一致性：不信任模型回显的 original，一律以本地输入为准。
            result.original = localInput
            // has_issues=false 时 corrected 必须等于本地输入。
            if !result.hasIssues { result.corrected = localInput }
            // corrected 为空兜底。
            if result.corrected.trimmed.isEmpty { result.corrected = localInput }
            return .success(result)
        } catch {
            // JSON 语法已合法，解码失败即字段契约违规（Issue.reason / summary 关键字段缺失等）。
            let detail = (error as? DecodingError).map(String.init(describing:)) ?? error.localizedDescription
            return .failure(.contract(detail))
        }
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

// MARK: - 流式 SSE chunk（OpenAI chat.completion.chunk）

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?            // 个别帧可能缺 delta（如纯 usage 帧）→ 可空
        let finishReason: String?
        enum CodingKeys: String, CodingKey { case delta; case finishReason = "finish_reason" }
    }
    let choices: [Choice]
}
