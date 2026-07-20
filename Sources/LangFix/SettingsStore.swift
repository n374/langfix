import Foundation
import Combine

/// 非敏感配置：UserDefaults。API key 不在此处（见 KeychainStore，红线 Constraint-1）。
/// @MainActor：仅在主线程（Coordinator / SettingsView）访问；引擎只拿其 config() 快照。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let d = UserDefaults.standard

    @Published var baseURL: String { didSet { d.set(baseURL, forKey: K.baseURL) } }
    @Published var model: String { didSet { d.set(model, forKey: K.model) } }
    @Published var temperature: Double { didSet { d.set(temperature, forKey: K.temperature) } }
    @Published var maxChars: Int { didSet { d.set(maxChars, forKey: K.maxChars) } }
    @Published var diffThreshold: Double { didSet { d.set(diffThreshold, forKey: K.diffThreshold) } }
    @Published var minWordsForGuard: Int { didSet { d.set(minWordsForGuard, forKey: K.minWordsForGuard) } }
    @Published var minAbsEdits: Int { didSet { d.set(minAbsEdits, forKey: K.minAbsEdits) } }
    @Published var structuredModeRaw: String { didSet { d.set(structuredModeRaw, forKey: K.structuredMode) } }
    @Published var streamingEnabled: Bool { didSet { d.set(streamingEnabled, forKey: K.streamingEnabled) } }
    /// 弹窗主题（非敏感偏好）：只存 `ReviewThemeID.rawValue`（Material 不可 Codable），
    /// 不进 `AppConfig`（与 AI 引擎无关）。切换即时生效由 SwiftUI @Published 触发重绘。
    @Published var reviewThemeRaw: String { didSet { d.set(reviewThemeRaw, forKey: K.reviewTheme) } }
    /// 窗口行为模式（非敏感偏好）：开窗时捕获，已打开窗口下次生效。
    @Published var windowBehaviorModeRaw: String { didSet { d.set(windowBehaviorModeRaw, forKey: K.windowBehaviorMode) } }
    /// 结果浮窗字号档位（非敏感偏好）：只存 `ReviewFontTier.rawValue`，不进 `AppConfig`（与 AI 引擎无关）。
    /// 显示即时生效由 @Published 重绘承担；窗口重测量由 ReviewWindowController 显式订阅（design font-size-setting D4/D5）。
    @Published var reviewFontTierRaw: String { didSet { d.set(reviewFontTierRaw, forKey: K.reviewFontTier) } }

    // MARK: 语言配置（language-config change · design D1/D2）

    /// 用户语言（母语，驱动 UI 与解释/翻译）。didSet 维持不变式：与目标语言相等 → 目标自动翻转（UI 层第①层保证）。
    @Published var userLanguageRaw: String {
        didSet {
            d.set(userLanguageRaw, forKey: K.userLanguage)
            if userLanguageRaw == targetLanguageRaw, let u = AppLanguage(rawValue: userLanguageRaw) {
                targetLanguageRaw = u.other.rawValue
            }
        }
    }
    /// 目标语言（被纠错语言、混排统一方向）。didSet 同上反向翻转（两 didSet 互触发一轮后收敛，不死循环）。
    @Published var targetLanguageRaw: String {
        didSet {
            d.set(targetLanguageRaw, forKey: K.targetLanguage)
            if targetLanguageRaw == userLanguageRaw, let t = AppLanguage(rawValue: targetLanguageRaw) {
                userLanguageRaw = t.other.rawValue
            }
        }
    }
    /// 语言是否已确认（design D2/D3）：新装为 false → 首次触发纠错前强制引导；确认后置 true 永不回退。
    @Published var languageConfigured: Bool { didSet { d.set(languageConfigured, forKey: K.languageConfigured) } }

    enum K {
        static let baseURL = "baseURL"
        static let model = "model"
        static let temperature = "temperature"
        static let maxChars = "maxChars"
        static let diffThreshold = "diffThreshold"
        static let minWordsForGuard = "minWordsForGuard"
        static let minAbsEdits = "minAbsEdits"
        static let structuredMode = "structuredMode"
        static let streamingEnabled = "streamingEnabled"
        static let reviewTheme = "reviewTheme"
        static let windowBehaviorMode = "windowBehaviorMode"
        static let reviewFontTier = "reviewFontTier"
        static let userLanguage = "userLanguage"
        static let targetLanguage = "targetLanguage"
        static let languageConfigured = "languageConfigured"

        /// **v1 存量键集（冻结常量，design D2）**：仅用于「老用户升级」判定——任一键有持久化值即算旧版使用痕迹。
        /// 之后新增的设置键**不要**加进来（判定只看 v1 存量集，新键不影响老用户识别）。
        static let legacyV1Keys: [String] = [
            baseURL, model, temperature, maxChars, diffThreshold, minWordsForGuard,
            minAbsEdits, structuredMode, streamingEnabled, reviewTheme, windowBehaviorMode, reviewFontTier,
        ]
    }

    private init() {
        // 语言迁移早于 register(defaults:) 执行；且 v1 键探测经 persistentDomain 只看落盘值（见
        // migrateLanguageIfNeeded 注释），双重保证老用户判定不被注册默认污染（design D2）。
        Self.migrateLanguageIfNeeded(
            defaults: d,
            persistentDomainName: Bundle.main.bundleIdentifier,
            localeIdentifier: Locale.preferredLanguages.first ?? Locale.current.identifier,
            hasLegacyKeychainKey: KeychainStore.hasAPIKey)
        d.register(defaults: [
            K.temperature: 0.2,
            K.maxChars: 4000,
            K.diffThreshold: 0.35,
            K.minWordsForGuard: 6,
            K.minAbsEdits: 2,
            K.structuredMode: StructuredMode.auto.rawValue,
            K.streamingEnabled: true,   // 默认开启流式（旧用户升级后默认 true）
            K.reviewTheme: ReviewThemeID.defaultID.rawValue,   // 默认 Aurora Glass（旧用户升级即得默认）
            K.windowBehaviorMode: WindowBehaviorMode.defaultMode.rawValue,   // 默认 C：普通窗口
            K.reviewFontTier: ReviewFontTier.defaultTier.rawValue,   // 默认「大」（未显式设置过的老用户升级即得新默认）
        ])
        baseURL = d.string(forKey: K.baseURL) ?? ""
        model = d.string(forKey: K.model) ?? ""
        temperature = d.double(forKey: K.temperature)
        maxChars = d.integer(forKey: K.maxChars)
        diffThreshold = d.double(forKey: K.diffThreshold)
        minWordsForGuard = d.integer(forKey: K.minWordsForGuard)
        minAbsEdits = d.integer(forKey: K.minAbsEdits)
        structuredModeRaw = d.string(forKey: K.structuredMode) ?? StructuredMode.auto.rawValue
        streamingEnabled = d.bool(forKey: K.streamingEnabled)   // register 默认 true → 未设置时返回 true
        reviewThemeRaw = d.string(forKey: K.reviewTheme) ?? ReviewThemeID.defaultID.rawValue
        windowBehaviorModeRaw = d.string(forKey: K.windowBehaviorMode) ?? WindowBehaviorMode.defaultMode.rawValue
        reviewFontTierRaw = d.string(forKey: K.reviewFontTier) ?? ReviewFontTier.defaultTier.rawValue
        // 读取校验（design D1 第②层保证）：非法 rawValue / 目标==用户（手改 defaults 脏数据）→ 确定性修复并写回。
        let lang = LanguagePolicy.sanitize(
            userRaw: d.string(forKey: K.userLanguage),
            targetRaw: d.string(forKey: K.targetLanguage),
            localeIdentifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
        userLanguageRaw = lang.user.rawValue
        targetLanguageRaw = lang.target.rawValue
        languageConfigured = d.bool(forKey: K.languageConfigured)
        d.set(lang.user.rawValue, forKey: K.userLanguage)     // init 内赋值不触发 didSet，显式写回修复值
        d.set(lang.target.rawValue, forKey: K.targetLanguage)
    }

    /// 一次性确定性语言迁移（design D2，幂等：仅 `languageConfigured` 键不存在时执行）。
    /// 抽为可注入 defaults 的静态函数以便测试；老用户信号 = 任一 v1 持久化键 ∨ Keychain API key（宽口径，评审 R1-4）。
    ///
    /// **v1 键探测必须只看真正落盘的持久化值，不得用 `object(forKey:)`**（MR 阶段复验缺陷修复）：
    /// registration domain 是**进程全局**的（跨 UserDefaults 实例共享），任何早于本迁移执行的
    /// `register(defaults:)`（如测试进程里其他套件先触碰了 `SettingsStore.shared`）都会让 `object(forKey:)`
    /// 误命中注册默认值（temperature/maxChars 等恰是 legacyV1Keys 成员），把全新安装误判成老用户。
    /// 探测用 `persistentDomain(forName:)`：**实测**（本机 Foundation，回归锚
    /// `testMigrationImmuneToRegistrationDomainPollution` 持续验证）它只返回落盘域、不含注册默认；
    /// 注意其**空域返回 nil 而非空字典**——nil 必须按「无任何落盘值 = 新装」处理，绝不能因 nil 回退到
    /// `object(forKey:)`（否则污染照旧漏进来，这正是上一版实现的 bug）。
    /// `CFPreferencesCopyAppValue` 不可用作替代：实测其搜索链会命中 register 的默认值。
    /// `persistentDomainName` 为 nil（非 bundle 环境兜底）时退回 `object(forKey:)`，此时正确性仍由
    /// init 内「迁移先于 register」的固定顺序保证。
    static func migrateLanguageIfNeeded(defaults d: UserDefaults,
                                        persistentDomainName: String?,
                                        localeIdentifier: String,
                                        hasLegacyKeychainKey: Bool) {
        // languageConfigured 从不进 register(defaults:)，object(forKey:) 判定其存在性恒准确。
        guard d.object(forKey: K.languageConfigured) == nil else { return }
        let hasPersistedKey: (String) -> Bool
        if let domain = persistentDomainName {
            let persisted = d.persistentDomain(forName: domain) ?? [:]   // nil = 域内无任何落盘值（新装）
            hasPersistedKey = { persisted[$0] != nil }
        } else {
            hasPersistedKey = { d.object(forKey: $0) != nil }
        }
        let hasLegacyTrace = K.legacyV1Keys.contains(where: hasPersistedKey) || hasLegacyKeychainKey
        if hasLegacyTrace {
            // 老用户升级：自动迁移为 用户=中、目标=英、已配置（等价现状行为，不打断；truth table 最后一行）。
            d.set(AppLanguage.chinese.rawValue, forKey: K.userLanguage)
            d.set(AppLanguage.english.rawValue, forKey: K.targetLanguage)
            d.set(true, forKey: K.languageConfigured)
        } else {
            // 新装：按 locale truth table 预填，待首启引导确认（languageConfigured=false）。
            let (user, target) = LanguagePolicy.defaults(forLocaleIdentifier: localeIdentifier)
            d.set(user.rawValue, forKey: K.userLanguage)
            d.set(target.rawValue, forKey: K.targetLanguage)
            d.set(false, forKey: K.languageConfigured)
        }
    }

    var structuredMode: StructuredMode {
        StructuredMode(rawValue: structuredModeRaw) ?? .auto
    }

    /// 当前选中的主题（非法 rawValue 自动 fallback 默认）。
    var reviewTheme: ReviewTheme {
        ReviewThemeCatalog.theme(ReviewThemeID(rawValueOrDefault: reviewThemeRaw))
    }

    /// 当前窗口行为模式（非法 rawValue 自动 fallback 默认 C）。
    var windowBehaviorMode: WindowBehaviorMode {
        WindowBehaviorMode(rawValueOrDefault: windowBehaviorModeRaw)
    }

    /// 当前结果浮窗字号档位（非法 rawValue 自动 fallback 默认「大」）。
    var reviewFontTier: ReviewFontTier {
        ReviewFontTier(rawValueOrDefault: reviewFontTierRaw)
    }

    /// 用户语言（init 已 sanitize、didSet 维持合法，兜底仅防御性）。
    var userLanguage: AppLanguage { AppLanguage(rawValue: userLanguageRaw) ?? .english }

    /// 目标语言（不变式：恒 ≠ userLanguage；兜底取 other 保证不变式即便 raw 被外部改坏）。
    var targetLanguage: AppLanguage {
        let t = AppLanguage(rawValue: targetLanguageRaw) ?? userLanguage.other
        return t == userLanguage ? userLanguage.other : t
    }

    /// 组装传给引擎的配置快照（含 Keychain 里的 key）。
    func config() -> AppConfig {
        AppConfig(
            baseURL: baseURL,
            apiKey: KeychainStore.apiKey() ?? "",
            model: model,
            temperature: temperature,
            maxChars: maxChars,
            diffThreshold: diffThreshold,
            minWordsForGuard: minWordsForGuard,
            minAbsEdits: minAbsEdits,
            structuredMode: structuredMode,
            streamingEnabled: streamingEnabled,
            targetLanguage: targetLanguage,
            userLanguage: userLanguage
        )
    }
}
