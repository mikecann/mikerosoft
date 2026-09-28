import Foundation

enum ScrollSpeed: String, CaseIterable {
    case slow
    case medium
    case fast

    var title: String {
        rawValue.capitalized
    }

    var pixelsPerTick: Double {
        switch self {
        case .slow:
            return 40
        case .medium:
            return 64
        case .fast:
            return 96
        }
    }
}

enum Smoothness: String, CaseIterable {
    case low
    case medium
    case high

    var title: String {
        rawValue.capitalized
    }

    var timeConstant: TimeInterval {
        switch self {
        case .low:
            return 0.045
        case .medium:
            return 0.07
        case .high:
            return 0.1
        }
    }
}

struct Settings: Equatable {
    var backForwardEnabled = true
    var smoothScrollingEnabled = true
    var scrollSpeed = ScrollSpeed.medium
    var smoothness = Smoothness.high

    var scrollTuning: ScrollAnimator.Tuning {
        ScrollAnimator.Tuning(
            pixelsPerTick: scrollSpeed.pixelsPerTick,
            timeConstant: smoothness.timeConstant
        )
    }
}

/// Settings shared between the menu on the main thread and the event tap on
/// its own thread.
final class SettingsStore {
    private enum Key {
        static let backForwardEnabled = "backForwardEnabled"
        static let smoothScrollingEnabled = "smoothScrollingEnabled"
        static let scrollSpeed = "scrollSpeed"
        static let smoothness = "smoothness"
        static let debugLogging = "debugLogging"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var value: Settings

    /// Logs one line per scroll glide. Turn on with
    /// `defaults write com.mikerosoft.mikey-mouse debugLogging -bool true`.
    let debugLogging: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let fallback = Settings()
        value = Settings(
            backForwardEnabled: defaults.object(forKey: Key.backForwardEnabled) as? Bool
                ?? fallback.backForwardEnabled,
            smoothScrollingEnabled: defaults.object(forKey: Key.smoothScrollingEnabled) as? Bool
                ?? fallback.smoothScrollingEnabled,
            scrollSpeed: defaults.string(forKey: Key.scrollSpeed).flatMap(ScrollSpeed.init)
                ?? fallback.scrollSpeed,
            smoothness: defaults.string(forKey: Key.smoothness).flatMap(Smoothness.init)
                ?? fallback.smoothness
        )
        debugLogging = defaults.bool(forKey: Key.debugLogging)
    }

    var current: Settings {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ change: (inout Settings) -> Void) {
        lock.lock()
        change(&value)
        let snapshot = value
        lock.unlock()

        defaults.set(snapshot.backForwardEnabled, forKey: Key.backForwardEnabled)
        defaults.set(snapshot.smoothScrollingEnabled, forKey: Key.smoothScrollingEnabled)
        defaults.set(snapshot.scrollSpeed.rawValue, forKey: Key.scrollSpeed)
        defaults.set(snapshot.smoothness.rawValue, forKey: Key.smoothness)
    }
}
