import Foundation

enum CaptureSource: Hashable, Sendable {
    case screen
    case camera
    case audio
    case recoveryAudio

    var filenameSuffix: String {
        switch self {
        case .screen: "screen"
        case .camera: "camera"
        case .audio: "audio"
        case .recoveryAudio: "backup-audio"
        }
    }

    var displayName: String {
        switch self {
        case .screen: "Screen"
        case .camera: "Camera"
        case .audio: "Audio"
        case .recoveryAudio: "Backup audio"
        }
    }

    var fileExtension: String {
        switch self {
        case .audio: "m4a"
        case .recoveryAudio: "caf"
        case .screen, .camera: "mov"
        }
    }
}

func normalizedRecordingBaseName(_ candidate: String) -> String? {
    var name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.lowercased().hasSuffix(".mov") || name.lowercased().hasSuffix(".m4a") {
        name.removeLast(4)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let invalidCharacters = CharacterSet(charactersIn: "/:\0")
    guard !name.isEmpty, name.rangeOfCharacter(from: invalidCharacters) == nil else {
        return nil
    }
    return name
}

func defaultRecordingBaseName(
    startedAt: Date,
    timeZone: TimeZone = .current
) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    return formatter.string(from: startedAt)
}

func recordingOutputURLs(
    mode: RecordingMode,
    directory: URL,
    startedAt: Date,
    baseName: String? = nil,
    timeZone: TimeZone = .current
) -> [CaptureSource: URL] {
    let prefix = baseName ?? defaultRecordingBaseName(startedAt: startedAt, timeZone: timeZone)

    var outputs: [CaptureSource: URL] = [:]
    func outputURL(for source: CaptureSource) -> URL {
        directory.appendingPathComponent(
            "\(prefix)-\(source.filenameSuffix).\(source.fileExtension)"
        )
    }

    if mode.capturesScreen {
        outputs[.screen] = outputURL(for: .screen)
    }
    if mode.capturesCamera {
        outputs[.camera] = outputURL(for: .camera)
    }
    if mode.capturesAudio {
        outputs[.audio] = outputURL(for: .audio)
    }
    return outputs
}

/// Returns a take name whose files don't exist yet, adding "-2", "-3" and so
/// on when needed, so a reused name can never overwrite an earlier take.
func availableRecordingBaseName(_ baseName: String, isTaken: (String) -> Bool) -> String {
    guard isTaken(baseName) else { return baseName }
    var suffix = 2
    while isTaken("\(baseName)-\(suffix)") {
        suffix += 1
    }
    return "\(baseName)-\(suffix)"
}

struct CaptureProblem: Identifiable, Equatable, Sendable {
    let id = UUID()
    let sourceName: String
    let message: String
    let takeTime: TimeInterval
    /// Problems that damage the primary media sound the alarm. Backup-only
    /// problems are shown quietly so the alarm doesn't end up in a good take.
    let soundsAlarm: Bool

    var timecode: String {
        let seconds = max(0, Int(takeTime.rounded(.down)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    var summary: String {
        "\(timecode)  \(sourceName): \(message)"
    }
}

func captureProblemReport(takeName: String, problems: [CaptureProblem]) -> String {
    var lines = [
        "Record It problems for \(takeName)",
        "Times are from the start of the take. Everything else kept recording.",
        ""
    ]
    lines += problems.map(\.summary)
    return lines.joined(separator: "\n") + "\n"
}

let minimumFreeRecordingBytes: Int64 = 10 * 1_000_000_000

func availableRecordingBytes(at directory: URL) -> Int64? {
    let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
}
