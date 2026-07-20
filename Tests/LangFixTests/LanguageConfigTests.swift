import XCTest
@testable import LangFix

// MARK: - LanguagePolicy（design D1/D2：truth table 与不变式）

final class LanguagePolicyTests: XCTestCase {

    // spec「语言配置」三分支 truth table。
    func testLocaleDefaults() {
        XCTAssertEqual(LanguagePolicy.defaults(forLocaleIdentifier: "zh-Hans-CN").user, .chinese)
        XCTAssertEqual(LanguagePolicy.defaults(forLocaleIdentifier: "zh-Hans-CN").target, .english)
        XCTAssertEqual(LanguagePolicy.defaults(forLocaleIdentifier: "zh_TW").user, .chinese)
        XCTAssertEqual(LanguagePolicy.defaults(forLocaleIdentifier: "en-US").user, .english)
        XCTAssertEqual(LanguagePolicy.defaults(forLocaleIdentifier: "en-US").target, .chinese)
        // 非中英 locale → 用户=英、目标=中（唯一确定，不歧义）。
        XCTAssertEqual(LanguagePolicy.defaults(forLocaleIdentifier: "ja-JP").user, .english)
        XCTAssertEqual(LanguagePolicy.defaults(forLocaleIdentifier: "ja-JP").target, .chinese)
        XCTAssertEqual(LanguagePolicy.defaults(forLocaleIdentifier: "de_DE").user, .english)
        XCTAssertEqual(LanguagePolicy.defaults(forLocaleIdentifier: "de_DE").target, .chinese)
    }

    // spec「目标语言必须异于用户语言」：相等 → 目标强制翻转（确定性修复，不 crash）。
    func testNormalizedEnforcesTargetNotEqualUser() {
        XCTAssertEqual(LanguagePolicy.normalized(user: .chinese, target: .chinese).target, .english)
        XCTAssertEqual(LanguagePolicy.normalized(user: .english, target: .english).target, .chinese)
        let ok = LanguagePolicy.normalized(user: .chinese, target: .english)
        XCTAssertEqual(ok.user, .chinese)
        XCTAssertEqual(ok.target, .english)
    }

    // 脏数据（非法 rawValue / 相等态）→ sanitize 确定性修复。
    func testSanitizeDirtyData() {
        // 非法 raw → locale 兜底。
        let bad = LanguagePolicy.sanitize(userRaw: "fr", targetRaw: "xx", localeIdentifier: "zh-Hans")
        XCTAssertEqual(bad.user, .chinese)
        XCTAssertEqual(bad.target, .english)
        // 手改 defaults 相等态 → 目标翻转。
        let eq = LanguagePolicy.sanitize(userRaw: "en", targetRaw: "en", localeIdentifier: "en-US")
        XCTAssertEqual(eq.user, .english)
        XCTAssertEqual(eq.target, .chinese)
        // nil（键缺失）→ locale 默认。
        let none = LanguagePolicy.sanitize(userRaw: nil, targetRaw: nil, localeIdentifier: "ja-JP")
        XCTAssertEqual(none.user, .english)
        XCTAssertEqual(none.target, .chinese)
    }

    func testAppLanguageOther() {
        XCTAssertEqual(AppLanguage.chinese.other, .english)
        XCTAssertEqual(AppLanguage.english.other, .chinese)
    }
}

// MARK: - 迁移（design D2：老用户自动迁移 / 新装预填）

@MainActor
final class LanguageMigrationTests: XCTestCase {

