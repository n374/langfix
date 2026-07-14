import XCTest
import Foundation
@testable import LangFix

/// 覆盖 spec「视觉主题可选」：多主题、默认、切换持久化、非法 fallback、不入 AppConfig。
final class ReviewThemeTests: XCTestCase {

    func testCatalogHasFourNamedThemes() {
        XCTAssertEqual(ReviewThemeID.allCases.count, 4, "≥2 套主题（本实现 4 套全保留）")
        for id in ReviewThemeID.allCases {
            let t = ReviewThemeCatalog.theme(id)
            XCTAssertEqual(t.id, id, "目录返回的主题 id 与请求一致")
            XCTAssertFalse(t.displayName.isEmpty, "每套主题有展示名")
        }
    }

    func testDefaultIsAuroraGlass() {
        XCTAssertEqual(ReviewThemeID.defaultID, .auroraGlass, "默认主题 Aurora Glass（用户拍板）")
    }

    func testThemeIDIdentifiableAndTokens() {
        for id in ReviewThemeID.allCases {
            XCTAssertEqual(id.id, id.rawValue, "Identifiable.id == rawValue")
            let t = ReviewThemeCatalog.theme(id)
            // collapsedForeground 派生自 primaryText；语义色齐备且展开/胶囊共用。
            XCTAssertEqual(t.collapsedForeground, t.primaryText)
            XCTAssertNotEqual(t.accent, t.error, "accent 与 error 可区分")
            XCTAssertGreaterThan(t.cornerRadius, 0)
        }
    }

    func testRawValueFallback() {
        XCTAssertEqual(ReviewThemeID(rawValueOrDefault: "neonNoir"), .neonNoir, "合法 rawValue 正常解析")
        XCTAssertEqual(ReviewThemeID(rawValueOrDefault: "garbage"), .auroraGlass, "非法 rawValue fallback 默认")
        XCTAssertEqual(ReviewThemeID(rawValueOrDefault: nil), .auroraGlass, "缺失 rawValue fallback 默认")
        XCTAssertEqual(ReviewThemeID(rawValueOrDefault: ""), .auroraGlass, "空串 fallback 默认")
    }

    /// 持久化语义：复刻 SettingsStore 的 register + string 读取机制（独立 suite，无污染）。
    func testThemePersistenceViaUserDefaults() {
        let suiteName = "langfix.test.theme.persistence"
        let d = UserDefaults(suiteName: suiteName)!
        d.removePersistentDomain(forName: suiteName)
        d.register(defaults: ["reviewTheme": ReviewThemeID.defaultID.rawValue])

        // 未设置时读出默认。
        XCTAssertEqual(d.string(forKey: "reviewTheme"), "auroraGlass", "未设置 → 默认 Aurora Glass")

        // 切换写入后读出新值，且跨「实例」（重新 UserDefaults(suiteName:)）仍生效。
        d.set(ReviewThemeID.neonNoir.rawValue, forKey: "reviewTheme")
        let d2 = UserDefaults(suiteName: suiteName)!
        XCTAssertEqual(d2.string(forKey: "reviewTheme"), "neonNoir", "切换持久化，下次启动仍生效")
        XCTAssertEqual(ReviewThemeID(rawValueOrDefault: d2.string(forKey: "reviewTheme")), .neonNoir)

        d.removePersistentDomain(forName: suiteName)
    }

    /// 主题不进 AppConfig（与 AI 引擎无关，design.md §2.6）。
    func testThemeNotInAppConfig() {
        let mirror = Mirror(reflecting: testConfig())
        let labels = mirror.children.compactMap { $0.label }
        XCTAssertFalse(labels.contains { $0.lowercased().contains("theme") },
                       "AppConfig 不应携带任何 theme 字段")
    }
}
