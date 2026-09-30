import CoreGraphics
import Foundation
import TandemCore

/// Where a transition draws on its lane, the way Filmora draws one: a
/// see-through box over the time it plays, as wide as its length at the
/// current zoom (so dragging its edge or the inspector's slider visibly
/// widens it), centred on the cut or over its clip's head or tail. A label
/// in the middle holds its icon, and its name when that fits. All in lane
/// coordinates.
enum TransitionGeometry {
    /// The label's height at most, and its icon's side.
    static let labelHeight: CGFloat = 18
    /// The label's padding either side of its name.
    static let labelPadding: CGFloat = 5
    /// A box is never narrower than this, so it shows zoomed right out.
    static let minimumWidth: CGFloat = 2

    /// The box over the time it plays: its window's span on whole points,
    /// a point in from the lane's top and bottom. Nil when its clips aren't
    /// there or don't meet.
    static func boxRect(_ transition: Transition, on track: Track, lane: TimelineLane, scale: TimelineScale) -> CGRect? {
        guard let window = transition.window(on: track), let middle = transition.middle(on: track) else { return nil }
        var minX = settled(scale.x(window.start))
        var maxX = settled(scale.x(window.end))
        if maxX - minX < minimumWidth {
            let centre = settled(scale.x(middle))
            minX = centre - minimumWidth / 2
            maxX = centre + minimumWidth / 2
        }
        return CGRect(x: minX, y: lane.y + 1, width: maxX - minX, height: max(0, lane.height - 2))
    }

    /// Whole points, so different paintings of the same box agree.
    private static func settled(_ x: CGFloat) -> CGFloat {
        ((x * 1_000_000).rounded() / 1_000_000).rounded()
    }

    /// The label in the middle of a box: its icon, and the name beside it
    /// when both fit inside the box.
    struct Label: Equatable {
        var rect: CGRect
        var icon: CGRect
        /// Where the name starts, when it's shown.
        var nameX: CGFloat?
    }

    /// Where the label goes. A transition between two clips keeps at least
    /// its icon on the cut while its clips are wide enough, even when the
    /// box is narrower than the icon, as its chip always did, so it can
    /// still be seen and clicked zoomed out; one at a clip's head or tail
    /// shows it only inside its box. `nameWidth` is the name's width in the
    /// label's font.
    static func label(_ transition: Transition, on track: Track, lane: TimelineLane, scale: TimelineScale, nameWidth: CGFloat) -> Label? {
        guard let box = boxRect(transition, on: track, lane: lane, scale: scale), let middle = transition.middle(on: track) else { return nil }
        let room: CGFloat
        if let from = clip(transition.fromClipID, on: track), let to = clip(transition.toClipID, on: track) {
            room = min(scale.width(of: from.duration), scale.width(of: to.duration)) * 0.6
        } else {
            room = box.width - 4
        }
        let side = min(labelHeight, lane.height - 6, room).rounded(.down)
        guard side >= 10 else { return nil }
        let y: CGFloat
        switch lane.style {
        case .video, .broll:
            // Below the clips' name badges, which run along their tops.
            y = min(lane.maxY - 2 - side, max(lane.midY - side / 2, lane.y + 20)).rounded()
        default:
            y = (lane.midY - side / 2).rounded()
        }
        let centre = settled(scale.x(middle))
        let named = side + 2 + nameWidth + labelPadding
        if nameWidth > 0, named + 8 <= box.width {
            let rect = CGRect(x: (centre - named / 2).rounded(), y: y, width: named.rounded(.up), height: side)
            return Label(rect: rect, icon: CGRect(x: rect.minX, y: y, width: side, height: side), nameX: rect.minX + side + 1)
        }
        let rect = CGRect(x: (centre - side / 2).rounded(), y: y, width: side, height: side)
        return Label(rect: rect, icon: rect, nameX: nil)
    }

    /// Everything a transition paints, so a change repaints just that: its
    /// box with its outline, and its label.
    static func paintRect(_ transition: Transition, on track: Track, lane: TimelineLane, scale: TimelineScale) -> CGRect? {
        guard let box = boxRect(transition, on: track, lane: lane, scale: scale) else { return nil }
        // The widest label its box could hold, whatever its name.
        let label = TransitionGeometry.label(transition, on: track, lane: lane, scale: scale, nameWidth: 0)?.rect ?? box
        return box.union(label).insetBy(dx: -2, dy: -1)
    }

    // MARK: - Pressing it

    /// What a press on a transition does.
    enum Part: Equatable {
        /// Selects it.
        case body
        /// Drags that edge to change its length.
        case edge(ClipEdge)
    }

