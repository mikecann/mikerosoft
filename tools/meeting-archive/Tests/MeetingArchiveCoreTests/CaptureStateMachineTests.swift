import Foundation
import XCTest
@testable import MeetingArchiveCore

final class CaptureStateMachineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPositiveMeetingStartsExactlyOnceAndStopsAtFirstOffSignal() throws {
        let session = meetingSession(id: "meet-1")
        var machine = CaptureStateMachine()

        XCTAssertEqual(machine.handle(.cameraOn(session, at: now)), [.startCapture(session)])
        XCTAssertEqual(machine.handle(.cameraOn(session, at: now.addingTimeInterval(1))), [])

        let meetingID = UUID()
        XCTAssertEqual(
            machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now.addingTimeInterval(2))),
            []
        )
        XCTAssertEqual(
            machine.handle(.cameraOff(sessionID: session.id, at: now.addingTimeInterval(3))),
            [.stopCapture(meetingID: meetingID, reason: .cameraOff)]
        )
        XCTAssertEqual(machine.handle(.cameraOff(sessionID: session.id, at: now.addingTimeInterval(4))), [])
        XCTAssertEqual(machine.handle(.cameraOn(session, at: now.addingTimeInterval(5))), [])
    }

    func testUnknownAndPreviewSessionsAreExcluded() {
        var machine = CaptureStateMachine()
        let unknown = MeetingSessionDescriptor(
            id: "unknown",
            sourceApplication: .init(bundleIdentifier: "com.example.unknown", displayName: "Unknown", kind: .other),
            surface: .init(id: "window-1", title: nil, kind: .unknown),
            attribution: .unknown
        )
        let preview = MeetingSessionDescriptor(
            id: "preview",
            sourceApplication: .init(bundleIdentifier: "com.apple.PhotoBooth", displayName: "Preview", kind: .cameraPreview),
            surface: .init(id: "window-2", title: nil, kind: .cameraPreview),
            attribution: .positive
        )

        XCTAssertEqual(machine.handle(.cameraOn(unknown, at: now)), [])
        XCTAssertEqual(machine.handle(.cameraOn(preview, at: now)), [])
        XCTAssertNil(machine.state.currentSession)
    }

    func testSkipSurvivesPersistenceAndSuppressesRestOfSameSession() throws {
        let session = meetingSession(id: "meet-skip")
        let meetingID = UUID()
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        _ = machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now))

        XCTAssertEqual(
            machine.handle(.skipCurrent(at: now.addingTimeInterval(1))),
            [
                .stopCapture(meetingID: meetingID, reason: .skipped),
                .sessionSkipped(sessionID: session.id),
            ]
        )

        let encoded = try ModelCodec.encoder.encode(machine.state)
        let restoredState = try ModelCodec.decoder.decode(RecorderState.self, from: encoded)
        var restored = CaptureStateMachine(state: restoredState)

        XCTAssertEqual(restored.handle(.cameraOn(session, at: now.addingTimeInterval(2))), [])
        XCTAssertEqual(restored.handle(.applicationObserved(bundleIdentifier: session.sourceApplication.bundleIdentifier, at: now.addingTimeInterval(3))), [])
        XCTAssertEqual(restored.handle(.cameraOff(sessionID: session.id, at: now.addingTimeInterval(4))), [])

        let next = meetingSession(id: "meet-next")
        XCTAssertEqual(restored.handle(.cameraOn(next, at: now.addingTimeInterval(5))), [.startCapture(next)])
    }

    func testPersistentPauseStopsCurrentCaptureAndResumeDoesNotRestartIt() throws {
        let session = meetingSession(id: "meet-pause")
        let meetingID = UUID()
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        _ = machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now))

        XCTAssertEqual(
            machine.handle(.setPaused(true, at: now.addingTimeInterval(1))),
            [.stopCapture(meetingID: meetingID, reason: .paused)]
        )
        XCTAssertTrue(machine.state.isPaused)

        let data = try ModelCodec.encoder.encode(machine.state)
        var restored = CaptureStateMachine(state: try ModelCodec.decoder.decode(RecorderState.self, from: data))
        XCTAssertEqual(restored.handle(.setPaused(false, at: now.addingTimeInterval(2))), [])
        XCTAssertEqual(restored.handle(.applicationObserved(bundleIdentifier: session.sourceApplication.bundleIdentifier, at: now.addingTimeInterval(3))), [])
        XCTAssertEqual(restored.handle(.cameraOn(session, at: now.addingTimeInterval(4))), [])
    }

    func testRestartDoesNotTreatPersistedWriterAsAliveOrRestartOpenSession() {
        let session = meetingSession(id: "meet-crash")
        let persisted = RecorderState(
            currentSession: ActiveMeetingSession(
                descriptor: session,
                phase: .recording,
                firstObservedAt: now,
                meetingID: UUID()
            )
        )

        var restored = CaptureStateMachine(restoringPersistedState: persisted)
        XCTAssertEqual(restored.state.currentSession?.phase, .suppressed(.interrupted))
        XCTAssertEqual(restored.handle(.applicationObserved(bundleIdentifier: "com.google.Chrome", at: now)), [])
        XCTAssertEqual(restored.handle(.cameraOn(session, at: now)), [])
    }

    func testCaptureErrorBeforeStartCompletesSuppressesSessionAndStopsLateCallback() {
        let session = meetingSession(id: "meet-start-error")
        let meetingID = UUID()
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))

        XCTAssertEqual(
            machine.handle(.captureInterrupted(sessionID: session.id, at: now.addingTimeInterval(1))),
            []
        )
        XCTAssertEqual(machine.state.currentSession?.phase, .suppressed(.interrupted))
        XCTAssertEqual(
            machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now.addingTimeInterval(2))),
            [.stopCapture(meetingID: meetingID, reason: .interrupted)]
        )
        XCTAssertEqual(machine.handle(.cameraOn(session, at: now.addingTimeInterval(3))), [])
    }

    func testCaptureErrorAfterRecordingStopsPartialAndIsIdempotent() {
        let session = meetingSession(id: "meet-recording-error")
        let meetingID = UUID()
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        _ = machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now))

        XCTAssertEqual(
            machine.handle(.captureInterrupted(sessionID: session.id, at: now.addingTimeInterval(1))),
            [.stopCapture(meetingID: meetingID, reason: .interrupted)]
        )
        XCTAssertEqual(machine.state.currentSession?.phase, .suppressed(.interrupted))
        XCTAssertEqual(
            machine.handle(.captureInterrupted(sessionID: session.id, at: now.addingTimeInterval(2))),
            []
        )
    }

    func testCaptureErrorForUnrelatedSessionIsIgnored() {
        let active = meetingSession(id: "active")
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(active, at: now))

        XCTAssertEqual(
            machine.handle(.captureInterrupted(sessionID: "unrelated", at: now.addingTimeInterval(1))),
            []
        )
        XCTAssertEqual(machine.state.currentSession?.phase, .startRequested)
    }

    func testConfirmedOffAfterInterruptionAllowsNewSessionIDToStart() {
        let interrupted = meetingSession(id: "interrupted")
        let next = meetingSession(id: "after-off")
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(interrupted, at: now))
        _ = machine.handle(.captureInterrupted(sessionID: interrupted.id, at: now.addingTimeInterval(1)))

        XCTAssertEqual(machine.handle(.cameraOff(sessionID: interrupted.id, at: now.addingTimeInterval(2))), [])
        XCTAssertEqual(machine.handle(.cameraOn(next, at: now.addingTimeInterval(3))), [.startCapture(next)])
    }

    func testOverlappingSessionDoesNotReplaceActiveMeeting() {
        let first = meetingSession(id: "first")
        let second = meetingSession(id: "second")
        var machine = CaptureStateMachine()

        XCTAssertEqual(machine.handle(.cameraOn(first, at: now)), [.startCapture(first)])
        XCTAssertEqual(machine.handle(.cameraOn(second, at: now)), [])
        XCTAssertEqual(machine.state.currentSession?.descriptor.id, first.id)
    }

    private func meetingSession(id: String) -> MeetingSessionDescriptor {
        MeetingSessionDescriptor(
            id: id,
            sourceApplication: .init(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome", kind: .googleMeet),
            surface: .init(id: "window-\(id)", title: "Meeting", kind: .meeting),
            attribution: .positive
        )
    }
}
