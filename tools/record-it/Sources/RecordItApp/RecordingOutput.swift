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