    private func freshSuite(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // spec「老用户升级自动迁移不被打断」：任一 v1 键有持久化值 → 中/英 + 已配置。
    func testLegacyUserMigratesToConfiguredZhEn() {
        let d = freshSuite("langfix.test.migrate.legacy")
        d.set("https://x/v1", forKey: "baseURL")   // 旧版使用痕迹
        SettingsStore.migrateLanguageIfNeeded(defaults: d, persistentDomainName: "langfix.test.migrate.legacy",
                                              localeIdentifier: "en-US", hasLegacyKeychainKey: false)
        XCTAssertEqual(d.string(forKey: "userLanguage"), "zh", "老用户迁移恒为 用户=中（truth table 最后一行，与 locale 无关）")
        XCTAssertEqual(d.string(forKey: "targetLanguage"), "en")
        XCTAssertTrue(d.bool(forKey: "languageConfigured"), "老用户视为已配置，不强制 onboarding")
        d.removePersistentDomain(forName: "langfix.test.migrate.legacy")
    }

    // 老用户宽口径（评审 R1-4）：仅 Keychain 有 key、无任何 defaults 键 → 仍判老用户。
    func testKeychainOnlyLegacySignalCountsAsLegacy() {
        let d = freshSuite("langfix.test.migrate.keychain")
        SettingsStore.migrateLanguageIfNeeded(defaults: d, persistentDomainName: "langfix.test.migrate.keychain",
                                              localeIdentifier: "zh-Hans", hasLegacyKeychainKey: true)
        XCTAssertTrue(d.bool(forKey: "languageConfigured"))
        XCTAssertEqual(d.string(forKey: "userLanguage"), "zh")
        d.removePersistentDomain(forName: "langfix.test.migrate.keychain")
    }

    // spec「新装首启强制配语言」：零痕迹 → 按 locale 预填、languageConfigured=false。
    func testFreshInstallPrefillsByLocaleUnconfigured() {
        for (locale, user, target) in [("zh-Hans-CN", "zh", "en"), ("en-GB", "en", "zh"), ("ja-JP", "en", "zh")] {
            let name = "langfix.test.migrate.fresh.\(locale)"
            let d = freshSuite(name)
            SettingsStore.migrateLanguageIfNeeded(defaults: d, persistentDomainName: name,
                                                  localeIdentifier: locale, hasLegacyKeychainKey: false)
            XCTAssertEqual(d.string(forKey: "userLanguage"), user, locale)
            XCTAssertEqual(d.string(forKey: "targetLanguage"), target, locale)
            XCTAssertFalse(d.bool(forKey: "languageConfigured"), "新装未确认前不算已配置")
            XCTAssertNotNil(d.object(forKey: "languageConfigured"), "显式写 false，保证迁移幂等")
            d.removePersistentDomain(forName: name)
        }
    }

    // MR 复验缺陷回归锚：registration domain 为进程全局，被其他套件的 register(defaults:) 污染后
    // （temperature 等恰是 legacyV1Keys 成员），新装判定必须不受影响——探测只看 persistentDomain。
    func testMigrationImmuneToRegistrationDomainPollution() {
        let name = "langfix.test.migrate.pollution"
        let d = freshSuite(name)
        // 显式重现串行测试进程的真实污染：注册与 legacyV1Keys 同名的默认值（进程全局生效）。
        d.register(defaults: ["temperature": 0.2, "maxChars": 4000])
        XCTAssertNotNil(d.object(forKey: "temperature"), "前置确认：object(forKey:) 确实会命中注册默认（污染成立）")
        SettingsStore.migrateLanguageIfNeeded(defaults: d, persistentDomainName: name,
                                              localeIdentifier: "en-GB", hasLegacyKeychainKey: false)
        XCTAssertFalse(d.bool(forKey: "languageConfigured"), "注册默认不得把新装误判为老用户")
        XCTAssertEqual(d.string(forKey: "userLanguage"), "en", "仍按 locale 预填（新装分支）")
        XCTAssertEqual(d.string(forKey: "targetLanguage"), "zh")
        d.removePersistentDomain(forName: name)
    }

    // 幂等：languageConfigured 键已存在（无论 true/false）→ 不再改写语言键。
    func testMigrationIdempotent() {
        let d = freshSuite("langfix.test.migrate.idempotent")
        SettingsStore.migrateLanguageIfNeeded(defaults: d, persistentDomainName: "langfix.test.migrate.idempotent",
                                              localeIdentifier: "zh-Hans", hasLegacyKeychainKey: false)
        // 用户手动改为 英/中 后再次启动（此时还写入了 baseURL）：不得被迁移覆盖回 中/英。
        d.set("en", forKey: "userLanguage")
        d.set("zh", forKey: "targetLanguage")
        d.set("https://x/v1", forKey: "baseURL")
        SettingsStore.migrateLanguageIfNeeded(defaults: d, persistentDomainName: "langfix.test.migrate.idempotent",
                                              localeIdentifier: "zh-Hans", hasLegacyKeychainKey: true)
        XCTAssertEqual(d.string(forKey: "userLanguage"), "en", "已有 languageConfigured 键 → 迁移不再执行")
        XCTAssertEqual(d.string(forKey: "targetLanguage"), "zh")
        d.removePersistentDomain(forName: "langfix.test.migrate.idempotent")
    }
}

// MARK: - L10n（design D4：key 双语齐全）

final class L10nTests: XCTestCase {

    // 全部 key 两语言均非空（enum 表编译期穷尽，此处锚定「非空」与「确实分语言」）。
    func testAllKeysNonEmptyBothLanguages() {
        for key in L10n.Key.allCases {
            XCTAssertFalse(L10n.t(key, .chinese).isEmpty, "\(key) 中文缺失")
            XCTAssertFalse(L10n.t(key, .english).isEmpty, "\(key) 英文缺失")
        }
    }

    // 代表性 key 两语言确实不同（防止占位复制）。
    func testRepresentativeKeysDiffer() {
        for key in [L10n.Key.sectionCorrected, .headerNoIssues, .composerPlaceholder,
                    .settingsLanguageSection, .errAuth, .followUpOutputGuardNote] {
            XCTAssertNotEqual(L10n.t(key, .chinese), L10n.t(key, .english), "\(key) 两语言不应相同")
        }
    }

