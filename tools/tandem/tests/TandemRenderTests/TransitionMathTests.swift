import CoreGraphics
import XCTest
import TandemCore
@testable import TandemRender

final class TransitionMathTests: XCTestCase {
    func testPushMovesBothShotsInEveryDirection() {
        let cases: [(Direction, CGVector)] = [(.left, CGVector(dx: -1, dy: 0)), (.right, CGVector(dx: 1, dy: 0)), (.up, CGVector(dx: 0, dy: -1)), (.down, CGVector(dx: 0, dy: 1))]
        for (direction, v) in cases {
            let start = TransitionRenderer.offsets(.push, direction: direction, progress: 0)
            XCTAssertEqual(start.from, .zero, "\(direction)")
            XCTAssertEqual(start.to, CGVector(dx: -v.dx, dy: -v.dy), "\(direction)")
            let middle = TransitionRenderer.offsets(.push, direction: direction, progress: 0.5)
            XCTAssertEqual(middle.from.dx, v.dx / 2, accuracy: 1e-9)
            XCTAssertEqual(middle.from.dy, v.dy / 2, accuracy: 1e-9)
            XCTAssertEqual(middle.to.dx, -v.dx / 2, accuracy: 1e-9)
            let end = TransitionRenderer.offsets(.push, direction: direction, progress: 1)
            XCTAssertEqual(end.from, v)
            XCTAssertEqual(end.to, .zero)
        }
    }

    func testSlideOnlyMovesTheIncomingShot() {
        for direction in [Direction.left, .right, .up, .down] {
            for p in [0.0, 0.3, 0.7, 1.0] {
                XCTAssertEqual(TransitionRenderer.offsets(.slide, direction: direction, progress: p).from, .zero)
            }
            XCTAssertEqual(TransitionRenderer.offsets(.slide, direction: direction, progress: 1).to, .zero)
        }
    }

    func testDefaultDirectionIsLeft() {
        XCTAssertEqual(TransitionRenderer.offsets(.push, direction: nil, progress: 1).from, CGVector(dx: -1, dy: 0))
    }

    func testCutSlideSpendsItsTimeAtTheEnds() {
        XCTAssertLessThan(TransitionRenderer.eased(.cutSlide, 0.25), TransitionRenderer.eased(.push, 0.25))
        XCTAssertEqual(TransitionRenderer.eased(.cutSlide, 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TransitionRenderer.eased(.cutSlide, 1), 1, accuracy: 1e-9)
        XCTAssertEqual(TransitionRenderer.eased(.dissolve, 0.3), 0.3, accuracy: 1e-9)
    }

    func testDipLevels() {
        let both = TransitionRenderer.dipLevels(progress: 0.25, hasFrom: true, hasTo: true)
        XCTAssertEqual(both.from, 0.5, accuracy: 1e-9)
        XCTAssertEqual(both.to, 0, accuracy: 1e-9)
        XCTAssertEqual(TransitionRenderer.dipLevels(progress: 0.75, hasFrom: true, hasTo: true).to, 0.5, accuracy: 1e-9)
        XCTAssertEqual(TransitionRenderer.dipLevels(progress: 0.25, hasFrom: true, hasTo: false).from, 0.75, accuracy: 1e-9)
        XCTAssertEqual(TransitionRenderer.dipLevels(progress: 0.25, hasFrom: false, hasTo: true).to, 0.25, accuracy: 1e-9)
    }
}
