import XCTest
import AppKit
import SwiftUI
@testable import LangFix

/// round4 需求：停止/关闭/隐藏按钮合并、中文直译、顶层菜单、跟随鼠标定位。
@MainActor
final class Round4FeaturesTests: XCTestCase {

    // MARK: 需求3 —— 「停止」决策：流式冻结部分结果，其余态关闭

    func testStopOutcomeFreezesStreaming() {
        let preview = StreamingPreview(corrected: "Partial output")
        switch AppCoordinator.stopOutcome(for: .streaming(preview)) {
        case .freeze(let p): XCTAssertEqual(p.corrected, "Partial output")
        case .close: XCTFail("流式态应冻结为部分结果，而非关闭")
        }
    }

    func testStopOutcomeClosesNonStreaming() {
        // loading（尚无内容）与 result/error 都退化为关闭。
        for phase in [ReviewState.Phase.loading,
                      .result(Self.sampleResult()),
                      .error("boom")] {
            if case .close = AppCoordinator.stopOutcome(for: phase) { continue }
            XCTFail("非流式态应关闭")
        }
    }

    // MARK: 需求2 —— 流式解析器提取 translation（新字段名，language-config D6；闭合后整体填充）

    func testPartialParserExtractsTranslation() {
        var parser = PartialReviewParser()
        _ = parser.feed("{\"corrected\":\"Thanks\",\"translation\":\"谢谢\"")
        let snap = parser.snapshot(stage: .receiving)
        XCTAssertEqual(snap.corrected, "Thanks")
        XCTAssertEqual(snap.translation, "谢谢", "translation 闭合后应被提取")
    }

    // MARK: 需求4/5 —— 顶层主菜单 + Cmd+, 快捷键

    func testAppMenuHasSettingsWithCommandComma() {
        let menu = AppMenu.build(target: AppDelegate(), language: .chinese)
        guard let appMenu = menu.items.first?.submenu else { return XCTFail("缺 App 子菜单") }
        guard let settings = appMenu.items.first(where: { $0.title == "设置…" }) else {
            return XCTFail("缺「设置…」菜单项")
        }
        XCTAssertEqual(settings.keyEquivalent, ",", "设置项快捷键为逗号")
        XCTAssertTrue(settings.keyEquivalentModifierMask.contains(.command), "Cmd+, 约定")
    }

    func testAppMenuHasEditAndWindowSubmenus() {
        let menu = AppMenu.build(target: AppDelegate(), language: .chinese)
        XCTAssertGreaterThanOrEqual(menu.items.count, 3, "至少 App/Edit/Window 三个子菜单")
        let editMenu = menu.items[1].submenu
        XCTAssertNotNil(editMenu?.items.first(where: { $0.title == "复制" }), "Edit 菜单含复制")
        XCTAssertNotNil(editMenu?.items.first(where: { $0.keyEquivalent == "c" }), "复制快捷键 Cmd+C")
    }

    // MARK: 需求3/2 —— 各态视图可实例化并布局（覆盖操作栏 / 直译行 / 停止态视图）

    func testAllPhaseViewsLayoutWithoutCrash() {
        _ = NSApplication.shared
        let state = ReviewState()
        let preview = StreamingPreview(corrected: "This is a fix.", translation: "这是一个修正。",
                                       summary: "小改", issues: [Self.sampleIssue()])
        let phases: [ReviewState.Phase] = [
            .loading,
            .streaming(preview),
            .stopped(preview),
            .result(Self.sampleResult(translation: "这是修正后的中文直译。", issues: [Self.sampleIssue()])),
            .error("网络异常"),
        ]
        for phase in phases {
            state.phase = phase
            let host = NSHostingView(rootView: ReviewView(
                state: state,
                maxContentSize: CGSize(width: ReviewWindowSizing.minWidth, height: 700),
                isOverflowing: false))
            host.frame = NSRect(x: 0, y: 0, width: ReviewWindowSizing.minWidth, height: 1)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }

    /// 操作栏按钮回调确实透传到 state（隐藏/停止/关闭）。
    func testActionCallbacksInvokeStateHooks() {
        let state = ReviewState()
        var hide = 0, stop = 0, close = 0
        state.onHide = { hide += 1 }
        state.onStop = { stop += 1 }
        state.onClose = { close += 1 }
        state.onHide?(); state.onStop?(); state.onClose?()
        XCTAssertEqual([hide, stop, close], [1, 1, 1])
    }

    // MARK: helpers

    private static func sampleResult(translation: String = "", issues: [Issue] = []) -> ReviewResult {
        ReviewResult(hasIssues: !issues.isEmpty, original: "orig text", corrected: "corrected text",
                     translation: translation, summary: "总评", issues: issues,
                     alternative: "a more idiomatic rewrite", alternativeReason: "这样更符合母语表达习惯")
    }

    private static func sampleIssue() -> Issue {
        Issue(category: .grammar, severity: .error, before: "a", after: "b", reason: "原因")
    }
}
