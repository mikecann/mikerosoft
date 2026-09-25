import Foundation
import TandemCore

/// Compares two cuts of the same footage, for example the decision-models
/// EDL rebuild against the imported Filmora v14 it's meant to match.
///
/// The voice is the backbone of Mike's cuts, so clips are matched on it:
/// two voice clips match when they play the same stretch of the same
/// camera file. Named anchors (section starts, given as a camera file and
/// a time in it) show where each cut puts the same words.
public struct CutComparison: Codable, Equatable, Sendable {
    public struct Side: Codable, Equatable, Sendable {
        public var name: String
        public var duration: Double
        public var videoClips: Int
        public var audioClips: Int
        public var voiceClips: Int
        /// Video transitions by type, plus "audio" for audio crossfades.
        public var transitions: [String: Int]
        public var markers: Int
    }

    /// A stretch of a camera file's voice.
    public struct VoiceClip: Codable, Equatable, Sendable {
        public var file: String
        public var sourceStart: Double
        public var sourceEnd: Double
        public var timelineStart: Double
    }

    public struct Anchor: Codable, Equatable, Sendable {
        public var name: String
        public var a: Double?
        public var b: Double?
        public var delta: Double? {
            guard let a, let b else { return nil }
            return ((a - b) * 1000).rounded() / 1000
        }
    }

    /// Where a matched voice clip sits in each cut.
    public struct Drift: Codable, Equatable, Sendable {
        public var b: Double
        public var aMinusB: Double
    }

    public var a: Side
    public var b: Side
    /// Voice clips of `b` that `a` has too, same file and source range.
    public var matchedVoice: Int
    public var voiceOnlyInA: [VoiceClip]
    public var voiceOnlyInB: [VoiceClip]
    public var drift: [Drift]
    public var anchors: [Anchor]

    /// - Parameters:
    ///   - anchors: named points as (camera file path, seconds into it).
    ///   - tolerance: how far apart two source edges can be and still match.
    public static func compare(
        _ a: Project, named nameA: String,
        _ b: Project, named nameB: String,
        anchors: [(name: String, file: String, time: Double)] = [],
        tolerance: Double = 0.04
    ) -> CutComparison {
        let voiceA = voice(in: a)
        let voiceB = voice(in: b)
        var unmatchedA = voiceA
        var matched: [(a: VoiceClip, b: VoiceClip)] = []
        var onlyB: [VoiceClip] = []
        for clip in voiceB {
            if let index = unmatchedA.firstIndex(where: {
                $0.file == clip.file && abs($0.sourceStart - clip.sourceStart) <= tolerance && abs($0.sourceEnd - clip.sourceEnd) <= tolerance
            }) {
                matched.append((unmatchedA.remove(at: index), clip))
            } else {
                onlyB.append(clip)
            }
        }
        matched.sort { $0.b.timelineStart < $1.b.timelineStart }
        let step = max(1, matched.count / 12)
        var drift = stride(from: 0, to: matched.count, by: step).map { i in
            Drift(b: round(matched[i].b.timelineStart), aMinusB: round(matched[i].a.timelineStart - matched[i].b.timelineStart))
        }
        if let last = matched.last, drift.last?.b != round(last.b.timelineStart) {
            drift.append(Drift(b: round(last.b.timelineStart), aMinusB: round(last.a.timelineStart - last.b.timelineStart)))
        }
        return CutComparison(
            a: side(a, named: nameA, voice: voiceA.count),
            b: side(b, named: nameB, voice: voiceB.count),
            matchedVoice: matched.count,
            voiceOnlyInA: unmatchedA,
            voiceOnlyInB: onlyB,
            drift: drift,
            anchors: anchors.map { anchor in
                Anchor(name: anchor.name, a: timeline(of: anchor.file, at: anchor.time, in: voiceA), b: timeline(of: anchor.file, at: anchor.time, in: voiceB))
            }
        )
    }