    // 「修正 N」引用 token 同源（design D11）：UI badge 与解析器语言一致。
    func testFixBadgeToken() {
        XCTAssertEqual(L10n.fixBadge(2, .chinese), "修正 2")
        XCTAssertEqual(L10n.fixBadge(2, .english), "Fix 2")
    }
}

// MARK: - 字段去后缀 + 兼容解码 + fail loud（design D5）

final class LanguageFieldContractTests: XCTestCase {

    // spec「旧 _zh 字段兼容读取」：旧字段 payload → 解析成功、内容映射到新属性、不丢内容。
    func testLegacyZhPayloadDecodes() throws {
        let json = """
        {"has_issues": true, "original": "o", "corrected": "c",
         "translation_zh": "直译", "summary_zh": "总评",
         "issues": [{"index":1,"category":"grammar","severity":"error","before":"a","after":"b","reason_zh":"旧原因"}],
         "alternative": "alt", "alternative_reason_zh": "旧说明"}
        """
        let r = try JSONDecoder().decode(ReviewResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.translation, "直译")
        XCTAssertEqual(r.summary, "总评")
        XCTAssertEqual(r.issues.first?.reason, "旧原因")
        XCTAssertEqual(r.alternativeReason, "旧说明")
    }

    // 新字段 payload 正常解析；新旧同现时新字段优先。
    func testNewFieldsDecodeAndTakePriority() throws {
        let json = """
        {"has_issues": true, "original": "o", "corrected": "c",
         "translation": "new-t", "translation_zh": "old-t",
         "summary": "new-s", "summary_zh": "old-s",
         "issues": [{"index":1,"category":"tone","severity":"optional","before":"a","after":"b",
                     "reason":"new-r","reason_zh":"old-r"}]}
        """
        let r = try JSONDecoder().decode(ReviewResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.translation, "new-t")
        XCTAssertEqual(r.summary, "new-s")
        XCTAssertEqual(r.issues.first?.reason, "new-r")
    }

    // spec「关键字段缺失 fail loud」：issue.reason 新旧都缺 → 整体解码失败，绝不静默空解释当成功。
    func testMissingReasonFailsLoud() {
        let json = """
        {"has_issues": true, "original": "o", "corrected": "c", "summary": "s",
         "issues": [{"index":1,"category":"grammar","severity":"error","before":"a","after":"b"}]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ReviewResult.self, from: Data(json.utf8)),
                             "缺 reason 必须整体解码失败（fail loud）")
    }

    // has_issues=true 且 summary 新旧都缺 → fail loud；has_issues=false 允许空（例外分支，design D5）。
    func testSummaryCriticalityByHasIssues() {
        let missing = """
        {"has_issues": true, "original": "o", "corrected": "c",
         "issues": [{"index":1,"category":"grammar","severity":"error","before":"a","after":"b","reason":"r"}]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(ReviewResult.self, from: Data(missing.utf8)))

        let noIssues = """
        {"has_issues": false, "original": "o", "corrected": "o", "issues": []}
        """
        XCTAssertNoThrow(try JSONDecoder().decode(ReviewResult.self, from: Data(noIssues.utf8)),
                         "has_issues=false 时 summary 可选（prompt 约 3）")
    }

    // 编码只写新字段（无旧读方）。
    func testEncodeWritesOnlyNewFieldNames() throws {
        let r = ReviewResult(hasIssues: true, original: "o", corrected: "c",
                             translation: "t", summary: "s",
                             issues: [Issue(index: 1, category: .grammar, severity: .error,
                                            before: "a", after: "b", reason: "r")])
        let data = try JSONEncoder().encode(r)
        let out = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(out.contains("\"summary\""))
        XCTAssertTrue(out.contains("\"reason\""))
        XCTAssertFalse(out.contains("_zh"), "编码不写旧字段名")
    }
}

// MARK: - Prompt 双模板（design D7/D8：同构锚定 + 混排反转 + strict 不回退）

final class LanguagePromptTests: XCTestCase {

