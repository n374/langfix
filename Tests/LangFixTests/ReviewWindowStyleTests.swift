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

    @MainActor
    func testShortLoadingMeasurementDoesNotGreedyFillTallContainer() {
        _ = NSApplication.shared
        let state = ReviewState()
        state.phase = .loading
        let maxHeight: CGFloat = 700
        let host = NSHostingView(rootView: ReviewMeasurementView(
            state: state,
            maxContentSize: CGSize(width: ReviewWindowSizing.minWidth, height: maxHeight),
            onNaturalSizeChange: { _ in }
        ))
        host.frame = NSRect(x: 0, y: 0, width: ReviewWindowSizing.minWidth, height: maxHeight)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(host.fittingSize.height, maxHeight * 0.5)
    }

    @MainActor
    func testLoadingMeasurementAndAppliedHeightDoNotLeaveLargeFooterWhitespace() {
        _ = NSApplication.shared
        let state = ReviewState()
        state.phase = .loading
        let controller = ReviewWindowController(state: state, behavior: .normal)
        controller.showCentered()
        defer { controller.close() }

        let snapshot = controller.measureAndApplyForTesting()
        XCTAssertLessThan(snapshot.natural.height, snapshot.maxContent.height * 0.5)
        XCTAssertLessThan(snapshot.appliedContent.height, snapshot.maxContent.height * 0.5)
        XCTAssertLessThanOrEqual(snapshot.appliedContent.height - snapshot.natural.height, 32)
    }

    @MainActor
    func testStreamingPeakFallsBackThroughRealMeasurementAndApplyPath() {
        _ = NSApplication.shared
        let state = ReviewState()
        state.phase = .loading
        let controller = ReviewWindowController(state: state, behavior: .normal)
        controller.showCentered()
        defer { controller.close() }

        let initial = controller.measureAndApplyForTesting()
        let maxHeight = initial.maxContent.height
        let peak = measureSubMaxPeak(controller: controller, state: state, maxHeight: maxHeight)
        XCTAssertLessThan(peak.appliedContent.height, maxHeight, "test setup must keep the peak below maxH")

        state.phase = .streaming(StreamingPreview(corrected: "A concise correction."))
        let short = controller.measureAndApplyForTesting()
        XCTAssertLessThan(short.natural.height, peak.natural.height - 80)
        XCTAssertEqual(short.appliedContent.height, short.natural.height, accuracy: 2)
        XCTAssertNotEqual(short.appliedContent.height, peak.appliedContent.height, accuracy: 2)
        XCTAssertLessThan(short.appliedContent.height, maxHeight * 0.5)

        state.phase = .loading
        let loading = controller.measureAndApplyForTesting()
        XCTAssertEqual(loading.appliedContent.height, loading.natural.height, accuracy: 2)
        XCTAssertNotEqual(loading.appliedContent.height, peak.appliedContent.height, accuracy: 2)
        XCTAssertLessThan(loading.appliedContent.height, maxHeight * 0.5)
    }

    @MainActor
    func testLongStreamingContentCapsAtMaxHeightAndMarksOverflow() {
        _ = NSApplication.shared
        let state = ReviewState()
        state.phase = .streaming(StreamingPreview(corrected: Self.streamingText(lines: 120)))
        let controller = ReviewWindowController(state: state, behavior: .normal)
        controller.showCentered()
        defer { controller.close() }

        let snapshot = controller.measureAndApplyForTesting()
        XCTAssertGreaterThan(snapshot.natural.height, snapshot.maxContent.height)
        XCTAssertEqual(snapshot.appliedContent.height, snapshot.maxContent.height, accuracy: 2)
        XCTAssertTrue(snapshot.isOverflowing)
    }

    @MainActor
    func testMaxHeightFrameDoesNotPolluteNextShortMeasurementAndApply() {
        _ = NSApplication.shared
        let state = ReviewState()
        state.phase = .streaming(StreamingPreview(corrected: Self.streamingText(lines: 120)))
        let controller = ReviewWindowController(state: state, behavior: .normal)
        controller.showCentered()
        defer { controller.close() }

        let capped = controller.measureAndApplyForTesting()
        XCTAssertGreaterThan(capped.natural.height, capped.maxContent.height)
        XCTAssertEqual(capped.appliedContent.height, capped.maxContent.height, accuracy: 2)

        state.phase = .streaming(StreamingPreview(corrected: "A concise correction."))
        let short = controller.measureAndApplyForTesting()
        XCTAssertLessThan(short.natural.height, capped.maxContent.height * 0.5)
        XCTAssertEqual(short.appliedContent.height, short.natural.height, accuracy: 2)
        XCTAssertNotEqual(short.appliedContent.height, capped.appliedContent.height, accuracy: 2)
        XCTAssertFalse(short.isOverflowing)
    }

    @MainActor
    func testInitialFrameIsUpperRightBiasedAndInsideVisibleFrame() {
        let visibleFrame = NSRect(x: 120, y: 80, width: 1600, height: 1000)
        let windowFrame = NSRect(x: 0, y: 0, width: 420, height: 220)
        let frame = ReviewWindowController.initialFrameForTesting(windowFrame: windowFrame,
                                                                  visibleFrame: visibleFrame)
        let centeredOrigin = NSPoint(
            x: visibleFrame.minX + (visibleFrame.width - windowFrame.width) / 2,
            y: visibleFrame.minY + (visibleFrame.height - windowFrame.height) / 2
        )

        XCTAssertGreaterThan(frame.origin.y, centeredOrigin.y)
        XCTAssertGreaterThan(frame.origin.x, centeredOrigin.x)
        XCTAssertTrue(visibleFrame.contains(frame))
    }

    @MainActor
    private func measureSubMaxPeak(controller: ReviewWindowController,
                                   state: ReviewState,
                                   maxHeight: CGFloat) -> ReviewWindowController.MeasurementSnapshot {
        var last = controller.measurementSnapshotForTesting()
        for lines in stride(from: 8, through: 70, by: 2) {
            state.phase = .streaming(StreamingPreview(corrected: Self.streamingText(lines: lines)))
            let snapshot = controller.measureAndApplyForTesting()
            last = snapshot
            if snapshot.natural.height > maxHeight * 0.55 && snapshot.natural.height < maxHeight * 0.85 {
                return snapshot
            }
        }
        XCTFail("could not produce a deterministic sub-max peak; last measured height \(last.natural.height), max \(maxHeight)")
        return last
    }

    private static func streamingText(lines: Int) -> String {
        (1...lines)
            .map { "Line \($0): This sentence keeps the streaming preview tall enough for measurement." }
            .joined(separator: "\n")
    }
}
