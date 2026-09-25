import Foundation
import TandemCore

/// What the top bar's agent chip knows: who last reached the project over
/// the API, when, and where their last edit landed. The API reports every
/// call (`TandemService.onCall`), reads included, and counts open watch
/// streams, so "connected" means a call in the last few minutes or a
/// stream still open.
struct AgentPresence: Equatable {
    var author: String
    /// The last call of any kind.
    var lastSeen: Date
    /// The last edit, undo or redo.
    var lastEdit: Date?
    /// The section the last edit touched, like "§4".
    var section: String?

    /// How long after its last contact an agent still counts as connected.
    static let connectedFor: TimeInterval = 300
    /// How long after an edit the chip says the agent is editing.
    static let editingFor: TimeInterval = 30

    /// Records a call that didn't edit: a status read, a frame, a watch.
    mutating func looked(by author: String, at date: Date) {
        self.author = author
        lastSeen = date
    }

    /// Records an edit, undo or redo.
    mutating func edited(by author: String, section: String?, at date: Date) {
        self.author = author
        lastSeen = date
        lastEdit = date
        if let section { self.section = section }
    }
}

/// The agent chip's words and dot.
enum AgentChipState: Equatable {
    /// No agent has been in touch lately. `serving` is false when the API
    /// couldn't start.
    case idle(serving: Bool)
    case editing(name: String, section: String?)
    case connected(name: String)
    case edited(name: String, at: Date)

    /// - Parameter watching: an agent has a watch stream open, so it's
    ///   connected however long ago it last called.
    static func of(_ presence: AgentPresence?, serving: Bool, watching: Bool = false, now: Date) -> AgentChipState {
        guard let presence else { return watching ? .connected(name: ActivityLog.displayName("agent")) : .idle(serving: serving) }
        let name = ActivityLog.displayName(presence.author)
        if let edit = presence.lastEdit, now.timeIntervalSince(edit) < AgentPresence.editingFor {
            return .editing(name: name, section: presence.section)
        }
        if watching || now.timeIntervalSince(presence.lastSeen) < AgentPresence.connectedFor {
            return .connected(name: name)
        }
        if let edit = presence.lastEdit { return .edited(name: name, at: edit) }
        return .idle(serving: serving)
    }

    /// The bold part.
    var name: String {
        switch self {
        case .idle: return "Agents"
        case .editing(let name, _), .connected(let name), .edited(let name, _): return name
        }
    }

    /// The muted part after the name.
    var detail: String {
        switch self {
        case .idle(let serving): return serving ? "not connected" : "API off"
        case .editing(_, let section): return section.map { "is editing \($0)" } ?? "is editing"
        case .connected: return "connected"
        case .edited(_, let date): return "edited \(date.formatted(date: .omitted, time: .shortened))"
        }
    }

    /// True while an agent is around, for the green dot.
    var isActive: Bool {
        switch self {
        case .editing, .connected: return true
        case .idle, .edited: return false
        }
    }
}

/// Where on the timeline an edit landed, so the chip can say which
/// section an agent is working in.
enum ChangeRegion {
    /// The stretch of timeline covered by clips that were added, removed or
    /// changed between two versions of the project. Nil when no clip moved.
    static func between(_ old: Project, _ new: Project) -> TimeRange? {
        var before: [String: Clip] = [:]
        for track in old.allTracks {
            for clip in track.clips { before[clip.id] = clip }
        }
        var start: Time?
        var end: Time?
        func include(_ range: TimeRange) {
            start = min(start ?? range.start, range.start)
            end = max(end ?? range.end, range.end)
        }
        for track in new.allTracks {
            for clip in track.clips {
                if let old = before.removeValue(forKey: clip.id) {
                    if old != clip {
                        include(old.range)
                        include(clip.range)
                    }
                } else {
                    include(clip.range)
                }
            }
        }
        // Whatever's left was removed.
        for clip in before.values { include(clip.range) }
        guard let start, let end else { return nil }
        return TimeRange(start: start, end: end)
    }

    /// The section a time falls in: the last marker at or before it. Mike's
    /// section markers read "§4 What it means", so those shorten to "§4".
    static func section(at time: Time, in project: Project) -> String? {
        guard let marker = project.markers.filter({ $0.time <= time }).max(by: { $0.time < $1.time }) else { return nil }
        let name = marker.name.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("§"), let first = name.split(separator: " ").first { return String(first) }
        guard !name.isEmpty else { return nil }
        return name.count > 18 ? String(name.prefix(17)) + "…" : name
    }
}