    private func ruleCount(_ s: String) -> Int {
        let re = try! NSRegularExpression(pattern: "^\\s*\\d+\\. ", options: [.anchorsMatchLines])
        return re.numberOfMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    // 中文模板逐字回归锚（现网用户零回归）+ 混排反转（spec「多语言混排统一到目标语言」）。
    func testChineseTemplateAnchorsAndUnificationReversal() {
        let sys = Prompt.system(mode: .firstPass, target: .english, user: .chinese)
        XCTAssertTrue(sys.contains("职场书面沟通"))
        XCTAssertTrue(sys.contains("最小改动"))
        XCTAssertTrue(sys.contains("转写为英文的地道表达"), "混排规则已反转为统一转写")
        XCTAssertTrue(sys.contains("统一为英文"))
        XCTAssertFalse(sys.contains("不翻译其余语言"), "旧「只修不译」规则必须移除（行为反转）")
        XCTAssertTrue(sys.contains("逐字保真"))
        XCTAssertTrue(sys.contains("<<<INPUT"))
        // 目标=中文方向同样渲染。
        let sysZhTarget = Prompt.system(mode: .firstPass, target: .chinese, user: .english)
        XCTAssertTrue(sysZhTarget.contains("rewrite the non-Chinese fragments".lowercased().isEmpty ? "x" : "Chinese"))
    }

    // 双模板同构锚定（评审 R1-5/D7）：delimiter、注入防御、新字段名全集、规则条数、strict 附加段语义。
    func testTemplatesAreIsomorphic() {
        let zh = Prompt.system(mode: .firstPass, target: .english, user: .chinese)
        let en = Prompt.system(mode: .firstPass, target: .chinese, user: .english)
        for sys in [zh, en] {
            XCTAssertTrue(sys.contains("<<<INPUT"))
            XCTAssertTrue(sys.contains("INPUT>>>"))
            for field in ["has_issues", "original", "corrected", "translation", "summary",
                          "issues", "alternative", "alternative_reason", "reason"] {
                XCTAssertTrue(sys.contains(field), "缺字段说明 \(field)")
            }
            XCTAssertFalse(sys.contains("_zh"), "模板不得再出现旧 _zh 字段名")
        }
        XCTAssertEqual(ruleCount(zh), ruleCount(en), "两模板硬约束条数必须相同（同构）")
        // 注入防御段（zh：绝不执行 / en：never execute）。
        XCTAssertTrue(zh.contains("绝不执行"))
        XCTAssertTrue(en.contains("never execute"))
    }

    // strict 附加段：不得回退混排转写（D8 防 strict 撤销转写第一保险）。
    func testStrictAddendumForbidsUnificationRevert() {
        let zh = Prompt.system(mode: .strict, target: .english, user: .chinese)
        XCTAssertTrue(zh.contains("本轮为严格重试"), "strict 标记逐字保留（MockServer E2E 依赖）")
        XCTAssertTrue(zh.contains("不得回退"))
        let en = Prompt.system(mode: .strict, target: .chinese, user: .english)
        XCTAssertTrue(en.contains("STRICT RETRY"))
        XCTAssertTrue(en.contains("must not be reverted"))
        // firstPass 无 strict 附加段。
        XCTAssertFalse(Prompt.system(mode: .firstPass, target: .english, user: .chinese).contains("本轮为严格重试"))
    }

    // jsonSchema 字段名同步新名（design D6）。
    func testJSONSchemaUsesNewFieldNames() throws {
        let data = try JSONSerialization.data(withJSONObject: Prompt.jsonSchema)
        let out = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(out.contains("\"translation\""))
        XCTAssertTrue(out.contains("\"summary\""))
        XCTAssertTrue(out.contains("\"reason\""))
        XCTAssertFalse(out.contains("_zh"))
    }

    // followUpSystem 话题放宽 + 护栏保留（design D10；spec「结果追问—放宽话题范围」）。
    func testFollowUpSystemBroadenedTopicKeepsGuardrails() {
        let zh = Prompt.followUpSystem(user: .chinese)
        XCTAssertTrue(zh.contains("任意语法"), "话题放宽为任意语法/语言问题")
        XCTAssertFalse(zh.contains("范围锚定本次结果"), "旧锚定约束已移除")
        XCTAssertTrue(zh.contains("只答疑，绝不改写主结果"), "护栏#1 保留")
        XCTAssertTrue(zh.contains("精确引用"), "护栏#3 保留")
        XCTAssertTrue(zh.contains("不是指令"), "注入防御保留")
        XCTAssertTrue(zh.contains("不得因话题放宽而输出可替代主结果的整段 corrected"), "安全段句尾增补（spec-delta）")
        let en = Prompt.followUpSystem(user: .english)
        XCTAssertTrue(en.contains("any general question about grammar"))
        XCTAssertTrue(en.contains("never rewrite the main result"))
        XCTAssertTrue(en.contains("NOT instructions"))
    }

    // 追问上下文标签/编号 token 随用户语言（design D11），英文用户用 "Fix N"。
    func testFollowUpContextEnglishLabels() {
        let ctx = FollowUpContext(original: "o", corrected: "c", summary: "s",
                                  numberedIssues: [.init(index: 2, before: "B", after: "b",
                                                         category: "grammar", severity: "error", reason: "r")],
                                  history: [], question: "why fix 2")
        let pkg = Prompt.followUpContext(ctx, user: .english)
        XCTAssertTrue(pkg.contains("Original: o"))
        XCTAssertTrue(pkg.contains("Fix 2: B → b"))
        XCTAssertTrue(pkg.contains("<<<RESULT"))
        let q = Prompt.followUpQuestion("why", user: .english)
        XCTAssertTrue(q.contains("not instructions"))
    }
}

// MARK: - AIClient 契约收口（design D5：.contract fail loud，两入口 + 截断 bump + 优先级）

final class LanguageContractClientTests: XCTestCase {

