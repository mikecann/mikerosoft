/// Pure lifecycle for one `NativeRecording` instance. Access is serialized by
/// the recorder's small lifecycle lock; this type owns no native objects.
struct NativeCaptureLifecycle: Equatable, Sendable {
    private enum Phase: Equatable, Sendable {
        case preparing
        case activating
        case active
        case stopping
        case stopped
    }

    private var phase: Phase = .preparing
    private(set) var hasCapturedSamples = false

    var startupPermitted: Bool {
        phase == .preparing
    }

    var acceptsSamples: Bool {
        // SCStream may enqueue samples before startCapture() returns. Do not
        // create writers until that async activation has succeeded and the
        // caller's startup cancellation had one final chance to win.
        phase == .active
    }

    var reportsFailures: Bool {
        phase == .preparing || phase == .activating || phase == .active
    }

    mutating func beginActivation() -> Bool {
        guard phase == .preparing else { return false }
        phase = .activating
        return true
    }

    mutating func didActivate() -> Bool {
        guard phase == .activating else { return false }
        phase = .active
        return true
    }

    mutating func cancelStartup() {
        guard phase == .preparing || phase == .activating else { return }
        phase = .stopping
    }

    mutating func recordAcceptedSample() {
        // The caller records this only after a sample passed the active gate
        // and was appended. Preserve that fact if stop began meanwhile.
        hasCapturedSamples = true
    }

    /// Returns whether a native stream may need stopping.
    mutating func beginStop() -> Bool {
        let hadStartedStream = phase == .activating || phase == .active
        guard phase != .stopping, phase != .stopped else { return false }
        phase = .stopping
        return hadStartedStream
    }

    mutating func didStop() {
        phase = .stopped
    }
}
