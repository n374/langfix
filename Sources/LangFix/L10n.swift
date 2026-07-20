import Foundation

/// 自研轻量双语表（language-config change · design D4）：UI 语言由**应用内用户语言设置**驱动，
/// String Catalog / NSLocalizedString 按系统 locale 选语言、运行时切换需重启，不适配本需求，故用
/// enum 表：编译期穷尽检查（新增 key 忘译 = 编译错误）、可单测、切换即时生效（视图观察 SettingsStore 重绘）。
///
/// **约定**：全部用户可见字符串必须经本表（或本文件的带参函数）取值；源代码其余位置出现中文串仅允许
/// prompt 模板 / 发给模型的数据标签（Prompt.swift）、注释与测试 fixture（DoD 中文字符 grep 白名单，design D4）。
enum L10n {

    enum Key: CaseIterable {
        // 结果浮窗 · 状态与区块
        case checking, previewing, finalizing, stoppedPartial
        case sectionPreview, sectionCorrected, sectionDiff, sectionIssues
        case sectionAlternative, sectionAlternativeDiff
        case headerOverEdited, headerNoIssues
        case copy, copied
        case followUpTitle, answering, answerInterrupted
        case composerPlaceholder
        // 通用动作
        case hide, stop, close, retry, openSettings, cancel, ok, confirm
        // issue 类别 badge
        case categoryGrammar, categorySpelling, categoryWordChoice
        case categoryNaturalness, categoryTone, categoryPunctuation
        // 追问护栏 / 提示
        case followUpOutputGuardNote, followUpNoReferencable, followUpBudgetOverflow
        // 错误（ReviewError.localizedText）
        case errEmptyInput, errAuth, errRateLimited, errDecode, errContract
        case errCancelled, errContextLength, errTruncated, genericError
        case noHTTPResponse, invalidBaseURL
        // 缺配置字段名
        case missingBaseURL, missingAPIKey, missingModel
        // Coordinator alerts / 引导
        case clipboardEmpty
        case configNeededTitle
        case languageOnboardingTitle, languageOnboardingBody
        case serviceEmptySelection
        case aboutSubtitle, settingsWindowTitle
        // 设置页
        case settingsLanguageSection, settingsUserLanguage, settingsTargetLanguage
        case settingsLanguageHint, settingsLanguageConfirmBanner
        case settingsEndpointSection, settingsModelPlaceholder
        case settingsTestConnection, settingsTesting
        case settingsAdvancedSection, settingsStructuredOutput, settingsStructuredAuto, settingsStructuredText
        case settingsDiffThreshold, settingsMinWords, settingsMinAbsEdits, settingsMaxChars
        case settingsTheme, settingsFontSize, settingsWindowBehavior
        case settingsStreamingToggle, settingsLaunchAtLogin
        case settingsPrivacyTitle, settingsPrivacyBody
        // 窗口行为模式
        case windowModeFocusCollapseTitle, windowModeFocusCollapseSubtitle
        case windowModeAlwaysOnTopTitle, windowModeAlwaysOnTopSubtitle
        case windowModeNormalTitle, windowModeNormalSubtitle
        // 胶囊三态
        case capsuleWorking, capsuleDone, capsuleFailed
        // 字号档位
        case fontTierSmall, fontTierStandard, fontTierLarge, fontTierXLarge
        // 菜单
        case menuCheckClipboard, menuSettings, menuAbout, menuQuit, menuHideApp
        case menuEdit, menuUndo, menuRedo, menuCut, menuCopy, menuPaste, menuSelectAll
        case menuWindow, menuMinimize, menuClose
        // 连接测试（probe）
        case probeAuth, probe404, probe400
        case probe429
    }

    static func t(_ key: Key, _ lang: AppLanguage) -> String {
        let p = pair(key)
        return lang == .chinese ? p.zh : p.en
    }

    // MARK: - 带参文案

    static func headerFoundIssues(_ n: Int, _ lang: AppLanguage) -> String {
        lang == .chinese ? "发现 \(n) 处可改进" : "Found \(n) suggestion\(n == 1 ? "" : "s")"
    }

    /// 「修正 N」token：UI badge、追问引用 chip、prompt 上下文编号、引用解析四处同源同语言（design D11）。
    static func fixBadge(_ n: Int, _ lang: AppLanguage) -> String {
        lang == .chinese ? "修正 \(n)" : "Fix \(n)"
    }

    static func referenceHelp(_ n: Int, _ lang: AppLanguage) -> String {
        lang == .chinese ? "在追问中引用「\(fixBadge(n, lang))」" : "Reference \(fixBadge(n, lang)) in a follow-up"
    }

    static func tooLong(_ n: Int, _ max: Int, _ lang: AppLanguage) -> String {
        lang == .chinese ? "文本过长（\(n) 字符，上限 \(max)）"
                         : "Text too long (\(n) characters, limit \(max))"
    }

