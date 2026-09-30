import AppKit
import QuartzCore
import TandemCore

/// The ruler's band over agent changes waiting for review: a faint wash
/// over each stretch with changes in it, a strip along the top for each
/// change, stronger where they pile up so a music bed changed end to end
/// doesn't hide the shots over it, and a wedge at each place Next agent
/// change stops. All of it stays clear of the markers, labels and in to
/// out range.
enum ReviewBand {
    static let stripHeight: CGFloat = 3
    /// A removal on its own is a moment; it still gets a band to see and
    /// hover.
    static let minimumWidth: CGFloat = 6
    static let wedgeWidth: CGFloat = 8
    static let wedgeHeight: CGFloat = 5

    /// Where a stretch of time's band is, in the ruler's x.
    static func span(from start: Time, to end: Time, scale: TimelineScale) -> ClosedRange<CGFloat> {
        let x0 = scale.x(start)
        let x1 = scale.x(end)
        guard x1 - x0 < minimumWidth else { return x0...x1 }
        let middle = (x0 + x1) / 2
        return (middle - minimumWidth / 2)...(middle + minimumWidth / 2)
    }

    static func draw(_ review: TimelineReview, scale: TimelineScale, in bounds: CGRect, context: CGContext) {
        func visible(_ span: ClosedRange<CGFloat>) -> Bool { span.upperBound >= 0 && span.lowerBound <= bounds.width }
        context.setFillColor(Theme.agent.opacity(0.07).cg)
        for region in review.regions {
            let span = span(from: region.start, to: region.end, scale: scale)
            guard visible(span) else { continue }
            context.fill(CGRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: bounds.height))
        }
        context.setFillColor(Theme.agent.opacity(0.45).cg)
        for change in review.spans {
            let span = span(from: change.start, to: change.end, scale: scale)
            guard visible(span) else { continue }
            context.fill(CGRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: stripHeight))
        }
        context.setFillColor(Theme.agent.cg)
        for stop in review.stops {
            let x = scale.x(stop.time)
            guard x >= -wedgeWidth, x <= bounds.width + wedgeWidth else { continue }
            let wedge = CGMutablePath()
            wedge.move(to: CGPoint(x: x - wedgeWidth / 2, y: 0))
            wedge.addLine(to: CGPoint(x: x + wedgeWidth / 2, y: 0))
            wedge.addLine(to: CGPoint(x: x, y: wedgeHeight))
            wedge.closeSubpath()
            context.addPath(wedge)
        }
        context.fillPath()
    }
}

/// Violet marks over the lanes for agent changes waiting for review: a
/// tint and outline on each changed clip and transition, and a notch at
/// each join where something was taken out.
///
/// The marks are views inside `content`, placed at content coordinates (x
/// is seconds times pixels a second, y down from the top of the tracks)
/// and scrolled by moving `content`'s bounds, so a scroll moves them all
/// at once and nothing draws. They're only placed again when the changes,
/// the clips, the zoom or the lanes change. The lanes' tiles never repaint
/// for them.
@MainActor
final class ReviewOverlayView: NSView {
    weak var container: TimelineContainerView?
    private let content = ReviewMarksContent()
    private var boxes: [NSView] = []
    private var notches: [RemovalNotchView] = []
    /// What the marks were placed for.
    private var placedFor: Placement?

    private struct Placement: Equatable {
        var review: TimelineReview
        var revision: Int
        var pixelsPerSecond: Double
        var layout: TimelineLayout
        /// A drag's preview, which moves clips without a new revision.
        var preview: Project?
    }

