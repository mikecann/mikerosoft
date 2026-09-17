import Foundation
import MeetingArchiveCore

struct CaptureStartRequest: Equatable, Sendable {
    let session: MeetingSessionDescriptor
    let meetingID: UUID
    let windowID: UInt32
}

struct SafeCaptureWindow: Equatable, Sendable {
    let sessionID: String
    let windowID: UInt32
}

struct CaptureFinalizationRequest: Equatable, Sendable {
    let meetingID: UUID
    let reason: CaptureStopReason

    // Skip suppresses the rest of the camera session, but the portion already
    // captured still follows the normal naming and auto-save path. Deletion is
    // reserved for the explicit Discard action in the prompt.
    var discardAfterFinalization: Bool { false }
}

enum CaptureStartDecision: Equatable, Sendable {
    case start(CaptureStartRequest)
    case deferred
}

enum CaptureStopDecision: Equatable, Sendable {
    case finalize(CaptureFinalizationRequest)
    case ignored
}

/// Serializes the controller's single native writer without knowing anything
/// about cameras or files. CaptureStateMachine remains the source of truth for
/// meeting semantics; this type only keeps asynchronous writer work attached
/// to the meeting ID that created it.
struct CaptureLifecycleCoordinator: Sendable {
    private(set) var activeStart: CaptureStartRequest?
    private(set) var finalizingMeetingID: UUID?
    private(set) var deferredStart: CaptureStartRequest?

    mutating func requestStart(_ request: CaptureStartRequest) -> CaptureStartDecision {
        guard activeStart == nil, finalizingMeetingID == nil else {
            deferredStart = request
            return .deferred
        }
        activeStart = request
        return .start(request)
    }

    mutating func requestStop(meetingID: UUID, reason: CaptureStopReason) -> CaptureStopDecision {
        guard activeStart?.meetingID == meetingID, finalizingMeetingID == nil else {
            return .ignored
        }
        activeStart = nil
        finalizingMeetingID = meetingID
        return .finalize(CaptureFinalizationRequest(meetingID: meetingID, reason: reason))
    }

    mutating func finalizationCompleted(
        meetingID: UUID,
        recorderState: RecorderState,
        safeWindow: SafeCaptureWindow?
    ) -> CaptureStartRequest? {
        guard finalizingMeetingID == meetingID else { return nil }
        finalizingMeetingID = nil
        return promoteDeferredStart(recorderState: recorderState, safeWindow: safeWindow)
    }

    mutating func startAborted(
        meetingID: UUID,
        recorderState: RecorderState,
        safeWindow: SafeCaptureWindow?
    ) -> CaptureStartRequest? {
        guard activeStart?.meetingID == meetingID else { return nil }
        activeStart = nil
        return promoteDeferredStart(recorderState: recorderState, safeWindow: safeWindow)
    }

    mutating func retryDeferredStart(
        recorderState: RecorderState,
        safeWindow: SafeCaptureWindow?
    ) -> CaptureStartRequest? {
        guard activeStart == nil, finalizingMeetingID == nil else { return nil }
        return promoteDeferredStart(recorderState: recorderState, safeWindow: safeWindow)
    }

    func ownsActiveStart(meetingID: UUID) -> Bool {
        activeStart?.meetingID == meetingID
    }

    func isFinalizing(meetingID: UUID) -> Bool {
        finalizingMeetingID == meetingID
    }

    private mutating func promoteDeferredStart(
        recorderState: RecorderState,
        safeWindow: SafeCaptureWindow?
    ) -> CaptureStartRequest? {
        guard let deferredStart else { return nil }
        guard let current = recorderState.currentSession,
              current.phase == .startRequested,
              current.descriptor == deferredStart.session else {
            self.deferredStart = nil
            return nil
        }
        // Unknown or temporarily unsafe video is not a session transition.
        // Keep the request queued so a later safe snapshot can retry it.
        guard let safeWindow,
              safeWindow.sessionID == deferredStart.session.id else { return nil }

        let currentRequest = CaptureStartRequest(
            session: deferredStart.session,
            meetingID: deferredStart.meetingID,
            windowID: safeWindow.windowID
        )
        self.deferredStart = nil
        activeStart = currentRequest
        return currentRequest
    }
}
