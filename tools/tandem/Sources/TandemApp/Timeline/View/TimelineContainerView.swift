import AppKit
import TandemCore

/// The timeline: ruler on top, track headers on the left, lanes filling the
/// rest, and the playhead over both. Layer-backed AppKit throughout; it
/// redraws when the model changes and moves only the playhead view while
/// playing.
@MainActor
final class TimelineContainerView: NSView {
    let model: EditorModel
    let ruler = TimelineRulerView()
    let headers = TimelineHeaderView()
    let lanes = TimelineLanesView()
    let corner = TimelineCornerView()
    private let playheadView = PlayheadView()
    private(set) var artwork: MediaArtwork
    private var loops: [ObservationLoop] = []
    /// The lane layout for the project being shown (which may be a drag
    /// preview).
    private(set) var layoutCache: TimelineLayout

    init(model: EditorModel) {
        self.model = model
        self.artwork = MediaArtwork(analysis: model.session.analysis)
        self.layoutCache = TimelineLayout.make(project: model.project, showTranscript: model.showTranscript, heightOverrides: model.timeline.trackHeights)
        super.init(frame: NSRect(x: 0, y: 0, width: 1_200, height: 320))
        wantsLayer = true
        // Since macOS 14 views don't clip drawing to their bounds by
        // default, and a dirty rect can reach past them. The timeline
        // fills its dirty rects, so it has to clip.
        clipsToBounds = true
        layer?.backgroundColor = Theme.window.cg
        for view in [ruler, headers, lanes, corner] as [TimelineChildView] {
            view.container = self
            addSubview(view)
        }
        addSubview(playheadView)
        model.timeline.playheadX = { [weak self] in
            guard let self else { return nil }
            return self.model.timeline.scale.x(self.model.playback.time)
        }
        loops.append(ObservationLoop(read: { [weak self] in self?.readDrawingState() }, onChange: { [weak self] in self?.modelChanged() }))
        loops.append(ObservationLoop(read: { [weak self] in _ = self?.model.playback.time }, onChange: { [weak self] in self?.playheadMoved() }))
        // New thumbnails, waveforms or transcripts: look again and redraw.
        // Job progress alone doesn't redraw the timeline.
        artwork.onDecoded = { [weak self] in self?.setAllNeedsDisplay() }
        loops.append(ObservationLoop(read: { [weak self] in _ = self?.model.artworkRevision }, onChange: { [weak self] in
            self?.artwork.invalidate()
            self?.setAllNeedsDisplay()
        }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        MainActor.assumeIsolated {
            for loop in loops { loop.cancel() }
        }
    }

    override var isFlipped: Bool { true }

    /// Touches everything the timeline draws, so the observation loop knows
    /// what to watch.
    private func readDrawingState() {
        _ = model.project
        _ = model.selection
        _ = model.selectedTransitionID
        _ = model.inPoint
        _ = model.outPoint
        _ = model.showTranscript
        _ = model.tool
        _ = model.linkedSelection
        _ = model.timeline.scale
        _ = model.timeline.verticalOffset
        _ = model.timeline.trackHeights
        _ = model.draggedMediaIDs
        _ = model.timeline.renamingTrackID
    }

    private func modelChanged() {
        relayoutLanes()
        setAllNeedsDisplay()
        positionPlayhead()
        // A new track opens its name for typing.
        if model.timeline.renamingTrackID != nil { headers.syncRename() }
    }

    func setAllNeedsDisplay() {
        ruler.needsDisplay = true
        headers.needsDisplay = true
        lanes.needsDisplay = true
    }

    // MARK: - Layout

    /// The project the lanes show: the drag preview while dragging.
    var displayedProject: Project { lanes.previewProject ?? model.project }

    func relayoutLanes() {
        let project = displayedProject
        let layout = TimelineLayout.make(project: project, showTranscript: model.showTranscript, heightOverrides: model.timeline.trackHeights)
        if layout != layoutCache { layoutCache = layout }
        clampVerticalOffset()
    }

    override func layout() {
        super.layout()
        let header = Theme.Metrics.trackHeaderWidth
        let rulerHeight = Theme.Metrics.rulerHeight
        corner.frame = CGRect(x: 0, y: 0, width: header, height: rulerHeight)
        ruler.frame = CGRect(x: header, y: 0, width: max(0, bounds.width - header), height: rulerHeight)
        headers.frame = CGRect(x: 0, y: rulerHeight, width: header, height: max(0, bounds.height - rulerHeight))
        lanes.frame = CGRect(x: header, y: rulerHeight, width: max(0, bounds.width - header), height: max(0, bounds.height - rulerHeight))
        let width = lanes.bounds.width
        if abs(model.timeline.lanesWidth - width) > 0.5 { model.timeline.lanesWidth = width }
        if model.timeline.fitPending && width > 200 {
            model.timeline.fit(model.project.duration)
        }
        clampVerticalOffset()
        positionPlayhead()
    }

    func clampVerticalOffset() {
        let maximum = max(0, layoutCache.contentHeight - lanes.bounds.height)
        let clamped = min(max(model.timeline.verticalOffset, 0), maximum)
        if clamped != model.timeline.verticalOffset { model.timeline.verticalOffset = clamped }
    }

    // MARK: - Playhead

    private func playheadMoved() {
        positionPlayhead()
        followPlayhead()
        lanes.playheadMoved()
    }

    func positionPlayhead() {
        let x = Theme.Metrics.trackHeaderWidth + model.timeline.scale.x(model.playback.time)
        let width = Theme.Metrics.playheadHeadWidth
        let visible = x >= Theme.Metrics.trackHeaderWidth - width / 2 && x <= bounds.width + width
        playheadView.isHidden = !visible
        let frame = CGRect(x: (x - width / 2).rounded(), y: Theme.Metrics.rulerHeight - Theme.Metrics.playheadHeadHeight + 2, width: width, height: max(0, bounds.height - Theme.Metrics.rulerHeight + Theme.Metrics.playheadHeadHeight - 2))
        if playheadView.frame != frame { playheadView.frame = frame }
    }

    /// Pages the view along while playing, like Premiere.
    private func followPlayhead() {
        guard model.playback.isPlaying, lanes.bounds.width > 100 else { return }
        let x = model.timeline.scale.x(model.playback.time)
        let width = lanes.bounds.width
        if x > width - 20 || x < 0 {
            model.timeline.scale.scrollSeconds = model.playback.time.seconds - Double(width * (model.playback.rate >= 0 ? 0.1 : 0.9)) / model.timeline.scale.pixelsPerSecond
        }
    }

    // MARK: - Scrolling and zoom

    /// Horizontal gestures scroll time; vertical ones scroll the tracks when
    /// they don't fit, otherwise time. Option or Cmd with the wheel zooms
    /// around the pointer.
    func handleScroll(_ event: NSEvent, lanesX: CGFloat) {
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= 12
            dy *= 12
        }
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let factor = pow(1.01, Double(dy + dx))
            model.timeline.zoom(by: factor, anchorX: lanesX)
            return
        }
        let overflow = layoutCache.contentHeight > lanes.bounds.height + 1
        if abs(dx) >= abs(dy) || !overflow || event.modifierFlags.contains(.shift) {
            let delta = abs(dx) >= abs(dy) ? dx : dy
            let seconds = model.timeline.scale.scrollSeconds - Double(delta) / model.timeline.scale.pixelsPerSecond
            model.timeline.scale.scrollSeconds = min(max(0, seconds), maxScrollSeconds)
        } else {
            model.timeline.verticalOffset -= dy
            clampVerticalOffset()
        }
    }

