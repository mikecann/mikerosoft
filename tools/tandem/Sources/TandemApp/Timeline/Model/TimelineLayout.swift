import CoreGraphics
import Foundation
import TandemCore

/// What a lane holds, which sets its height and colours.
enum LaneStyle: Equatable {
    case transcript
    case text
    case graphics
    case video
    case broll
    case voice
    case music
    case sfx
    case audio

    /// Guesses a track's style from its kind and name. Mike's standard
    /// project names its tracks Screen, Camera, B-roll, Graphics, Text,
    /// Voice, Music and SFX.
    static func of(_ track: Track) -> LaneStyle {
        let name = track.name.lowercased()
        switch track.kind {
        case .video:
            if name.contains("text") || name.contains("title") || name.contains("caption") { return .text }
            if name.contains("graphic") || name.contains("sticker") { return .graphics }
            if name.contains("b-roll") || name.contains("broll") { return .broll }
            return .video
        case .audio:
            if name.contains("voice") || name.contains("dialog") || name.contains("vo") { return .voice }
            if name.contains("music") { return .music }
            if name.contains("sfx") || name.contains("effect") || name.contains("sound") { return .sfx }
            return .audio
        }
    }

    var defaultHeight: CGFloat {
        switch self {
        case .transcript: return Theme.TrackHeight.transcript
        case .text: return Theme.TrackHeight.text
        case .graphics: return Theme.TrackHeight.graphics
        case .video: return Theme.TrackHeight.video
        case .broll: return Theme.TrackHeight.broll
        case .voice: return Theme.TrackHeight.voice
        case .music: return Theme.TrackHeight.music
        case .sfx: return Theme.TrackHeight.sfx
        case .audio: return Theme.TrackHeight.audio
        }
    }
}

/// One horizontal lane of the timeline: the transcript or a track.
struct TimelineLane: Equatable {
    /// Nil for the transcript lane.
    var trackID: String?
    var kind: TrackKind?
    var style: LaneStyle
    /// Top edge, measured down from the top of the tracks area.
    var y: CGFloat
    var height: CGFloat

    var maxY: CGFloat { y + height }
    var midY: CGFloat { y + height / 2 }
    var isTranscript: Bool { trackID == nil }

    func contains(y value: CGFloat) -> Bool {
        value >= y && value < maxY
    }
}

/// Where every lane sits, top to bottom: the transcript lane, then video
/// tracks with the highest first (the one that draws on top), then audio
/// tracks in order.
struct TimelineLayout: Equatable {
    var lanes: [TimelineLane]
    var contentHeight: CGFloat

    static func make(
        project: Project,
        showTranscript: Bool,
        heightOverrides: [String: CGFloat] = [:],
        topPadding: CGFloat = Theme.Metrics.tracksTopPadding,
        gap: CGFloat = Theme.Metrics.trackGap
    ) -> TimelineLayout {
        var lanes: [TimelineLane] = []
        var y = topPadding
        func add(_ lane: TimelineLane) {
            var lane = lane
            lane.y = y
            lanes.append(lane)
            y += lane.height + gap
        }
        if showTranscript {
            add(TimelineLane(trackID: nil, kind: nil, style: .transcript, y: 0, height: LaneStyle.transcript.defaultHeight))
        }
        for track in project.videoTracks.reversed() + project.audioTracks {
            let style = LaneStyle.of(track)
            let height = heightOverrides[track.id] ?? style.defaultHeight
            add(TimelineLane(trackID: track.id, kind: track.kind, style: style, y: 0, height: height))
        }
        return TimelineLayout(lanes: lanes, contentHeight: y)
    }

    func lane(atY y: CGFloat) -> TimelineLane? {
        lanes.first { $0.contains(y: y) }
    }

    /// The lane under `y`, or the nearest one when `y` falls in a gap or
    /// past either end. Drags use this so the pointer never "falls off".
    func nearestTrackLane(toY y: CGFloat, kind: TrackKind? = nil) -> TimelineLane? {
        let candidates = lanes.filter { $0.trackID != nil && (kind == nil || $0.kind == kind) }
        if let exact = candidates.first(where: { $0.contains(y: y) }) { return exact }
        return candidates.min { abs($0.midY - y) < abs($1.midY - y) }
    }

    func lane(forTrack id: String) -> TimelineLane? {
        lanes.first { $0.trackID == id }
    }

    /// The track `offset` lanes away from `trackID` among tracks of the same
    /// kind, in on-screen order. Positive moves down the screen. Clamped.
    func track(_ trackID: String, offsetBy offset: Int) -> String? {
        guard let lane = lane(forTrack: trackID) else { return nil }
        let sameKind = lanes.filter { $0.kind == lane.kind && $0.trackID != nil }
        guard let index = sameKind.firstIndex(where: { $0.trackID == trackID }) else { return nil }
        let target = min(max(index + offset, 0), sameKind.count - 1)
        return sameKind[target].trackID
    }

    /// The on-screen position of a track among lanes of its kind.
    func order(of trackID: String) -> Int? {
        guard let lane = lane(forTrack: trackID) else { return nil }
        return lanes.filter { $0.kind == lane.kind && $0.trackID != nil }.firstIndex { $0.trackID == trackID }
    }
}
