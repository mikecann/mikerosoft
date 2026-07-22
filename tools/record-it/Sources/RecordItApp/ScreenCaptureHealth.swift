import Foundation

struct ScreenCaptureHealthState {
    private(set) var lastScreenCallbackAt: TimeInterval
    private(set) var consecutiveRejectedFrames = 0

    init(startedAt: TimeInterval) {
        lastScreenCallbackAt = startedAt
    }

    mutating func recordScreenCallback(at time: TimeInterval) {
        lastScreenCallbackAt = time
    }

    mutating func recordVideoAppend(accepted: Bool) {
        consecutiveRejectedFrames = accepted ? 0 : consecutiveRejectedFrames + 1
    }

    func problem(at time: TimeInterval) -> String? {
        if time - lastScreenCallbackAt >= 10 {
            return "No screen frames were delivered for 10 seconds."
        }
        if consecutiveRejectedFrames >= 60 {
            return "The video encoder rejected 60 consecutive screen frames."
        }
        return nil
    }
}

final class RecordingDiagnostics: @unchecked Sendable {
    static let shared = RecordingDiagnostics()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let logURL: URL

    private init() {
        logURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Record It", isDirectory: true)
            .appendingPathComponent("record-it.log")
    }

    func log(_ message: String) {
        lock.withLock {
            do {
                try fileManager.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let data = Data("\(timestamp) \(message)\n".utf8)
                if !fileManager.fileExists(atPath: logURL.path) {
                    try data.write(to: logURL, options: .atomic)
                    return
                }
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                // Diagnostics must never be allowed to interrupt a recording.
            }
        }
    }
}
