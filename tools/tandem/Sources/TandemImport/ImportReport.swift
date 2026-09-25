import Foundation
import TandemCore

/// What an import did and didn't carry over.
///
/// Items are grouped: the same message from many clips is one item with a
/// count and the timeline times of the first few, so a report on a
/// 500-clip project stays readable.
public struct ImportReport: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable, CaseIterable {
        /// Worth knowing, nothing lost. For example a mapping decision.
        case note
        /// Carried over, but not exactly: a speed ramp played at its
        /// average speed, a transition Tandem doesn't have played as a
        /// dissolve.
        case approximated
        /// Left out because Tandem has no equivalent yet: stickers, blend
        /// modes, speed curves on audio.
        case unsupported
        /// The file wasn't found where the project says. The clip is kept,
        /// pointing at the old path, so relinking brings it back.
        case missingMedia
        /// Something that should have worked and didn't. Always a bug in
        /// the importer or the source file.
        case failed
    }

    public struct Item: Codable, Equatable, Sendable {
        public var severity: Severity
        /// A short area name: "transition", "effect", "title", "media"...
        public var category: String
        public var message: String
        /// How many times it happened.
        public var count: Int
        /// Timeline seconds of the first few occurrences, to find them.
        public var at: [Double]

        public init(severity: Severity, category: String, message: String, count: Int = 1, at: [Double] = []) {
            self.severity = severity
            self.category = category
            self.message = message
            self.count = count
            self.at = at
        }
    }

    /// The file or folder the project came from.
    public var source: String
    /// "filmora" or "edl".
    public var importer: String
    public var projectName: String
    public var items: [Item]
    /// Plain numbers about the result ("clips", "tracks", "duration"...)
    /// and, for comparisons, about the original.
    public var stats: [String: Double]

    private static let maxTimes = 8

    public init(source: String, importer: String, projectName: String) {
        self.source = source
        self.importer = importer
        self.projectName = projectName
        self.items = []
        self.stats = [:]
    }

    /// Records something, merging it with an earlier identical message.
    public mutating func add(_ severity: Severity, _ category: String, _ message: String, at time: Time? = nil) {
        let seconds = time.map { ($0.seconds * 1000).rounded() / 1000 }
        if let i = items.firstIndex(where: { $0.severity == severity && $0.category == category && $0.message == message }) {
            items[i].count += 1
            if let seconds, items[i].at.count < Self.maxTimes { items[i].at.append(seconds) }
        } else {
            items.append(Item(severity: severity, category: category, message: message, at: seconds.map { [$0] } ?? []))
        }
    }

    public func items(_ severity: Severity) -> [Item] {
        items.filter { $0.severity == severity }
    }

    /// Total occurrences at a severity.
    public func count(_ severity: Severity) -> Int {
        items(severity).reduce(0) { $0 + $1.count }
    }

    /// A readable summary for people: stats first, then every item grouped
    /// by severity, worst first.
    public var text: String {
        var lines = ["Imported \"\(projectName)\" from \(source) (\(importer) importer)."]
        if !stats.isEmpty {
            let parts = stats.keys.sorted().map { key -> String in
                let value = stats[key]!
                let shown = value.rounded() == value ? String(Int(value)) : String(format: "%.3f", value)
                return "\(key) \(shown)"
            }
            lines.append(parts.joined(separator: ", "))
        }
        let order: [(Severity, String)] = [
            (.failed, "Failed"),
            (.missingMedia, "Missing media"),
            (.unsupported, "Not carried over"),
            (.approximated, "Approximated"),
            (.note, "Notes")
        ]
        for (severity, title) in order {
            let group = items(severity)
            guard !group.isEmpty else { continue }
            lines.append("")
            lines.append("\(title) (\(group.reduce(0) { $0 + $1.count })):")
            for item in group {
                var line = "- [\(item.category)] \(item.message)"
                if item.count > 1 { line += " (x\(item.count))" }
                if !item.at.isEmpty {
                    line += " at " + item.at.map { Time(seconds: $0).description }.joined(separator: ", ")
                    if item.count > item.at.count { line += "..." }
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}
