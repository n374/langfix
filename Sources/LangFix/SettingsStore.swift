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

    private enum K {
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
    }

    private init() {
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
            streamingEnabled: streamingEnabled
        )
    }
}
