import Foundation

public struct ValidationIssue: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning }

    public var severity: Severity
    public var message: String
    /// The clip, track, transition or media the issue is about.
    public var objectID: String?

    public init(_ severity: Severity, _ message: String, objectID: String? = nil) {
        self.severity = severity
        self.message = message
        self.objectID = objectID
    }
}

/// Checks the invariants every command must keep. The coordinator refuses a
/// batch that leaves any `.error` behind; `tandem validate` prints them all.
public enum ProjectValidator {
    public static func validate(_ p: Project) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func error(_ message: String, _ id: String? = nil) { issues.append(ValidationIssue(.error, message, objectID: id)) }
        func warning(_ message: String, _ id: String? = nil) { issues.append(ValidationIssue(.warning, message, objectID: id)) }

        if p.settings.width <= 0 || p.settings.height <= 0 { error("Canvas size must be positive.") }
        if p.settings.frameRate.numerator <= 0 || p.settings.frameRate.denominator <= 0 { error("Frame rate must be positive.") }

        // IDs are unique across the project.
        var seen = Set<String>()
        func claim(_ id: String, _ what: String) {
            if seen.contains(id) { error("Duplicate ID \(id) (\(what)).", id) }
            seen.insert(id)
        }
        for item in p.media { claim(item.id, "media") }
        for track in p.allTracks {
            claim(track.id, "track")
            for clip in track.clips { claim(clip.id, "clip") }
            for transition in track.transitions { claim(transition.id, "transition") }
        }
        for marker in p.markers { claim(marker.id, "marker") }

        let mediaByID = Dictionary(p.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let frame = p.settings.frameRate.frameDuration
        for track in p.allTracks {
            var previous: Clip?
            for clip in track.clips {
                if clip.duration <= .zero { error("Clip \(clip.id) on \"\(track.name)\" has no duration.", clip.id) }
                if clip.start < .zero { error("Clip \(clip.id) starts before 0.", clip.id) }
                if clip.speed <= 0 { error("Clip \(clip.id) has speed \(clip.speed).", clip.id) }
                if let previous {
                    if clip.start < previous.start {
                        error("Clips on \"\(track.name)\" are out of order.", clip.id)
                    } else if clip.start < previous.end {
                        error("Clips \(previous.id) and \(clip.id) overlap on \"\(track.name)\".", clip.id)
                    }
                }
                previous = clip
                if let effects = clip.video?.effects, Set(effects.map(\.id)).count != effects.count {
                    error("Clip \(clip.id) has two effects with the same ID.", clip.id)
                }
                switch clip.content {
                case .media(let mediaID):
                    guard let item = mediaByID[mediaID] else {
                        error("Clip \(clip.id) uses missing media \(mediaID).", clip.id)
                        continue
                    }
                    if track.kind == .video && !(item.hasVideo || item.kind == .image) {
                        error("Clip \(clip.id) on video track \"\(track.name)\" has no picture.", clip.id)
                    }
                    if track.kind == .audio && !item.hasAudio {
                        error("Clip \(clip.id) on audio track \"\(track.name)\" has no sound.", clip.id)
                    }
                    if item.kind != .image {
                        if clip.sourceStart < -frame {
                            error("Clip \(clip.id) starts before the beginning of \(item.path).", clip.id)
                        }
                        if let length = item.duration, clip.sourceEnd > length + frame {
                            error("Clip \(clip.id) runs past the end of \(item.path).", clip.id)
                        }
                    }
                case .text, .graphic, .solid, .adjustment:
                    if track.kind == .audio { error("Audio track \"\(track.name)\" holds a non-media clip \(clip.id).", clip.id) }
                }
                for (path, list) in clip.keyframes where list != list.sorted(by: { $0.time < $1.time }) {
                    warning("Keyframes for \(path) on clip \(clip.id) are out of order.", clip.id)
                }
            }

            var tails = Set<String>()
            var heads = Set<String>()
            let clips = Dictionary(track.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for t in track.transitions {
                if t.duration <= .zero { error("Transition \(t.id) has no duration.", t.id) }
                let from = t.fromClipID.flatMap { clips[$0] }
                let to = t.toClipID.flatMap { clips[$0] }
                if t.fromClipID == nil && t.toClipID == nil { error("Transition \(t.id) isn't attached to a clip.", t.id) }
                if t.fromClipID != nil && from == nil { error("Transition \(t.id) refers to a clip that isn't on \"\(track.name)\".", t.id) }
                if t.toClipID != nil && to == nil { error("Transition \(t.id) refers to a clip that isn't on \"\(track.name)\".", t.id) }
                if let from, let to, from.end != to.start {
                    error("Transition \(t.id) joins clips that don't meet.", t.id)
                }
                if let id = t.fromClipID {
                    if tails.contains(id) { error("Clip \(id) has two transitions at its end.", t.id) }
                    tails.insert(id)
                }
                if let id = t.toClipID {
                    if heads.contains(id) { error("Clip \(id) has two transitions at its start.", t.id) }
                    heads.insert(id)
                }
                if track.kind == .audio && t.type != .dissolve {
                    warning("Audio transitions are always crossfades; \(t.type.rawValue) plays as one.", t.id)
                }
            }
        }

        // A transition's sound is a clip on an audio track, and only its.
        let soundTies = p.allTracks.flatMap(\.transitions).filter { $0.soundClipID != nil }
        if !soundTies.isEmpty {
            let audioClips = Set(p.audioTracks.flatMap(\.clips).map(\.id))
            var sounds = Set<String>()
            for transition in soundTies {
                guard let soundID = transition.soundClipID else { continue }
                if !audioClips.contains(soundID) {
                    error("Transition \(transition.id)'s sound \(soundID) isn't a clip on an audio track.", transition.id)
                }
                if !sounds.insert(soundID).inserted {
                    error("Clip \(soundID) is the sound of two transitions.", transition.id)
                }
            }
        }

        var groups: [String: [Clip]] = [:]
        for clip in p.allTracks.flatMap(\.clips) {
            if let group = clip.linkGroup { groups[group, default: []].append(clip) }
        }
        for (group, members) in groups where members.count == 1 {
            warning("Link group \(group) has only one clip.", members[0].id)
        }
        return issues
    }
}
