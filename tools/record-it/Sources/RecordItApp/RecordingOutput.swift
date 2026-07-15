import Foundation

enum CaptureSource: Hashable {
    case screen
    case camera

    var filenameSuffix: String {
        switch self {
        case .screen: "screen"
        case .camera: "camera"
        }
    }
}

func normalizedRecordingBaseName(_ candidate: String) -> String? {
    var name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.lowercased().hasSuffix(".mov") {
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
    if mode.capturesScreen {
        outputs[.screen] = directory.appendingPathComponent("\(prefix)-screen.mov")
    }
    if mode.capturesCamera {
        outputs[.camera] = directory.appendingPathComponent("\(prefix)-camera.mov")
    }
    return outputs
}
