import XCTest
@testable import MeetingArchiveApp

final class NativeCaptureLifecycleTests: XCTestCase {
    func testCancellationWhilePreparingPreventsLaterActivation() {
        var lifecycle = NativeCaptureLifecycle()

        XCTAssertTrue(lifecycle.startupPermitted)
        lifecycle.cancelStartup()

        XCTAssertFalse(lifecycle.startupPermitted)
        XCTAssertFalse(lifecycle.beginActivation())
        XCTAssertFalse(lifecycle.acceptsSamples)
        XCTAssertFalse(lifecycle.reportsFailures)
    }

    func testSamplesRemainCutOffWhileStartCaptureAwaitsAndAfterCancellation() {
        var lifecycle = NativeCaptureLifecycle()
        XCTAssertTrue(lifecycle.beginActivation())
        XCTAssertFalse(lifecycle.acceptsSamples)

        lifecycle.cancelStartup()

        XCTAssertFalse(lifecycle.acceptsSamples)
        XCTAssertFalse(lifecycle.didActivate())
        XCTAssertFalse(lifecycle.reportsFailures)
    }

    func testNormalActivationAcceptsSamplesUntilStopBegins() {
        var lifecycle = NativeCaptureLifecycle()
        XCTAssertTrue(lifecycle.beginActivation())
        XCTAssertFalse(lifecycle.acceptsSamples)
        XCTAssertTrue(lifecycle.didActivate())
        XCTAssertTrue(lifecycle.acceptsSamples)
        XCTAssertFalse(lifecycle.hasCapturedSamples)
        lifecycle.recordAcceptedSample()
        XCTAssertTrue(lifecycle.hasCapturedSamples)

        XCTAssertTrue(lifecycle.beginStop())

        XCTAssertFalse(lifecycle.acceptsSamples)
        XCTAssertFalse(lifecycle.reportsFailures)
        XCTAssertFalse(lifecycle.beginStop())
    }

    func testLateStartupCancellationDoesNotSilentlyCutOffActiveCapture() {
        var lifecycle = NativeCaptureLifecycle()
        _ = lifecycle.beginActivation()
        _ = lifecycle.didActivate()

        lifecycle.cancelStartup()

        XCTAssertTrue(lifecycle.acceptsSamples)
        XCTAssertTrue(lifecycle.reportsFailures)
        XCTAssertTrue(lifecycle.beginStop())
    }

    func testStoppingBeforeActivationDoesNotClaimAStartedStream() {
        var lifecycle = NativeCaptureLifecycle()

        XCTAssertFalse(lifecycle.beginStop())
        XCTAssertFalse(lifecycle.startupPermitted)
        XCTAssertFalse(lifecycle.acceptsSamples)
    }

    func testFinishingStopIsTerminalAndIdempotent() {
        var lifecycle = NativeCaptureLifecycle()
        _ = lifecycle.beginActivation()
        _ = lifecycle.didActivate()
        _ = lifecycle.beginStop()

        lifecycle.didStop()
        lifecycle.didStop()

        XCTAssertFalse(lifecycle.startupPermitted)
        XCTAssertFalse(lifecycle.acceptsSamples)
        XCTAssertFalse(lifecycle.reportsFailures)
        XCTAssertFalse(lifecycle.beginActivation())
    }

    func testRejectedStartupSamplesNeverClaimCapturedMedia() {
        var lifecycle = NativeCaptureLifecycle()
        _ = lifecycle.beginActivation()

        lifecycle.cancelStartup()

        XCTAssertFalse(lifecycle.hasCapturedSamples)
    }
}
