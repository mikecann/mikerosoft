import Foundation

final class VideoHQPreferences {
    private enum Key {
        static let lastSelectedProjectPath = "videoHQ.lastSelectedProjectPath"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastSelectedProjectURL: URL? {
        get {
            guard let path = defaults.string(forKey: Key.lastSelectedProjectPath),
                  !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.lastSelectedProjectPath)
                return
            }
            defaults.set(
                newValue.standardizedFileURL.path,
                forKey: Key.lastSelectedProjectPath
            )
        }
    }
}
