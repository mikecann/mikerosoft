import QuartzCore
import XCTest
@testable import TaskbarApp

final class TaskbarSelectionAnimationTests: XCTestCase {
    func testUsesShortCompositorAnimation() {
        XCTAssertEqual(TaskbarSelectionAnimation.duration, 0.22, accuracy: 0.001)
    }

    func testTimingFunctionUsesSoftEaseOutControlPoints() {
        var first = [Float](repeating: 0, count: 2)
        var second = [Float](repeating: 0, count: 2)

        TaskbarSelectionAnimation.timingFunction.getControlPoint(at: 1, values: &first)
        TaskbarSelectionAnimation.timingFunction.getControlPoint(at: 2, values: &second)

        XCTAssertEqual(first[0], 0.18, accuracy: 0.001)
        XCTAssertEqual(first[1], 0.88, accuracy: 0.001)
        XCTAssertEqual(second[0], 0.28, accuracy: 0.001)
        XCTAssertEqual(second[1], 1.0, accuracy: 0.001)
    }
}
