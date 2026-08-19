import Foundation

struct MediaCaptureHealthState {
    private static let stalledMediaTimeout: TimeInterval = 10
    private static let rejectedSampleLimit = 60
    private static let digitalSilenceThresholdDecibels: Float = -120
    private static let digitalSilenceTimeout: TimeInterval = 3

    let requiresVideo: Bool
    let requiresAudio: Bool
    let failsOnDigitalSilence: Bool
    private let startedAt: TimeInterval
    private(set) var lastScreenCallbackAt: TimeInterval
    private(set) var lastAudioCallbackAt: TimeInterval?
    private(set) var consecutiveRejectedFrames = 0
    private(set) var consecutiveRejectedAudioSamples = 0
    private(set) var digitalSilenceStartedAt: TimeInterval?

    init(
        startedAt: TimeInterval,
        requiresVideo: Bool = true,
        requiresAudio: Bool = false,
        failsOnDigitalSilence: Bool = false
    ) {
        self.requiresVideo = requiresVideo
        self.requiresAudio = requiresAudio
        self.failsOnDigitalSilence = failsOnDigitalSilence
        self.startedAt = startedAt
        lastScreenCallbackAt = startedAt
    }

    mutating func recordScreenCallback(at time: TimeInterval) {
        lastScreenCallbackAt = time
    }

    mutating func recordVideoAppend(accepted: Bool) {
        consecutiveRejectedFrames = accepted ? 0 : consecutiveRejectedFrames + 1
    }

    mutating func recordAudioCallback(
        at time: TimeInterval,
        accepted: Bool,
        peakDecibels: Float
    ) {
        lastAudioCallbackAt = time
        consecutiveRejectedAudioSamples = accepted ? 0 : consecutiveRejectedAudioSamples + 1

        guard failsOnDigitalSilence else { return }
        if peakDecibels <= Self.digitalSilenceThresholdDecibels {
            digitalSilenceStartedAt = digitalSilenceStartedAt ?? time
        } else {
            digitalSilenceStartedAt = nil
        }
    }

    func problem(at time: TimeInterval) -> String? {
        if requiresVideo, time - lastScreenCallbackAt >= Self.stalledMediaTimeout {
            return "No screen frames were delivered for 10 seconds."
        }
        if consecutiveRejectedFrames >= Self.rejectedSampleLimit {
            return "The video encoder rejected 60 consecutive screen frames."
        }
        if requiresAudio,
           time - (lastAudioCallbackAt ?? startedAt) >= Self.stalledMediaTimeout {
            return "No audio samples were delivered for 10 seconds."
        }
        if consecutiveRejectedAudioSamples >= Self.rejectedSampleLimit {
            return "The audio encoder rejected 60 consecutive microphone samples."
        }
        if failsOnDigitalSilence,
           let digitalSilenceStartedAt,
           time - digitalSilenceStartedAt >= Self.digitalSilenceTimeout {
            return "The microphone delivered digital silence for 3 seconds. It may be muted or stalled."
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
