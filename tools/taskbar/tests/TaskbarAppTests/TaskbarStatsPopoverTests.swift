import AppKit
import XCTest
@testable import TaskbarApp

final class TaskbarStatsPopoverTests: XCTestCase {
    func testMemoryGaugeNeedleFollowsFlippedDialAtLowMidAndHighUsage() {
        let center = NSPoint(x: 100, y: 100)
        let low = statsGaugeNeedleEndpoint(percent: 0, center: center, radius: 54)
        let middle = statsGaugeNeedleEndpoint(percent: 50, center: center, radius: 54)
        let high = statsGaugeNeedleEndpoint(percent: 100, center: center, radius: 54)

        XCTAssertEqual(low.x, 63.75, accuracy: 0.01)
        XCTAssertEqual(low.y, 83.10, accuracy: 0.01)
        XCTAssertEqual(middle.x, 69.36, accuracy: 0.01)
        XCTAssertEqual(middle.y, 125.71, accuracy: 0.01)
        XCTAssertEqual(high.x, 110.35, accuracy: 0.01)
        XCTAssertEqual(high.y, 138.64, accuracy: 0.01)

        XCTAssertLessThan(low.y, center.y)
        XCTAssertGreaterThan(middle.y, center.y)
        XCTAssertGreaterThan(high.x, center.x)
        XCTAssertGreaterThan(high.y, center.y)
    }

    func testPopoversShrinkAfterRemovingDataLessSections() {
        XCTAssertEqual(StatsPopoverLayout.size(for: .gpu), NSSize(width: 360, height: 560))
        XCTAssertEqual(StatsPopoverLayout.size(for: .network), NSSize(width: 360, height: 780))
    }
}
