import CoreGraphics
import Foundation
import TandemCore

/// Which part of a clip the pointer is over.
enum ClipPart: Equatable {
    case body
    /// The start edge.
    case head
    /// The end edge.
    case tail
}

/// What sits under a point in the lanes.
enum TimelineHit: Equatable {
    case clip(clipID: String, trackID: String, part: ClipPart)
    case transition(transitionID: String, trackID: String)
    case emptyTrack(trackID: String, time: Time)
    case transcript(time: Time)
    case nothing

    var clipID: String? {
        if case .clip(let id, _, _) = self { return id }
        return nil
    }

    var trackID: String? {
        switch self {
        case .clip(_, let track, _), .transition(_, let track), .emptyTrack(let track, _): return track
        case .transcript, .nothing: return nil
        }
    }
}

/// Finds what's under the pointer. Points are in lane coordinates: `x` from
/// the left edge of the lanes, `y` from the top of the tracks area
/// (including any vertical scroll).
struct TimelineHitTester {
    var project: Project
    var layout: TimelineLayout
    var scale: TimelineScale
    var edgeGrab: CGFloat = Theme.Metrics.edgeGrab

    func hit(_ point: CGPoint) -> TimelineHit {
        guard let lane = layout.lane(atY: point.y) else { return .nothing }
        let rate = project.settings.frameRate
        guard let trackID = lane.trackID, let track = project.track(trackID) else {
            return .transcript(time: scale.time(atX: point.x, rate: rate))
        }
        for transition in track.transitions {
            if let rect = TransitionGeometry.hitRect(transition, on: track, lane: lane, scale: scale), rect.contains(point) {
                return .transition(transitionID: transition.id, trackID: trackID)
            }
        }
        if let (clip, part) = clipAndPart(on: track, x: point.x) {
            return .clip(clipID: clip.id, trackID: trackID, part: part)
        }
        return .emptyTrack(trackID: trackID, time: scale.time(atX: point.x, rate: rate))
    }

    /// The clip under `x` and the part of it, preferring an edge within
    /// `edgeGrab` pixels. An edge can be grabbed from just outside the clip
    /// too, which makes short clips trimmable.
    func clipAndPart(on track: Track, x: CGFloat) -> (Clip, ClipPart)? {
        var nearestEdge: (clip: Clip, part: ClipPart, distance: CGFloat)?
        var body: Clip?
        for clip in track.clips {
            let minX = scale.x(clip.start)
            let maxX = scale.x(clip.end)
            if maxX < x - edgeGrab { continue }
            if minX > x + edgeGrab { break }
            if x >= minX && x < maxX { body = clip }
            // A third of the clip at most, so a short clip keeps a body to grab.
            let grab = min(edgeGrab, max(2, (maxX - minX) / 3))
            let headDistance = abs(x - minX)
            let tailDistance = abs(x - maxX)
            if headDistance <= grab, nearestEdge == nil || headDistance < nearestEdge!.distance || (headDistance == nearestEdge!.distance && x >= minX) {
                nearestEdge = (clip, .head, headDistance)
            }
            if tailDistance <= grab, nearestEdge == nil || tailDistance < nearestEdge!.distance || (tailDistance == nearestEdge!.distance && x < maxX) {
                nearestEdge = (clip, .tail, tailDistance)
            }
        }
        if let edge = nearestEdge { return (edge.clip, edge.part) }
        if let body { return (body, .body) }
        return nil
    }

    /// The rectangle a clip occupies, in lane coordinates.
    func rect(of clip: Clip, in lane: TimelineLane) -> CGRect {
        let minX = scale.x(clip.start)
        return CGRect(x: minX, y: lane.y, width: max(1, scale.x(clip.end) - minX), height: lane.height)
    }

    /// Clips whose rectangles touch `rect` (a marquee), in timeline order.
    func clips(in rect: CGRect) -> [String] {
        var ids: [String] = []
        for lane in layout.lanes {
            guard let trackID = lane.trackID, let track = project.track(trackID) else { continue }
            guard lane.maxY > rect.minY && lane.y < rect.maxY else { continue }
            for clip in track.clips where self.rect(of: clip, in: lane).intersects(rect) {
                ids.append(clip.id)
            }
        }
        return ids
    }
}

/// Where transitions draw: a chip centred on the cut (or on the clip's
/// head or tail), widened to the transition's length when zoomed in.
enum TransitionGeometry {
    static let chipSize: CGFloat = 24

    /// The timeline range a transition covers.
    static func range(_ transition: Transition, on track: Track) -> TimeRange? {
        let from = transition.fromClipID.flatMap { id in track.clips.first { $0.id == id } }
        let to = transition.toClipID.flatMap { id in track.clips.first { $0.id == id } }
        let half = Time(flicks: transition.duration.flicks / 2)
        switch (from, to) {
        case (let from?, _?):
            return TimeRange(start: from.end - half, duration: transition.duration)
        case (let from?, nil):
            return TimeRange(start: from.end - transition.duration, duration: transition.duration)
        case (nil, let to?):
            return TimeRange(start: to.start, duration: transition.duration)
        case (nil, nil):
            return nil
        }
    }

    /// The span band, in lane coordinates.
    static func bandRect(_ transition: Transition, on track: Track, lane: TimelineLane, scale: TimelineScale) -> CGRect? {
        guard let range = range(transition, on: track) else { return nil }
        let minX = scale.x(range.start)
        return CGRect(x: minX, y: lane.y, width: scale.x(range.end) - minX, height: lane.height)
    }

    /// The chip on a cut between two clips, in lane coordinates. It shrinks
    /// with the clips beside it so a zoomed-out timeline isn't all chips,
    /// and there's none for one-sided transitions (they draw as a ramp).
    static func chipRect(_ transition: Transition, on track: Track, lane: TimelineLane, scale: TimelineScale) -> CGRect? {
        guard let fromID = transition.fromClipID, let toID = transition.toClipID,
              let from = track.clips.first(where: { $0.id == fromID }),
              let to = track.clips.first(where: { $0.id == toID }) else { return nil }
        let narrowest = min(scale.width(of: from.duration), scale.width(of: to.duration))
        let size = min(chipSize, lane.height - 4, (narrowest * 0.6).rounded())
        guard size >= 10 else { return nil }
        let centreX = scale.x(from.end)
        return CGRect(x: centreX - size / 2, y: lane.midY - size / 2, width: size, height: size)
    }

    /// Where a click selects the transition: the chip, or the band for
    /// one-sided transitions and chips too small to draw.
    static func hitRect(_ transition: Transition, on track: Track, lane: TimelineLane, scale: TimelineScale) -> CGRect? {
        if let chip = chipRect(transition, on: track, lane: lane, scale: scale) { return chip }
        guard transition.fromClipID == nil || transition.toClipID == nil,
              let band = bandRect(transition, on: track, lane: lane, scale: scale), band.width >= 6 else { return nil }
        return band.insetBy(dx: 0, dy: lane.height * 0.25)
    }
}
