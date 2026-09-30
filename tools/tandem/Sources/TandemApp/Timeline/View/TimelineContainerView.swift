import AppKit
import TandemCore

/// The timeline: ruler on top, track headers on the left, lanes filling the
/// rest, and the playhead over both. Layer-backed AppKit throughout. When
/// the model changes it redraws only the views, and the parts of the lanes,
/// that look different (see `TimelineDamage`); while playing it moves only
/// the playhead view.
@MainActor
final class TimelineContainerView: NSView {
    let model: EditorModel
    let ruler = TimelineRulerView()
    let headers = TimelineHeaderView()
    let lanes = TimelineLanesView()
    let corner = TimelineCornerView()
    let scroller = TimelineScrollerView()
    private let playheadView = PlayheadView()
    private(set) var artwork: MediaArtwork
    private var loops: [ObservationLoop] = []
    /// The lane layout for the project being shown (which may be a drag
    /// preview).
    private(set) var layoutCache: TimelineLayout
    /// What the views draw, copied from the model (see `TimelineDrawState`).
    private(set) var drawState: TimelineDrawState
    /// The playhead's time, kept here so layout and drawing never read the
    /// playback controller (which would redraw them 60 times a second).
    private(set) var playheadTime: Time
    /// Model changes and drag previews wait here for the next frame.
    private var modelPending = false
    private var previewPending = false
    private lazy var pacer = FramePacer(view: self) { [weak self] in self?.applyPending() }