    static func notConfigured(_ fields: [String], _ lang: AppLanguage) -> String {
        lang == .chinese ? "请先配置：\(fields.joined(separator: "、"))"
                         : "Please configure first: \(fields.joined(separator: ", "))"
    }

    static func configNeededBody(_ fields: [String], _ lang: AppLanguage) -> String {
        lang == .chinese
            ? "缺少：\(fields.joined(separator: "、"))。在设置里填好 OpenAI 兼容端点、API key 与模型后再试。"
            : "Missing: \(fields.joined(separator: ", ")). Fill in the OpenAI-compatible endpoint, API key and model in Settings, then try again."
    }

    static func network(_ m: String, _ lang: AppLanguage) -> String {
        lang == .chinese ? "网络异常：\(m)" : "Network error: \(m)"
    }

    static func serverError(_ code: Int, _ lang: AppLanguage) -> String {
        lang == .chinese ? "服务端错误（HTTP \(code)）" : "Server error (HTTP \(code))"
    }

    static func invalidReference(_ invalid: [Int], count: Int, _ lang: AppLanguage) -> String {
        let list = invalid.map(String.init).joined(separator: lang == .chinese ? "、" : ", ")
        return lang == .chinese
            ? "修正 \(list) 不存在，可引用 1–\(count)"
            : "Fix \(list) does not exist; you can reference 1–\(count)"
    }

    static func launchAtLoginFailed(_ m: String, _ lang: AppLanguage) -> String {
        lang == .chinese ? "登录项设置失败：\(m)" : "Failed to set login item: \(m)"
    }

    // MARK: - 连接测试（probe）带参文案

    static func probeMissing(_ fields: [String], _ lang: AppLanguage) -> String {
        lang == .chinese ? "缺少：\(fields.joined(separator: "、"))"
                         : "Missing: \(fields.joined(separator: ", "))"
    }

    static func probeOK(_ model: String, _ lang: AppLanguage) -> String {
        lang == .chinese ? "连接成功，模型 \(model) 可用" : "Connected. Model \(model) is available"
    }

    static func probeModelUnavailable(_ model: String, _ lang: AppLanguage) -> String {
        lang == .chinese ? "模型不可用：\(model)" : "Model unavailable: \(model)"
    }

    static func probeHTTP(_ code: Int, _ lang: AppLanguage) -> String {
        "HTTP \(code)"
    }

    static func probeNetworkError(_ m: String, _ lang: AppLanguage) -> String {
        lang == .chinese ? "网络错误：\(m)" : "Network error: \(m)"
    }

    /// AI 解析失败/截断的兜底结果 summary（AIClient fallback note）。
    static func fallbackTruncated(_ lang: AppLanguage) -> String {
        lang == .chinese ? "结果被截断，已尽力展示原文" : "Result was truncated; showing your original text"
    }

    static func fallbackParseFailed(_ lang: AppLanguage) -> String {
        lang == .chinese ? "解析失败，已尽力展示原文" : "Failed to parse the response; showing your original text"
    }

    // MARK: - 双语表

