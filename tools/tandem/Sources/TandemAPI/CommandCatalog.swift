import Foundation
import TandemCore

/// The name of every `EditCommand` case. `EditCommand.commandCase` switches
/// over the enum exhaustively, so adding a command to TandemCore fails to
/// compile until it's listed here, and the schema tests then insist it has a
/// schema entry and an example.
public enum CommandCase: String, CaseIterable, Codable, Sendable {
    case updateProject, updateSettings, addTrack, removeTrack, moveTrack, updateTrack
    case addMedia, updateMedia, removeMedia
    case placeMedia, insertClip, removeClips, rippleDeleteRange, closeGap, insertTime, insertTemplate, addSectionCards, fitSectionCards
    case blade, trim, roll, slip, slide, setSpeed
    case moveClips, updateClip, link, unlink, applyLayout, zoomToRegion, setFormatLayout, addMotion
    case addTransition, updateTransition, removeTransition
    case addEffect, updateEffect, removeEffect, moveEffect, setKeyframes
    case normalizeSpeech
    case addMarker, updateMarker, removeMarker
}

extension EditCommand {
    public var commandCase: CommandCase {
        switch self {
        case .updateProject: return .updateProject
        case .updateSettings: return .updateSettings
        case .addTrack: return .addTrack
        case .removeTrack: return .removeTrack
        case .moveTrack: return .moveTrack
        case .updateTrack: return .updateTrack
        case .addMedia: return .addMedia
        case .updateMedia: return .updateMedia
        case .removeMedia: return .removeMedia
        case .placeMedia: return .placeMedia
        case .insertClip: return .insertClip
        case .removeClips: return .removeClips
        case .rippleDeleteRange: return .rippleDeleteRange
        case .closeGap: return .closeGap
        case .insertTime: return .insertTime
        case .insertTemplate: return .insertTemplate
        case .addSectionCards: return .addSectionCards
        case .fitSectionCards: return .fitSectionCards
        case .blade: return .blade
        case .trim: return .trim
        case .roll: return .roll
        case .slip: return .slip
        case .slide: return .slide
        case .setSpeed: return .setSpeed
        case .moveClips: return .moveClips
        case .updateClip: return .updateClip
        case .link: return .link
        case .unlink: return .unlink
        case .applyLayout: return .applyLayout
        case .zoomToRegion: return .zoomToRegion
        case .setFormatLayout: return .setFormatLayout
        case .addMotion: return .addMotion
        case .addTransition: return .addTransition
        case .updateTransition: return .updateTransition
        case .removeTransition: return .removeTransition
        case .addEffect: return .addEffect
        case .updateEffect: return .updateEffect
        case .removeEffect: return .removeEffect
        case .moveEffect: return .moveEffect
        case .setKeyframes: return .setKeyframes
        case .normalizeSpeech: return .normalizeSpeech
        case .addMarker: return .addMarker
        case .updateMarker: return .updateMarker
        case .removeMarker: return .removeMarker
        }
    }

}