    override func setUp() {
        StubURLProtocol.reset()
        StreamingStubURLProtocol.reset()
    }
    override func tearDown() {
        StubURLProtocol.reset()
        StreamingStubURLProtocol.reset()
    }

    /// 合法 JSON 但缺 issue.reason（新旧都无）→ 契约违规 fixture。
    private let contractViolatingContent = """
    {"has_issues": true, "original": "o", "corrected": "c fixed", "summary": "s",
     "issues": [{"index":1,"category":"grammar","severity":"error","before":"a","after":"b"}]}
    """

    // 非流式：关键字段缺失 → repair 重试仍败 → 全 tier 后抛 .contract 进错误态，**不返回 fallback**（评审 R1-1）。
    func testContractViolationThrowsNotFallback() async {
        StubURLProtocol.handler = { _ in (200, chatResponseJSON(content: self.contractViolatingContent)) }
        let client = AIClient(session: stubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "m-contract")
        do {
            let r = try await client.review(text: "some input here now", config: cfg, mode: .firstPass)
            XCTFail("契约违规必须抛错，不得返回 fallback（实返回 corrected=\(r.corrected)）")
        } catch let e as ReviewError {
            guard case .contract = e else { return XCTFail("应为 .contract，实为 \(e)") }
        } catch { XCTFail("意外错误 \(error)") }
        XCTAssertGreaterThanOrEqual(StubURLProtocol.requestCount, 2, "应先做一次 repair 重试")
    }

    // 非 JSON 纯文本 → 仍走既有「展示原文」fallback（现状回归，.decode 路径不受影响）。
    func testPlainTextStillFallsBack() async throws {
        StubURLProtocol.handler = { _ in (200, chatResponseJSON(content: "this is plain prose, no json at all")) }
        let client = AIClient(session: stubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "m-plain")
        let r = try await client.review(text: "my input text here", config: cfg, mode: .firstPass)
        XCTAssertEqual(r.corrected, "my input text here", "纯文本解析失败维持展示原文 fallback")
        XCTAssertFalse(r.hasIssues)
    }

    // 截断 bump 分支（评审 R2-1）：bump 后 finish!=length 但契约违规 → 不走「结果被截断」fallback，抛 .contract。
    func testTruncationBumpContractNotSwallowed() async {
        StubURLProtocol.handler = { _ in
            if StubURLProtocol.requestCount == 1 {
                return (200, chatResponseJSON(content: "{partial", finishReason: "length"))
            }
            return (200, chatResponseJSON(content: self.contractViolatingContent, finishReason: "stop"))
        }
        let client = AIClient(session: stubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "m-bump-contract")
        do {
            let r = try await client.review(text: "input for bump case", config: cfg, mode: .firstPass)
            XCTFail("bump 后契约违规不得吞成截断 fallback（实返回 summary=\(r.summary)）")
        } catch let e as ReviewError {
            guard case .contract = e else { return XCTFail("应为 .contract，实为 \(e)") }
        } catch { XCTFail("意外错误 \(error)") }
    }

    // 截断 bump 后仍非合法 JSON（.decode）→ 维持「结果被截断」fallback（现状语义回归）。
    func testTruncationBumpDecodeKeepsTruncatedFallback() async throws {
        StubURLProtocol.handler = { _ in
            if StubURLProtocol.requestCount == 1 {
                return (200, chatResponseJSON(content: "{partial", finishReason: "length"))
            }
            return (200, chatResponseJSON(content: "still not json", finishReason: "stop"))
        }
        let client = AIClient(session: stubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "m-bump-decode")
        let r = try await client.review(text: "input for bump decode", config: cfg, mode: .firstPass)
        XCTAssertEqual(r.corrected, "input for bump decode")
        XCTAssertFalse(r.hasIssues)
    }

    // .contract 优先级不被后续 tier 的 .decode 覆盖（评审 R2-2）：auto 三 tier 混合失败 → 终抛 .contract。
    func testContractPriorityOverDecodeAcrossTiers() async {
        StubURLProtocol.handler = { _ in
            // 前两次请求（jsonSchema tier 的 chat + repair）回契约违规 JSON；其余回纯文本。
            if StubURLProtocol.requestCount <= 2 {
                return (200, chatResponseJSON(content: self.contractViolatingContent))
            }
            return (200, chatResponseJSON(content: "plain text garbage"))
        }
        let client = AIClient(session: stubbedSession())
        let cfg = testConfig(structured: .auto, model: "m-priority")
        do {
            _ = try await client.review(text: "priority case input", config: cfg, mode: .firstPass)
            XCTFail("应抛 .contract（优先级高于后续 .decode）")
        } catch let e as ReviewError {
            guard case .contract = e else { return XCTFail("应为 .contract，实为 \(e)") }
        } catch { XCTFail("意外错误 \(error)") }
    }

