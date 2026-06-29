import XCTest
@testable import LangFix

final class KeychainStoreTests: XCTestCase {

    func testRoundTrip() throws {
        let ok = KeychainStore.setAPIKey("sk-test-12345")
        try XCTSkipUnless(ok, "当前环境无法写 Keychain（如沙箱/CI 无钥匙串），跳过")
        defer { KeychainStore.deleteAPIKey() }

        XCTAssertEqual(KeychainStore.apiKey(), "sk-test-12345")
        XCTAssertTrue(KeychainStore.hasAPIKey)

        // 覆盖写
        XCTAssertTrue(KeychainStore.setAPIKey("sk-test-67890"))
        XCTAssertEqual(KeychainStore.apiKey(), "sk-test-67890")

        // 删除
        XCTAssertTrue(KeychainStore.deleteAPIKey())
        XCTAssertNil(KeychainStore.apiKey())
        XCTAssertFalse(KeychainStore.hasAPIKey)
    }

    func testEmptyKeyDeletes() throws {
        let ok = KeychainStore.setAPIKey("temp")
        try XCTSkipUnless(ok, "无 Keychain，跳过")
        _ = KeychainStore.setAPIKey("   ")   // 空白等价删除
        XCTAssertNil(KeychainStore.apiKey())
    }
}
