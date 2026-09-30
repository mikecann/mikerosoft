import AppKit
import QuartzCore
import TandemCore

/// The scroll bar under the tracks (see `TimelineScroller`): it shows
/// where the lanes are in the video and where the playhead is. Drag the
/// thumb to scroll, drag its ends to zoom, click the bar to jump there
/// and double-click it to fit the whole video.
@MainActor
final class TimelineScrollerView: TimelineChildView {
    private var hovering: TimelineScroller.Part?
    private var trackingArea: NSTrackingArea?
    /// A drag in progress: which part was pressed, where, and the bar as
    /// it was then, so the mapping doesn't shift as the zoom changes.
    private var drag: (part: TimelineScroller.Part, startX: CGFloat, bar: TimelineScroller)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag to scroll the timeline, or drag either end to zoom. Click to jump there; double-click to fit the whole video."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The bar inside the view, clear of its edges.
    private var trackRect: CGRect { bounds.insetBy(dx: 4, dy: 3) }

    /// The bar for what the timeline draws now. It reads the container's
    /// copy of the model, never the model: see `TimelineDrawState`.
    private func bar() -> TimelineScroller? {
        guard let container else { return nil }
        let scale = container.drawState.scale
        return TimelineScroller(
            scrollSeconds: scale.scrollSeconds,
            visibleSeconds: Double(max(container.lanes.bounds.width, 100)) / scale.pixelsPerSecond,
            duration: container.drawState.project.duration.seconds,
            width: trackRect.width
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let started = CACurrentMediaTime()
        defer { DrawTiming.record("scroller", CACurrentMediaTime() - started) }
        guard let context = NSGraphicsContext.current?.cgContext, let bar = bar(), let container else { return }
        context.setFillColor(Theme.window.cg)
        context.fill(bounds)
        let track = trackRect
        let radius = track.height / 2
        context.setFillColor(Theme.raised.cg)
        context.addPath(CGPath(roundedRect: track, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        let active = drag != nil || hovering == .thumb || hovering == .leadingEdge || hovering == .trailingEdge
        let thumb = CGRect(x: track.minX + bar.thumbX, y: track.minY, width: bar.thumbWidth, height: track.height)
        context.setFillColor((active ? Theme.textFaint : Theme.textFainter).cg)
        context.addPath(CGPath(roundedRect: thumb, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        // Where the playhead is in the whole video.
        let tick = (track.minX + bar.x(forSeconds: container.playheadTime.seconds)).rounded()
        context.setFillColor(Theme.amber.cg)
        context.fill(CGRect(x: tick - 1, y: bounds.minY + 1, width: 2, height: bounds.height - 2))
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func x(of event: NSEvent) -> CGFloat {
        convert(event.locationInWindow, from: nil).x - trackRect.minX
    }

    override func mouseMoved(with event: NSEvent) {
        let part = bar()?.part(at: x(of: event))
        (part == .leadingEdge || part == .trailingEdge ? CursorKind.zoomEdge : .arrow).set()
        if part != hovering {
            hovering = part
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard drag == nil else { return }
        hovering = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let model = container?.model, var start = bar() else { return }
        if event.clickCount == 2 {
            model.timeline.fit(model.project.duration)
            return
        }
        let x = x(of: event)
        var part = start.part(at: x)
        if part == .track {
            // Jump there, then carry on as a drag of the thumb.
            let scroll = start.scrollSeconds(centredOn: x)
            model.timeline.scale.scrollSeconds = scroll
            start.scrollSeconds = scroll
            part = .thumb
        }
        drag = (part, x, start)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let container else { return }
        let model = container.model
        let dx = x(of: event) - drag.startX
        switch drag.part {
        case .thumb, .track:
            model.timeline.scale.scrollSeconds = drag.bar.scrollSeconds(draggedFrom: drag.bar.scrollSeconds, by: dx)
        case .leadingEdge, .trailingEdge:
            // No closer than the timeline's deepest zoom.
            let lanesWidth = Double(max(container.lanes.bounds.width, 100))
            let minimum = lanesWidth / TimelineScale.maximumPixelsPerSecond
            let range = drag.part == .leadingEdge
                ? drag.bar.range(draggingLeadingEdgeBy: dx, minimumSeconds: minimum)
                : drag.bar.range(draggingTrailingEdgeBy: dx, minimumSeconds: minimum)
            model.timeline.fitPending = false
            model.timeline.scale = TimelineScale(pixelsPerSecond: lanesWidth / (range.end - range.start), scrollSeconds: range.start)
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        container?.scrollWheel(with: event)
    }
}
