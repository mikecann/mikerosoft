import Foundation

public enum CaptureStopReason: String, Codable, Equatable, Sendable {
    case cameraOff = "camera_off"
    case skipped
    case paused
    case interrupted
}

public enum CaptureEvent: Equatable, Sendable {
    case cameraOn(MeetingSessionDescriptor, at: Date)
    case cameraOff(sessionID: String, at: Date)
    case captureStarted(sessionID: String, meetingID: UUID, at: Date)
    case captureInterrupted(sessionID: String, at: Date)
    case skipCurrent(at: Date)
    case setPaused(Bool, at: Date)
    case applicationObserved(bundleIdentifier: String, at: Date)
}

public enum CaptureEffect: Equatable, Sendable {
    case startCapture(MeetingSessionDescriptor)
    case stopCapture(meetingID: UUID, reason: CaptureStopReason)
    case sessionSkipped(sessionID: String)
}

public struct CaptureStateMachine: Sendable {
    public private(set) var state: RecorderState

    public init(state: RecorderState = RecorderState()) {
        self.state = state
    }

    public init(restoringPersistedState state: RecorderState) {
        self.state = state.restoredAfterProcessRestart()
    }

    @discardableResult
    public mutating func handle(_ event: CaptureEvent) -> [CaptureEffect] {
        switch event {
        case .cameraOn(let descriptor, let date):
            return cameraOn(descriptor, at: date)
        case .cameraOff(let sessionID, _):
            return cameraOff(sessionID: sessionID)
        case .captureStarted(let sessionID, let meetingID, _):
            return captureStarted(sessionID: sessionID, meetingID: meetingID)
        case .captureInterrupted(let sessionID, _):
            return captureInterrupted(sessionID: sessionID)
        case .skipCurrent:
            return skipCurrent()
        case .setPaused(let paused, _):
            return setPaused(paused)
        case .applicationObserved:
            // Seeing an application stay open is not a camera-session transition.
            return []
        }
    }

    private mutating func cameraOn(_ descriptor: MeetingSessionDescriptor, at date: Date) -> [CaptureEffect] {
        guard descriptor.isEligibleForCapture else { return [] }
        guard !state.completedSessionIDs.contains(descriptor.id) else { return [] }
        guard state.currentSession == nil else { return [] }

        let phase: ActiveSessionPhase = state.isPaused ? .suppressed(.paused) : .startRequested
        state.currentSession = ActiveMeetingSession(
            descriptor: descriptor,
            phase: phase,
            firstObservedAt: date,
            meetingID: nil
        )
        return state.isPaused ? [] : [.startCapture(descriptor)]
    }

    private mutating func cameraOff(sessionID: String) -> [CaptureEffect] {
        guard let current = state.currentSession, current.descriptor.id == sessionID else { return [] }
        rememberCompleted(sessionID)
        state.currentSession = nil

        guard current.phase == .recording, let meetingID = current.meetingID else { return [] }
        return [.stopCapture(meetingID: meetingID, reason: .cameraOff)]
    }

    private mutating func captureStarted(sessionID: String, meetingID: UUID) -> [CaptureEffect] {
        guard var current = state.currentSession, current.descriptor.id == sessionID else {
            if state.completedSessionIDs.contains(sessionID) {
                return [.stopCapture(meetingID: meetingID, reason: .cameraOff)]
            }
            return []
        }

        switch current.phase {
        case .startRequested:
            current.phase = .recording
            current.meetingID = meetingID
            state.currentSession = current
            return []
        case .suppressed(let reason):
            let stopReason: CaptureStopReason = switch reason {
            case .skipped: .skipped
            case .paused: .paused
            case .interrupted: .interrupted
            }
            return [.stopCapture(meetingID: meetingID, reason: stopReason)]
        case .recording:
            return []
        }
    }

    private mutating func captureInterrupted(sessionID: String) -> [CaptureEffect] {
        guard var current = state.currentSession, current.descriptor.id == sessionID else { return [] }

        switch current.phase {
        case .startRequested:
            current.phase = .suppressed(.interrupted)
            state.currentSession = current
            return []
        case .recording:
            current.phase = .suppressed(.interrupted)
            state.currentSession = current
            guard let meetingID = current.meetingID else { return [] }
            return [.stopCapture(meetingID: meetingID, reason: .interrupted)]
        case .suppressed:
            return []
        }
    }

    private mutating func skipCurrent() -> [CaptureEffect] {
        guard var current = state.currentSession else { return [] }
        if case .suppressed(.skipped) = current.phase { return [] }

        var effects: [CaptureEffect] = []
        if current.phase == .recording, let meetingID = current.meetingID {
            effects.append(.stopCapture(meetingID: meetingID, reason: .skipped))
        }
        current.phase = .suppressed(.skipped)
        state.currentSession = current
        effects.append(.sessionSkipped(sessionID: current.descriptor.id))
        return effects
    }

    private mutating func setPaused(_ paused: Bool) -> [CaptureEffect] {
        guard state.isPaused != paused else { return [] }
        state.isPaused = paused
        guard paused, var current = state.currentSession else { return [] }

        var effects: [CaptureEffect] = []
        if current.phase == .recording, let meetingID = current.meetingID {
            effects.append(.stopCapture(meetingID: meetingID, reason: .paused))
        }
        current.phase = .suppressed(.paused)
        state.currentSession = current
        return effects
    }

    private mutating func rememberCompleted(_ sessionID: String) {
        state.completedSessionIDs.removeAll { $0 == sessionID }
        state.completedSessionIDs.append(sessionID)
        if state.completedSessionIDs.count > 128 {
            state.completedSessionIDs.removeFirst(state.completedSessionIDs.count - 128)
        }
    }
}