    private static func pair(_ key: Key) -> (zh: String, en: String) {
        switch key {
        // 结果浮窗 · 状态与区块
        case .checking: return ("正在检查…", "Checking…")
        case .previewing: return ("校对预览中…", "Previewing…")
        case .finalizing: return ("定稿中…", "Finalizing…")
        case .stoppedPartial: return ("已停止（部分结果）", "Stopped (partial result)")
        case .sectionPreview: return ("修正预览", "Correction preview")
        case .sectionCorrected: return ("修正结果", "Corrected")
        case .sectionDiff: return ("改动对照", "Changes")
        case .sectionIssues: return ("逐条说明", "Details")
        case .sectionAlternative: return ("更地道的整体说法（非最小改动）", "More idiomatic rewrite (not minimal-edit)")
        case .sectionAlternativeDiff: return ("地道版改动对照（相对原文）", "Rewrite changes (vs. your original)")
        case .headerOverEdited: return ("AI 改动较大，请逐条核对", "Large edits made — please verify each change")
        case .headerNoIssues: return ("无明显错误", "No obvious issues")
        case .copy: return ("复制", "Copy")
        case .copied: return ("已复制", "Copied")
        case .followUpTitle: return ("AI 追问", "Ask AI")
        case .answering: return ("正在回答…", "Answering…")
        case .answerInterrupted: return ("回答中断", "Answer interrupted")
        case .composerPlaceholder:
            return ("问点什么：本次修正、或任何语法/用词问题", "Ask anything: this correction, or any grammar/word question")
        // 通用动作
        case .hide: return ("隐藏", "Hide")
        case .stop: return ("停止", "Stop")
        case .close: return ("关闭", "Close")
        case .retry: return ("重试", "Retry")
        case .openSettings: return ("打开设置", "Open Settings")
        case .cancel: return ("取消", "Cancel")
        case .ok: return ("好", "OK")
        case .confirm: return ("确认", "Confirm")
        // issue 类别 badge
        case .categoryGrammar: return ("语法", "Grammar")
        case .categorySpelling: return ("拼写", "Spelling")
        case .categoryWordChoice: return ("用词", "Word choice")
        case .categoryNaturalness: return ("地道度", "Naturalness")
        case .categoryTone: return ("语气", "Tone")
        case .categoryPunctuation: return ("标点", "Punctuation")
        // 追问护栏 / 提示
        case .followUpOutputGuardNote:
            return ("（追问仅答疑，不提供可替代主结果的整段改写；如需重新纠错请重新划词。）",
                    "(Follow-up is for Q&A only and will not produce a full replacement text; to review new text, select it and start a new review.)")
        case .followUpNoReferencable:
            return ("本次结果没有可引用的修正", "This result has no fixes to reference")
        case .followUpBudgetOverflow:
            return ("本次结果与问题过长，超出可用上下文预算，请缩短问题或重新纠错后再追问",
                    "The result plus your question exceeds the context budget; shorten the question or start a new review")
        // 错误
        case .errEmptyInput: return ("选区为空", "Selection is empty")
        case .errAuth: return ("鉴权失败，请检查 API key / 端点", "Authentication failed; check your API key / endpoint")
        case .errRateLimited: return ("请求过于频繁，请稍后重试", "Too many requests; please retry later")
        case .errDecode: return ("解析失败，请重试", "Failed to parse the model response; please retry")
        case .errContract:
            return ("AI 返回内容缺少必需的解释字段，请重试", "The AI response is missing required explanation fields; please retry")
        case .errCancelled: return ("已取消", "Cancelled")
        case .errContextLength:
            return ("本次结果与问答过长，超出模型上下文上限，请缩短问题或减少追问后重试",
                    "The result and conversation exceed the model context limit; shorten the question or reduce follow-ups and retry")
        case .errTruncated:
            return ("回答不完整（被截断或为空），请重试或换个更聚焦的问题",
                    "The answer is incomplete (truncated or empty); retry or ask a more focused question")
        case .genericError: return ("出错了", "Something went wrong")
        case .noHTTPResponse: return ("无 HTTP 响应", "No HTTP response")
        case .invalidBaseURL: return ("无效的 baseURL", "Invalid baseURL")
        // 缺配置字段名
        case .missingBaseURL: return ("端点 baseURL", "endpoint baseURL")
        case .missingAPIKey: return ("API key", "API key")
        case .missingModel: return ("模型 model", "model")
        // Coordinator alerts / 引导
        case .clipboardEmpty: return ("剪贴板没有文本", "No text in clipboard")
        case .configNeededTitle: return ("请先完成配置", "Finish setup first")
        case .languageOnboardingTitle: return ("请先完成语言设置", "Set up languages first")
        case .languageOnboardingBody:
            return ("首次使用请先选择你的母语与纠错目标语言（已按系统语言预填，配置一次即可）。配置完成后重新划词即可开始纠错。",
                    "Before the first review, please confirm your native language and the target language to correct (prefilled from your system language; one-time setup). After confirming, select text again to start.")
        case .serviceEmptySelection: return ("LangFix: 选区为空", "LangFix: selection is empty")
        case .aboutSubtitle:
            return ("划词写作纠错 · PopClip 触发 · 最小改动 + 母语解释",
                    "Selection-based writing review · PopClip trigger · minimal edits + native-language explanations")
        case .settingsWindowTitle: return ("LangFix 设置", "LangFix Settings")
        // 设置页
        case .settingsLanguageSection: return ("语言", "Languages")
        case .settingsUserLanguage: return ("我的母语（界面与解释语言）", "My native language (UI & explanations)")
        case .settingsTargetLanguage: return ("纠错目标语言", "Target language to correct")
        case .settingsLanguageHint:
            return ("说明：LangFix 会把混入的其他语言统一转写为目标语言。",
                    "Note: LangFix rewrites mixed-in fragments of other languages into the target language.")
        case .settingsLanguageConfirmBanner:
            return ("请确认语言设置——已按系统语言预填", "Please confirm your languages — prefilled from your system language")
        case .settingsEndpointSection: return ("AI 端点（OpenAI 兼容）", "AI endpoint (OpenAI-compatible)")
        case .settingsModelPlaceholder: return ("如 gpt-4o-mini / 某快模型", "e.g. gpt-4o-mini / a fast model")
        case .settingsTestConnection: return ("测试连接", "Test connection")
        case .settingsTesting: return ("测试中…", "Testing…")
        case .settingsAdvancedSection: return ("高级（最小改动护栏 / 解码）", "Advanced (minimal-edit guard / decoding)")
        case .settingsStructuredOutput: return ("结构化输出", "Structured output")
        case .settingsStructuredAuto: return ("auto（自动降级）", "auto (with fallback)")
        case .settingsStructuredText: return ("纯文本", "plain text")
        case .settingsDiffThreshold: return ("改动阈值 diffThreshold", "Edit threshold diffThreshold")
        case .settingsMinWords: return ("护栏最小词数 minWordsForGuard", "Guard min words minWordsForGuard")
        case .settingsMinAbsEdits: return ("护栏最小编辑数 minAbsEdits", "Guard min edits minAbsEdits")
        case .settingsMaxChars: return ("输入上限 maxChars", "Input limit maxChars")
        case .settingsTheme: return ("弹窗主题", "Popup theme")
        case .settingsFontSize: return ("字号（结果浮窗）", "Font size (result popup)")
        case .settingsWindowBehavior: return ("窗口行为", "Window behavior")
        case .settingsStreamingToggle:
            return ("流式渲染（逐字预览，端点不支持时自动回退）",
                    "Streaming rendering (live preview; falls back automatically if unsupported)")
        case .settingsLaunchAtLogin:
            return ("登录时启动（常驻，消除冷启动延迟）", "Launch at login (stay resident, no cold-start delay)")
        case .settingsPrivacyTitle: return ("隐私", "Privacy")
        case .settingsPrivacyBody:
            return ("API key 仅存于 macOS Keychain；不记录原文与修正文。注意：选中文本与你的追问内容都会通过 HTTPS 发送到你配置的端点处理（非本地处理），敏感内容请自行选择可信端点。追问会话仅存于当前结果窗口的内存，关窗即清、不落盘。",
                    "Your API key is stored only in the macOS Keychain; original and corrected texts are never logged. Note: selected text and your follow-up questions are sent over HTTPS to the endpoint you configure (not processed locally) — choose a trusted endpoint for sensitive content. Follow-up sessions live only in the current window's memory and are cleared on close, never persisted.")
        // 窗口行为模式
        case .windowModeFocusCollapseTitle: return ("失焦折叠", "Collapse on blur")
        case .windowModeFocusCollapseSubtitle:
            return ("切到别处自动变胶囊；Esc / 隐藏也会折叠", "Auto-collapses to a capsule when you switch away; Esc / Hide also collapse")
        case .windowModeAlwaysOnTopTitle: return ("始终置顶", "Always on top")
        case .windowModeAlwaysOnTopSubtitle:
            return ("窗口和胶囊都保持置顶；Esc / 隐藏可暂收", "Window and capsule stay on top; Esc / Hide tuck them away")
        case .windowModeNormalTitle: return ("默认窗口", "Normal window")
        case .windowModeNormalSubtitle:
            return ("像普通窗口一样可被遮挡；Esc / 隐藏可收起", "Behaves like a normal window and can be covered; Esc / Hide collapse it")
        // 胶囊三态
        case .capsuleWorking: return ("处理中", "Working")
        case .capsuleDone: return ("已完成", "Done")
        case .capsuleFailed: return ("出错", "Failed")
        // 字号档位
        case .fontTierSmall: return ("小", "Small")
        case .fontTierStandard: return ("标准", "Standard")
        case .fontTierLarge: return ("大", "Large")
        case .fontTierXLarge: return ("特大", "X-Large")
        // 菜单
        case .menuCheckClipboard: return ("检查剪贴板文本", "Check Clipboard Text")
        case .menuSettings: return ("设置…", "Settings…")
        case .menuAbout: return ("关于 LangFix", "About LangFix")
        case .menuQuit: return ("退出 LangFix", "Quit LangFix")
        case .menuHideApp: return ("隐藏 LangFix", "Hide LangFix")
        case .menuEdit: return ("编辑", "Edit")
        case .menuUndo: return ("撤销", "Undo")
        case .menuRedo: return ("重做", "Redo")
        case .menuCut: return ("剪切", "Cut")
        case .menuCopy: return ("复制", "Copy")
        case .menuPaste: return ("粘贴", "Paste")
        case .menuSelectAll: return ("全选", "Select All")
        case .menuWindow: return ("窗口", "Window")
        case .menuMinimize: return ("最小化", "Minimize")
        case .menuClose: return ("关闭", "Close")
        // 连接测试（probe）
        case .probeAuth: return ("鉴权失败：请检查 API key", "Authentication failed: check your API key")
        case .probe404: return ("404：请检查 baseURL 或 model 是否存在", "404: check that the baseURL and model exist")
        case .probe400: return ("请求被拒（400）", "Request rejected (400)")
        case .probe429: return ("限流（429），请稍后再试", "Rate limited (429); try again later")
        }
    }
}
