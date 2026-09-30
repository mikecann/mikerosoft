import CoreGraphics
import Foundation

/// The scroll bar under the tracks: where its thumb sits for what the
/// lanes show, and what dragging it, its ends or the bar does.
///
/// The bar stands for the video, start to end, and the thumb covers the
/// part of it on screen: the whole bar when all of it shows. Scrolled past
/// the end (the timeline goes on until the end sits mid-screen) the thumb
/// shrinks against the end of the bar. Its ends zoom, like Premiere's zoom
/// scroll bar, and the bar outside it jumps there.
struct TimelineScroller: Equatable {
    /// Seconds at the lanes' left edge.
    var scrollSeconds: Double
    /// Seconds across the lanes.
    var visibleSeconds: Double
    /// The video's length.
    var duration: Double
    /// The bar's width in points.
    var width: CGFloat

    /// Narrower than this and the thumb would be hard to grab.
    static let minimumThumb: CGFloat = 28
    /// How much of each end of the thumb zooms rather than scrolls.
    static let edgeGrab: CGFloat = 7

    /// How far right the timeline scrolls: until the end of the video is in
    /// the middle of the lanes, as `TimelineContainerView` allows.
    var maxScrollSeconds: Double { Self.maxScrollSeconds(duration: duration, visibleSeconds: visibleSeconds) }

    static func maxScrollSeconds(duration: Double, visibleSeconds: Double) -> Double {
        max(0, duration - visibleSeconds * 0.5)
    }

    /// The seconds the bar stands for: the video's length.
    var span: Double { max(duration, 0.001) }

    var canScroll: Bool { maxScrollSeconds > 0.0001 }

    /// The thumb's left edge and width: the part of the video on screen,
    /// widened to `minimumThumb` about its middle when that's narrower.
    private var thumb: (x: CGFloat, width: CGFloat) {
        guard width > 0 else { return (0, 0) }
        let left = x(forSeconds: scrollSeconds)
        let right = x(forSeconds: scrollSeconds + visibleSeconds)
        let size = min(width, max(Self.minimumThumb, right - left))
        let x = min(max(0, (left + right) / 2 - size / 2), width - size)
        return (x, size)
    }

    var thumbX: CGFloat { thumb.x }
    var thumbWidth: CGFloat { thumb.width }

    /// Where a time sits along the bar, for the thumb and the playhead's
    /// tick.
    func x(forSeconds seconds: Double) -> CGFloat {
        width * CGFloat(min(max(seconds / span, 0), 1))
    }

    enum Part: Equatable { case leadingEdge, trailingEdge, thumb, track }

    func part(at x: CGFloat) -> Part {
        let left = thumbX
        let right = thumbX + thumbWidth
        guard x >= left, x <= right else { return .track }
        // A small thumb keeps its middle third for dragging.
        let grab = min(Self.edgeGrab, thumbWidth / 3)
        if x < left + grab { return .leadingEdge }
        if x > right - grab { return .trailingEdge }
        return .thumb
    }

    /// The scroll position after dragging the thumb `dx` points from where
    /// it was at `startScroll`.
    func scrollSeconds(draggedFrom startScroll: Double, by dx: CGFloat) -> Double {
        guard canScroll else { return startScroll }
        return clampScroll(startScroll + seconds(forPoints: dx))
    }

    /// The scroll position that puts the time at `x` in the middle of the
    /// lanes, for a click on the bar.
    func scrollSeconds(centredOn x: CGFloat) -> Double {
        guard canScroll else { return scrollSeconds }
        return clampScroll(seconds(forPoints: x) - visibleSeconds / 2)
    }

    /// What's on screen after dragging the thumb's leading end `dx` points:
    /// the end time stays, the start moves.
    func range(draggingLeadingEdgeBy dx: CGFloat, minimumSeconds: Double) -> (start: Double, end: Double) {
        let end = scrollSeconds + visibleSeconds
        let start = scrollSeconds + seconds(forPoints: dx)
        return (min(max(0, start), end - minimumSeconds), end)
    }

    /// What's on screen after dragging the thumb's trailing end `dx`
    /// points: the start time stays, and the end moves from where the
    /// thumb shows it (the end of the video when the lanes run past it).
    func range(draggingTrailingEdgeBy dx: CGFloat, minimumSeconds: Double) -> (start: Double, end: Double) {
        let shown = min(scrollSeconds + visibleSeconds, span)
        let end = shown + seconds(forPoints: dx)
        return (scrollSeconds, max(end, scrollSeconds + minimumSeconds))
    }

    private func clampScroll(_ seconds: Double) -> Double {
        min(max(0, seconds), maxScrollSeconds)
    }

    /// A distance along the bar as seconds of the video.
    private func seconds(forPoints points: CGFloat) -> Double {
        width > 0 ? Double(points / width) * span : 0
    }
}
