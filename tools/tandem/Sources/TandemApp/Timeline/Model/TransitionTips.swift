import Foundation
import TandemCore

/// Words for a transition on the timeline: its tooltips and its drag label.
@MainActor
enum TransitionTips {
    /// "Push · 0.70 s · with A quick light swoosh", and what a drag does.
    static func body(_ id: String, in project: Project) -> String? {
        guard let (transition, track) = find(id, in: project) else { return nil }
        var lines = [summary(transition, in: project)]
        if track.locked {
            lines.append("On a locked track")
        } else if transition.fromClipID != nil && transition.toClipID != nil {
            lines.append("Drag either edge to make it longer or shorter; both sides move together")
        } else {
            lines.append("Drag its inside edge to make it longer or shorter")
        }
        return lines.joined(separator: "\n")
    }

    /// Over an edge a drag moves.
    static func edge(_ id: String, in project: Project) -> String? {
        guard let (transition, _) = find(id, in: project) else { return nil }
        let how = transition.fromClipID != nil && transition.toClipID != nil
            ? "Drag to make it longer or shorter; both sides move together, up to half of each clip"
            : "Drag to make it longer or shorter, up to half of its clip"
        return summary(transition, in: project) + "\n" + how
    }

    /// Beside the pointer while an edge is dragged: "Push · 0.80 s".
    static func dragLabel(_ id: String, length: Time, in project: Project) -> String {
        let name = find(id, in: project)?.transition.type.displayName ?? "Transition"
        return "\(name) · \(seconds(length))"
    }

    /// Its type, length and sound.
    static func summary(_ transition: Transition, in project: Project) -> String {
        var text = "\(transition.type.displayName) · \(seconds(transition.duration))"
        if let sound = transition.soundClipID.flatMap({ project.clip($0) }) {
            text += " · with \(soundName(sound, in: project))"
        }
        return text
    }

    /// A sound clip's name, readable: "A quick light swoosh sweeping from
    /// left" for the library's `a-quick-light-swoosh-sweeping-from-left--rgm8r7d7.wav`.
    static func soundName(_ clip: Clip, in project: Project) -> String {
        let words = ClipRenderer.name(of: clip, in: project)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// "0.70 s".
    static func seconds(_ time: Time) -> String {
        String(format: "%.2f s", time.seconds)
    }

    private static func find(_ id: String, in project: Project) -> (transition: Transition, track: Track)? {
        guard let location = project.location(ofTransition: id) else { return nil }
        let track = project[location.track]
        return (track.transitions[location.index], track)
    }
}
