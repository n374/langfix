import XCTest
import AppKit
import SwiftUI
@testable import LangFix

/// 覆盖 change font-size-setting spec-delta 的 4 个 Scenario（design §7）：
/// 默认大于旧基准 / 持久化 / 档位单调性与锚点回归 / 大字号长内容封顶（含 D5 订阅链路生产测试）。
final class ReviewTypographyTests: XCTestCase {

    // MARK: Scenario「默认大于旧正文基准」（§7-1）

    func testDefaultTierIsLargeWhenAbsent() {
        let suite = "langfix.test.fonttier.default"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        // 复刻 SettingsStore 的 register(defaults:) 机制：未显式设置时读到默认「大」。
        d.register(defaults: ["reviewFontTier": ReviewFontTier.defaultTier.rawValue])
        let tier = ReviewFontTier(rawValueOrDefault: d.string(forKey: "reviewFontTier"))
        XCTAssertEqual(tier, .large, "未显式设置时默认档 = 大（全新安装与未设置过的老用户升级同此）")
        d.removePersistentDomain(forName: suite)
    }

    func testDefaultTierBodyExceedsLegacyBaseline() {
        let t = ReviewTypography(tier: ReviewFontTier.defaultTier)
        XCTAssertGreaterThan(t.body, ReviewTypography.legacyBodyBaseline,
                             "默认档正文必须严格大于旧正文基准 13pt（spec「默认大于旧基准」，锚点断言不依赖散落硬值）")
    }

    func testInvalidRawValueFallsBackToLarge() {
        XCTAssertEqual(ReviewFontTier(rawValueOrDefault: "banana"), .large)
        XCTAssertEqual(ReviewFontTier(rawValueOrDefault: nil), .large)
        XCTAssertEqual(ReviewFontTier(rawValueOrDefault: ""), .large)
    }

    // MARK: Scenario「用户调整并持久化」（§7-2）

    func testTierPersistsAcrossReload() {
        let suite = "langfix.test.fonttier.persist"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.register(defaults: ["reviewFontTier": ReviewFontTier.defaultTier.rawValue])
        // 写档位 → 重读还原（对齐 ConfigDefaultsTests 惯例，独立 suite 无污染）。
        d.set(ReviewFontTier.small.rawValue, forKey: "reviewFontTier")
        XCTAssertEqual(ReviewFontTier(rawValueOrDefault: d.string(forKey: "reviewFontTier")), .small)
        d.removePersistentDomain(forName: suite)
    }

    // MARK: 档位单调性 / 锚点回归（§7-3）

    func testRolePointsStrictlyIncreaseAcrossTiers() {
        let ordered: [ReviewFontTier] = [.small, .standard, .large, .xLarge]
        for (lo, hi) in zip(ordered, ordered.dropFirst()) {
            let a = ReviewTypography(tier: lo).allRolePoints
            let b = ReviewTypography(tier: hi).allRolePoints
            for (x, y) in zip(a, b) {
                XCTAssertLessThan(x, y, "\(lo) → \(hi) 每个角色字号都必须严格递增")
            }
        }
    }

    /// 锚点回归：standard 档 == D3 固化 pt 表（锁 typography 表自身不漂移；
    /// 口径见 design D3——按 macOS 默认内容尺寸固化，不宣称与旧渲染像素相等）。
    func testStandardTierMatchesFrozenPtTable() {
        let t = ReviewTypography(tier: .standard)
        XCTAssertEqual(t.body, 13)
        XCTAssertEqual(t.bubble, 12.5)
        XCTAssertEqual(t.issueLine, 12)
        XCTAssertEqual(t.header, 11)
        XCTAssertEqual(t.sectionLabel, 10)
        XCTAssertEqual(t.badge, 10)
        XCTAssertEqual(t.chipTitle, 12.5)
        XCTAssertEqual(t.chipIcon, 11)
        XCTAssertEqual(t.iconAction, 13)
    }

    func testTierBodyPointsMatchDesignTable() {
        XCTAssertEqual(ReviewTypography(tier: .small).body, 12)
        XCTAssertEqual(ReviewTypography(tier: .standard).body, 13)
        XCTAssertEqual(ReviewTypography(tier: .large).body, 14.5)
        XCTAssertEqual(ReviewTypography(tier: .xLarge).body, 16)
    }

    /// 所有派生字号半点取整（design D2）：×2 后为整数，避免怪异小数渲染模糊。
    func testAllRolePointsAreHalfPointAligned() {
        for tier in ReviewFontTier.allCases {
            for p in ReviewTypography(tier: tier).allRolePoints {
                XCTAssertEqual((p * 2).rounded(), p * 2, accuracy: 0.0001,
                               "\(tier) 档存在非半点对齐的字号 \(p)")
            }
        }
    }

    // MARK: Scenario「大字号 + 长内容仍封顶不超屏」（§7-4，测量路径 + sizing 判定）

