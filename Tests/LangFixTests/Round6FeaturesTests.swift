import XCTest
import AppKit
import SwiftUI
@testable import LangFix

/// round6：主菜单栏 activation policy 决策 + 更地道说法区块（默认展开 + diff + 说明）。
@MainActor
final class Round6FeaturesTests: XCTestCase {

    // MARK: 需求3 —— activation policy 决策（有可交互窗口才切 .regular 显示主菜单栏）

    func testWantsRegularPolicy() {
        XCTAssertTrue(AppCoordinator.wantsRegularPolicy(reviewExpanded: true, settingsVisible: false))
        XCTAssertTrue(AppCoordinator.wantsRegularPolicy(reviewExpanded: false, settingsVisible: true))
        XCTAssertTrue(AppCoordinator.wantsRegularPolicy(reviewExpanded: true, settingsVisible: true))
        XCTAssertFalse(AppCoordinator.wantsRegularPolicy(reviewExpanded: false, settingsVisible: false),
                       "无任何可交互窗口 → 回 .accessory（无 Dock 图标、收起主菜单栏）")
    }

    // MARK: 需求1/2 —— 更地道说法区块：默认展开、含 diff 与说明；两种 diff 分支都能布局

    func testAlternativeBlockLayoutWithDiffAndReason() {
        _ = NSApplication.shared
        let state = ReviewState()
        // alternative 与原文不同 → 走「地道版改动对照」diff 分支；带 reason → 走说明分支。
        state.phase = .result(ReviewResult(
            hasIssues: true, original: "I want know that", corrected: "I want to know that",
            translation: "我想知道那个", summary: "缺 to",
            issues: [Issue(category: .grammar, severity: .error, before: "want know",
                           after: "want to know", reason: "不定式")],
            alternative: "I'd like to know more about that", alternativeReason: "更委婉自然"))
        renderAndAssert(state)
    }

    func testAlternativeBlockLayoutWhenAlternativeEqualsInput() {
        _ = NSApplication.shared
        let state = ReviewState()
        // alternative 与原文相同 → 不出 diff 分支；reason 为空 → 不出说明分支（覆盖另一半）。
        state.phase = .result(ReviewResult(
            hasIssues: false, original: "All good here.", corrected: "All good here.",
            translation: "", summary: "", issues: [],
            alternative: "All good here.", alternativeReason: ""))
        renderAndAssert(state)
    }

    // 注：需求3 的"展示主菜单栏"是运行期 AppKit 行为，headless/CI 无法断言；且驱动真实窗口 +
    // NSApp.activate + 自旋 runloop 的用例会污染共享测试进程（拖垮后续重度测量测试）。故这里只用纯函数
    // 与不激活应用的路径覆盖决策逻辑；主菜单栏真的显示与否由用户在真机确认（见 ADR-0001 §6.2）。

    /// 无任何窗口时 syncActivationPolicy 应把 NSApp 落到非 .regular（执行真实策略切换路径）。
    func testSyncActivationPolicyAccessoryWhenNoWindows() {
        _ = NSApplication.shared
        AppCoordinator.shared.syncActivationPolicy()
        XCTAssertNotEqual(NSApp.activationPolicy(), .regular,
                          "无可交互窗口 → 不应是 .regular（不显示主菜单栏/Dock 图标）")
    }

    private func renderAndAssert(_ state: ReviewState) {
        let host = NSHostingView(rootView: ReviewView(
            state: state,
            maxContentSize: CGSize(width: ReviewWindowSizing.minWidth, height: 700),
            isOverflowing: false))
        host.frame = NSRect(x: 0, y: 0, width: ReviewWindowSizing.minWidth, height: 1)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
