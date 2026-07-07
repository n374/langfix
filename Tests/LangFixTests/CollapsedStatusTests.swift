import XCTest
@testable import LangFix

/// 覆盖 spec「折叠态状态可视化」：三态由 Phase 派生，颜色/图标互不相同。
@MainActor
final class CollapsedStatusTests: XCTestCase {

    func testPhaseToStatusMapping() {
        XCTAssertEqual(CollapsedStatus(.loading), .working)
        XCTAssertEqual(CollapsedStatus(.streaming(StreamingPreview(corrected: "x"))), .working)
        XCTAssertEqual(CollapsedStatus(.stopped(StreamingPreview(corrected: "x"))), .done,
                       "停止态为已完成（非进行中），胶囊显示 done")
        XCTAssertEqual(CollapsedStatus(.result(sampleResult())), .done)
        XCTAssertEqual(CollapsedStatus(.error("boom")), .failed)
    }

    func testIconsAreDistinct() {
        let icons = [CollapsedStatus.working, .done, .failed].map(\.iconName)
        XCTAssertEqual(Set(icons).count, 3, "三态图标互不相同")
    }

    func testTitlesAreDistinctAndNonEmpty() {
        let titles = [CollapsedStatus.working, .done, .failed].map(\.title)
        XCTAssertEqual(Set(titles).count, 3, "三态文案互不相同")
        XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })
    }

    func testColorsAreDistinct() {
        let t = ReviewThemeCatalog.auroraGlass
        let colors = [CollapsedStatus.working.color(t),
                      CollapsedStatus.done.color(t),
                      CollapsedStatus.failed.color(t)]
        XCTAssertNotEqual(colors[0], colors[1], "进行中 ≠ 已完成")
        XCTAssertNotEqual(colors[1], colors[2], "已完成 ≠ 出错")
        XCTAssertNotEqual(colors[0], colors[2], "进行中 ≠ 出错")
    }

    func testErrorStatusDistinctFromOthers() {
        XCTAssertNotEqual(CollapsedStatus.failed, .working)
        XCTAssertNotEqual(CollapsedStatus.failed, .done)
        // 出错态色与其余两态在所有主题下都可辨识。
        for id in ReviewThemeID.allCases {
            let t = ReviewThemeCatalog.theme(id)
            XCTAssertNotEqual(CollapsedStatus.failed.color(t), CollapsedStatus.working.color(t))
            XCTAssertNotEqual(CollapsedStatus.failed.color(t), CollapsedStatus.done.color(t))
        }
    }

    private func sampleResult() -> ReviewResult {
        ReviewResult(hasIssues: false, original: "a", corrected: "a", summaryZh: "", issues: [])
    }
}
