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
