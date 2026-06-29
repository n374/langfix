import Foundation
import Combine

/// 非敏感配置：UserDefaults。API key 不在此处（见 KeychainStore，红线 Constraint-1）。
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

    private enum K {
        static let baseURL = "baseURL"
        static let model = "model"
        static let temperature = "temperature"
        static let maxChars = "maxChars"
        static let diffThreshold = "diffThreshold"
        static let minWordsForGuard = "minWordsForGuard"
        static let minAbsEdits = "minAbsEdits"
        static let structuredMode = "structuredMode"
    }

    private init() {
        d.register(defaults: [
            K.temperature: 0.2,
            K.maxChars: 4000,
            K.diffThreshold: 0.35,
            K.minWordsForGuard: 6,
            K.minAbsEdits: 2,
            K.structuredMode: StructuredMode.auto.rawValue,
        ])
        baseURL = d.string(forKey: K.baseURL) ?? ""
        model = d.string(forKey: K.model) ?? ""
        temperature = d.double(forKey: K.temperature)
        maxChars = d.integer(forKey: K.maxChars)
        diffThreshold = d.double(forKey: K.diffThreshold)
        minWordsForGuard = d.integer(forKey: K.minWordsForGuard)
        minAbsEdits = d.integer(forKey: K.minAbsEdits)
        structuredModeRaw = d.string(forKey: K.structuredMode) ?? StructuredMode.auto.rawValue
    }

    var structuredMode: StructuredMode {
        StructuredMode(rawValue: structuredModeRaw) ?? .auto
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
            structuredMode: structuredMode
        )
    }
}
