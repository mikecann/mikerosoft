import CoreMedia
import Foundation

protocol CaptureRecording: Sendable {
    func start() async throws
    func stop() async throws
}

final class RecordingStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStartTime: CMTime?

    var startTime: CMTime? {
        lock.withLock { storedStartTime }
    }

    func open(at startTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        lock.withLock {
            if storedStartTime == nil {
                storedStartTime = startTime
            }
        }
    }
}

struct RecordingSession: Sendable {
    let recorders: [any CaptureRecording]
    let startGate: RecordingStartGate?

    init(recorders: [any CaptureRecording], startGate: RecordingStartGate? = nil) {
        self.recorders = recorders
        self.startGate = startGate
    }

    func start() async throws {
        do {
            try await runConcurrently { recorder in
                try await recorder.start()
            }
            startGate?.open()
        } catch {
            await stopIgnoringErrors()
            throw error
        }
    }

    func stop() async throws {
        try await runConcurrently { recorder in
            try await recorder.stop()
        }
    }

    private func runConcurrently(
        operation: @escaping @Sendable (any CaptureRecording) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for recorder in recorders {
                group.addTask {
                    try await operation(recorder)
                }
            }
            try await group.waitForAll()
        }
    }

    private func stopIgnoringErrors() async {
        await withTaskGroup(of: Void.self) { group in
            for recorder in recorders {
                group.addTask {
                    try? await recorder.stop()
                }
            }
        }
    }
}

extension ScreenRecorder: CaptureRecording {}
extension CameraRecorder: CaptureRecording {}
extension AudioRecorder: CaptureRecording {}
