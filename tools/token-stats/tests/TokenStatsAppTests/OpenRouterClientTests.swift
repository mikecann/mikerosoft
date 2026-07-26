import Foundation
import XCTest
@testable import TokenStatsApp

final class OpenRouterClientTests: XCTestCase {
    func testManagementKeyValidationRejectsIncompleteClipboardValue() {
        XCTAssertTrue(
            OpenRouterManagementKey.isValid(
                "sk-or-v1-" + String(repeating: "a", count: 64)
            )
        )
        XCTAssertFalse(
            OpenRouterManagementKey.isValid(
                String(repeating: "a", count: 64)
            )
        )
        XCTAssertFalse(OpenRouterManagementKey.isValid("sk-or-v1-short"))
    }

    func testActivityRequestUsesManagementKeyWithoutPuttingItInTheURL() throws {
        let request = try OpenRouterActivityClient.activityRequest(
            managementKey: "management-secret"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/activity")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer management-secret"
        )
        XCTAssertFalse(request.url?.absoluteString.contains("management-secret") ?? true)
    }
}
