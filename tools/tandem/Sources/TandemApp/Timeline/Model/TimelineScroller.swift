import CoreGraphics
import Foundation

/// The scroll bar under the tracks: where its thumb sits for what the
/// lanes show, and what dragging it, its ends or the bar does.
///
/// The bar stands for everything the timeline scrolls across: from the
/// start to where the end of the video sits in the middle of the lanes.
/// The thumb covers what's on screen. Its ends zoom, like Premiere's zoom
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

    /// Everything the bar stands for, in seconds.
    var span: Double { max(maxScrollSeconds + visibleSeconds, 0.001) }

    var canScroll: Bool { maxScrollSeconds > 0.0001 }

    var thumbWidth: CGFloat {
        guard width > 0 else { return 0 }
        guard canScroll else { return width }
        return min(width, max(Self.minimumThumb, width * CGFloat(visibleSeconds / span)))
    }

    /// The thumb's left edge.
    var thumbX: CGFloat {
        guard canScroll else { return 0 }
        return (width - thumbWidth) * CGFloat(min(max(scrollSeconds / maxScrollSeconds, 0), 1))
    }

    /// Where a time sits along the bar, for the playhead's tick.
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
        let travel = width - thumbWidth
        guard travel > 0, canScroll else { return startScroll }
        let seconds = startScroll + Double(dx / travel) * maxScrollSeconds
        return min(max(0, seconds), maxScrollSeconds)
    }

    /// The scroll position that centres the thumb on `x`, for a click on
    /// the bar.
    func scrollSeconds(centredOn x: CGFloat) -> Double {
        let travel = width - thumbWidth
        guard travel > 0, canScroll else { return scrollSeconds }
        let seconds = Double((x - thumbWidth / 2) / travel) * maxScrollSeconds
        return min(max(0, seconds), maxScrollSeconds)
    }

    /// What's on screen after dragging the thumb's leading end `dx` points:
    /// the end time stays, the start moves.
    func range(draggingLeadingEdgeBy dx: CGFloat, minimumSeconds: Double) -> (start: Double, end: Double) {
        let end = scrollSeconds + visibleSeconds
        let start = scrollSeconds + seconds(forPoints: dx)
        return (min(max(0, start), end - minimumSeconds), end)
    }

    /// What's on screen after dragging the thumb's trailing end `dx`
    /// points: the start time stays, the end moves.
    func range(draggingTrailingEdgeBy dx: CGFloat, minimumSeconds: Double) -> (start: Double, end: Double) {
        let end = scrollSeconds + visibleSeconds + seconds(forPoints: dx)
        return (scrollSeconds, max(end, scrollSeconds + minimumSeconds))
    }

    /// A distance along the bar as seconds of the timeline.
    private func seconds(forPoints points: CGFloat) -> Double {
        width > 0 ? Double(points / width) * span : 0
    }
}
