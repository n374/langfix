import XCTest
import CoreGraphics
@testable import LangFix

/// 覆盖 spec review-window「弹窗尺寸随内容自适应」的四个 Scenario（纯策略逻辑）。
final class ReviewWindowSizingTests: XCTestCase {
    private let sizing = ReviewWindowSizing()   // minHeight = 132
    /// 1600×1000 屏 → maxW=640(=1600×0.4)、maxH=700(=1000×0.7)。
    private let vf1600 = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    // MARK: 短内容出小窗

    func testShortContentYieldsSmallWindow() {
        let t = sizing.target(natural: CGSize(width: 300, height: 90), visibleFrame: vf1600)
        XCTAssertEqual(t.width, 480, "宽 < minW 夹到 480")
        XCTAssertEqual(t.height, 132, "高 < minH 夹到 minH=132（贴近内容自然高，不撑满高）")
        XCTAssertLessThan(t.height, sizing.limits(visibleFrame: vf1600).height, "短内容高远小于 maxH")
    }

    // MARK: 宽度按屏幕相对范围 clamp（三档）

    func testWidthClampThreeBuckets() {
        func w(_ nat: CGFloat) -> CGFloat {
            sizing.target(natural: CGSize(width: nat, height: 300), visibleFrame: vf1600).width
        }
        XCTAssertEqual(w(300), 480, "小于 minW → 480")
        XCTAssertEqual(w(560), 560, "范围内 → 取自然宽")
        XCTAssertEqual(w(900), 640, "大于 maxW → 夹到 maxW=1600×0.4=640")
    }

    // MARK: 流式增高到上限后滚动（末帧封顶）

    func testHeightGrowsThenCapsAtMaxH() {
        let naturals: [CGFloat] = [120, 180, 260, 900]
        let heights = naturals.map {
            sizing.target(natural: CGSize(width: 480, height: $0), visibleFrame: vf1600).height
        }
        XCTAssertEqual(heights, [132, 180, 260, 700], "低于 minH 夹 132；范围内取自然；超 maxH 封顶 700（末帧需内部滚动）")
    }

    func testNoOverflowUntilNaturalHeightExceedsMaxH() {
        let maxH = sizing.limits(visibleFrame: vf1600).height
        let frames: [CGFloat] = [132, 240, 699.9, 700]
        for h in frames {
            XCTAssertFalse(
                sizing.isOverflowing(natural: CGSize(width: 480, height: h), visibleFrame: vf1600),
                "naturalH=\(h) ≤ maxH 时显示树不应包 ScrollView"
            )
        }
        XCTAssertTrue(
            sizing.isOverflowing(natural: CGSize(width: 480, height: maxH + 0.1), visibleFrame: vf1600),
            "只有 naturalH > maxH 才允许显示树包 ScrollView"
        )
    }

    func testFrameByFrameNaturalUnderMaxMatchesWindowHeight() {
        let frames: [CGFloat] = [150, 220, 360, 520, 700]
        for naturalH in frames {
            let target = sizing.target(natural: CGSize(width: 480, height: naturalH), visibleFrame: vf1600)
            XCTAssertEqual(target.height, naturalH, accuracy: 0.001)
            XCTAssertFalse(sizing.isOverflowing(natural: CGSize(width: 480, height: naturalH), visibleFrame: vf1600))
        }
    }

    // MARK: 上限随分辨率按比例缩放（非固定 px）

    func testMaxHeightScalesWithResolution() {
        let vfTall = CGRect(x: 0, y: 0, width: 1600, height: 1400)
        XCTAssertEqual(sizing.limits(visibleFrame: vf1600).height, 700, accuracy: 0.001)   // 1000×0.7
        XCTAssertEqual(sizing.limits(visibleFrame: vfTall).height, 980, accuracy: 0.001)   // 1400×0.7
        // 两屏 maxH 之比 == 两屏高之比（比例恒定，非固定像素）。
        XCTAssertEqual(980.0 / 700.0, 1400.0 / 1000.0, accuracy: 0.0001)
    }

    // MARK: 高度单调不减（streaming 阶段）

    func testHeightMonotonicWhenStreaming() {
        // 自然高忽升忽降，但单调守卫下窗口高只增不减。
        let naturals: [CGFloat] = [200, 150, 300, 260]
        var last: CGFloat = 132
        var applied: [CGFloat] = []
        for n in naturals {
            let t = sizing.monotonicTarget(natural: CGSize(width: 480, height: n),
                                           visibleFrame: vf1600, lastHeight: last, isStreaming: true)
            last = t.height
            applied.append(t.height)
        }
        XCTAssertEqual(applied, [200, 200, 300, 300], "streaming 下高度单调不减")
        for i in 1..<applied.count { XCTAssertGreaterThanOrEqual(applied[i], applied[i - 1]) }
    }

    func testNonStreamingDoesNotForceMonotonic() {
        // 非流式（result/error 收敛）不强制单调：允许按内容回落（controller 另有阈值防抖）。
        let t = sizing.monotonicTarget(natural: CGSize(width: 480, height: 150),
                                       visibleFrame: vf1600, lastHeight: 400, isStreaming: false)
        XCTAssertEqual(t.height, 150, "非流式不强制单调增高")
    }

    // MARK: 窄屏兜底（D2）

    func testNarrowScreenWidthFloor() {
        let narrow = CGRect(x: 0, y: 0, width: 1000, height: 800)   // 1000×0.4=400 < 480
        XCTAssertEqual(sizing.limits(visibleFrame: narrow).width, 480, "窄屏 maxW 以 480 兜底，区间不非法")
    }
}
