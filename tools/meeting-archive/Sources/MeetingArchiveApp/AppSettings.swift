import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    @Published var selectedCalendarIDs: Set<String> { didSet { defaults.set(Array(selectedCalendarIDs), forKey: "calendarIDs") } }
    @Published var archiveHost: String { didSet { defaults.set(archiveHost, forKey: "archiveHost") } }
    @Published var archiveRoot: String { didSet { defaults.set(archiveRoot, forKey: "archiveRoot") } }
    /// Bruce's playback viewer behind Tailscale Serve. It streams video with
    /// range requests and shows the transcript, so nothing is copied locally.
    @Published var viewerURL: String { didSet { defaults.set(viewerURL, forKey: "viewerURL") } }
    // Enable only after checking that this directory is included in Bruce's
    // existing backup. A network transfer is not evidence of backup coverage.
    @Published var backupCoverageVerified: Bool { didSet { defaults.set(backupCoverageVerified, forKey: "backupCoverageVerified") } }
    private let defaults = UserDefaults.standard

    init() {
        selectedCalendarIDs = Set(defaults.stringArray(forKey: "calendarIDs") ?? [])
        archiveHost = defaults.string(forKey: "archiveHost") ?? "bruce"
        archiveRoot = defaults.string(forKey: "archiveRoot") ?? "/Volumes/CannMedia/MeetingArchive"
        viewerURL = defaults.string(forKey: "viewerURL") ?? "https://bruce.tail9ef766.ts.net:10443"
        backupCoverageVerified = defaults.bool(forKey: "backupCoverageVerified")
    }
}

enum AppPaths {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["MEETING_ARCHIVE_DATA_DIR"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Meeting Archive", isDirectory: true)
    }
    static var spool: URL { root.appendingPathComponent("spool", isDirectory: true) }
    static var index: URL { root.appendingPathComponent("index", isDirectory: true) }
    static func meeting(_ id: UUID) -> URL { spool.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
}
