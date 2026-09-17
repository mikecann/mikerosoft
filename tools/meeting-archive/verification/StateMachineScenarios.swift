import Foundation

@main
private enum StateMachineScenarios {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_789_128_000)
        try cameraOffDuringStartup(now)
        try skipDuringStartup(now)
        try restartSuppression(now)
        overlappingAndRapidSessions(now)
        print("state-machine startup, stop, skip, restart and overlap scenarios passed")
    }

    private static func cameraOffDuringStartup(_ now: Date) throws {
        let session = descriptor("startup-off")
        let meetingID = UUID()
        var machine = CaptureStateMachine()
        precondition(machine.handle(.cameraOn(session, at: now)) == [.startCapture(session)])
        precondition(machine.handle(.cameraOff(sessionID: session.id, at: now)) == [])
        precondition(
            machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now))
                == [.stopCapture(meetingID: meetingID, reason: .cameraOff)]
        )
        let persisted = try ModelCodec.decoder.decode(
            RecorderState.self,
            from: ModelCodec.encoder.encode(machine.state)
        )
        precondition(persisted.completedSessionIDs.contains(session.id))
    }

    private static func skipDuringStartup(_ now: Date) throws {
        let session = descriptor("startup-skip")
        let meetingID = UUID()
        var machine = CaptureStateMachine()
        _ = machine.handle(.cameraOn(session, at: now))
        precondition(machine.handle(.skipCurrent(at: now)) == [.sessionSkipped(sessionID: session.id)])
        precondition(
            machine.handle(.captureStarted(sessionID: session.id, meetingID: meetingID, at: now))
                == [.stopCapture(meetingID: meetingID, reason: .skipped)]
        )
        let restored = try ModelCodec.decoder.decode(
            RecorderState.self,
            from: ModelCodec.encoder.encode(machine.state)
        )
        precondition(restored.currentSession?.phase == .suppressed(.skipped))
    }

    private static func restartSuppression(_ now: Date) throws {
        let session = descriptor("restart")
        let state = RecorderState(
            currentSession: ActiveMeetingSession(
                descriptor: session,
                phase: .recording,
                firstObservedAt: now,
                meetingID: UUID()
            )
        )
        var machine = CaptureStateMachine(restoringPersistedState: state)
        precondition(machine.state.currentSession?.phase == .suppressed(.interrupted))
        precondition(machine.handle(.cameraOn(session, at: now)) == [])
        precondition(machine.handle(.cameraOff(sessionID: session.id, at: now)) == [])
        precondition(machine.state.currentSession == nil)
    }

    private static func overlappingAndRapidSessions(_ now: Date) {
        let first = descriptor("first")
        let overlap = descriptor("overlap")
        let next = descriptor("next")
        let meetingID = UUID()
        var machine = CaptureStateMachine()
        precondition(machine.handle(.cameraOn(first, at: now)) == [.startCapture(first)])
        precondition(machine.handle(.cameraOn(overlap, at: now)) == [])
        _ = machine.handle(.captureStarted(sessionID: first.id, meetingID: meetingID, at: now))
        precondition(
            machine.handle(.cameraOff(sessionID: first.id, at: now))
                == [.stopCapture(meetingID: meetingID, reason: .cameraOff)]
        )
        precondition(machine.handle(.cameraOn(next, at: now)) == [.startCapture(next)])
    }

    private static func descriptor(_ id: String) -> MeetingSessionDescriptor {
        MeetingSessionDescriptor(
            id: id,
            sourceApplication: .init(
                bundleIdentifier: "com.google.Chrome",
                displayName: "Google Chrome",
                kind: .googleMeet
            ),
            surface: .init(id: "window-\(id)", title: "Meeting", kind: .meeting),
            attribution: .positive
        )
    }
}
