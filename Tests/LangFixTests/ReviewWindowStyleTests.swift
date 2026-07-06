import XCTest
import AppKit
import SwiftUI
@testable import LangFix

/// 覆盖 spec「取消手动 resize」：展开 panel styleMask 不含 .resizable。
final class ReviewWindowStyleTests: XCTestCase {

    func testExpandedStyleHasNoResizable() {
        XCTAssertFalse(ReviewWindowStyle.expanded.contains(.resizable),
                       "展开 panel 不可手动缩放（尺寸全由内容/流式驱动）")
    }

    func testExpandedStyleSanity() {
        XCTAssertTrue(ReviewWindowStyle.expanded.contains(.titled))
        XCTAssertTrue(ReviewWindowStyle.expanded.contains(.closable))
        XCTAssertTrue(ReviewWindowStyle.expanded.contains(.fullSizeContentView))
    }

    func testCapsuleStyleIsBorderless() {
        XCTAssertTrue(ReviewWindowStyle.capsule.contains(.borderless))
        XCTAssertTrue(ReviewWindowStyle.capsule.contains(.nonactivatingPanel))
        XCTAssertFalse(ReviewWindowStyle.capsule.contains(.resizable))
    }

    func testWindowLevelPolicyFollowsBehavior() {
        let focus = WindowLevelPolicy.policy(for: .focusCollapse)
        XCTAssertEqual(focus.level, .normal)
        XCTAssertFalse(focus.isFloatingPanel)

        let top = WindowLevelPolicy.policy(for: .alwaysOnTop)
        XCTAssertEqual(top.level, .floating)
        XCTAssertTrue(top.isFloatingPanel)

        let normal = WindowLevelPolicy.policy(for: .normal)
        XCTAssertEqual(normal.level, .normal)
        XCTAssertFalse(normal.isFloatingPanel)
    }

    @MainActor
    func testControllerInitializesAndClosesWithoutOrderingWindows() {
        _ = NSApplication.shared
        let state = ReviewState()
        state.phase = .loading
        let controller = ReviewWindowController(state: state, behavior: .normal)
        let appearance = controller.expandedPanelAppearanceForTesting()
        XCTAssertFalse(appearance.isOpaque)
        XCTAssertEqual(appearance.backgroundColor, .clear)
        controller.close()
    }

    @MainActor
    func testControllerHandlesCollapseExpandAndCloseEvents() {
        _ = NSApplication.shared
        let state = ReviewState()
        state.phase = .loading
        var closeCalls = 0
        let controller = ReviewWindowController(state: state, behavior: .alwaysOnTop)
        controller.onRequestClose = { closeCalls += 1 }
        controller.handleForTesting(.hideIcon)
        controller.handleForTesting(.tapCapsule)
        controller.handleForTesting(.closeRequested)
        XCTAssertEqual(closeCalls, 1)
        controller.close()
    }

    @MainActor
    func testReviewViewBodyEvaluatesDirectContentBranch() {
        let state = ReviewState()
        state.phase = .loading
        _ = ReviewView(state: state,
                       maxContentSize: CGSize(width: ReviewWindowSizing.minWidth, height: 700),
                       isOverflowing: false).body
        _ = ReviewView(state: state,
                       maxContentSize: CGSize(width: ReviewWindowSizing.minWidth, height: 700),
                       isOverflowing: true).body
        _ = ReviewMeasurementView(state: state,
                                  maxContentSize: CGSize(width: ReviewWindowSizing.minWidth, height: 700),
                                  onNaturalSizeChange: { _ in }).body
    }

    @MainActor
    func testShortStreamingMeasurementDoesNotFillMaxHeight() {
        _ = NSApplication.shared
        let state = ReviewState()
        state.phase = .streaming(StreamingPreview(corrected: "A short fix."))
        let host = NSHostingView(rootView: ReviewMeasurementView(
            state: state,
            maxContentSize: CGSize(width: ReviewWindowSizing.minWidth, height: 700),
            onNaturalSizeChange: { _ in }
        ))
        host.frame = NSRect(x: 0, y: 0, width: ReviewWindowSizing.minWidth, height: 1)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(host.fittingSize.height, 300)
    }
}
