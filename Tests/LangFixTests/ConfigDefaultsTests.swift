import XCTest
@testable import LangFix

/// 流式开关默认值契约：缺 key 时取默认 true（SettingsStore 用 register(defaults:) + bool 读取实现该语义）。
/// 用独立 UserDefaults suite 锁定「register 默认 true → 未设置时 bool 返回 true」，确定性、无污染。
final class ConfigDefaultsTests: XCTestCase {

    func testStreamingEnabledDefaultsTrueWhenAbsent() {
        let suite = "langfix.test.streaming.default"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        // 复刻 SettingsStore 的默认注册机制。
        d.register(defaults: ["streamingEnabled": true])
        XCTAssertTrue(d.bool(forKey: "streamingEnabled"), "未显式设置时流式开关默认 true")
        // 显式关闭后读出 false（开关可写）。
        d.set(false, forKey: "streamingEnabled")
        XCTAssertFalse(d.bool(forKey: "streamingEnabled"))
        d.removePersistentDomain(forName: suite)
    }

    func testAppConfigCarriesStreamingFlag() {
        XCTAssertTrue(testConfig().streamingEnabled)
        XCTAssertFalse(testConfig(streaming: false).streamingEnabled)
    }
}
