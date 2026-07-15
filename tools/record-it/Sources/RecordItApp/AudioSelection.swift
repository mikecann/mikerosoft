import Foundation

enum ScreenAudioSource: String, CaseIterable, Identifiable, Sendable {
    case systemSound
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemSound: "System Sound"
        case .none: "None"
        }
    }

    var capturesSystemAudio: Bool { self == .systemSound }
}