/// Words for commands: undo labels, dry runs.
public enum CommandText {
    /// A short description of one command, like
    /// "Ripple delete 00:10.000-00:12.000".
    public static func summary(_ command: EditCommand) -> String {
        func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
        switch command {
        case .updateProject: return "Update project"
        case .updateSettings: return "Change project settings"
        case .addTrack(let kind, let name, _, _): return name.map { "Add track \($0)" } ?? "Add \(kind.rawValue) track"
        case .removeTrack: return "Remove track"
        case .moveTrack: return "Move track"
        case .updateTrack: return "Update track"
        case .addMedia(let item): return "Add \((item.path as NSString).lastPathComponent)"
        case .updateMedia: return "Update media"
        case .removeMedia: return "Remove media"
        case .placeMedia(let ids, let at, _, _, _, _, _, _): return "Place \(count(ids.count, "file")) at \(at)"
        case .insertClip(_, let clip, let mode): return mode == .insert ? "Insert clip at \(clip.start)" : "Add clip at \(clip.start)"
        case .removeClips(let ids, let ripple, _): return ripple == true ? "Ripple delete \(count(ids.count, "clip"))" : "Lift \(count(ids.count, "clip"))"
        case .rippleDeleteRange(let range, _): return "Ripple delete \(range.start)-\(range.end)"
        case .closeGap(_, let at): return "Close gap at \(at)"
        case .insertTime(let at, let duration, _): return "Insert \(TimeText.duration(duration)) at \(at)"
        case .insertTemplate(let template, let at, _, _): return "Insert \(template.name) at \(at)"
        case .addSectionCards(let markerIDs, _, _, _, let mode, _, _):
            let markers = markerIDs.map { count($0.count, "marker") } ?? "section markers"
            return mode == .insert ? "Add section cards at \(markers), making room" : "Add section cards at \(markers)"
        case .fitSectionCards(let clipIDs): return clipIDs.map { "Fit \(count($0.count, "section card")) to their words" } ?? "Fit section cards to their words"
        case .blade(let at, _, _): return "Cut at \(at)"
        case .trim(_, let edge, _, let ripple, _): return ripple == true ? "Ripple trim \(edge.rawValue)" : "Trim \(edge.rawValue)"
        case .roll: return "Roll edit"
        case .slip: return "Slip clip"
        case .slide: return "Slide clip"
        case .setSpeed(_, let speed, _, _): return "Speed \(number(speed))x"
        case .moveClips(let ids, _, _, _, _): return "Move \(count(ids.count, "clip"))"
        case .updateClip: return "Update clip"
        case .link: return "Link clips"
        case .unlink: return "Unlink clips"
        case .applyLayout(_, let preset): return "Layout \(preset.name)"
        case .zoomToRegion(_, _, let at, _): return at.map { "Zoom at \($0)" } ?? "Zoom"
        case .setFormatLayout(let ids, let format, let slot, _): return "Place \(count(ids.count, "clip")) in the \(slot.rawValue) of \(format)"
        case .addMotion(let ids, let style, _): return "\(style.name) on \(count(ids.count, "clip"))"
        case .addTransition(_, let transition): return "Add \(transition.type.rawValue)"
        case .updateTransition: return "Update transition"
        case .removeTransition: return "Remove transition"
        case .addEffect(_, let effect, _): return "Add \(effect.type)"
        case .updateEffect: return "Update effect"
        case .removeEffect: return "Remove effect"
        case .moveEffect: return "Reorder effects"
        case .setKeyframes(_, let parameter, let keyframes): return keyframes.isEmpty ? "Remove \(parameter) animation" : "Animate \(parameter)"
        case .normalizeSpeech: return "Normalise speech clips"
        case .addMarker(let marker): return marker.name.isEmpty ? "Add marker" : "Add marker \(marker.name)"
        case .updateMarker: return "Update marker"
        case .removeMarker: return "Remove marker"
        }
    }

    /// A number without a needless ".0": 2, 1.5.
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(format: "%g", value)
    }

    /// A label for a batch with no label of its own.
    public static func label(for commands: [EditCommand]) -> String {
        guard let first = commands.first else { return "Edit" }
        if commands.count == 1 { return summary(first) }
        if commands.allSatisfy({ $0.commandCase == first.commandCase }) {
            switch first.commandCase {
            case .rippleDeleteRange: return "\(commands.count) ripple deletes"
            case .blade: return "\(commands.count) cuts"
            default: break
            }
        }
        return "\(summary(first)) and \(commands.count - 1) more"
    }
}

/// Reading edit commands sent by agents. Before decoding, commands are
/// checked against the schema (so a misspelt field is an error instead of
/// being silently ignored) and a few friendly forms are accepted:
/// times as `mm:ss.mmm` strings and ranges as `{start, end}`.
public enum CommandJSON {
    /// Keys whose values are times.
    static let timeKeys: Set<String> = [
        "at", "sourceStart", "duration", "delta", "to", "start", "end", "time", "offset",
        "fadeIn", "fadeOut", "animationDuration", "takeOffset"
    ]

    /// Free-form values that must be left exactly as they are.
    static let opaqueKeys: Set<String> = ["metadata", "values", "props", "params", "propsJSON", "tags", "fields"]

    /// `path` names the command in error messages, like `commands[2]`.
    public static func decode(_ value: JSONValue, path: String = "") throws -> EditCommand {
        let normalized = normalize(value)
        let problems = CommandSchema.validate(command: normalized, path: path)
        if !problems.isEmpty {
            throw ServiceError(.badRequest, problems.prefix(3).joined(separator: "; "))
        }
        do {
            return try normalized.decode(as: EditCommand.self)
        } catch let error as DecodingError {
            let text = DecodingErrorText.describe(error)
            throw ServiceError(.badRequest, path.isEmpty ? text : "\(path).\(text)")
        }
    }

    public static func normalize(_ value: JSONValue, key: String? = nil) -> JSONValue {
        if let key, opaqueKeys.contains(key) { return value }
        switch value {
        case .object(let fields):
            var result: [String: JSONValue] = [:]
            for (k, v) in fields { result[k] = normalize(v, key: k) }
            if key == "range", result["duration"] == nil,
               case .number(let start)? = result["start"], case .number(let end)? = result["end"] {
                result["duration"] = .number(end - start)
                result.removeValue(forKey: "end")
            }
            return .object(result)
        case .array(let items):
            return .array(items.map { normalize($0, key: key) })
        case .string(let text):
            if let key, timeKeys.contains(key), let time = TimeText.parse(text) {
                return .number(time.seconds)
            }
            return value
        default:
            return value
        }
    }
}
