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

func recordingOutputURLs(
    mode: RecordingMode,
    directory: URL,
    startedAt: Date,
    timeZone: TimeZone = .current
) -> [CaptureSource: URL] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd_HHmmss"
    let prefix = formatter.string(from: startedAt)

    var outputs: [CaptureSource: URL] = [:]
    if mode.capturesScreen {
        outputs[.screen] = directory.appendingPathComponent("\(prefix)-screen.mov")
    }
    if mode.capturesCamera {
        outputs[.camera] = directory.appendingPathComponent("\(prefix)-camera.mov")
    }
    return outputs
}
