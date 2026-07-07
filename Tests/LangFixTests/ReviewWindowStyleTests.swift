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
        let glass = controller.expandedVisualEffectForTesting()
        XCTAssertEqual(glass.material, .hudWindow)
        XCTAssertEqual(glass.blendingMode, .behindWindow)
        XCTAssertEqual(glass.state, .active)
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
    func testStreamingStateChangesResizeThroughProductionRunLoopPath() {
        _ = NSApplication.shared
        let state = ReviewState()
        state.phase = .loading
        let controller = ReviewWindowController(state: state, behavior: .normal)
        controller.showCentered()
        defer { controller.close() }

        settleMainRunLoop()
        let loading = controller.measurementSnapshotForTesting()
        XCTAssertLessThan(loading.appliedContent.height, loading.maxContent.height * 0.5)

        state.phase = .streaming(StreamingPreview(corrected: "A concise correction."))
        settleMainRunLoop()
        let short = controller.measurementSnapshotForTesting()
        XCTAssertLessThan(short.natural.height, short.maxContent.height * 0.5)
        XCTAssertLessThan(short.appliedContent.height, short.maxContent.height * 0.5)
        XCTAssertLessThanOrEqual(short.appliedContent.height - short.natural.height, 32)

        state.phase = .streaming(StreamingPreview(corrected: Self.streamingText(lines: 120)))
        settleMainRunLoop()
        let long = controller.measurementSnapshotForTesting()
        XCTAssertGreaterThan(long.natural.height, long.maxContent.height)
        XCTAssertEqual(long.appliedContent.height, long.maxContent.height, accuracy: 2)
        XCTAssertTrue(long.isOverflowing)

        state.phase = .streaming(StreamingPreview(corrected: "A concise correction."))
        settleMainRunLoop()
        let backToShort = controller.measurementSnapshotForTesting()
        XCTAssertLessThan(backToShort.natural.height, long.maxContent.height * 0.5)
        XCTAssertLessThanOrEqual(backToShort.appliedContent.height - backToShort.natural.height, 32)
        XCTAssertNotEqual(backToShort.appliedContent.height, long.appliedContent.height, accuracy: 2)
        XCTAssertFalse(backToShort.isOverflowing)
    }

    @MainActor
    func testInitialFrameFollowsMouseToRightWhenSpaceAvailable() {
        let visibleFrame = NSRect(x: 120, y: 80, width: 1600, height: 1000)
        let windowSize = CGSize(width: 420, height: 220)
        // 鼠标在屏左侧，右侧有充足空间 → 窗口落在鼠标右侧并留 gap。
        let mouse = NSPoint(x: 400, y: 600)
        let frame = ReviewWindowController.placeInitialFrame(
            windowSize: windowSize, mouseLocation: mouse, visibleFrame: visibleFrame,
            gap: 24, topMarginRatio: 0.12)
        XCTAssertEqual(frame.origin.x, mouse.x + 24, accuracy: 0.5, "窗口左边缘 = 鼠标 x + gap（在鼠标右侧）")
        XCTAssertTrue(visibleFrame.contains(frame), "不越界")
    }

    @MainActor
    func testInitialFrameFlipsToLeftWhenRightHasNoRoom() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let windowSize = CGSize(width: 420, height: 220)
        // 鼠标贴近右边界，右侧放不下 → 翻到鼠标左侧。
        let mouse = NSPoint(x: 1400, y: 500)
        let frame = ReviewWindowController.placeInitialFrame(
            windowSize: windowSize, mouseLocation: mouse, visibleFrame: visibleFrame,
            gap: 24, topMarginRatio: 0.12)
        XCTAssertLessThanOrEqual(frame.maxX, mouse.x, "窗口整体在鼠标左侧")
        XCTAssertTrue(visibleFrame.contains(frame), "不越界")
    }

    @MainActor
    func testInitialFrameVerticalTopAnchorBiasedUp() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let windowSize = CGSize(width: 420, height: 220)
        let mouse = NSPoint(x: 300, y: 500)
        let frame = ReviewWindowController.placeInitialFrame(
            windowSize: windowSize, mouseLocation: mouse, visibleFrame: visibleFrame,
            gap: 24, topMarginRatio: 0.12)
        // 顶边应锚定在 屏顶 - 屏高×0.12 附近（偏上）。
        let expectedTopEdge = visibleFrame.maxY - visibleFrame.height * 0.12
        XCTAssertEqual(frame.maxY, expectedTopEdge, accuracy: 0.5, "顶边锚定在屏顶下方 12% 处（居中略偏上）")
        // 顶边高于屏幕竖直中点（偏上而非居中）。
        XCTAssertGreaterThan(frame.maxY, visibleFrame.midY)
        XCTAssertTrue(visibleFrame.contains(frame))
    }

    @MainActor
    func testInitialScreenSelectionUsesMouseScreenForSecondaryDisplay() {
        let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = NSRect(x: 1440, y: -120, width: 1920, height: 1080)
        let selected = ReviewWindowController.visibleFrameForInitialDisplayForTesting(
            mouseLocation: NSPoint(x: 2200, y: 200),
            screens: [main, secondary],
            fallback: main
        )
        XCTAssertEqual(selected, secondary)
    }

    // MARK: round5 —— 多屏定位：驱动「真实初始定位路径」的选屏（非只测注入 vf 的 placeInitialFrame）

    /// **round5 回归**：鼠标在副屏时，初始定位组合函数（生产 `positionExpandedPanelForInitialDisplay`
    /// 调用的同一个 `initialFrame`：选屏 → 定位 → clamp）必须让窗口落在副屏，绝不被拉回主屏。
    /// 该断言对旧实现（初始定位用 `expandedPanel.screen`=主屏当 vf）会 fail——正是前三次绿却没修好的漏洞点。
    @MainActor
    func testInitialFrameLandsOnMouseScreenNotMainOnMultiDisplay() {
        // 副屏在主屏右侧、原点带负 y（真实多屏常见布局，能暴露坐标系/clamp 问题）。
        let main = ReviewWindowController.ScreenFrame(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875))
        let secondary = ReviewWindowController.ScreenFrame(
            frame: NSRect(x: 1440, y: -180, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 1440, y: -180, width: 1920, height: 1055))
        let mouse = NSPoint(x: 1440 + 900, y: -180 + 500)   // 鼠标在副屏内
        let frame = ReviewWindowController.initialFrame(
            windowSize: CGSize(width: 336, height: 200), mouseLocation: mouse,
            screens: [main, secondary], fallbackVisibleFrame: main.visibleFrame,
            gap: 24, topMarginRatio: 0.12)
        XCTAssertTrue(secondary.visibleFrame.contains(frame), "窗口应落在鼠标所在的副屏 visibleFrame 内")
        XCTAssertFalse(frame.intersects(main.frame), "窗口不得出现在主屏（旧 bug：被 clamp 回主屏）")
    }

    /// 选屏返回的是命中屏的 visibleFrame（非 frame），且能命中负原点/偏移副屏。
    @MainActor
    func testSelectVisibleFrameReturnsHitScreenVisibleFrame() {
        let main = ReviewWindowController.ScreenFrame(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 25, width: 1440, height: 875))
        let secondary = ReviewWindowController.ScreenFrame(
            frame: NSRect(x: -1920, y: -100, width: 1920, height: 1080),
            visibleFrame: NSRect(x: -1920, y: -100, width: 1920, height: 1055))
        let onSecondary = ReviewWindowController.selectVisibleFrame(
            mouseLocation: NSPoint(x: -1000, y: 200), screens: [main, secondary], fallback: main.visibleFrame)
        XCTAssertEqual(onSecondary, secondary.visibleFrame, "命中副屏 → 返回副屏 visibleFrame")
        // 鼠标不在任何屏 → fallback。
        let off = ReviewWindowController.selectVisibleFrame(
            mouseLocation: NSPoint(x: 99_999, y: 99_999), screens: [main, secondary], fallback: main.visibleFrame)
        XCTAssertEqual(off, main.visibleFrame, "命中不了任何屏 → fallback")
    }

    @MainActor
    private func measureSubMaxPeak(controller: ReviewWindowController,
                                   state: ReviewState,
                                   maxHeight: CGFloat) -> ReviewWindowController.MeasurementSnapshot {
        // 逐行（stride by 1，从 1 行起）细粒度搜索，保证在任意屏幕尺寸/视图开销下都能落入
        // (0.55·maxH, 0.85·maxH) 目标带——粗粒度（by 2）在小屏（如 CI runner，maxH≈477）上会
        // 因单步跨度大而跳过整个带，导致找不到 sub-max peak。带宽约 0.3·maxH ≫ 单行高度，逐行必命中。
        var last = controller.measurementSnapshotForTesting()
        var best: ReviewWindowController.MeasurementSnapshot?
        for lines in stride(from: 1, through: 90, by: 1) {
            state.phase = .streaming(StreamingPreview(corrected: Self.streamingText(lines: lines)))
            let snapshot = controller.measureAndApplyForTesting()
            last = snapshot
            if snapshot.natural.height > maxHeight * 0.55 && snapshot.natural.height < maxHeight * 0.85 {
                return snapshot
            }
            // 兜底：记录最后一个仍严格低于 maxH 的快照，避免搜索未命中带时返回越界（clamp 到 maxH）的快照。
            if snapshot.natural.height < maxHeight { best = snapshot }
        }
        if let best {
            return best
        }
        XCTFail("could not produce a deterministic sub-max peak; last measured height \(last.natural.height), max \(maxHeight)")
        return last
    }

    private static func streamingText(lines: Int) -> String {
        (1...lines)
            .map { "Line \($0): This sentence keeps the streaming preview tall enough for measurement." }
            .joined(separator: "\n")
    }

    @MainActor
    private func settleMainRunLoop(iterations: Int = 8) {
        for _ in 0..<iterations {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }
}
