import XCTest
@testable import LangFix

/// **最高优先级：关闭取消在途请求（回归现状 onClose 不 cancel 的正确性 bug，design.md §5 / §2.4）。**
/// 现状缺口：`onClose` 只关窗、不 cancel 底层 Task；本 change 汇聚为唯一幂等 cancel 路径。
@MainActor
final class CloseSemanticsTests: XCTestCase {

    // MARK: onClose 与 onCancel 都汇聚到同一 cancel 路径

    func testBothCloseAndCancelRouteToCancel() {
        let state = ReviewState()
        var cancelCalls = 0
        AppCoordinator.wireCloseSemantics(state: state) { cancelCalls += 1 }

        state.onCancel?()
        XCTAssertEqual(cancelCalls, 1, "取消按钮触发 cancel 路径")
        state.onClose?()
        XCTAssertEqual(cancelCalls, 2, "关闭按钮同样触发 cancel 路径（修复 onClose 不 cancel 的 bug）")
    }

    // MARK: 关闭后底层 Task 确实被 cancel（Task.isCancelled == true）

    func testCloseCancelsUnderlyingTask() async {
        let task = Task { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        XCTAssertFalse(task.isCancelled, "初始未取消")

        let state = ReviewState()
        AppCoordinator.wireCloseSemantics(state: state) { task.cancel() }
        state.onClose?()

        XCTAssertTrue(task.isCancelled, "关闭后底层 Task.isCancelled == true")
        task.cancel()
    }

    func testCancelButtonAlsoCancelsUnderlyingTask() async {
        let task = Task { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        let state = ReviewState()
        AppCoordinator.wireCloseSemantics(state: state) { task.cancel() }
        state.onCancel?()
        XCTAssertTrue(task.isCancelled, "取消按钮亦 cancel 底层 Task")
        task.cancel()
    }

    // MARK: 差分回归——Esc / 失焦（折叠）绝不 cancel，与关闭路径对照

    func testEscAndResignDoNotCancel() {
        // 折叠路径（esc/resignKey）在状态机层就标记 cancelTask=false，与关闭路径形成差分。
        XCTAssertFalse(ReviewWindowMode.expanded.reduce(.esc).cancelTask, "Esc 折叠不取消")
        XCTAssertFalse(ReviewWindowMode.expanded.reduce(.resignKey).cancelTask, "失焦折叠不取消")
        XCTAssertTrue(ReviewWindowMode.expanded.reduce(.closeRequested).cancelTask, "唯有关闭取消")
    }

    /// 折叠态后台流式继续 vs 关闭态请求取消 的差分：折叠事件不 cancel，关闭事件 cancel。
    func testCollapseKeepsTaskCloseCancelsTask() async {
        // 折叠：不 cancel。
        let collapsingTask = Task { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        if ReviewWindowMode.expanded.reduce(.resignKey).cancelTask { collapsingTask.cancel() }
        XCTAssertFalse(collapsingTask.isCancelled, "折叠态底层 Task 后台继续（未取消）")
        collapsingTask.cancel()

        // 关闭：cancel。
        let closingTask = Task { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        if ReviewWindowMode.expanded.reduce(.closeRequested).cancelTask { closingTask.cancel() }
        XCTAssertTrue(closingTask.isCancelled, "关闭态底层 Task 被取消")
        closingTask.cancel()
    }
}
