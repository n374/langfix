import XCTest
import AppKit
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
}