    init(model: EditorModel) {
        self.model = model
        self.artwork = MediaArtwork(analysis: model.session.analysis)
        self.layoutCache = TimelineLayout.make(project: model.project, showTranscript: model.showTranscript, heightOverrides: model.timeline.trackHeights)
        self.drawState = TimelineDrawState(model: model)
        self.playheadTime = model.playback.time
        super.init(frame: NSRect(x: 0, y: 0, width: 1_200, height: 320))
        wantsLayer = true
        // Since macOS 14 views don't clip drawing to their bounds by
        // default, and a dirty rect can reach past them. The timeline
        // fills its dirty rects, so it has to clip.
        clipsToBounds = true
        layer?.backgroundColor = Theme.window.cg
        for view in [ruler, headers, lanes, corner, scroller] as [TimelineChildView] {
            view.container = self
            addSubview(view)
        }
        addSubview(playheadView)
        model.timeline.playheadX = { [weak self] in
            guard let self else { return nil }
            return self.model.timeline.scale.x(self.model.playback.time)
        }
        loops.append(ObservationLoop(read: { [weak self] in self?.readDrawingState() }, onChange: { [weak self] in self?.modelChangeArrived() }))
        loops.append(ObservationLoop(read: { [weak self] in _ = self?.model.playback.time }, onChange: { [weak self] in self?.playheadMoved() }))
        // A new tool changes what a press would do, so the cursor too.
        loops.append(ObservationLoop(read: { [weak self] in _ = self?.model.tool }, onChange: { [weak self] in self?.lanes.refreshCursor() }))
        // New thumbnails, waveforms or transcripts: look again and redraw.
        // Job progress alone doesn't redraw the timeline.
        artwork.onDecoded = { [weak self] in self?.lanes.artworkDecoded() }
        loops.append(ObservationLoop(read: { [weak self] in _ = self?.model.artworkRevision }, onChange: { [weak self] in
            self?.artwork.invalidate()
            self?.modelChangeArrived()
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
        _ = TimelineDrawState(model: model)
    }

    /// The model changed: the timeline catches up at the next frame.
    private func modelChangeArrived() {
        modelPending = true
        pacer.request()
    }

    private func applyPending() {
        let started = CACurrentMediaTime()
        defer { DrawTiming.record("timeline updates", CACurrentMediaTime() - started) }
        if modelPending {
            modelPending = false
            modelChanged()
        }
        if previewPending {
            previewPending = false
            if relayoutLanes() { headers.needsDisplay = true }
            lanes.previewDidChange()
        }
    }

    /// Copies the model's new state and redraws what it changed.
    private func modelChanged() {
        let old = drawState
        drawState = TimelineDrawState(model: model)
        let layoutChanged = relayoutLanes()
        let damage = TimelineDamage.between(old, drawState, layout: layoutCache, layoutChanged: layoutChanged)
        if damage.ruler { ruler.needsDisplay = true }
        if damage.headers { headers.needsDisplay = true }
        if damage.lanesReshaped {
            lanes.reshaped()
        } else if damage.allLanes {
            lanes.redrawAll()
        } else {
            if damage.lanesMoved { lanes.lanesMoved() }
            if damage.lanesEdited { lanes.contentChanged() }
            for rect in damage.laneRects { lanes.redraw(rect) }
        }
        if old.scale != drawState.scale || old.showTranscript != drawState.showTranscript || old.revision != drawState.revision {
            lanes.playheadMoved(to: playheadTime)
        }
        if old.scale != drawState.scale || old.project.duration != drawState.project.duration {
            scroller.needsDisplay = true
        }
        positionPlayhead()
        // A new track opens its name for typing.
        if model.timeline.renamingTrackID != nil { headers.syncRename() }
    }

    /// The lanes' drag or drop preview changed: at the next frame they
    /// redraw, and so do the headers when the lanes moved (a drop can add a
    /// track).
    func previewChanged() {
        previewPending = true
        pacer.request()
    }

    // MARK: - Painted positions

    /// The content point (x is seconds times pixels a second, y down from
    /// the top of the tracks) at the lanes' top left, on whole points so
    /// that painted tiles land on whole pixels wherever they're scrolled.
    var contentOrigin: CGPoint {
        let scale = drawState.scale
        return CGPoint(x: (scale.scrollSeconds * scale.pixelsPerSecond).rounded(), y: drawState.verticalOffset.rounded())
    }

    /// The scale the timeline is painted at: the model's, scrolled to a
    /// whole point.
    var drawScale: TimelineScale {
        let scale = drawState.scale
        return TimelineScale(pixelsPerSecond: scale.pixelsPerSecond, scrollSeconds: contentOrigin.x / scale.pixelsPerSecond)
    }

    // MARK: - Layout

    /// The project the lanes show: the drag preview while dragging.
    var displayedProject: Project { lanes.previewProject ?? drawState.project }

    /// Lays the lanes out again for the project shown, and says whether
    /// they moved.
    @discardableResult
    func relayoutLanes() -> Bool {
        let project = displayedProject
        let layout = TimelineLayout.make(project: project, showTranscript: drawState.showTranscript, heightOverrides: drawState.trackHeights)
        let changed = layout != layoutCache
        if changed { layoutCache = layout }
        clampVerticalOffset()
        return changed
    }

    override func layout() {
        super.layout()
        let header = Theme.Metrics.trackHeaderWidth
        let rulerHeight = Theme.Metrics.rulerHeight
        let barHeight = Theme.Metrics.timelineScrollerHeight
        let tracksHeight = max(0, bounds.height - rulerHeight - barHeight)
        corner.frame = CGRect(x: 0, y: 0, width: header, height: rulerHeight)
        ruler.frame = CGRect(x: header, y: 0, width: max(0, bounds.width - header), height: rulerHeight)
        headers.frame = CGRect(x: 0, y: rulerHeight, width: header, height: tracksHeight)
        lanes.frame = CGRect(x: header, y: rulerHeight, width: max(0, bounds.width - header), height: tracksHeight)
        scroller.frame = CGRect(x: header, y: rulerHeight + tracksHeight, width: max(0, bounds.width - header), height: barHeight)
        let width = lanes.bounds.width
        if abs(model.timeline.lanesWidth - width) > 0.5 { model.timeline.lanesWidth = width }
        if model.timeline.fitPending && width > 200 {
            model.timeline.fit(model.project.duration)
            // Drawn at the fitted scale in this same pass, not the next.
            modelChanged()
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
        playheadTime = model.playback.time
        positionPlayhead()
        followPlayhead()
        lanes.playheadMoved(to: playheadTime)
        scroller.needsDisplay = true
    }

    func positionPlayhead() {
        let x = Theme.Metrics.trackHeaderWidth + drawScale.x(playheadTime)
        let width = Theme.Metrics.playheadHeadWidth
        let visible = x >= Theme.Metrics.trackHeaderWidth - width / 2 && x <= bounds.width + width
        playheadView.isHidden = !visible
        // Down to the scroll bar, which marks the playhead itself.
        let frame = CGRect(x: (x - width / 2).rounded(), y: Theme.Metrics.rulerHeight - Theme.Metrics.playheadHeadHeight + 2, width: width, height: max(0, bounds.height - Theme.Metrics.timelineScrollerHeight - Theme.Metrics.rulerHeight + Theme.Metrics.playheadHeadHeight - 2))
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
        CursorKind.grabbing.set()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let pan else { return super.otherMouseDragged(with: event) }
        let next = pan.offsets(
            at: convert(event.locationInWindow, from: nil), pixelsPerSecond: model.timeline.scale.pixelsPerSecond,
            maxScrollSeconds: maxScrollSeconds, maxVerticalOffset: layoutCache.contentHeight - lanes.bounds.height
        )
        if next.scrollSeconds != model.timeline.scale.scrollSeconds { model.timeline.scale.scrollSeconds = next.scrollSeconds }
        if next.verticalOffset != model.timeline.verticalOffset { model.timeline.verticalOffset = next.verticalOffset }
        CursorKind.grabbing.set()
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
