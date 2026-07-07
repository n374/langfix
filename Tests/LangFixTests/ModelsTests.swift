import XCTest
@testable import LangFix

final class ModelsTests: XCTestCase {

    func testReviewResultDecodingTolerant() throws {
        let json = """
        {
          "has_issues": true,
          "original": "I has went",
          "corrected": "I have gone",
          "summary_zh": "时态错误",
          "issues": [
            {"category": "grammar", "severity": "error", "before": "has went", "after": "have gone", "reason_zh": "完成时用 have + 过去分词"},
            {"category": "totally_unknown", "severity": "weird", "before": "x", "after": "y", "reason_zh": "未知类别应落到地道度"}
          ]
        }
        """
        let r = try JSONDecoder().decode(ReviewResult.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(r.hasIssues)
        XCTAssertEqual(r.corrected, "I have gone")
        XCTAssertEqual(r.issues.count, 2)
        XCTAssertEqual(r.issues[0].category, .grammar)
        // 未知枚举宽容回退
        XCTAssertEqual(r.issues[1].category, .naturalness)
        XCTAssertEqual(r.issues[1].severity, .improvement)
    }

    func testExtractJSONStripsCodeFence() {
        let fenced = """
        ```json
        {"has_issues": false, "corrected": "ok"}
        ```
        """
        let out = AIClient.extractJSON(fenced)
        XCTAssertTrue(out.hasPrefix("{"))
        XCTAssertTrue(out.hasSuffix("}"))
        XCTAssertFalse(out.contains("```"))
    }

    func testExtractJSONStripsSurroundingText() {
        let messy = "这是结果：{\"corrected\":\"x\"} 以上。"
        let out = AIClient.extractJSON(messy)
        XCTAssertEqual(out, "{\"corrected\":\"x\"}")
    }

    // round4 需求2：corrected 的中文直译 translation_zh。

    func testReviewResultDecodesTranslationZh() throws {
        let json = """
        {"has_issues": false, "original": "Thx", "corrected": "Thanks",
         "translation_zh": "谢谢", "summary_zh": "更完整", "issues": []}
        """
        let r = try JSONDecoder().decode(ReviewResult.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(r.translationZh, "谢谢")
    }

    func testReviewResultTranslationZhDefaultsEmptyWhenAbsent() throws {
        // 模型未返回 translation_zh 时宽容缺省为空串（不影响其它字段）。
        let json = """
        {"has_issues": false, "original": "ok", "corrected": "ok", "summary_zh": "", "issues": []}
        """
        let r = try JSONDecoder().decode(ReviewResult.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(r.translationZh, "")
    }
}