    // 流式入口：契约违规同样 fail loud（评审 R1-1 两入口）。
    func testStreamingContractViolationThrows() async {
        StreamingStubURLProtocol.handler = { _, _ in
            StreamStubResponse(chunks: sseFrames(content: self.contractViolatingContent))
        }
        let client = AIClient(session: streamingStubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "m-stream-contract")
        do {
            _ = try await client.reviewStreaming(text: "stream contract input", config: cfg, mode: .firstPass) { _ in }
            XCTFail("流式契约违规必须抛错")
        } catch let e as ReviewError {
            guard case .contract = e else { return XCTFail("应为 .contract，实为 \(e)") }
        } catch { XCTFail("意外错误 \(error)") }
    }

    // 混排转写结果正常解析 + 基准一致性（spec「混排统一」：original 恒为本地输入）。
    func testUnifiedMixedResultParsesWithLocalOriginal() async throws {
        let content = """
        {"has_issues": true, "original": "ECHO", "corrected": "Let's meet tomorrow at 3pm",
         "summary": "统一混排", "issues": [{"index":1,"category":"word_choice","severity":"improvement",
         "before":"明天","after":"tomorrow","reason":"混排统一为英文"}]}
        """
        StubURLProtocol.handler = { _ in (200, chatResponseJSON(content: content)) }
        let client = AIClient(session: stubbedSession())
        let cfg = testConfig(structured: .jsonObject, model: "m-mixed")
        let r = try await client.review(text: "Let's meet 明天 at 3pm", config: cfg, mode: .firstPass)
        XCTAssertEqual(r.corrected, "Let's meet tomorrow at 3pm", "夹带片段被转写而非保留")
        XCTAssertEqual(r.original, "Let's meet 明天 at 3pm", "original 恒为本地输入（基准一致性）")
        XCTAssertEqual(r.issues.first?.before, "明天")
    }
}

// MARK: - ReviewEngine 统一回退检测（design D8/D9）

final class UnificationGuardTests: XCTestCase {

    // 纯函数：两方向回退检出 + 容差内不误判 + 单语言输入恒 false。
    func testUnificationRegressedDetection() {
        let input = "We should meet 明天下午 at the office"
        let first = "We should meet tomorrow afternoon at the office"
        let strictReverted = "We should meet 明天下午 at the office"
        // 目标=英：strict 把 4 个 CJK 全留回来（first 为 0）→ 超容差 max(2, ⌈0.2×4⌉=1)=2 → regressed。
        XCTAssertTrue(ReviewEngine.unificationRegressed(input: input, first: first,
                                                        strict: strictReverted, target: .english))
        // strict 与 first 同样完成转写 → 不回退。
        XCTAssertFalse(ReviewEngine.unificationRegressed(input: input, first: first,
                                                         strict: first, target: .english))
        // 目标=中方向：strict 保留英文单词（ASCII 字母大幅回升）→ regressed。
        let zhInput = "这个 deadline 我 already 知道了"
        let zhFirst = "这个截止日期我已经知道了"
        let zhStrictReverted = "这个 deadline 我 already 知道了"
        XCTAssertTrue(ReviewEngine.unificationRegressed(input: zhInput, first: zhFirst,
                                                        strict: zhStrictReverted, target: .chinese))
        // 单语言输入（无混排）恒 false，零影响。
        XCTAssertFalse(ReviewEngine.unificationRegressed(input: "pure english sentence here",
                                                         first: "pure english sentence now",
                                                         strict: "pure english sentence here", target: .english))
    }

    // 专有名词容差不误判（比较式检测）：两版都合法保留少量非目标字符 → 差值 0，不判回退。
    func testProperNounsNotFalselyFlagged() {
        let input = "Please check 飞书 doc and reply 明天"
        let first = "Please check 飞书 doc and reply tomorrow"    // 保留产品名「飞书」，转写「明天」
        let strict = "Please check 飞书 doc and reply tomorrow"
        XCTAssertFalse(ReviewEngine.unificationRegressed(input: input, first: first,
                                                         strict: strict, target: .english))
    }

    // false negative 锚定（design D8）：strict 保留整句中文未转写（字符差远超容差）必须判 regressed。
    func testWholeSentenceRevertAnchored() {
        let input = "Deadline is Friday 我们需要尽快确认这个方案 thanks"
        let first = "Deadline is Friday; we need to confirm this plan ASAP, thanks"
        let strict = "Deadline is Friday 我们需要尽快确认这个方案 thanks"
        XCTAssertTrue(ReviewEngine.unificationRegressed(input: input, first: first,
                                                        strict: strict, target: .english))
    }

