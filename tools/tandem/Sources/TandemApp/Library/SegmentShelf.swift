import Foundation
import TandemAPI
import TandemCore

/// The shared library's saved segments as the app last read them, for the
/// Text tab's Segments and for drops: a segment is dragged as the template
/// `segment:<its folder>`, which `BuiltInTemplates.template(_:)` finds
/// here, so a segment drops on the timeline the way a built-in template
/// does. Safe from any thread.
final class SegmentShelf: @unchecked Sendable {
    static let shared = SegmentShelf()

    /// The template ID a segment is dragged as.
    static let prefix = "segment:"

    private let lock = NSLock()
    private var stored: [StoredSegment] = []

    /// Every segment, by name.
    var segments: [StoredSegment] {
        lock.withLock { stored }
    }

    func update(_ segments: [StoredSegment]) {
        lock.withLock { stored = segments }
    }

    /// The template ID for a segment.
    static func templateID(_ segment: StoredSegment) -> String {
        prefix + segment.id
    }

    /// The segment a template ID names.
    func segment(forTemplate id: String) -> StoredSegment? {
        guard id.hasPrefix(Self.prefix) else { return nil }
        let folder = String(id.dropFirst(Self.prefix.count))
        return segments.first { $0.id == folder }
    }

    /// The template to insert for `segment:<folder>`, its files where they
    /// are in the library. Nil for other IDs, and for a segment missing a
    /// file, so a drop can't put half of one in.
    func template(_ id: String) -> Template? {
        guard let segment = segment(forTemplate: id), segment.missingFiles.isEmpty else { return nil }
        return segment.insertableTemplate()
    }
}
