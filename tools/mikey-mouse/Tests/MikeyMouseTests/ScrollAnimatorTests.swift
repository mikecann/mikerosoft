import XCTest
@testable import MikeyMouse

final class ScrollAnimatorTests: XCTestCase {
    private let tuning = ScrollAnimator.Tuning(pixelsPerTick: 60, timeConstant: 0.08)

    func testOneTickScrollsExactlyOneStepThenSettles() {
        var animator = ScrollAnimator(tuning: tuning)

        animator.addTicks(x: 0, y: -1, at: 0)
        let frames = run(&animator, from: 0, seconds: 1)

        XCTAssertEqual(frames.map(\.y).reduce(0, +), -60)
        XCTAssertTrue(frames.allSatisfy { $0.x == 0 })
        XCTAssertTrue(animator.isIdle)
    }

    func testMotionStartsFastAndEasesOut() {
        var animator = ScrollAnimator(tuning: tuning)

        animator.addTicks(x: 0, y: 1, at: 0)
        let frames = run(&animator, from: 0, seconds: 1)

        let firstQuarter = frames.prefix(12).map(\.y).reduce(0, +)
        let secondQuarter = frames.dropFirst(12).prefix(12).map(\.y).reduce(0, +)
        XCTAssertGreaterThan(firstQuarter, secondQuarter * 2)
    }

    func testMostOfTheDistanceIsCoveredWithinThreeTimeConstants() {
        var animator = ScrollAnimator(tuning: tuning)

        animator.addTicks(x: 0, y: 1, at: 0)
        let frames = run(&animator, from: 0, seconds: 0.24)

        XCTAssertGreaterThanOrEqual(frames.map(\.y).reduce(0, +), 56)
    }

    func testAnimationFinishesWithinHalfASecond() {
        var animator = ScrollAnimator(tuning: tuning)

        animator.addTicks(x: 0, y: 1, at: 0)
        _ = run(&animator, from: 0, seconds: 0.5)

        XCTAssertTrue(animator.isIdle)
    }

    func testSlowTicksEachTravelOneStep() {
        var animator = ScrollAnimator(tuning: tuning)
        var frames: [PixelDelta] = []

        for tick in 0..<3 {
            let time = Double(tick) * 0.2
            animator.addTicks(x: 0, y: 1, at: time)
            frames += run(&animator, from: time, seconds: 0.2)
        }
        frames += run(&animator, from: 0.6, seconds: 1)

        XCTAssertEqual(frames.map(\.y).reduce(0, +), 180)
    }

    func testFastTicksTravelFurther() {
        var animator = ScrollAnimator(tuning: tuning)

        for tick in 0..<5 {
            animator.addTicks(x: 0, y: 1, at: Double(tick) * 0.02)
        }
        let frames = run(&animator, from: 0.08, seconds: 1)

        // The first tick has no interval to measure. The next four arrive at
        // 50 ticks per second, 6.25x the threshold rate: 1 + 0.5 * 5.25.
        XCTAssertEqual(Double(frames.map(\.y).reduce(0, +)), 60 + 4 * 217.5, accuracy: 1)
    }

    func testAccelerationIsCapped() {
        var animator = ScrollAnimator(tuning: tuning)

        for tick in 0..<5 {
            animator.addTicks(x: 0, y: 1, at: Double(tick) * 0.001)
        }
        let frames = run(&animator, from: 0.004, seconds: 1)

        XCTAssertEqual(Double(frames.map(\.y).reduce(0, +)), 60 + 4 * 60 * 5, accuracy: 1)
    }

    func testPauseResetsAcceleration() {
        var animator = ScrollAnimator(tuning: tuning)

        animator.addTicks(x: 0, y: 1, at: 0)
        animator.addTicks(x: 0, y: 1, at: 0.02)
        _ = run(&animator, from: 0.02, seconds: 0.98)
        XCTAssertTrue(animator.isIdle)

        animator.addTicks(x: 0, y: 1, at: 1)
        let frames = run(&animator, from: 1, seconds: 1)

        XCTAssertEqual(frames.map(\.y).reduce(0, +), 60)
    }

    func testReversingDirectionDropsTheRemainingDistance() {
        var animator = ScrollAnimator(tuning: tuning)

        animator.addTicks(x: 0, y: -1, at: 0)
        let beforeReversal = run(&animator, from: 0, seconds: 0.03)
        animator.addTicks(x: 0, y: 1, at: 0.03)
        let afterReversal = run(&animator, from: 0.03, seconds: 1)

        XCTAssertLessThan(beforeReversal.map(\.y).reduce(0, +), 0)
        XCTAssertGreaterThan(beforeReversal.map(\.y).reduce(0, +), -60)
        XCTAssertTrue(afterReversal.allSatisfy { $0.y >= 0 })
        XCTAssertEqual(afterReversal.map(\.y).reduce(0, +), 60)
    }

    func testHorizontalTicksScrollHorizontally() {
        var animator = ScrollAnimator(tuning: tuning)

        animator.addTicks(x: -1, y: 0, at: 0)
        let frames = run(&animator, from: 0, seconds: 1)

        XCTAssertEqual(frames.map(\.x).reduce(0, +), -60)
        XCTAssertTrue(frames.allSatisfy { $0.y == 0 })
    }

    func testStopClearsPendingDistance() {
        var animator = ScrollAnimator(tuning: tuning)

        animator.addTicks(x: 0, y: 1, at: 0)
        _ = run(&animator, from: 0, seconds: 0.02)
        animator.stop()

        XCTAssertTrue(animator.isIdle)
        XCTAssertEqual(animator.advance(to: 0.1), .zero)
    }

    func testIdleAnimatorEmitsNothing() {
        var animator = ScrollAnimator(tuning: tuning)

        XCTAssertTrue(animator.isIdle)
        XCTAssertEqual(animator.advance(to: 5), .zero)
    }

    private func run(
        _ animator: inout ScrollAnimator,
        from start: TimeInterval,
        seconds: TimeInterval
    ) -> [PixelDelta] {
        var frames: [PixelDelta] = []
        let frameCount = Int((seconds * 120).rounded())
        for frame in 1...frameCount {
            frames.append(animator.advance(to: start + Double(frame) / 120))
        }
        return frames
    }
}
