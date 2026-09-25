import Foundation
import TandemCore

/// The render module's warnings, worded for the status bar: where the
/// preview can't match the export yet.
enum PreviewWarnings {
    /// A warning with media paths cut down to the names the browser uses
    /// ("camera 10:54", "c1a").
    static func short(_ message: String, media: [MediaItem]) -> String {
        var text = message
        // Longest first, so a path that contains another is replaced whole.
        for item in media.sorted(by: { $0.path.count > $1.path.count }) where text.contains(item.path) {
            text = text.replacingOccurrences(of: item.path, with: MediaCatalog.shortName(item))
        }
        return text
    }

    /// The first warning and how many more there are, or nil for none.
    static func summary(_ warnings: [String], media: [MediaItem]) -> String? {
        guard let first = warnings.first else { return nil }
        let text = short(first, media: media)
        return warnings.count > 1 ? "\(text) (+\(warnings.count - 1) more)" : text
    }
}
