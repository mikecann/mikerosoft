import Foundation

/// Where the app keeps its preferences: recent projects, the project list's
/// size, export speed. A test copy sets `TANDEM_DEFAULTS_SUITE` so it keeps
/// its own, instead of sharing (and rewriting) the installed app's.
enum AppDefaults {
    static let suiteName: String? = {
        guard let name = ProcessInfo.processInfo.environment["TANDEM_DEFAULTS_SUITE"], !name.isEmpty else { return nil }
        return name
    }()

    static let store: UserDefaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard

    /// True for a test copy with its own preferences. It also leaves
    /// AppKit's saved window frames alone.
    static var isolated: Bool { suiteName != nil }
}
