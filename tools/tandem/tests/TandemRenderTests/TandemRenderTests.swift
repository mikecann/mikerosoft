import XCTest
@testable import TandemRender

final class TandemRenderPlaceholderTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(TandemRender.version.isEmpty)
    }
}
