import Foundation

/// Where the app keeps its preferences: recent projects, the project list's
/// size, where the editor window was, export speed. A test copy sets
/// `TANDEM_DEFAULTS_SUITE` so it keeps its own, instead of sharing (and
/// rewriting) the installed app's.
enum AppDefaults {
    static let suiteName: String? = {
        guard let name = ProcessInfo.processInfo.environment["TANDEM_DEFAULTS_SUITE"], !name.isEmpty else { return nil }
        return name
    }()

    static let store: UserDefaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
}