    // 择优优先级：换行保留 > 统一不回退 > ratio 小（design D8）。
    func testPickStrictPriority() {
        // strict 回退统一 → 即便 ratio 更小也选 first。
        XCTAssertFalse(ReviewEngine.pickStrict(firstRatio: 0.6, firstLostNL: false,
                                               strictRatio: 0.1, strictLostNL: false,
                                               strictUnificationRegressed: true))
        // 换行维度优先于统一维度：first 丢换行、strict 保住 → 选 strict（即便回退统一）。
        XCTAssertTrue(ReviewEngine.pickStrict(firstRatio: 0.6, firstLostNL: true,
                                              strictRatio: 0.5, strictLostNL: false,
                                              strictUnificationRegressed: true))
        // 无统一维度 → 沿用 ratio 小者（既有语义回归）。
        XCTAssertTrue(ReviewEngine.pickStrict(firstRatio: 0.6, firstLostNL: false,
                                              strictRatio: 0.2, strictLostNL: false,
                                              strictUnificationRegressed: false))
    }

    // 采纳点①（评审 R1-2）：strict 达标但回退转写 → 不采纳 strict，选 firstPass 并标 overEdited（R2-3 不变式）。
    func testStrictRevertedNotAdoptedEvenIfUnderThreshold() async throws {
        let input = "We should meet 明天下午 at the office"
        let first = "We should meet tomorrow afternoon at the office"   // 完成转写（超小阈值）
        let strict = input                                              // strict 撤销转写 = 原文，ratio 0
        let stub = StubProvider(first: first, strict: strict)
        let engine = ReviewEngine(client: stub)
        // 阈值调小 + 豁免关掉，保证护栏触发（护栏流程不变，只测采纳点）。
        let cfg = testConfig(threshold: 0.1, minWords: 1, minAbs: 0)
        let r = try await engine.review(text: input, config: cfg)
        XCTAssertEqual(stub.calls, ["firstPass", "strict"], "护栏流程不变：仍先 strict 重试一次")
        XCTAssertEqual(r.corrected, first, "不得采纳撤销了混排转写的 strict 版")
        XCTAssertTrue(r.overEdited, "最终候选超阈 ⇒ overEdited 恒成立（R2-3 不变式）")
    }

    // 采纳点②：都超阈且 strict 回退 → pickBetter 选 firstPass（统一维度优先于 ratio）。
    func testPickBetterPrefersUnificationOverRatio() {
        let first = ReviewResult(hasIssues: true, original: "o",
                                 corrected: "We should meet tomorrow afternoon at the office", summary: "", issues: [])
        let strict = ReviewResult(hasIssues: true, original: "o",
                                  corrected: "We should meet 明天下午 at the office", summary: "", issues: [])
        let picked = ReviewEngine.pickBetter(first: first, firstRatio: 0.6, firstLostNL: false,
                                             strict: strict, strictRatio: 0.2, strictLostNL: false,
                                             strictUnificationRegressed: true)
        XCTAssertEqual(picked.corrected, first.corrected, "统一不回退优先于 ratio 小")
    }

    // strict 干净达标（完成转写、低 ratio）→ 照常采纳、不 overEdited（不误伤正常路径）。
    func testStrictCleanAdoptionUnaffected() async throws {
        let input = "We should meet 明天下午 at the office"
        let first = "Completely rewritten version that changes everything a lot indeed"
        let strict = "We should meet tomorrow afternoon at the office"
        let stub = StubProvider(first: first, strict: strict)
        let engine = ReviewEngine(client: stub)
        let cfg = testConfig(threshold: 0.6, minWords: 1, minAbs: 0)
        let r = try await engine.review(text: input, config: cfg)
        XCTAssertEqual(r.corrected, strict)
        XCTAssertFalse(r.overEdited)
    }

    // 混排超阈仍先 strict retry（spec「护栏流程不变」回归锚）：流程与非混排一致。
    func testMixedInputStillTriggersStrictRetry() async throws {
        let input = "We should meet 明天下午 at the office ok"
        let stub = StubProvider(first: "Total rewrite something else entirely different here",
                                strict: "We should meet tomorrow afternoon at the office, ok")
        let engine = ReviewEngine(client: stub)
        let r = try await engine.review(text: input, config: testConfig(threshold: 0.35, minWords: 1, minAbs: 0))
        XCTAssertEqual(stub.calls, ["firstPass", "strict"], "混排输入超阈仍先 strict 重试一次，不跳过护栏")
        _ = r
    }
}

// MARK: - 追问：引用 token 双语言 + 贴新文本拦截（design D10/D11）

final class LanguageFollowUpTests: XCTestCase {

    // 引用解析双语言（design D11）：英文 "fix N"/"correction N" 命中；跨语言 token 不误判。
    func testParseReferencesEnglishTokens() {
        XCTAssertEqual(FollowUpSession.parseReferences("why is fix 2 better", language: .english), [2])
        XCTAssertEqual(FollowUpSession.parseReferences("Fix2 and CORRECTION 10 please", language: .english), [2, 10])
        XCTAssertEqual(FollowUpSession.parseReferences("prefix2 suffix3 nothing", language: .english), [])
        XCTAssertEqual(FollowUpSession.parseReferences("general grammar question", language: .english), [])
        // 跨语言不误判：英文态不识别「修正 N」，中文态不识别 "fix N"。
        XCTAssertEqual(FollowUpSession.parseReferences("修正 2 呢", language: .english), [])
        XCTAssertEqual(FollowUpSession.parseReferences("why is fix 2 better", language: .chinese), [])
    }