    /// Clips on audio tracks playing camera files: Mike's voice.
    static func voice(in project: Project) -> [VoiceClip] {
        let cameras = Dictionary(uniqueKeysWithValues: project.media.filter { $0.role == .camera }.map { ($0.id, $0.path) })
        return project.audioTracks.flatMap(\.clips).compactMap { clip in
            guard let id = clip.mediaID, let file = cameras[id] else { return nil }
            return VoiceClip(file: file, sourceStart: round(clip.sourceStart.seconds), sourceEnd: round(clip.sourceEnd.seconds), timelineStart: round(clip.start.seconds))
        }.sorted { $0.timelineStart < $1.timelineStart }
    }

    /// Where a cut plays a moment of a camera file's voice: the clip that
    /// starts nearest it (within a second), or the one playing it.
    static func timeline(of file: String, at time: Double, in voice: [VoiceClip]) -> Double? {
        let clips = voice.filter { $0.file == file }
        if let nearest = clips.min(by: { abs($0.sourceStart - time) < abs($1.sourceStart - time) }), abs(nearest.sourceStart - time) <= 1 {
            return round(nearest.timelineStart + max(0, time - nearest.sourceStart))
        }
        if let playing = clips.first(where: { $0.sourceStart <= time && time < $0.sourceEnd }) {
            return round(playing.timelineStart + time - playing.sourceStart)
        }
        return nil
    }

    static func side(_ project: Project, named name: String, voice: Int) -> Side {
        var transitions: [String: Int] = [:]
        for track in project.videoTracks {
            for transition in track.transitions { transitions[transition.type.rawValue, default: 0] += 1 }
        }
        let audio = project.audioTracks.reduce(0) { $0 + $1.transitions.count }
        if audio > 0 { transitions["audio"] = audio }
        return Side(
            name: name,
            duration: round(project.duration.seconds),
            videoClips: project.videoTracks.reduce(0) { $0 + $1.clips.count },
            audioClips: project.audioTracks.reduce(0) { $0 + $1.clips.count },
            voiceClips: voice,
            transitions: transitions,
            markers: project.markers.count
        )
    }

    static func round(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    /// A readable summary.
    public var text: String {
        func describe(_ side: Side) -> String {
            let transitions = side.transitions.keys.sorted().map { "\($0) \(side.transitions[$0]!)" }.joined(separator: ", ")
            return "\(side.name): \(Time(seconds: side.duration)) long, \(side.videoClips) video and \(side.audioClips) audio clips, \(side.voiceClips) voice clips, transitions: \(transitions.isEmpty ? "none" : transitions), \(side.markers) markers"
        }
        var lines = [describe(a), describe(b)]
        lines.append(String(format: "Duration difference: %+.3f s (%@ minus %@)", a.duration - b.duration, a.name, b.name))
        lines.append("Voice clips matching (same file and source range): \(matchedVoice) of \(b.voiceClips) in \(b.name); \(voiceOnlyInA.count) only in \(a.name), \(voiceOnlyInB.count) only in \(b.name).")
        if !drift.isEmpty {
            lines.append("Where matching clips sit (\(b.name) time: \(a.name) minus \(b.name)): " + drift.map { String(format: "%@ %+.2f", Time(seconds: $0.b).description, $0.aMinusB) }.joined(separator: ", "))
        }
        if !anchors.isEmpty {
            lines.append("Anchors:")
            for anchor in anchors {
                let at = { (value: Double?) in value.map { Time(seconds: $0).description } ?? "missing" }
                let delta = anchor.delta.map { String(format: " (%+.2f s)", $0) } ?? ""
                lines.append("- \(anchor.name): \(at(anchor.a)) vs \(at(anchor.b))\(delta)")
            }
        }
        func list(_ clips: [VoiceClip]) -> String {
            clips.prefix(12).map { "\(URL(fileURLWithPath: $0.file).lastPathComponent) \(String(format: "%.3f-%.3f", $0.sourceStart, $0.sourceEnd)) at \(Time(seconds: $0.timelineStart))" }.joined(separator: "; ")
                + (clips.count > 12 ? "; ..." : "")
        }
        if !voiceOnlyInA.isEmpty { lines.append("Only in \(a.name): " + list(voiceOnlyInA)) }
        if !voiceOnlyInB.isEmpty { lines.append("Only in \(b.name): " + list(voiceOnlyInB)) }
        return lines.joined(separator: "\n")
    }
}
