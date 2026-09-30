import Foundation

/// Where each project's timeline was when its window closed: the playhead,
/// the zoom and the scroll. Reopening it (Tandem restarting to install a
/// build, say) carries on there instead of at the start, fitted.
enum TimelinePlacement {
    static let key = "projectTimelines"

    struct Saved: Equatable {
        var playhead: Double
        var pixelsPerSecond: Double
        var scrollSeconds: Double
        var verticalOffset: Double
    }

    static func save(_ saved: Saved, for project: URL, to store: UserDefaults = AppDefaults.store) {
        var all = store.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
        all[project.standardizedFileURL.path] = [
            "playhead": saved.playhead,
            "pixelsPerSecond": saved.pixelsPerSecond,
            "scrollSeconds": saved.scrollSeconds,
            "verticalOffset": saved.verticalOffset
        ]
        store.set(all, forKey: key)
    }

    /// What was saved for `project`, or nil when nothing was or it doesn't
    /// make sense (a zoom of zero, say).
    static func saved(for project: URL, in store: UserDefaults = AppDefaults.store) -> Saved? {
        guard let all = store.dictionary(forKey: key) as? [String: [String: Double]],
              let values = all[project.standardizedFileURL.path],
              let playhead = values["playhead"], let pixelsPerSecond = values["pixelsPerSecond"],
              let scroll = values["scrollSeconds"], pixelsPerSecond.isFinite, pixelsPerSecond > 0,
              playhead.isFinite, scroll.isFinite else { return nil }
        let vertical = values["verticalOffset"] ?? 0
        return Saved(playhead: max(0, playhead), pixelsPerSecond: pixelsPerSecond, scrollSeconds: max(0, scroll), verticalOffset: vertical.isFinite ? max(0, vertical) : 0)
    }
}
