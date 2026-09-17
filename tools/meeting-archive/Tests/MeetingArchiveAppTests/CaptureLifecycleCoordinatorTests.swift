import Foundation
import MeetingArchiveCore
import XCTest
@testable import MeetingArchiveApp

final class CaptureLifecycleCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRapidOffOnDefersNextCaptureWhilePreviousMeetingFinalizes() {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        var coordinator = CaptureLifecycleCoordinator()

        XCTAssertEqual(coordinator.requestStart(old), .start(old))
        XCTAssertEqual(
            coordinator.requestStop(meetingID: old.meetingID, reason: .cameraOff),
            .finalize(.init(meetingID: old.meetingID, reason: .cameraOff))
        )
        XCTAssertEqual(coordinator.requestStart(next), .deferred)
        XCTAssertEqual(coordinator.deferredStart, next)
    }

    func testSkipWhileStartIsDeferredPreventsItFromStartingAfterFinalization() {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        var coordinator = finalizingCoordinator(old: old, deferred: next)
        let state = recorderState(for: next.session, phase: .suppressed(.skipped))

        XCTAssertNil(coordinator.finalizationCompleted(
            meetingID: old.meetingID,
            recorderState: state,
            safeWindow: .init(sessionID: next.session.id, windowID: next.windowID)
        ))
        XCTAssertNil(coordinator.deferredStart)
    }

    func testCameraOffWhileStartIsDeferredPreventsItFromStartingAfterFinalization() {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        var coordinator = finalizingCoordinator(old: old, deferred: next)

        XCTAssertNil(coordinator.finalizationCompleted(
            meetingID: old.meetingID,
            recorderState: RecorderState(),
            safeWindow: nil
        ))
        XCTAssertNil(coordinator.deferredStart)
    }

    func testStaleStopForOldMeetingCannotFinalizeNewWriter() throws {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        var coordinator = finalizingCoordinator(old: old, deferred: next)
        let start = try XCTUnwrap(coordinator.finalizationCompleted(
            meetingID: old.meetingID,
            recorderState: recorderState(for: next.session, phase: .startRequested),
            safeWindow: .init(sessionID: next.session.id, windowID: next.windowID)
        ))

        XCTAssertEqual(start, next)
        XCTAssertEqual(coordinator.requestStop(meetingID: old.meetingID, reason: .cameraOff), .ignored)
        XCTAssertEqual(coordinator.activeStart, next)
    }

    func testLateStartupCallbackCannotStopMeetingPromotedAfterAbort() throws {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        var coordinator = CaptureLifecycleCoordinator()
        _ = coordinator.requestStart(old)
        XCTAssertEqual(coordinator.requestStart(next), .deferred)

        let start = try XCTUnwrap(coordinator.startAborted(
            meetingID: old.meetingID,
            recorderState: recorderState(for: next.session, phase: .startRequested),
            safeWindow: .init(sessionID: next.session.id, windowID: next.windowID)
        ))

        XCTAssertEqual(start, next)
        XCTAssertEqual(coordinator.requestStop(meetingID: old.meetingID, reason: .interrupted), .ignored)
        XCTAssertEqual(coordinator.activeStart, next)
    }

    func testMatchingDeferredStartUsesCurrentSafeWindowAfterPreviousFinalizes() throws {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        var coordinator = finalizingCoordinator(old: old, deferred: next)

        let start = try XCTUnwrap(coordinator.finalizationCompleted(
            meetingID: old.meetingID,
            recorderState: recorderState(for: next.session, phase: .startRequested),
            safeWindow: .init(sessionID: next.session.id, windowID: 21)
        ))

        XCTAssertEqual(start.session, next.session)
        XCTAssertEqual(start.meetingID, next.meetingID)
        XCTAssertEqual(start.windowID, 21)
        XCTAssertEqual(coordinator.activeStart, start)
    }

    func testUnsafeWindowAtFinalizationRetriesAndStartsOnceWhenItBecomesSafe() throws {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        let state = recorderState(for: next.session, phase: .startRequested)
        var coordinator = finalizingCoordinator(old: old, deferred: next)

        XCTAssertNil(coordinator.finalizationCompleted(
            meetingID: old.meetingID,
            recorderState: state,
            safeWindow: nil
        ))
        XCTAssertEqual(coordinator.deferredStart, next)

        let start = try XCTUnwrap(coordinator.retryDeferredStart(
            recorderState: state,
            safeWindow: .init(sessionID: next.session.id, windowID: 21)
        ))
        XCTAssertEqual(start.windowID, 21)
        XCTAssertNil(coordinator.deferredStart)
        XCTAssertNil(coordinator.retryDeferredStart(
            recorderState: state,
            safeWindow: .init(sessionID: next.session.id, windowID: 21)
        ))
    }

    func testDeferredStartRequiresTheExactRequestedSession() {
        let old = request(sessionID: "old", meetingID: UUID(), windowID: 10)
        let next = request(sessionID: "next", meetingID: UUID(), windowID: 20)
        let replacement = session(id: "replacement")
        var coordinator = finalizingCoordinator(old: old, deferred: next)

        XCTAssertNil(coordinator.finalizationCompleted(
            meetingID: old.meetingID,
            recorderState: recorderState(for: replacement, phase: .startRequested),
            safeWindow: .init(sessionID: replacement.id, windowID: 30)
        ))
    }

    func testAllAutomaticStopReasonsKeepTheRecordedPortion() {
        for reason in [CaptureStopReason.cameraOff, .skipped, .paused, .interrupted] {
            let request = CaptureFinalizationRequest(meetingID: UUID(), reason: reason)
            XCTAssertFalse(request.discardAfterFinalization, "\(reason) should keep captured media")
        }
    }

    private func finalizingCoordinator(
        old: CaptureStartRequest,
        deferred: CaptureStartRequest
    ) -> CaptureLifecycleCoordinator {
        var coordinator = CaptureLifecycleCoordinator()
        _ = coordinator.requestStart(old)
        _ = coordinator.requestStop(meetingID: old.meetingID, reason: .cameraOff)
        _ = coordinator.requestStart(deferred)
        return coordinator
    }

    private func recorderState(
        for session: MeetingSessionDescriptor,
        phase: ActiveSessionPhase
    ) -> RecorderState {
        RecorderState(currentSession: ActiveMeetingSession(
            descriptor: session,
            phase: phase,
            firstObservedAt: now,
            meetingID: nil
        ))
    }

    private func request(sessionID: String, meetingID: UUID, windowID: UInt32) -> CaptureStartRequest {
        CaptureStartRequest(session: session(id: sessionID), meetingID: meetingID, windowID: windowID)
    }

    private func session(id: String) -> MeetingSessionDescriptor {
        MeetingSessionDescriptor(
            id: id,
            sourceApplication: .init(
                bundleIdentifier: "com.google.Chrome",
                displayName: "Google Chrome",
                kind: .googleMeet
            ),
            surface: .init(id: "cg-window-\(id)", title: "Meeting", kind: .meeting),
            attribution: .positive
        )
    }
}