    static let notchWidth: CGFloat = 9

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        content.wantsLayer = true
        addSubview(content)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Clicks and drags belong to the lanes underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        if content.frame.size != bounds.size { content.frame = CGRect(origin: .zero, size: bounds.size) }
        update()
    }

    /// Catches up with the container: places the marks again when what
    /// they show moved, and scrolls them with the lanes.
    func update() {
        guard let container else { return }
        let state = container.drawState
        let review = state.review
        guard !review.clipIDs.isEmpty || !review.transitionIDs.isEmpty || !review.removals.isEmpty else {
            if !isHidden { isHidden = true }
            placedFor = nil
            return
        }
        let placement = Placement(
            review: review, revision: state.revision, pixelsPerSecond: state.scale.pixelsPerSecond,
            layout: container.layoutCache, preview: container.lanes.previewProject
        )
        if placement != placedFor {
            let started = CACurrentMediaTime()
            place(review, in: container.displayedProject, layout: container.layoutCache, pixelsPerSecond: state.scale.pixelsPerSecond)
            placedFor = placement
            DrawTiming.record("review marks", CACurrentMediaTime() - started)
        }
        let origin = container.contentOrigin
        if content.bounds.origin != origin { content.setBoundsOrigin(origin) }
        if isHidden { isHidden = false }
    }

    /// Where the marks go, in content coordinates.
    private func place(_ review: TimelineReview, in project: Project, layout: TimelineLayout, pixelsPerSecond: Double) {
        func x(_ time: Time) -> CGFloat { CGFloat(time.seconds * pixelsPerSecond) }
        var boxFrames: [CGRect] = []
        var notchFrames: [CGRect] = []
        for lane in layout.lanes {
            guard let trackID = lane.trackID, let track = project.track(trackID) else { continue }
            for clip in track.clips where review.clipIDs.contains(clip.id) {
                let full = CGRect(x: x(clip.start), y: lane.y, width: max(1, x(clip.end) - x(clip.start)), height: lane.height)
                boxFrames.append(Self.box(inside: ClipRenderer.drawnRect(full)))
            }
            for transition in track.transitions where review.transitionIDs.contains(transition.id) {
                guard let span = Self.span(of: transition, on: track) else { continue }
                boxFrames.append(Self.box(inside: CGRect(x: x(span.start), y: lane.y, width: max(1, x(span.end) - x(span.start)), height: lane.height)))
            }
            for removal in review.removals where removal.trackID == trackID {
                notchFrames.append(CGRect(x: (x(removal.time) - Self.notchWidth / 2).rounded(), y: lane.y, width: Self.notchWidth, height: lane.height))
            }
        }
        show(boxFrames, in: &boxes, make: Self.makeBox)
        show(notchFrames, in: &notches) { RemovalNotchView() }
    }

    /// A mark sits just inside the clip, so a selected clip's amber
    /// outline still shows around it. Slivers get a plain bar.
    private static func box(inside rect: CGRect) -> CGRect {
        guard rect.width >= 10 else { return CGRect(x: rect.midX - max(rect.width, 3) / 2, y: rect.minY, width: max(rect.width, 3), height: rect.height) }
        return rect.insetBy(dx: 2, dy: 2)
    }

    private static func makeBox() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.agent.opacity(0.14).cg
        view.layer?.borderColor = Theme.agent.opacity(0.95).cg
        view.layer?.borderWidth = 1.5
        view.layer?.cornerRadius = 3
        return view
    }

    /// Reuses the views there are, adds what's missing and hides the rest.
    private func show<View: NSView>(_ frames: [CGRect], in views: inout [View], make: () -> View) {
        while views.count < frames.count {
            let view = make()
            content.addSubview(view)
            views.append(view)
        }
        for (index, view) in views.enumerated() {
            guard index < frames.count else {
                if !view.isHidden { view.isHidden = true }
                continue
            }
            if view.frame != frames[index] { view.frame = frames[index] }
            if view.isHidden { view.isHidden = false }
        }
    }

    /// The time a transition plays over: centred on its cut, or at the
    /// head or tail it fades.
    private static func span(of transition: Transition, on track: Track) -> (start: Time, end: Time)? {
        let from = transition.fromClipID.flatMap { id in track.clips.first { $0.id == id } }
        let to = transition.toClipID.flatMap { id in track.clips.first { $0.id == id } }
        switch (from, to) {
        case let (from?, _?):
            let start = from.end - Time(flicks: transition.duration.flicks / 2)
            return (start, start + transition.duration)
        case let (from?, nil):
            return (from.end - transition.duration, from.end)
        case let (nil, to?):
            return (to.start, to.start + transition.duration)
        case (nil, nil):
            return nil
        }
    }

    /// Where the marks show, in this view's coordinates, for tests.
    var shownFrames: (boxes: [CGRect], notches: [CGRect]) {
        func frames(_ views: [NSView]) -> [CGRect] {
            views.filter { !$0.isHidden }.map { content.convert($0.frame, to: self) }
        }
        return (frames(boxes), frames(notches))
    }
}

/// What the review marks sit in: flipped, so they run down from the top like
/// the lanes.
final class ReviewMarksContent: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// "Removed here": a line down the lane at the join with a wedge on top
/// pointing at it.
final class RemovalNotchView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let middle = bounds.midX
        context.setFillColor(Theme.agent.opacity(0.85).cg)
        context.fill(CGRect(x: middle - 0.75, y: 0, width: 1.5, height: bounds.height))
        context.setFillColor(Theme.agent.cg)
        let wedge = CGMutablePath()
        wedge.move(to: CGPoint(x: middle - bounds.width / 2, y: 0))
        wedge.addLine(to: CGPoint(x: middle + bounds.width / 2, y: 0))
        wedge.addLine(to: CGPoint(x: middle, y: 6))
        wedge.closeSubpath()
        context.addPath(wedge)
        context.fillPath()
    }
}
