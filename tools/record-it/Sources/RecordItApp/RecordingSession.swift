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

    /// Finalizes every recorder even when another one fails. A throwing task
    /// group would cancel the remaining finalizations and could lose files that
    /// were recorded perfectly.
    func stop() async throws {
        let errors = await withTaskGroup(of: Error?.self) { group in
            for recorder in recorders {
                group.addTask {
                    do {
                        try await recorder.stop()
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var errors: [Error] = []
            for await error in group {
                if let error { errors.append(error) }
            }
            return errors
        }
        if let error = errors.first { throw error }
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
