enum RecordingMode: String, CaseIterable, Identifiable {
    case screen
    case camera
    case both
    case audio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .screen: "Screen"
        case .camera: "Camera"
        case .both: "Both"
        case .audio: "Audio"
        }
    }

    var capturesScreen: Bool { self == .screen || self == .both }
    var capturesCamera: Bool { self == .camera || self == .both }
    var capturesAudio: Bool { self == .audio }
    var requiresVideoEncoder: Bool { capturesScreen || capturesCamera }
}
