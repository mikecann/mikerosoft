import Foundation

enum RecordingWriterStatus: Equatable, Sendable {
    case unknown
    case writing
    case completed
    case failed
    case cancelled
}

enum RecordingHealth: Int, Comparable, Sendable {
    case starting
    case healthy
    case warning
    case failed

    static func < (lhs: RecordingHealth, rhs: RecordingHealth) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct WriterProgress: Equatable, Sendable {
    let videoSamplesWritten: Int
    let audioSamplesWritten: Int
    let videoTimelineDuration: TimeInterval
    let audioTimelineDuration: TimeInterval
    let fileSizeBytes: Int64
    let writerStatus: RecordingWriterStatus

    var mediaDuration: TimeInterval {
        max(videoTimelineDuration, audioTimelineDuration)
    }
}

struct RecordingTelemetry: Identifiable, Equatable, Sendable {
    let source: CaptureSource
    let outputURL: URL
    let width: Int
    let height: Int
    let codecName: String
    let videoSamplesWritten: Int
    let audioSamplesWritten: Int
    let mediaDuration: TimeInterval
    let fileSizeBytes: Int64
    let lastVideoActivityAt: TimeInterval?
    let consecutiveRejectedVideoSamples: Int
    let writerStatus: RecordingWriterStatus
    let audioWaveformLevels: [Float]
    let health: RecordingHealth
    let healthMessage: String

    var id: CaptureSource { source }
    var outputFileName: String { outputURL.lastPathComponent }
    var resolutionLabel: String {
        source == .audio ? "Audio only" : "\(width) × \(height)"
    }

    init(
        source: CaptureSource,
        outputURL: URL,
        width: Int,
        height: Int,
        codecName: String,
        videoSamplesWritten: Int,
        audioSamplesWritten: Int,
        mediaDuration: TimeInterval,
        fileSizeBytes: Int64,
        lastVideoActivityAt: TimeInterval?,
        consecutiveRejectedVideoSamples: Int,
        writerStatus: RecordingWriterStatus,
        now: TimeInterval,
        audioWaveformLevels: [Float] = [],
        failureMessage: String? = nil
    ) {
        self.source = source
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.codecName = codecName
        self.videoSamplesWritten = videoSamplesWritten
        self.audioSamplesWritten = audioSamplesWritten
        self.mediaDuration = mediaDuration
        self.fileSizeBytes = fileSizeBytes
        self.lastVideoActivityAt = lastVideoActivityAt
        self.consecutiveRejectedVideoSamples = consecutiveRejectedVideoSamples
        self.writerStatus = writerStatus
        self.audioWaveformLevels = audioWaveformLevels

        if let failureMessage {
            health = .failed
            healthMessage = failureMessage
        } else if writerStatus == .failed || writerStatus == .cancelled {
            health = .failed
            healthMessage = source == .audio ? "The audio writer has stopped" : "The movie writer has stopped"
        } else if source == .audio {
            if let lastVideoActivityAt, now - lastVideoActivityAt >= 10 {
                health = .failed
                healthMessage = "No audio input for 10 seconds"
            } else if let lastVideoActivityAt, now - lastVideoActivityAt >= 3 {
                health = .warning
                healthMessage = "Waiting for the next audio sample"
            } else if audioSamplesWritten == 0 || lastVideoActivityAt == nil {
                health = .starting
                healthMessage = "Waiting for the first audio sample"
            } else if hasSustainedAudioSilence(audioWaveformLevels) {
                health = .warning
                healthMessage = "Input is silent. Check the selected microphone, mute, and gain"
            } else {
                health = .healthy
                healthMessage = "Audio and file output are active"
            }
        } else if source == .camera, audioSamplesWritten == 0 {
            health = .starting
            healthMessage = "Waiting for the first microphone sample"
        } else if source == .camera, hasSustainedAudioSilence(audioWaveformLevels) {
            health = .warning
            healthMessage = "Microphone is quiet. Check mute and input level"
        } else if consecutiveRejectedVideoSamples >= 60 {
            health = .failed
            healthMessage = "Video encoder is not accepting frames"
        } else if let lastVideoActivityAt, now - lastVideoActivityAt >= 10 {
            health = .failed
            healthMessage = "No video updates for 10 seconds"
        } else if let lastVideoActivityAt, now - lastVideoActivityAt >= 3 {
            health = .warning
            healthMessage = "Waiting for the next video update"
        } else if videoSamplesWritten == 0 || lastVideoActivityAt == nil {
            health = .starting
            healthMessage = "Waiting for the first written video sample"
        } else {
            health = .healthy
            healthMessage = "Video and file output are active"
        }
    }
}

private func hasSustainedAudioSilence(_ levels: [Float]) -> Bool {
    // The recorder samples the waveform at 10 Hz, so 30 quiet values means the
    // selected input has stayed below roughly -54 dB for 3 seconds.
    let recentLevels = levels.suffix(30)
    return recentLevels.count == 30 && recentLevels.allSatisfy { $0 <= 0.1 }
}

func shouldShowRecordingDashboard(isRecording: Bool, isBusy: Bool) -> Bool {
    // Keep the live dashboard visible while the recording is being finalized.
    isRecording
}

func overallRecordingHealth(_ healthValues: [RecordingHealth]) -> RecordingHealth {
    if healthValues.contains(.failed) { return .failed }
    if healthValues.contains(.warning) { return .warning }
    if healthValues.isEmpty || healthValues.contains(.starting) { return .starting }
    return .healthy
}
