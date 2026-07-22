import XCTest
@testable import RecordItApp

final class ScreenCaptureHealthTests: XCTestCase {
    func testHealthDetectsWhenScreenCaptureCallbacksStop() {
        let health = ScreenCaptureHealthState(startedAt: 100)

        XCTAssertNil(health.problem(at: 109.9))
        XCTAssertEqual(
            health.problem(at: 110.1),
            "No screen frames were delivered for 10 seconds."
        )
    }

    func testAnyScreenCallbackKeepsAStaticCaptureHealthy() {
        var health = ScreenCaptureHealthState(startedAt: 100)

        health.recordScreenCallback(at: 109)

        XCTAssertNil(health.problem(at: 118.9))
        XCTAssertNotNil(health.problem(at: 119.1))
    }

    func testHealthDetectsSustainedVideoEncoderBackpressure() {
        var health = ScreenCaptureHealthState(startedAt: 100)

        for _ in 0..<59 { health.recordVideoAppend(accepted: false) }
        XCTAssertNil(health.problem(at: 101))

        health.recordVideoAppend(accepted: false)
        XCTAssertEqual(
            health.problem(at: 101),
            "The video encoder rejected 60 consecutive screen frames."
        )

        health.recordVideoAppend(accepted: true)
        XCTAssertNil(health.problem(at: 101))
    }
}
