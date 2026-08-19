import XCTest
@testable import RecordItApp

final class ScreenCaptureHealthTests: XCTestCase {
    func testHealthDetectsWhenScreenCaptureCallbacksStop() {
        let health = MediaCaptureHealthState(startedAt: 100)

        XCTAssertNil(health.problem(at: 109.9))
        XCTAssertEqual(
            health.problem(at: 110.1),
            "No screen frames were delivered for 10 seconds."
        )
    }

    func testAnyScreenCallbackKeepsAStaticCaptureHealthy() {
        var health = MediaCaptureHealthState(startedAt: 100)

        health.recordScreenCallback(at: 109)

        XCTAssertNil(health.problem(at: 118.9))
        XCTAssertNotNil(health.problem(at: 119.1))
    }

    func testHealthDetectsSustainedVideoEncoderBackpressure() {
        var health = MediaCaptureHealthState(startedAt: 100)

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

    func testRequiredAudioCallbacksCannotDisappearWhileVideoContinues() {
        var health = MediaCaptureHealthState(startedAt: 100, requiresAudio: true)

        health.recordScreenCallback(at: 109)
        XCTAssertNil(health.problem(at: 109.9))
        XCTAssertEqual(
            health.problem(at: 110.1),
            "No audio samples were delivered for 10 seconds."
        )
    }

    func testRequiredAudioEncoderBackpressureIsAHardFailure() {
        var health = MediaCaptureHealthState(startedAt: 100, requiresAudio: true)

        for index in 0..<59 {
            health.recordAudioCallback(at: 100 + Double(index) / 100, accepted: false, peakDecibels: -12)
        }
        XCTAssertNil(health.problem(at: 101))

        health.recordAudioCallback(at: 101, accepted: false, peakDecibels: -12)
        XCTAssertEqual(
            health.problem(at: 101),
            "The audio encoder rejected 60 consecutive microphone samples."
        )

        health.recordAudioCallback(at: 101.1, accepted: true, peakDecibels: -12)
        XCTAssertNil(health.problem(at: 101.1))
    }

    func testOrdinaryQuietNeverHardFails() {
        var health = MediaCaptureHealthState(
            startedAt: 100,
            requiresVideo: false,
            requiresAudio: true,
            failsOnDigitalSilence: true
        )

        for second in 1...30 {
            health.recordAudioCallback(
                at: 100 + Double(second),
                accepted: true,
                peakDecibels: -60
            )
        }

        XCTAssertNil(health.problem(at: 130))
    }

    func testDigitalZeroMicrophoneIsAHardFailure() {
        var health = MediaCaptureHealthState(
            startedAt: 100,
            requiresVideo: false,
            requiresAudio: true,
            failsOnDigitalSilence: true
        )

        health.recordAudioCallback(at: 101, accepted: true, peakDecibels: -160)
        health.recordAudioCallback(at: 103.9, accepted: true, peakDecibels: -160)
        XCTAssertNil(health.problem(at: 103.9))
        health.recordAudioCallback(at: 104.1, accepted: true, peakDecibels: -160)
        XCTAssertEqual(
            health.problem(at: 104.1),
            "The microphone delivered digital silence for 3 seconds. It may be muted or stalled."
        )
    }

    func testRealMicrophoneSignalResetsTheSilenceWatchdog() {
        var health = MediaCaptureHealthState(
            startedAt: 100,
            requiresVideo: false,
            requiresAudio: true,
            failsOnDigitalSilence: true
        )

        health.recordAudioCallback(at: 101, accepted: true, peakDecibels: -60)
        health.recordAudioCallback(at: 109, accepted: true, peakDecibels: -20)
        health.recordAudioCallback(at: 110, accepted: true, peakDecibels: -60)

        XCTAssertNil(health.problem(at: 119.9))
        XCTAssertNotNil(health.problem(at: 120.1))
    }
}
