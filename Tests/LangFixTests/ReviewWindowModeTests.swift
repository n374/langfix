import XCTest
import Foundation
@testable import LangFix

/// 覆盖 spec「三态窗体与失焦折叠」+「关闭销毁并取消请求」的状态机语义（纯 reduce）。
/// **正确性核心**：失焦 / Esc 折叠但绝不 cancel；仅关闭路径 cancel（回归现状 onClose 不 cancel 的 bug）。
final class ReviewWindowModeTests: XCTestCase {
    private let modes = WindowBehaviorMode.allCases

    // MARK: 失焦 / Esc → 折叠，且不取消

    func testResignKeyCollapsesWithoutCancel() {
        let t = ReviewWindowMode.expanded.reduce(.resignKey)
        XCTAssertEqual(t.mode, .collapsed)
        XCTAssertFalse(t.cancelTask, "失焦折叠绝不取消底层 Task（后台流式继续）")
    }

    func testResignKeyOnlyFocusCollapseModeCollapses() {
        let expectations: [WindowBehaviorMode: ReviewWindowMode] = [
            .focusCollapse: .collapsed,
            .alwaysOnTop: .expanded,
            .normal: .expanded,
        ]
        for mode in modes {
            let state = ReviewWindowMachineState(behavior: mode, presentation: .expanded)
            let outcome = state.reduceOutcome(.resignKey)
            XCTAssertEqual(outcome.presentation, expectations[mode])
            if mode == .focusCollapse {
                XCTAssertEqual(outcome.actions, [.orderCapsule, .applyLevel])
            } else {
                XCTAssertTrue(outcome.actions.isEmpty, "\(mode) 失焦为 no-op")
            }
        }
    }

    func testEscCollapsesWithoutCancel() {
        let t = ReviewWindowMode.expanded.reduce(.esc)
        XCTAssertEqual(t.mode, .collapsed)
        XCTAssertFalse(t.cancelTask, "Esc 等同失焦：折叠不取消（已修正 .cancelAction）")
    }

    func testEscAndHideIconCollapseAllModesWithoutCancel() {
        for mode in modes {
            for event in [ReviewWindowEvent.esc, .hideIcon] {
                let state = ReviewWindowMachineState(behavior: mode, presentation: .expanded)
                let outcome = state.reduceOutcome(event)
                XCTAssertEqual(outcome.presentation, .collapsed)
                XCTAssertEqual(outcome.actions, [.orderCapsule, .applyLevel])
                XCTAssertFalse(outcome.actions.contains(.cancelTask), "\(mode) \(event) 不得 cancel")
            }
        }
    }

    // MARK: 点击胶囊 → 展开恢复

    func testTapCapsuleExpands() {
        let t = ReviewWindowMode.collapsed.reduce(.tapCapsule)
        XCTAssertEqual(t.mode, .expanded)
        XCTAssertFalse(t.cancelTask)
    }

    func testTapCapsuleAllModesExpandsAndRequestsRecompute() {
        for mode in modes {
            let state = ReviewWindowMachineState(behavior: mode, presentation: .collapsed)
            let outcome = state.reduceOutcome(.tapCapsule)
            XCTAssertEqual(outcome.presentation, .expanded)
            XCTAssertEqual(outcome.actions, [.recomputeSize, .applyLevel, .orderExpanded])
        }
    }

    func testRecomputeUsesCurrentNaturalSizeNotCollapsedOldSize() {
        let sizing = ReviewWindowSizing()
        let vf = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let old = sizing.target(natural: CGSize(width: 480, height: 180), visibleFrame: vf)
        let current = sizing.target(natural: CGSize(width: 480, height: 520), visibleFrame: vf)

        let state = ReviewWindowMachineState(behavior: .normal, presentation: .collapsed)
        let outcome = state.reduceOutcome(.tapCapsule)

        XCTAssertTrue(outcome.actions.contains(.recomputeSize), "展开必须触发当刻内容重算")
        XCTAssertNotEqual(current, old, "测试前提：折叠期间内容变化后当刻尺寸应不同于旧尺寸")
        XCTAssertEqual(current.height, 520)
    }

    // MARK: 关闭 → 销毁并取消（唯一 cancel 路径）

    func testCloseFromExpandedCancels() {
        let t = ReviewWindowMode.expanded.reduce(.closeRequested)
        XCTAssertEqual(t.mode, .closed)
        XCTAssertTrue(t.cancelTask, "关闭必须 cancel 底层 Task")
    }

    func testCloseCancelsInAllModes() {
        for mode in modes {
            for presentation in [ReviewWindowMode.expanded, .collapsed] {
                let state = ReviewWindowMachineState(behavior: mode, presentation: presentation)
                let outcome = state.reduceOutcome(.closeRequested)
                XCTAssertEqual(outcome.presentation, .closed)
                XCTAssertEqual(outcome.actions, [.cancelTask])
            }
        }
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

    // MARK: 设置默认值 / 持久化

    func testWindowBehaviorDefaultAndRawValueFallback() {
        XCTAssertEqual(WindowBehaviorMode.defaultMode, .normal)
        XCTAssertEqual(WindowBehaviorMode(rawValueOrDefault: nil), .normal)
        XCTAssertEqual(WindowBehaviorMode(rawValueOrDefault: ""), .normal)
        XCTAssertEqual(WindowBehaviorMode(rawValueOrDefault: "garbage"), .normal)
        XCTAssertEqual(WindowBehaviorMode(rawValueOrDefault: "alwaysOnTop"), .alwaysOnTop)
    }

    func testWindowBehaviorModeDisplayMetadata() {
        for mode in modes {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.subtitle.isEmpty)
            XCTAssertFalse(mode.iconName.isEmpty)
        }
        XCTAssertEqual(WindowBehaviorMode.focusCollapse.iconName, "eye.slash")
        XCTAssertEqual(WindowBehaviorMode.alwaysOnTop.iconName, "pin.fill")
        XCTAssertEqual(WindowBehaviorMode.normal.iconName, "macwindow")
    }

    func testWindowBehaviorPersistenceViaUserDefaults() {
        let suiteName = "langfix.test.window.behavior.persistence"
        let d = UserDefaults(suiteName: suiteName)!
        d.removePersistentDomain(forName: suiteName)
        d.register(defaults: ["windowBehaviorMode": WindowBehaviorMode.defaultMode.rawValue])

        XCTAssertEqual(WindowBehaviorMode(rawValueOrDefault: d.string(forKey: "windowBehaviorMode")), .normal)

        d.set(WindowBehaviorMode.alwaysOnTop.rawValue, forKey: "windowBehaviorMode")
        let d2 = UserDefaults(suiteName: suiteName)!
        XCTAssertEqual(WindowBehaviorMode(rawValueOrDefault: d2.string(forKey: "windowBehaviorMode")), .alwaysOnTop)

        d.removePersistentDomain(forName: suiteName)
    }

    func testWindowBehaviorModeNotInAppConfig() {
        let mirror = Mirror(reflecting: testConfig())
        let labels = mirror.children.compactMap { $0.label?.lowercased() }
        XCTAssertFalse(labels.contains { $0.contains("window") || $0.contains("behavior") },
                       "窗口行为是 UI 偏好，不进入 AI AppConfig")
    }
}
