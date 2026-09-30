import XCTest
@testable import TandemApp

/// Tandem's own tooltips sit beside the pointer and stay inside the window.
final class TipTests: XCTestCase {
    private let window = CGSize(width: 1_000, height: 600)
    private let tip = CGSize(width: 200, height: 30)

    func testBelowAndRightOfThePointer() {
        XCTAssertEqual(TipPlacement.origin(size: tip, at: CGPoint(x: 100, y: 100), in: window), CGPoint(x: 112, y: 120))
    }

    func testFlipsLeftNearTheRightEdge() {
        let origin = TipPlacement.origin(size: tip, at: CGPoint(x: 900, y: 100), in: window)
        XCTAssertEqual(origin.x, 900 - 200 - 6)
        XCTAssertLessThanOrEqual(origin.x + tip.width, 1_000)
    }

    func testFlipsAboveNearTheBottom() {
        let origin = TipPlacement.origin(size: tip, at: CGPoint(x: 100, y: 590), in: window)
        XCTAssertEqual(origin.y, 590 - 30 - 8)
    }

    @MainActor
    func testATipGoesWhenThePointerLeavesAndOnlyForItsOwner() {
        let center = TipCenter.shared
        let first = UUID()
        let second = UUID()
        center.hover("Blade tool (C)", owner: first, at: CGPoint(x: 10, y: 10))
        center.hover("Select tool (V)", owner: second, at: CGPoint(x: 40, y: 10))
        center.leave(owner: first)
        center.hide()
        XCTAssertNil(center.shown)
    }
}