    func handleMagnify(_ event: NSEvent, lanesX: CGFloat) {
        model.timeline.zoom(by: 1 + Double(event.magnification), anchorX: lanesX)
    }

    /// How far right you can scroll: until the end of the project sits in
    /// the middle of the lanes.
    var maxScrollSeconds: Double {
        let visibleSeconds = Double(max(lanes.bounds.width, 100)) / model.timeline.scale.pixelsPerSecond
        return max(0, model.project.duration.seconds - visibleSeconds * 0.5)
    }

    override func scrollWheel(with event: NSEvent) {
        handleScroll(event, lanesX: convert(event.locationInWindow, from: nil).x - Theme.Metrics.trackHeaderWidth)
    }

    // MARK: - Hand drag

    /// A middle-button drag in progress. The ruler, headers and lanes pass
    /// the button up to here, so a drag can start anywhere on the timeline,
    /// clips included: the middle button does nothing else.
    private var pan: TimelinePan?

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        pan = TimelinePan(start: convert(event.locationInWindow, from: nil), scrollSeconds: model.timeline.scale.scrollSeconds, verticalOffset: model.timeline.verticalOffset)
        NSCursor.closedHand.set()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let pan else { return super.otherMouseDragged(with: event) }
        let next = pan.offsets(
            at: convert(event.locationInWindow, from: nil), pixelsPerSecond: model.timeline.scale.pixelsPerSecond,
            maxScrollSeconds: maxScrollSeconds, maxVerticalOffset: layoutCache.contentHeight - lanes.bounds.height
        )
        if next.scrollSeconds != model.timeline.scale.scrollSeconds { model.timeline.scale.scrollSeconds = next.scrollSeconds }
        if next.verticalOffset != model.timeline.verticalOffset { model.timeline.verticalOffset = next.verticalOffset }
        NSCursor.closedHand.set()
    }

    override func otherMouseUp(with event: NSEvent) {
        guard pan != nil, event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        pan = nil
        NSCursor.arrow.set()
    }
}

