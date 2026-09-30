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
    /// An edge of a transition's box: drag to change its length.
    case transitionEdge(transitionID: String, trackID: String, edge: ClipEdge)
    case emptyTrack(trackID: String, time: Time)
    case transcript(time: Time)
    case nothing

    var clipID: String? {
        if case .clip(let id, _, _) = self { return id }
        return nil
    }

    var trackID: String? {
        switch self {
        case .clip(_, let track, _), .transition(_, let track), .transitionEdge(_, let track, _), .emptyTrack(let track, _): return track
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

    /// With `transitions` false, what's under a transition's box: a clip
    /// for an effect or a look dropped there.
    func hit(_ point: CGPoint, transitions: Bool = true) -> TimelineHit {
        guard let lane = layout.lane(atY: point.y) else { return .nothing }
        let rate = project.settings.frameRate
        guard let trackID = lane.trackID, let track = project.track(trackID) else {
            return .transcript(time: scale.time(atX: point.x, rate: rate))
        }
        for transition in track.transitions where transitions {
            switch TransitionGeometry.part(at: point, of: transition, on: track, lane: lane, scale: scale, grab: edgeGrab, editable: !track.locked) {
            case .body?: return .transition(transitionID: transition.id, trackID: trackID)
            case .edge(let edge)?: return .transitionEdge(transitionID: transition.id, trackID: trackID, edge: edge)
            case nil: continue
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
            let grab = Self.edgeReach(width: maxX - minX, grab: edgeGrab)
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

    /// How near its edges a clip `width` points wide trims: `grab`, but a
    /// third of the clip at most, so a short clip keeps a body to grab.
    static func edgeReach(width: CGFloat, grab: CGFloat) -> CGFloat {
        min(grab, max(2, width / 3))
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
