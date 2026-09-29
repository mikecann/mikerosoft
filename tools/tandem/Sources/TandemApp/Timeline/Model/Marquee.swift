import CoreGraphics
import Foundation
import TandemCore

/// A selection box being dragged over the lanes.
///
/// It works out what it would select on every move but leaves the model's
/// selection alone until the mouse comes up. A selection change redraws the
/// inspector and lays out the window again (about 16 ms on a real project),
/// far too slow to do on every mouse move. The corner the drag started from
/// is pinned to a time, so the box stays on its clips while the timeline
/// autoscrolls under it.
struct Marquee: Equatable {
    /// Where the drag started: a time, and a y in lane coordinates.
    var startSeconds: Double
    var startY: CGFloat
    /// The pointer, in lane coordinates.
    var end: CGPoint
    /// What the box adds to: the selection when Shift or Cmd was held.
    var base: Set<String>
    var modifiers: SelectionRules.Modifiers
    /// The clips the box selects as it stands.
    private(set) var selection: Set<String>

    init(at point: CGPoint, scale: TimelineScale, base: Set<String>, modifiers: SelectionRules.Modifiers) {
        startSeconds = scale.seconds(atX: point.x)
        startY = point.y
        end = point
        self.base = base
        self.modifiers = modifiers
        selection = base
    }

    /// The box in lane coordinates at the current scroll and zoom.
    func rect(scale: TimelineScale) -> CGRect {
        let startX = scale.x(seconds: startSeconds)
        return CGRect(x: min(startX, end.x), y: min(startY, end.y), width: abs(end.x - startX), height: abs(end.y - startY))
    }

    /// Where a click (a box that never grew) puts the playhead.
    func startTime(rate: FrameRate) -> Time {
        max(.zero, Time(seconds: startSeconds).roundedToFrame(rate))
    }

    /// Moves the pointer's corner to `point`. True when that changed which
    /// clips are selected, so the lanes need drawing again.
    mutating func move(to point: CGPoint, tester: TimelineHitTester, linkedSelection: Bool) -> Bool {
        end = point
        let ids = tester.clips(in: rect(scale: tester.scale))
        let next = SelectionRules.marquee(ids, in: tester.project, current: base, modifiers: modifiers, linkedSelection: linkedSelection)
        guard next != selection else { return false }
        selection = next
        return true
    }
}

/// A middle-button drag of the timeline. What's under the pointer stays
/// under it, like pushing a sheet of paper about: time scrolls sideways,
/// and the tracks scroll up and down when they don't all fit.
struct TimelinePan: Equatable {
    /// Where the drag started, in the timeline's (flipped) coordinates.
    var start: CGPoint
    var scrollSeconds: Double
    var verticalOffset: CGFloat

    /// The scroll and track offset with the pointer at `point`. Time stops
    /// at 0 and at `maxScrollSeconds` (or wherever it already was, if that's
    /// further, so the first move doesn't jump), the tracks at their ends.
    func offsets(at point: CGPoint, pixelsPerSecond: Double, maxScrollSeconds: Double, maxVerticalOffset: CGFloat) -> (scrollSeconds: Double, verticalOffset: CGFloat) {
        let seconds = scrollSeconds - Double(point.x - start.x) / pixelsPerSecond
        let offset = verticalOffset - (point.y - start.y)
        let lastSecond = max(maxScrollSeconds, scrollSeconds, 0)
        return (min(max(seconds, 0), lastSecond), min(max(offset, 0), max(maxVerticalOffset, 0)))
    }
}