    // spec「放宽后仍不吐可替代主结果的全文」：贴新文本（与旧 corrected 无相似性）要全文 → 拦截（评审 R1-3）。
    func testOutputGuardInterceptsPastedTextRewrite() {
        let corrected = "I would like to schedule a meeting with the team next Monday afternoon."
        let pasted = "Yesterday I have went to the store and buyed some apples for the party."
        let question = "帮我看看这段：\n\(pasted)\n能给我改好的一版吗"
        // 回答是粘贴文本的近拷贝式最小改动改写 → 必须被拦截替换为引导文案。
        let rewrite = "Yesterday I went to the store and bought some apples for the party."
        let guarded = FollowUpSession.applyOutputGuard(answer: rewrite, corrected: corrected,
                                                       question: question, language: .chinese)
        XCTAssertEqual(guarded, FollowUpSession.outputGuardNote, "贴新文本的整段改写不得作为可采纳结果呈现")
    }

    // 回答里 verbatim 引用整段粘贴文本 → 同样替换；正常解释（短例句）不误伤。
    func testOutputGuardPastedVerbatimAndNormalAnswer() {
        let corrected = "Corrected main result text that is long enough here."
        let pasted = "This is a fairly long pasted paragraph that the user wants rewritten entirely."
        let question = "please rewrite:\n\(pasted)"
        let quoting = "Here you go: \(pasted) — hope that helps."
        let guarded = FollowUpSession.applyOutputGuard(answer: quoting, corrected: corrected,
                                                       question: question, language: .english)
        XCTAssertFalse(guarded.contains(pasted), "整段粘贴文本 verbatim 回吐应被替换")

        let normal = "The phrase \"have went\" is wrong because the past participle of go is gone. For example: \"I have gone there.\""
        let kept = FollowUpSession.applyOutputGuard(answer: normal, corrected: corrected,
                                                    question: question, language: .english)
        XCTAssertEqual(kept, normal, "正常答疑与短例句不应被护栏改动")
    }

    // 既有 corrected 拦截在新签名下回归（含英文 note 文案）。
    func testOutputGuardCorrectedInterceptionEnglishNote() {
        let corrected = "I would like to schedule a meeting with the team next Monday afternoon."
        let answer = "Sure, the full version: \(corrected)"
        let guarded = FollowUpSession.applyOutputGuard(answer: answer, corrected: corrected,
                                                       question: "give me the full text", language: .english)
        XCTAssertFalse(guarded.contains(corrected))
        XCTAssertTrue(guarded.contains(L10n.t(.followUpOutputGuardNote, .english)))
    }

    // pastedBlocks：短提问不产块；长行/无换行长问题产块。
    func testPastedBlocksExtraction() {
        XCTAssertTrue(FollowUpSession.pastedBlocks(in: "为什么这样改？").isEmpty, "短问题不视为粘贴块")
        let long = String(repeating: "word ", count: 20)
        XCTAssertFalse(FollowUpSession.pastedBlocks(in: long).isEmpty)
    }
}

// MARK: - 入口 gate（design D3：语言未确认 → 强制引导、不发起 AI 请求）

@MainActor
final class LanguageEntryGateTests: XCTestCase {

    // spec「新装首启强制配语言」：语言 gate 早于配置完整性检查（语言未配 + 配置也缺 → 仍先语言引导）。
    func testLanguageGatePrecedesConfigCheck() {
        let incomplete = AppConfig(baseURL: "", apiKey: "", model: "", temperature: 0.2,
                                   maxChars: 4000, diffThreshold: 0.35, minWordsForGuard: 6,
                                   minAbsEdits: 2, structuredMode: .auto, streamingEnabled: true)
        XCTAssertEqual(AppCoordinator.entryGate(languageConfigured: false, config: incomplete), .languageOnboarding)
        XCTAssertEqual(AppCoordinator.entryGate(languageConfigured: false, config: testConfig()), .languageOnboarding,
                       "配置齐全但语言未确认 → 仍强制语言引导、不发起请求")
    }

    func testConfigGateAfterLanguageConfirmed() {
        let incomplete = AppConfig(baseURL: "https://x/v1", apiKey: "", model: "m", temperature: 0.2,
                                   maxChars: 4000, diffThreshold: 0.35, minWordsForGuard: 6,
                                   minAbsEdits: 2, structuredMode: .auto, streamingEnabled: true)
        guard case .configNeeded(let missing) = AppCoordinator.entryGate(languageConfigured: true, config: incomplete) else {
            return XCTFail("应进配置缺失分支")
        }
        XCTAssertEqual(missing, [L10n.t(.missingAPIKey, .chinese)])
        XCTAssertEqual(AppCoordinator.entryGate(languageConfigured: true, config: testConfig()), .proceed)
    }
}
