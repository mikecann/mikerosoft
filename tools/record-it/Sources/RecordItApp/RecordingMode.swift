enum RecordingMode: String, CaseIterable, Identifiable {
    case screen
    case camera
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .screen: "Screen"
        case .camera: "Camera"
        case .both: "Both"
        }
    }

    var capturesScreen: Bool { self != .camera }
    var capturesCamera: Bool { self != .screen }
}
