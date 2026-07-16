import Combine
import Foundation

final class RecordingPreferences: ObservableObject {
    private enum Key {
        static let openFinderAfterRecording = "openFinderAfterRecording"
    }

    private let defaults: UserDefaults

    @Published var openFinderAfterRecording: Bool {
        didSet {
            defaults.set(openFinderAfterRecording, forKey: Key.openFinderAfterRecording)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Key.openFinderAfterRecording) == nil {
            openFinderAfterRecording = true
        } else {
            openFinderAfterRecording = defaults.bool(forKey: Key.openFinderAfterRecording)
        }
    }
}