    /// 与 `refreshMeasurement` 相同的 `NSHostingController.sizeThatFits` 路径测同一长内容：
    /// xLarge 自然高 > standard，且 xLarge 下溢出判定为真、目标高度封顶 maxH（clamp 数学不改）。
    @MainActor
    func testXLargeLongContentMeasuresTallerAndCapsAtMaxH() {
        _ = NSApplication.shared
        let state = ReviewState()
        state.phase = .streaming(StreamingPreview(corrected: Self.longText(lines: 120)))

        let hStandard = Self.withTier(.standard) { Self.measuredNaturalHeight(state: state) }
        let hXLarge = Self.withTier(.xLarge) { Self.measuredNaturalHeight(state: state) }
        XCTAssertGreaterThan(hXLarge, hStandard + 40, "同一长内容在 xLarge 下自然高度应显著大于 standard")

        // 1600×1000 屏（maxH=700）：xLarge 长内容溢出、高度封顶（对齐 ReviewWindowSizingTests 模式）。
        let sizing = ReviewWindowSizing()
        let vf = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let natural = CGSize(width: ReviewWindowSizing.minWidth, height: hXLarge)
        XCTAssertTrue(sizing.isOverflowing(natural: natural, visibleFrame: vf))
        XCTAssertEqual(sizing.target(natural: natural, visibleFrame: vf).height, 700, accuracy: 0.001)
    }

    // MARK: D5 订阅链路生产测试（§7-4b，Codex 评审🔴3）

    /// 只改 `SettingsStore.shared.reviewFontTierRaw`、泵主 runloop——不手动强制测量——断言窗口经
    /// `$reviewFontTierRaw → refreshMeasurement` 生产链路重测量：自然高变大、isOverflowing 翻转、高度封顶。
    /// 内容长度按 Codex 备注选「standard 未溢出、xLarge 溢出」区间（逐行搜索次极高内容，带宽 ≫ 单行高必命中）。
    @MainActor
    func testFontTierChangeTriggersRemeasureAndCapsViaProductionPath() throws {
        _ = NSApplication.shared
        let store = SettingsStore.shared
        let original = store.reviewFontTierRaw
        // key 原本显式存在则恢复原值即可（didSet 落盘）；原本不存在才删，避免抹掉本机既有设置
        let hadKey = UserDefaults.standard.object(forKey: "reviewFontTier") != nil
        defer {
            store.reviewFontTierRaw = original
            if !hadKey { UserDefaults.standard.removeObject(forKey: "reviewFontTier") }
        }
        store.reviewFontTierRaw = ReviewFontTier.standard.rawValue

        let state = ReviewState()
        state.phase = .loading
        let controller = ReviewWindowController(state: state, behavior: .normal)
        controller.showCentered()
        defer { controller.close() }

        let maxH = controller.measureAndApplyForTesting().maxContent.height
        // standard 自然高落入 (0.85, 0.97)·maxH → xLarge（×≈1.23）后必 > maxH，翻转断言确定成立。
        var standardSnapshot: ReviewWindowController.MeasurementSnapshot?
        for lines in 1...200 {
            state.phase = .streaming(StreamingPreview(corrected: Self.longText(lines: lines)))
            let snap = controller.measureAndApplyForTesting()
            if snap.natural.height > maxH * 0.85 && snap.natural.height < maxH * 0.97 {
                standardSnapshot = snap
                break
            }
            if snap.natural.height >= maxH { break }   // 已触顶仍未落带（异常屏），停止搜索
        }
        let standard = try XCTUnwrap(standardSnapshot, "未能构造出「standard 不溢出」的次极高内容")
        XCTAssertFalse(standard.isOverflowing, "standard 档基线必须尚未溢出（翻转断言的前提）")

        store.reviewFontTierRaw = ReviewFontTier.xLarge.rawValue
        settleMainRunLoop()
        let xl = controller.measurementSnapshotForTesting()
        XCTAssertGreaterThan(xl.natural.height, standard.natural.height + 20,
                             "改档位后未经手动强制测量，自然高度应经订阅链路自动变大")
        XCTAssertTrue(xl.isOverflowing, "xLarge 下内容超 maxH 必翻 isOverflowing（中部滚动、底栏固定）")
        XCTAssertEqual(xl.appliedContent.height, xl.maxContent.height, accuracy: 2,
                       "窗口内容高度必须封顶在 maxH，不随字号放大超屏")
    }

    // MARK: 工具

    /// 暂改共享 store 的档位执行测量，测后恢复原值；落盘 key 仅在原本不存在时清理（不抹本机既有设置）。
    @MainActor
    private static func withTier<T>(_ tier: ReviewFontTier, _ body: () -> T) -> T {
        let store = SettingsStore.shared
        let original = store.reviewFontTierRaw
        let hadKey = UserDefaults.standard.object(forKey: "reviewFontTier") != nil
        store.reviewFontTierRaw = tier.rawValue
        defer {
            store.reviewFontTierRaw = original
            if !hadKey { UserDefaults.standard.removeObject(forKey: "reviewFontTier") }
        }
        return body()
    }

    /// 与 `ReviewWindowController.refreshMeasurement` 相同的测量路径（NSHostingController.sizeThatFits）。
    @MainActor
    private static func measuredNaturalHeight(state: ReviewState) -> CGFloat {
        let width = ReviewWindowSizing.minWidth
        let controller = NSHostingController(rootView: ReviewMeasurementView(
            state: state,
            maxContentSize: CGSize(width: width, height: 700),
            onNaturalSizeChange: { _ in }))
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        controller.view.layoutSubtreeIfNeeded()
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private static func longText(lines: Int) -> String {
        (1...lines)
            .map { "Line \($0): This sentence keeps the review content tall enough for measurement." }
            .joined(separator: "\n")
    }

    @MainActor
    private func settleMainRunLoop(iterations: Int = 8) {
        for _ in 0..<iterations {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }
}
