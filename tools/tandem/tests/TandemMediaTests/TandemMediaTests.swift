import XCTest
@testable import TandemMedia

final class TandemMediaPlaceholderTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(TandemMedia.version.isEmpty)
    }
}