/// A subview of the timeline that can reach its container.
class TimelineChildView: NSView {
    weak var container: TimelineContainerView?

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func scrollWheel(with event: NSEvent) {
        guard let container else { return super.scrollWheel(with: event) }
        container.handleScroll(event, lanesX: laneX(event))
    }

    override func magnify(with event: NSEvent) {
        container?.handleMagnify(event, lanesX: laneX(event))
    }

    /// The pointer's x in lane coordinates.
    func laneX(_ event: NSEvent) -> CGFloat {
        guard let container else { return 0 }
        return container.convert(event.locationInWindow, from: nil).x - Theme.Metrics.trackHeaderWidth
    }
}

/// The amber playhead: a pentagon head on the ruler's edge and a line down
/// through the lanes. Moving it is a frame change, not a redraw.
final class PlayheadView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = bounds.width
        let head = Theme.Metrics.playheadHeadHeight
        context.setFillColor(Theme.amber.cg)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: width, y: 0))
        path.addLine(to: CGPoint(x: width, y: head / 2))
        path.addLine(to: CGPoint(x: width / 2, y: head))
        path.addLine(to: CGPoint(x: 0, y: head / 2))
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
        let line = Theme.Metrics.playheadWidth
        context.fill(CGRect(x: width / 2 - line / 2, y: head - 2, width: line, height: bounds.height - head + 2))
    }
}

/// The selection box over the lanes: a tinted, outlined layer that moves
/// by changing its frame, so dragging it never redraws the clips under it.
final class MarqueeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.marqueeFill.cg
        layer?.borderColor = Theme.amber.opacity(0.7).cg
        layer?.borderWidth = 1
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the box at `rect`, in the lanes' view coordinates.
    func show(_ rect: CGRect) {
        let frame = rect.integral
        if self.frame != frame { self.frame = frame }
        isHidden = false
    }
}

/// Amber outlines over the clips a selection box is picking up, drawn by a
/// shape layer so the clips under them don't redraw while the box moves.
final class ClipOutlineView: NSView {
    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.fillColor = nil
        shape.strokeColor = Theme.amber.cg
        shape.lineWidth = 2
        shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(shape)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        shape.frame = bounds
    }

    /// Shows `outlines`, in this view's (flipped) coordinates.
    func show(_ outlines: [Marquee.Outline]) {
        let path = CGMutablePath()
        for outline in outlines {
            path.addRoundedRect(in: outline.rect, cornerWidth: outline.radius, cornerHeight: outline.radius)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        // The path is in flipped view coordinates. Whether the layer's y
        // runs down too depends on the flips above it in the layer tree
        // (the backing layer itself isn't flipped, a parent is).
        if shape.contentsAreFlipped() {
            shape.path = path
        } else {
            var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
            shape.path = path.copy(using: &flip)
        }
        CATransaction.commit()
        isHidden = outlines.isEmpty
    }
}