    /// The part of `transition` under `point`, or nil when the press is
    /// the clips': outside it, near a clip edge (for trims and rolls), or
    /// on a clip the box all but covers, which could otherwise only ever
    /// be picked as the transition. The label always selects it, and so
    /// does the label's band across the box, even over the cut in its
    /// middle. Its edges drag only when `editable` and the box is wide
    /// enough to grab them apart from the cut; zoomed out, the inspector's
    /// slider does it.
    static func part(at point: CGPoint, of transition: Transition, on track: Track, lane: TimelineLane, scale: TimelineScale, grab: CGFloat, editable: Bool) -> Part? {
        guard point.y >= lane.y, point.y < lane.maxY, let box = boxRect(transition, on: track, lane: lane, scale: scale) else { return nil }
        let label = label(transition, on: track, lane: lane, scale: scale, nameWidth: 0)?.rect
        if let label, label.contains(point) { return .body }
        // Everything else it answers to is in its box or a grab from it.
        guard point.x >= box.minX - grab, point.x <= box.maxX + grab else { return nil }
        let inLabelBand = label.map { point.y >= $0.minY && point.y < $0.maxY } ?? false
        for clip in track.clips {
            let minX = scale.x(clip.start)
            let maxX = scale.x(clip.end)
            guard maxX >= box.minX - grab, minX <= box.maxX + grab else { continue }
            let reach = TimelineHitTester.edgeReach(width: maxX - minX, grab: grab)
            for x in [minX, maxX] where abs(point.x - x) <= reach {
                let middle = x > box.minX + grab && x < box.maxX - grab
                if !(middle && inLabelBand) { return nil }
            }
            if !inLabelBand, point.x >= minX, point.x < maxX, swallows(box, minX...maxX, grab: grab) { return nil }
        }
        if showsGrips(box, grab: grab, editable: editable) {
            for edge in TransitionLength.draggableEdges(transition) {
                let x = edge == .start ? box.minX : box.maxX
                if abs(point.x - x) <= grab { return .edge(edge) }
            }
        }
        return box.contains(point) ? .body : nil
    }

    /// Whether the box covers all of a clip spanning `span` bar a sliver
    /// narrower than three grabs.
    static func swallows(_ box: CGRect, _ span: ClosedRange<CGFloat>, grab: CGFloat) -> Bool {
        let covered = min(span.upperBound, box.maxX) - max(span.lowerBound, box.minX)
        return covered > 0 && (span.upperBound - span.lowerBound) - covered < 3 * grab
    }

    /// Whether a selected transition shows grips on its edges: when a drag
    /// there changes its length (`part(at:)`).
    static func showsGrips(_ box: CGRect, grab: CGFloat, editable: Bool) -> Bool {
        editable && box.width >= 4 * grab
    }

    static func clip(_ id: String?, on track: Track) -> Clip? {
        id.flatMap { id in track.clips.first { $0.id == id } }
    }
}

/// Dragging a transition's edge changes its length. One between two clips
/// stays centred on the cut and both its sides move together, as in
/// Filmora, a whole frame at a time; one at a clip's head or tail keeps
/// its clip-edge side and moves the other.
enum TransitionLength {
    /// The edges a drag can move: both for a transition between two clips,
    /// the one inside its clip for one at a clip's head or tail.
    static func draggableEdges(_ transition: Transition) -> [ClipEdge] {
        switch (transition.fromClipID, transition.toClipID) {
        case (_?, _?): return [.start, .end]
        case (nil, _?): return [.end]
        case (_?, nil): return [.start]
        case (nil, nil): return []
        }
    }

    /// The lengths it can take on `track`: from a tenth of a second (a
    /// frame or two either side of a cut), up to half of each clip it
    /// plays over, so it never runs into a transition at a clip's other
    /// end. One already longer (the inspector allows up to its clips'
    /// whole length) can keep its length.
    static func limits(_ transition: Transition, on track: Track, rate: FrameRate) -> ClosedRange<Time>? {
        let from = TransitionGeometry.clip(transition.fromClipID, on: track)
        let to = TransitionGeometry.clip(transition.toClipID, on: track)
        let frame = rate.flicksPerFrame
        switch (from, to) {
        case let (from?, to?):
            guard from.end == to.start else { return nil }
            let lowest = Time(flicks: 2 * frames(Time(seconds: 0.05), rate) * frame)
            // Half of each clip either side of the cut, in whole frames: as
            // long as the shorter clip, a frame less when that's odd.
            let shorter = min(from.duration, to.duration)
            let whole = Time(flicks: 2 * (shorter.flicks / 2 / frame) * frame)
            let highest = max(whole, min(transition.duration, Time(flicks: 2 * shorter.flicks)))
            return lowest...max(lowest, highest)
        case let (only?, nil), let (nil, only?):
            let lowest = Time(flicks: frames(Time(seconds: 0.1), rate) * frame)
            let half = Time(flicks: (only.duration.flicks / 2 / frame) * frame)
            let highest = max(half, min(transition.duration, only.duration))
            return lowest...max(lowest, highest)
        case (nil, nil):
            return nil
        }
    }

    /// Whole frames in `time`, at least one, rounded up.
    private static func frames(_ time: Time, _ rate: FrameRate) -> Int64 {
        let perFrame = rate.flicksPerFrame
        return max(1, (time.flicks + perFrame - 1) / perFrame)
    }

    /// The length that puts the dragged `edge` at `time`, within `limits`,
    /// each side a whole number of frames.
    static func length(_ transition: Transition, on track: Track, edge: ClipEdge, at time: Time, rate: FrameRate) -> Time? {
        guard draggableEdges(transition).contains(edge), let limits = limits(transition, on: track, rate: rate) else { return nil }
        let from = TransitionGeometry.clip(transition.fromClipID, on: track)
        let to = TransitionGeometry.clip(transition.toClipID, on: track)
        let length: Time
        switch (from, to) {
        case let (from?, _?):
            let half = edge == .start ? from.end - time : time - from.end
            length = Time(flicks: 2 * half.roundedToFrame(rate).flicks)
        case let (nil, to?):
            length = (time - to.start).roundedToFrame(rate)
        case let (from?, nil):
            length = (from.end - time).roundedToFrame(rate)
        case (nil, nil):
            return nil
        }
        return min(max(length, limits.lowerBound), limits.upperBound)
    }
}
