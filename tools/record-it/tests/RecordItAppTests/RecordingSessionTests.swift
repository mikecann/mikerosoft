import XCTest
@testable import RecordItApp

final class RecordingSessionTests: XCTestCase {
    func testSessionStartsAndStopsEveryRequestedRecorder() async throws {
        let screen = RecordingSpy()
        let camera = RecordingSpy()
        let session = RecordingSession(recorders: [screen, camera])

        try await session.start()
        try await session.stop()

        let screenCounts = await screen.counts
        let cameraCounts = await camera.counts
        XCTAssertEqual(screenCounts.starts, 1)
        XCTAssertEqual(screenCounts.stops, 1)
        XCTAssertEqual(cameraCounts.starts, 1)
        XCTAssertEqual(cameraCounts.stops, 1)
    }

    func testSessionOpensSharedStartGateOnlyAfterEveryRecorderIsReady() async throws {
        let gate = RecordingStartGate()
        let session = RecordingSession(
            recorders: [RecordingSpy(), RecordingSpy()],
            startGate: gate
        )

        XCTAssertNil(gate.startTime)
        try await session.start()

        XCTAssertNotNil(gate.startTime)
    }

    func testOneFailingRecorderDoesNotAbandonTheOthersWhileTheyFinalize() async {
        let slow = SlowFinalizer()
        let session = RecordingSession(recorders: [FailingStop(), slow])

        do {
            try await session.stop()
            XCTFail("The failing recorder's error should still be reported.")
        } catch {}

        let finalized = await slow.finalizedWithoutCancellation
        XCTAssertTrue(finalized)
    }
}

private struct FailingStop: CaptureRecording {
    func start() async throws {}
    func stop() async throws {
        throw RecordItError.message("screen failed")
    }
}

private actor SlowFinalizer: CaptureRecording {
    private(set) var finalizedWithoutCancellation = false

    func start() async throws {}

    func stop() async throws {
        try? await Task.sleep(for: .milliseconds(200))
        finalizedWithoutCancellation = !Task.isCancelled
    }
}

private actor RecordingSpy: CaptureRecording {
    private(set) var counts = (starts: 0, stops: 0)

    func start() async throws {
        counts.starts += 1
    }

    func stop() async throws {
        counts.stops += 1
    }
}
