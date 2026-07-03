import XCTest
@testable import LangFix

/// 覆盖 spec「三态窗体与失焦折叠」+「关闭销毁并取消请求」的状态机语义（纯 reduce）。
/// **正确性核心**：失焦 / Esc 折叠但绝不 cancel；仅关闭路径 cancel（回归现状 onClose 不 cancel 的 bug）。
final class ReviewWindowModeTests: XCTestCase {

    // MARK: 失焦 / Esc → 折叠，且不取消

    func testResignKeyCollapsesWithoutCancel() {
        let t = ReviewWindowMode.expanded.reduce(.resignKey)
        XCTAssertEqual(t.mode, .collapsed)
        XCTAssertFalse(t.cancelTask, "失焦折叠绝不取消底层 Task（后台流式继续）")
    }

    func testEscCollapsesWithoutCancel() {
        let t = ReviewWindowMode.expanded.reduce(.esc)
        XCTAssertEqual(t.mode, .collapsed)
        XCTAssertFalse(t.cancelTask, "Esc 等同失焦：折叠不取消（已修正 .cancelAction）")
    }

    // MARK: 点击胶囊 → 展开恢复

    func testTapCapsuleExpands() {
        let t = ReviewWindowMode.collapsed.reduce(.tapCapsule)
        XCTAssertEqual(t.mode, .expanded)
        XCTAssertFalse(t.cancelTask)
    }

    // MARK: 关闭 → 销毁并取消（唯一 cancel 路径）

    func testCloseFromExpandedCancels() {
        let t = ReviewWindowMode.expanded.reduce(.closeRequested)
        XCTAssertEqual(t.mode, .closed)
        XCTAssertTrue(t.cancelTask, "关闭必须 cancel 底层 Task")
    }

    func testCloseFromCollapsedCancels() {
        let t = ReviewWindowMode.collapsed.reduce(.closeRequested)
        XCTAssertEqual(t.mode, .closed)
        XCTAssertTrue(t.cancelTask, "折叠态关闭同样 cancel")
    }

    // MARK: closed 终态幂等，无副作用

    func testClosedIsIdempotentNoCancel() {
        for e in [ReviewWindowEvent.closeRequested, .esc, .resignKey, .tapCapsule] {
            let t = ReviewWindowMode.closed.reduce(e)
            XCTAssertEqual(t.mode, .closed)
            XCTAssertFalse(t.cancelTask, "closed 终态不再取消/不再改 UI（幂等）")
        }
    }

    // MARK: 无意义事件为 no-op

    func testNoOpTransitions() {
        XCTAssertEqual(ReviewWindowMode.collapsed.reduce(.resignKey),
                       ReviewWindowTransition(mode: .collapsed, cancelTask: false))
        XCTAssertEqual(ReviewWindowMode.collapsed.reduce(.esc),
                       ReviewWindowTransition(mode: .collapsed, cancelTask: false))
        XCTAssertEqual(ReviewWindowMode.expanded.reduce(.tapCapsule),
                       ReviewWindowTransition(mode: .expanded, cancelTask: false))
    }

    // MARK: 折叠期间后台增量仍应用到内容（state 与窗口态解耦）

    @MainActor
    func testStateStillUpdatesWhileConceptuallyCollapsed() {
        // 窗口态与 ReviewState 解耦：无论展开/折叠，喂增量都更新 phase，展开后即最新。
        let state = ReviewState()
        state.phase = .streaming(StreamingPreview(corrected: "a"))
        state.phase = .streaming(StreamingPreview(corrected: "ab"))
        if case .streaming(let p) = state.phase {
            XCTAssertEqual(p.corrected, "ab", "折叠期间累积的增量在展开后为最新")
        } else {
            XCTFail("phase 应为 streaming")
        }
    }
}
