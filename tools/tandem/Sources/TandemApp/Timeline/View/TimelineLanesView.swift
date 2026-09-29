import AppKit
import QuartzCore
import TandemAssets
import TandemCore
import TandemMedia
import TandemRender

extension NSPasteboard.PasteboardType {
    /// Media IDs dragged from the browser, comma separated.
    static let tandemMedia = NSPasteboard.PasteboardType("com.mikerosoft.tandem.media")
}

/// The lanes: clips, transitions, the transcript and every edit gesture.
///
/// The content is painted into tiles `tileWidth` points of time wide that
/// move as the timeline scrolls, so a scroll paints only what comes into
/// view and a strip along the left edge, where the labels of clips that
/// start off screen stay in view. An edit, a selection or a drag's preview
/// repaints only the clips it changes; while zooming or dragging a track's
/// height, one full-size canvas paints instead of every tile. Everything
/// paints through `LanesPainter`.
///
/// Drags are planned by `DragPlanner` and previewed by drawing the project
/// as it would be after the edit; nothing is committed until mouse up, when
/// the planned batch goes to the model in one piece.
@MainActor
final class TimelineLanesView: TimelineChildView {
    private var model: EditorModel? { container?.model }

    /// The project as it would be after the drag or drop in progress.
    private(set) var previewProject: Project? {
        didSet { previewedCache = nil }
    }
    /// The clips the preview moved or made, worked out once per preview.
    private var previewedCache: Set<String>?
    private var session: DragSession?
    private var pressPoint: CGPoint = .zero
    private var pressSeconds: Double = 0
    private var pressHit: TimelineHit = .nothing
    private var pressModifiers = SelectionRules.Modifiers()
    /// A selected clip Cmd-pressed: deselected on mouse up unless dragged.
    private var pendingCommandToggle: String?
    /// A selection box being dragged. It and the clips it picks up are
    /// drawn by layers over the lanes (`outlineView` and `marqueeView`), so
    /// dragging it never redraws the clips.
    private var marquee: Marquee?
    private let outlineView = ClipOutlineView()
    private let marqueeView = MarqueeView()
    /// The scroll, zoom and track offset the outlines were placed for.
    private var outlinedAt: (scale: TimelineScale, offset: CGFloat)?
    private var snapLine: Time?
    private var dragLabel: (text: String, point: CGPoint)?
    private var drop: (batch: EditBatch, laneID: String?)?
    /// An asset library item on its way: placed at `time` once it's
    /// downloaded and copied into the project.
    private var assetDrop: (id: String, time: Time)?
    /// A look or font on its way to the clip under the pointer.
    private var assetApply: (asset: Asset, clipID: String)?
    /// Media files dragged in from Finder, found once per drag, and where
    /// they'd go.
    private var fileDrop: (files: [URL], time: Time, trackID: String?)?
    private var draggedFiles: [URL]?
    /// A keyframe being dragged: its clip as it was, the diamond, the rect
    /// the clip had (for reading levels off the volume line), and the edit
    /// so far.
    private var keyframeDrag: (clip: Clip, diamond: KeyframeDiamond, rect: CGRect, batch: EditBatch?, time: Time)?
    private var autoscrollTimer: Timer?
    private var lastDragEvent: NSEvent?
    private var trackingArea: NSTrackingArea?
    private var phraseCache: (revision: Int, artwork: Int, phrases: [TranscriptPhrase])?
    /// The transcript's phrases in the runs it shows them in at a zoom.
    private var groupCache: (pixelsPerSecond: Double, groups: [Range<Int>])?
    /// The run of phrases under the playhead, drawn brighter.
    private var highlightedGroup: Int?

    /// Width of a tile, in points: whole, and a multiple of the locked
    /// tracks' 8 point hatching.
    static let tileWidth: CGFloat = 512
    /// Tiles by index: tile `i` shows content x from `i * tileWidth`.
    private var tiles: [Int: LanesPaintView] = [:]
    private lazy var strip = LanesPaintView(role: .strip, lanes: self)
    private lazy var canvas = LanesPaintView(role: .canvas, lanes: self)
    /// The zoom, height and layout the tiles were painted for; when any
    /// changes they all paint again.
    private var tilesPaintedFor: (pixelsPerSecond: Double, height: CGFloat, layout: TimelineLayout)?
    /// True while the zoom or the lanes' heights are changing, until they
    /// rest for `reshapeRest`.
    private var isReshaping = false
    private var reshapeRestTimer: Timer?
    /// How long the zoom and heights stay still before the tiles come back.
    static let reshapeRest: TimeInterval = 0.25
    /// While zooming, or dragging a track's height, the canvas shows
    /// everything: every tile would paint again each step, and one big
    /// painting costs less than six.
    private var usesCanvas: Bool { isReshaping }
    /// Something changed while the canvas was up, so the tiles paint again
    /// when they come back.
    private var tilesStale = false
    /// The project, drag outlines and drop target the lanes were last
    /// painted for, so an edit or a preview's next move repaints only what
    /// differs.
    private var shownContent: PreviewState?
    /// A drag's snap line and label: layers over the lanes that move
    /// without repainting them.
    private let snapView = SnapLineView()
    private let labelView = DragLabelView()
    /// What a library or Finder drag carries, read once per drag, and the
    /// times it can snap to.
    private var dropPayload: LibraryDrag?
    private var dropTargets: SnapTargets?
    /// Where a library drag was last worked out for and what that came
    /// to: moving within the same frame and lane changes nothing.
    private var lastDrop: (key: DropKey, operation: NSDragOperation, snapLine: Time?)?

    private struct DropKey: Equatable {
        var payload: LibraryDrag
        var time: Time
        var target: DropTarget
        var insert: Bool
        var clipID: String?
    }
    /// Paint views that showed a thumbnail still decoding, to paint again
    /// when it's ready.
    private var awaitingArtwork: Set<ObjectIdentifier> = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.tandemMedia, .string, .fileURL])
        layer?.backgroundColor = Theme.window.cg
        // Tiles go in under the canvas as they're needed.
        canvas.isHidden = true
        addSubview(canvas)
        addSubview(strip)
        addSubview(outlineView)
        addSubview(marqueeView)
        addSubview(snapView)
        addSubview(labelView)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var offset: CGFloat { model?.timeline.verticalOffset ?? 0 }

    /// View coordinates to lane coordinates.
    private func lanePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: point.y + offset)
    }

    private func tester(for project: Project) -> TimelineHitTester? {
        guard let model, let container else { return nil }
        return TimelineHitTester(project: project, layout: container.layoutCache, scale: model.timeline.scale)
    }

    /// The transcript highlights the phrases under the playhead; they
    /// redraw when that changes, not on every frame.
    func playheadMoved(to time: Time) {
        guard let container, container.drawState.showTranscript,
              let lane = container.layoutCache.lanes.first(where: \.isTranscript) else {
            highlightedGroup = nil
            return
        }
        let phrases = transcriptPhrases(container.displayedProject, artwork: container.artwork)
        let groups = transcriptGroups(phrases)
        let current = TranscriptPhrase.group(at: time, in: groups, phrases: phrases)
        guard current != highlightedGroup else { return }
        let scale = container.drawScale
        let y = lane.y - container.contentOrigin.y
        for index in [highlightedGroup, current].compactMap({ $0 }) where index < groups.count {
            // From where its text can start to where the next run starts.
            let start = max(0, scale.x(phrases[groups[index].lowerBound].start))
            let end = index + 1 < groups.count ? scale.x(phrases[groups[index + 1].lowerBound].start) : bounds.width
            redraw(CGRect(x: start - 2, y: y, width: max(0, end - start) + 4, height: lane.height))
        }
        highlightedGroup = current
    }

    // MARK: - Painting

    /// Paints part of one of the paint views, in its own coordinates.
    func paint(_ view: LanesPaintView, _ dirty: CGRect) {
        let started = CACurrentMediaTime()
        defer {
            DrawTiming.record("lanes", CACurrentMediaTime() - started)
            DrawTiming.record("lanes area", Double(dirty.intersection(view.bounds).area / max(bounds.area, 1)), unit: .fraction)
        }
        guard let container, let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = contentOrigin(of: view)
        let painter = painter(for: view.role)
        let waits = container.artwork.waits
        context.saveGState()
        context.translateBy(x: -origin.x, y: -origin.y)
        painter.paint(dirty.offsetBy(dx: origin.x, dy: origin.y), area: view.bounds.offsetBy(dx: origin.x, dy: origin.y), in: context)
        context.restoreGState()
        if container.artwork.waits != waits { awaitingArtwork.insert(ObjectIdentifier(view)) }
    }

    /// The content point at a paint view's top left.
    private func contentOrigin(of view: LanesPaintView) -> CGPoint {
        switch view.role {
        case .tile(let index): return CGPoint(x: CGFloat(index) * Self.tileWidth, y: 0)
        case .strip, .canvas: return container?.contentOrigin ?? .zero
        }
    }

    private func painter(for role: LanesPaintView.Role) -> LanesPainter {
        guard let container else { fatalError("lanes painted outside a timeline") }
        let project = container.displayedProject
        let phrases = container.drawState.showTranscript ? transcriptPhrases(project, artwork: container.artwork) : []
        let origin = container.contentOrigin
        // Tiles draw labels where they fall; the strip and canvas pin them
        // to the lanes' left edge.
        var pinned = true
        if case .tile = role { pinned = false }
        return LanesPainter(
            project: project, state: container.drawState, layout: container.layoutCache, artwork: container.artwork,
            pinX: pinned ? origin.x : nil, viewMaxX: pinned ? origin.x + bounds.width : nil,
            phrases: phrases, groups: transcriptGroups(phrases), highlightedGroup: highlightedGroup,
            previewed: previewChangedClipIDs(project, committed: container.drawState.project),
            dropLaneID: drop?.laneID, keyframeDrag: keyframeDrag.map { ($0.clip.id, $0.time) },
            colorSpace: window?.colorSpace?.cgColorSpace, backingScale: window?.backingScaleFactor ?? 2
        )
    }

    // MARK: - Tiles

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        canvas.frame = bounds
        updateTiles()
    }

    /// Puts the tiles where the timeline is scrolled to, making tiles that
    /// came into view and painting them, and sizes the left-edge strip.
    func updateTiles() {
        guard let container, !usesCanvas, bounds.width > 0 else { return }
        let origin = container.contentOrigin
        let layout = container.layoutCache
        let pixelsPerSecond = container.drawState.scale.pixelsPerSecond
        let height = max(layout.contentHeight, origin.y + bounds.height)
        let repaint = tilesPaintedFor.map { $0.pixelsPerSecond != pixelsPerSecond || $0.height != height || $0.layout != layout } ?? true
        tilesPaintedFor = (pixelsPerSecond, height, layout)
        // Painted afresh, the tiles show the project as it is now.
        if repaint { shownContent = currentContent() }
        let width = Self.tileWidth
        let first = Int((origin.x / width).rounded(.down))
        let last = max(first, Int(((origin.x + bounds.width - 1) / width).rounded(.down)))
        // A tile either side stays, hidden, for small scrolls back; tiles
        // further away become the new ones.
        let kept = (first - 1)...(last + 1)
        var spare: [LanesPaintView] = []
        for (index, tile) in tiles where !kept.contains(index) {
            tiles[index] = nil
            spare.append(tile)
        }
        for index in first...last where tiles[index] == nil {
            let tile = spare.popLast() ?? {
                let made = LanesPaintView(role: .tile(index: index), lanes: self)
                addSubview(made, positioned: .below, relativeTo: canvas)
                return made
            }()
            tile.role = .tile(index: index)
            tiles[index] = tile
            tile.needsDisplay = true
        }
        for tile in spare { tile.removeFromSuperview() }
        for (index, tile) in tiles {
            let frame = CGRect(x: CGFloat(index) * width - origin.x, y: -origin.y, width: width, height: height)
            if tile.frame != frame { tile.frame = frame }
            // Hidden tiles don't paint until they show.
            tile.isHidden = !(first...last).contains(index)
            if repaint { tile.needsDisplay = true }
        }
        updateStrip(repaint: true)
    }

    /// The strip along the left edge covers what's pinned there, sized to
    /// its reach. It paints afresh when the timeline moves under it
    /// (`repaint`) or it changes size; otherwise only where it's redrawn.
    private func updateStrip(repaint: Bool) {
        guard let container, !usesCanvas else { return }
        let origin = container.contentOrigin
        let reach = painter(for: .strip).pinnedReach()
        let width = min(bounds.width, max(0, (reach - origin.x).rounded(.up) + 2))
        strip.isHidden = width <= 2
        let frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        let resized = strip.frame != frame
        if resized { strip.frame = frame }
        if !strip.isHidden && (repaint || resized) { strip.needsDisplay = true }
    }

    /// Everything paints again: new thumbnails, a new layout.
    func redrawAll() {
        shownContent = currentContent()
        if usesCanvas {
            canvas.needsDisplay = true
            tilesStale = true
            return
        }
        tilesPaintedFor = nil
        updateTiles()
    }

    /// The timeline scrolled, sideways or up and down: the tiles move with
    /// it and the strip paints again.
    func lanesMoved() {
        if usesCanvas {
            canvas.needsDisplay = true
        } else {
            updateTiles()
        }
    }

    /// Part of the lanes paints again, in the lanes' coordinates.
    func redraw(_ rect: CGRect) {
        if usesCanvas {
            canvas.setNeedsDisplay(rect)
            tilesStale = true
            return
        }
        for tile in tiles.values where !tile.isHidden && tile.frame.intersects(rect) {
            tile.setNeedsDisplay(rect.offsetBy(dx: -tile.frame.minX, dy: -tile.frame.minY))
        }
        if !strip.isHidden, strip.frame.intersects(rect) { strip.setNeedsDisplay(rect) }
    }

    /// The project shown changed (an edit, or a drag's preview): what
    /// changed paints again, or everything when tracks came or went.
    func contentChanged() {
        guard let container else { return }
        let content = currentContent()
        guard let shown = shownContent, !Self.changesEverything(from: shown.project, to: content.project, state: container.drawState),
              let rects = TimelineDamage.previewRects(
                from: shown, to: content, layout: container.layoutCache, scale: container.drawScale,
                offsetY: container.contentOrigin.y, width: bounds.width
              ) else {
            redrawAll()
            return
        }
        shownContent = content
        for rect in rects { redraw(rect) }
        // A label near the left edge can have grown or gone.
        if !rects.isEmpty { updateStrip(repaint: false) }
    }

    /// Changes that reach every clip: media (names and pictures), frame
    /// rate, and the length when the in to out range runs to the end.
    private static func changesEverything(from old: Project, to new: Project, state: TimelineDrawState) -> Bool {
        if old.media != new.media || old.settings != new.settings { return true }
        let rangeRunsToEnd = (state.inPoint != nil || state.outPoint != nil) && state.outPoint == nil
        return rangeRunsToEnd && old.duration != new.duration
    }

    /// Thumbnails landed: the views that showed them still decoding paint
    /// again.
    func artworkDecoded() {
        let waiting = awaitingArtwork
        awaitingArtwork = []
        for view in [canvas, strip] + Array(tiles.values) where waiting.contains(ObjectIdentifier(view)) {
            view.needsDisplay = true
        }
    }

    /// A drag or drop's preview changed: the snap line and label move, and
    /// the clips the preview changed since its last move paint again.
    func previewDidChange() {
        guard let container else { return }
        if let snapLine {
            snapView.show(atX: container.drawScale.x(snapLine).rounded(), height: bounds.height)
        } else {
            snapView.isHidden = true
        }
        if let dragLabel {
            labelView.show(dragLabel.text, near: CGPoint(x: dragLabel.point.x, y: dragLabel.point.y - container.contentOrigin.y), in: bounds)
        } else {
            labelView.isHidden = true
        }
        contentChanged()
    }

    /// What the lanes show: the project (or a drag's preview of it), the
    /// clips a preview outlines, a drop's target track, a dragged keyframe.
    private func currentContent() -> PreviewState {
        let project = container?.displayedProject ?? Project(name: "")
        return PreviewState(
            project: project, previewed: previewChangedClipIDs(project, committed: container?.drawState.project ?? project),
            dropLaneID: drop?.laneID, keyframeClipID: keyframeDrag?.clip.id, keyframeTime: keyframeDrag?.time
        )
    }

    /// The zoom or the lanes' heights changed: the canvas paints each step,
    /// and the tiles come back once they rest.
    func reshaped() {
        shownContent = currentContent()
        isReshaping = true
        reshapeRestTimer?.invalidate()
        let timer = Timer(timeInterval: Self.reshapeRest, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reshapeRested() }
        }
        RunLoop.main.add(timer, forMode: .common)
        reshapeRestTimer = timer
        canvas.isHidden = false
        strip.isHidden = true
        for tile in tiles.values { tile.isHidden = true }
        canvas.needsDisplay = true
    }

    /// Back to tiles, painted for the new zoom and heights.
    private func reshapeRested() {
        isReshaping = false
        canvas.isHidden = true
        // Its 30 MB of pixels aren't needed until the next zoom.
        canvas.layer?.contents = nil
        tilesStale = false
        tilesPaintedFor = nil
        updateTiles()
    }

    /// Clips that exist or moved in the preview, for highlighting a drop or
    /// drag. Worked out once per preview: it looks at every clip.
    private func previewChangedClipIDs(_ project: Project, committed: Project) -> Set<String> {
        guard previewProject != nil else { return [] }
        if let previewedCache { return previewedCache }
        var before: [String: (clip: Clip, trackID: String)] = [:]
        for track in committed.allTracks {
            for clip in track.clips { before[clip.id] = (clip, track.id) }
        }
        let committedTracks = Dictionary(uniqueKeysWithValues: committed.allTracks.map { ($0.id, $0) })
        var changed = Set<String>()
        for track in project.allTracks {
            // A track the preview didn't touch shares its clips with the
            // project, and compares at once.
            if committedTracks[track.id]?.clips == track.clips { continue }
            for clip in track.clips {
                guard let old = before[clip.id] else {
                    if drop != nil { changed.insert(clip.id) }
                    continue
                }
                if old.clip.start != clip.start || old.clip.duration != clip.duration || old.clip.sourceStart != clip.sourceStart || old.trackID != track.id {
                    changed.insert(clip.id)
                }
            }
        }
        previewedCache = changed
        return changed
    }

    // MARK: - Transcript lane

    /// The runs of phrases the transcript lane shows at the current zoom.
    private func transcriptGroups(_ phrases: [TranscriptPhrase]) -> [Range<Int>] {
        guard let container else { return [] }
        let scale = container.drawState.scale
        if let cache = groupCache, cache.pixelsPerSecond == scale.pixelsPerSecond, cache.groups.last?.upperBound ?? 0 == phrases.count {
            return cache.groups
        }
        let groups = TranscriptPhrase.readableGroups(phrases, minWidth: 64) { scale.x($0) }
        groupCache = (scale.pixelsPerSecond, groups)
        return groups
    }

    /// Words from the take's transcripts placed on the timeline and grouped
    /// into phrases at pauses.
    private func transcriptPhrases(_ project: Project, artwork: MediaArtwork) -> [TranscriptPhrase] {
        guard let container else { return [] }
        // A preview that leaves the take's sound alone (most drags) shows
        // the same words as the project.
        let committed = container.drawState.project
        if previewProject != nil, Self.speech(of: project) == Self.speech(of: committed) {
            return transcriptPhrases(committed, artwork: artwork, revision: container.drawState.revision)
        }
        return transcriptPhrases(project, artwork: artwork, revision: previewProject == nil ? container.drawState.revision : -1)
    }

    /// The tracks transcripts come from: the take's sound.
    private static func speech(of project: Project) -> [Track] {
        project.audioTracks.filter { $0.rippleMode == .cut && !$0.muted }
    }

    private func transcriptPhrases(_ project: Project, artwork: MediaArtwork, revision: Int) -> [TranscriptPhrase] {
        guard let container else { return [] }
        // A transcript that lands changes the phrases without an edit.
        let artworkRevision = container.drawState.artworkRevision
        if let cache = phraseCache, cache.revision == revision, cache.artwork == artworkRevision, revision >= 0 { return cache.phrases }
        var words: [(text: String, start: Time, end: Time)] = []
        // Where a track above already had words, so the same speech heard
        // on two tracks (camera and screen microphones) isn't listed twice.
        var covered: [TimeRange] = []
        // Transcripts live on the take's sound, on the tracks the take cuts.
        for track in project.audioTracks where track.rippleMode == .cut && !track.muted {
            var spoken: [TimeRange] = []
            for clip in track.clips where clip.enabled {
                guard let item = clip.mediaID.flatMap({ project.media($0) }), let transcript = artwork.transcript(for: item) else { continue }
                spoken.append(clip.range)
                for word in transcript.words where word.end > clip.sourceStart && word.start < clip.sourceEnd {
                    let start = clip.start + Time(seconds: max(0, (word.start - clip.sourceStart).seconds) / clip.speed)
                    let end = clip.start + Time(seconds: max(0, (word.end - clip.sourceStart).seconds) / clip.speed)
                    if covered.contains(where: { $0.start <= start && start < $0.end }) { continue }
                    words.append((word.text, start, min(end, clip.end)))
                }
            }
            covered += spoken
        }
        let phrases = TranscriptPhrase.group(words.sorted { $0.start < $1.start })
        phraseCache = (revision, artworkRevision, phrases)
        groupCache = nil
        return phrases
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(event)
    }

    private func updateCursor(_ event: NSEvent) {
        updateCursor(at: event.locationInWindow, flags: event.modifierFlags)
    }

    /// Sets the cursor for where the pointer is now, when something else
    /// changed what a press there would do (the tool, say).
    func refreshCursor() {
        guard let window, window.isKeyWindow else { return }
        let location = window.mouseLocationOutsideOfEventStream
        guard let under = window.contentView?.hitTest(location), under === self || under.isDescendant(of: self) else { return }
        updateCursor(at: location, flags: NSEvent.modifierFlags)
    }

    /// The cursor for what a press here would do (`CursorKind.timeline`).
    private func updateCursor(at windowPoint: CGPoint, flags: NSEvent.ModifierFlags) {
        guard let model, let tester = tester(for: model.project) else { return }
        let local = convert(windowPoint, from: nil)
        let point = CGPoint(x: local.x, y: local.y + offset)
        if model.tool != .blade, let found = tester.keyframe(at: point) {
            updateKeyframeToolTip(found.clipID, diamond: found.diamond, model: model)
            CursorKind.pointer.set()
            return
        }
        let hit = tester.hit(point)
        updateToolTip(hit, model: model)
        // The selection only decides which clips a move takes, not the kind
        // of drag, so it's left out here; the pointer moves a lot.
        let press = DragKind.forPress(on: hit, tool: model.tool, project: model.project, selection: [],
                                      rippleByDefault: model.rippleTrims, command: flags.contains(.command), option: flags.contains(.option))
        CursorKind.timeline(hit: hit, tool: model.tool, overKeyframe: false, press: press, project: model.project).set()
    }

    /// "Camera · main-camera", its times and what's on it, for hovering.
    private func updateToolTip(_ hit: TimelineHit, model: EditorModel) {
        var tip: String?
        switch hit {
        case .clip(let id, let trackID, let part):
            guard let clip = model.project.clip(id), let track = model.project.track(trackID) else { break }
            let renderer = ClipRenderer(project: model.project, scale: model.timeline.scale, artwork: nil, visible: 0...0, pinX: 0)
            var lines = ["\(track.name) · \(renderer.name(of: clip))"]
            let rate = model.frameRate
            lines.append("\(Timecode.string(clip.start, rate: rate)) to \(Timecode.string(clip.end, rate: rate)) (\(Timecode.string(clip.duration, rate: rate)))")
            if let badge = renderer.badgeText(for: clip) { lines.append(badge) }
            if clip.speed != 1 { lines.append("Speed \(Int((clip.speed * 100).rounded()))%") }
            switch part {
            case .head: lines.append("Drag to trim the start")
            case .tail: lines.append("Drag to trim the end")
            case .body: break
            }
            tip = lines.joined(separator: "\n")
        case .transition(let id, _):
            if let location = model.project.location(ofTransition: id) {
                let transition = model.project[location.track].transitions[location.index]
                tip = "\(transition.type.displayName) · \(String(format: "%.2f s", transition.duration.seconds))"
            }
        case .emptyTrack, .transcript, .nothing:
            tip = nil
        }
        if toolTip != tip { toolTip = tip }
    }

    /// "Keyframe · Scale and position", when it is and its easing.
    private func updateKeyframeToolTip(_ clipID: String, diamond: KeyframeDiamond, model: EditorModel) {
        guard let clip = model.project.clip(clipID) else { return }
        var lines = ["Keyframe · \(KeyframeEdits.summary(of: diamond.parameters, in: clip))"]
        var detail = Timecode.string(clip.start + diamond.time, rate: model.frameRate)
        if diamond.onVolumeLine, let db = clip.keyframes["audio.gainDB"]?.value(at: diamond.time)?.number {
            detail += String(format: " · %+.1f dB", db).replacingOccurrences(of: "-", with: "−")
        }
        if let easing = KeyframeEdits.easing(in: clip, at: diamond.time, tolerance: model.keyframeTolerance) {
            detail += " · \(easing.displayName.lowercased())"
        }
        lines.append(detail)
        lines.append(diamond.onVolumeLine ? "Drag to change the level or the time; Shift keeps the time" : "Drag to move it; right-click for easing")
        let tip = lines.joined(separator: "\n")
        if toolTip != tip { toolTip = tip }
    }

    private func modifiers(_ event: NSEvent) -> SelectionRules.Modifiers {
        let flags = event.modifierFlags
        return SelectionRules.Modifiers(shift: flags.contains(.shift), command: flags.contains(.command), option: flags.contains(.option))
    }

    private func dragContext() -> DragContext? {
        guard let model, let container else { return nil }
        return DragContext(
            project: model.project, scale: model.timeline.scale, layout: container.layoutCache,
            snapping: model.snapping, playhead: model.playback.time,
            inPoint: model.inPoint, outPoint: model.outPoint
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let model, let tester = tester(for: model.project) else { return }
        window?.makeFirstResponder(self)
        let point = lanePoint(event)
        let hit = tester.hit(point)
        let mods = modifiers(event)
        pressPoint = point
        pressSeconds = model.timeline.scale.seconds(atX: point.x)
        pressHit = hit
        pressModifiers = mods
        session = nil
        keyframeDrag = nil

        if event.clickCount == 1, model.tool != .blade, let found = tester.keyframe(at: point), let clip = model.project.clip(found.clipID),
           let lane = container?.layoutCache.lane(forTrack: found.trackID) {
            model.selectedTransitionID = nil
            model.focusedClipID = clip.id
            if !model.selection.contains(clip.id) {
                model.selection = SelectionRules.members(of: clip.id, in: model.project, linkedSelection: model.linkedSelection, option: mods.option)
            }
            model.selectedKeyframe = KeyframeRef(clipID: clip.id, time: found.diamond.time, parameters: found.diamond.parameters)
            model.playback.pause()
            model.playback.seek(to: clip.start + found.diamond.time)
            model.inspectorTab = lane.kind == .audio ? .audio : (model.inspectorTab == .audio || model.inspectorTab == .activity || model.inspectorTab == .info ? .video : model.inspectorTab)
            let rect = CGRect(x: model.timeline.scale.x(clip.start), y: lane.y, width: model.timeline.scale.x(clip.end) - model.timeline.scale.x(clip.start), height: lane.height)
            keyframeDrag = (clip, found.diamond, rect, nil, found.diamond.time)
            needsDisplay = true
            return
        }

        if event.clickCount == 2, let id = hit.clipID {
            model.selection = SelectionRules.members(of: id, in: model.project, linkedSelection: model.linkedSelection, option: mods.option)
            if model.project.location(ofClip: id)?.track.kind == .audio {
                model.inspectorTab = .audio
            } else if model.inspectorTab == .activity || model.inspectorTab == .info {
                model.inspectorTab = .video
            }
            return
        }

        if model.tool == .blade {
            if case .clip(let id, _, _) = hit {
                var time = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
                // Snap the cut to the playhead when it's close.
                let reach = model.timeline.scale.duration(forPixels: Theme.Metrics.snapDistance)
                if model.snapping, abs(time.flicks - model.playback.time.flicks) <= reach.flicks { time = model.playback.time }
                // Shift cuts every targeted track, like Premiere's razor.
                model.apply(TimelineEdits.blade(model.project, clipID: id, at: time, allTracks: mods.shift))
            }
            return
        }

        switch hit {
        case .transition(let id, _):
            model.selection = []
            model.selectedTransitionID = id
            return
        case .clip(let id, _, let part):
            model.selectedTransitionID = nil
            model.focusedClipID = id
            pendingCommandToggle = nil
            if part == .body && model.tool == .select {
                if mods.shift {
                    model.selection = SelectionRules.click(id, in: model.project, current: model.selection, modifiers: mods, linkedSelection: model.linkedSelection)
                    return
                }
                if mods.command {
                    // Cmd-click toggles the clip (on mouse up, if it doesn't
                    // turn into a drag); Cmd-drag inserts.
                    let members = SelectionRules.members(of: id, in: model.project, linkedSelection: model.linkedSelection, option: mods.option)
                    if model.selection.contains(id) {
                        pendingCommandToggle = id
                    } else {
                        model.selection.formUnion(members)
                    }
                } else {
                    model.selection = SelectionRules.click(id, in: model.project, current: model.selection, modifiers: mods, linkedSelection: model.linkedSelection)
                }
            } else if !model.selection.contains(id) {
                model.selection = SelectionRules.members(of: id, in: model.project, linkedSelection: model.linkedSelection, option: mods.option)
            }
            guard let kind = DragKind.forPress(
                on: hit, tool: model.tool, project: model.project, selection: model.selection,
                rippleByDefault: model.rippleTrims, command: mods.command, option: mods.option
            ), let context = dragContext() else { return }
            session = DragSession(kind: kind, context: context)
            // AppKit sends no cursor updates while the button is down.
            CursorKind.dragging(kind).set()
        case .emptyTrack, .transcript, .nothing:
            if !(mods.shift || mods.command) {
                model.selection = []
                model.selectedTransitionID = nil
            }
            marquee = Marquee(at: point, scale: model.timeline.scale, base: model.selection, modifiers: mods)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        lastDragEvent = event
        dragUpdate(event)
        autoscroll(event)
    }

    private func dragUpdate(_ event: NSEvent) {
        guard let model, let container else { return }
        let point = lanePoint(event)
        if var drag = keyframeDrag {
            let travelled = hypot(point.x - pressPoint.x, point.y - pressPoint.y)
            guard travelled >= 2 else { return }
            let scale = model.timeline.scale
            var time = drag.diamond.time
            if !event.modifierFlags.contains(.shift) {
                time = (drag.diamond.time + Time(seconds: scale.seconds(atX: point.x) - scale.seconds(atX: pressPoint.x))).roundedToFrame(model.frameRate)
            }
            time = min(max(time, .zero), drag.clip.duration)
            var value: ParamValue?
            var label = Timecode.string(drag.clip.start + time, rate: model.frameRate)
            if drag.diamond.onVolumeLine {
                let db = (KeyframeGeometry.gain(atY: point.y, in: drag.rect) * 10).rounded() / 10
                value = .number(db)
                label = String(format: "%+.1f dB", db).replacingOccurrences(of: "-", with: "−") + "  " + label
            }
            let commands = KeyframeEdits.moveKeyframes(in: drag.clip, from: drag.diamond.time, to: time, parameters: drag.diamond.parameters, tolerance: model.keyframeTolerance, value: value)
            drag.batch = commands.isEmpty ? nil : EditBatch(label: drag.diamond.onVolumeLine ? "Change level" : "Move keyframe", commands: commands)
            drag.time = time
            keyframeDrag = drag
            previewProject = drag.batch.flatMap { EditPreview.apply($0, to: model.project) }
            dragLabel = (label, point)
            container.previewChanged()
            return
        }
        if var session {
            let deltaX = point.x - model.timeline.scale.x(seconds: pressSeconds)
            let travelled = hypot(point.x - pressPoint.x, point.y - pressPoint.y)
            let flags = event.modifierFlags
            session.update(DragPointer(deltaX: deltaX, y: point.y, insert: flags.contains(.command), invertSnap: flags.contains(.shift)), travelled: travelled)
            self.session = session
            // A click that wobbles a point or so shows nothing new.
            guard session.distance >= 2 || previewProject != nil || snapLine != nil || dragLabel != nil else { return }
            previewProject = session.distance >= 2 ? session.preview : nil
            snapLine = session.distance >= 2 ? session.plan.snappedTo : nil
            if session.distance >= 2 {
                let delta = session.plan.delta
                let sign = delta < .zero ? "−" : "+"
                var text = sign + Timecode.string(Time(flicks: abs(delta.flicks)), rate: model.frameRate)
                if case .move = session.kind, flags.contains(.command) { text += "  insert" }
                dragLabel = (text, point)
            }
            container.previewChanged()
            return
        }
        if var box = marquee, let tester = tester(for: model.project) {
            let changed = box.move(to: point, tester: tester, linkedSelection: model.linkedSelection)
            marquee = box
            let scale = model.timeline.scale
            marqueeView.show(box.rect(scale: scale).offsetBy(dx: 0, dy: -offset))
            // Outlines go round what the box adds; they move again only
            // when it picks up or drops a clip, or the timeline scrolls.
            if changed || outlinedAt?.scale != scale || outlinedAt?.offset != offset {
                if outlineView.frame != bounds { outlineView.frame = bounds }
                // Placed as the clips are painted, on whole points.
                outlineView.show(Marquee.outlines(
                    of: box.selection.subtracting(model.selection), project: model.project, layout: container.layoutCache,
                    scale: container.drawScale, verticalOffset: container.contentOrigin.y, visibleX: -8...(bounds.width + 8)
                ))
                outlinedAt = (scale, offset)
            }
        }
    }

    /// Scrolls when a drag reaches the edge of the lanes.
    private func autoscroll(_ event: NSEvent) {
        guard let model else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let edge: CGFloat = 24
        let overshoot = x < edge ? x - edge : (x > bounds.width - edge ? x - (bounds.width - edge) : 0)
        guard overshoot != 0, session != nil || marquee != nil else {
            autoscrollTimer?.invalidate()
            autoscrollTimer = nil
            return
        }
        guard autoscrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let event = self.lastDragEvent else { return }
                let x = self.convert(event.locationInWindow, from: nil).x
                let over = x < edge ? x - edge : (x > self.bounds.width - edge ? x - (self.bounds.width - edge) : 0)
                guard over != 0 else {
                    self.autoscrollTimer?.invalidate()
                    self.autoscrollTimer = nil
                    return
                }
                let seconds = model.timeline.scale.scrollSeconds + Double(over) * 0.4 / model.timeline.scale.pixelsPerSecond
                model.timeline.scale.scrollSeconds = max(0, seconds)
                self.dragUpdate(event)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscrollTimer = timer
    }

    override func mouseUp(with event: NSEvent) {
        defer { updateCursor(event) }
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        guard let model, let container else { return }
        if let drag = keyframeDrag {
            keyframeDrag = nil
            if let batch = drag.batch, model.apply(batch) != nil {
                model.selectedKeyframe = KeyframeRef(clipID: drag.clip.id, time: drag.time, parameters: drag.diamond.parameters)
                model.playback.seek(to: drag.clip.start + drag.time)
            }
            previewProject = nil
            dragLabel = nil
            container.previewChanged()
            return
        }
        // What the drag drew over the lanes goes; the edit or selection it
        // made redraws through the model.
        let drewPreview = previewProject != nil || snapLine != nil || dragLabel != nil
        if let session {
            if let batch = session.finish() {
                model.apply(batch)
            } else if session.distance < 2, case .clip(let id, _, .body) = pressHit {
                if let toggle = pendingCommandToggle {
                    model.selection.subtract(SelectionRules.members(of: toggle, in: model.project, linkedSelection: model.linkedSelection, option: pressModifiers.option))
                } else if !(pressModifiers.shift || pressModifiers.command) {
                    // A plain click on a selected clip picks just that clip
                    // (and its links), like Premiere.
                    model.selection = SelectionRules.members(of: id, in: model.project, linkedSelection: model.linkedSelection, option: pressModifiers.option)
                    // And takes the playhead to its start, so the viewer
                    // shows what was picked, unless it's on the clip already.
                    if let clip = model.project.clip(id), let target = TimelineEdits.playheadForClick(on: clip, playhead: model.playback.time) {
                        model.playback.seek(to: target)
                    }
                }
            }
            pendingCommandToggle = nil
        } else if let box = marquee {
            let rect = box.rect(scale: model.timeline.scale)
            if hypot(rect.width, rect.height) < 3 {
                // A click on empty space moves the playhead there, which is
                // handy on a trackpad.
                if !(pressModifiers.shift || pressModifiers.command) {
                    model.playback.pause()
                    model.playback.seek(to: box.startTime(rate: model.frameRate))
                }
            } else {
                // The model hears about the box's selection once, now.
                let picked = SelectionRules.pruned(box.selection, in: model.project)
                if picked != model.selection { model.selection = picked }
            }
        }
        session = nil
        previewProject = nil
        marquee = nil
        marqueeView.isHidden = true
        outlineView.isHidden = true
        outlinedAt = nil
        snapLine = nil
        dragLabel = nil
        if drewPreview { container.previewChanged() }
    }

    // MARK: - Context menus

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model, let tester = tester(for: model.project) else { return nil }
        let point = lanePoint(event)
        let hit = tester.hit(point)
        let time = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
        let menu = NSMenu()
        if let found = tester.keyframe(at: point), let clip = model.project.clip(found.clipID) {
            if !model.selection.contains(clip.id) {
                model.selection = SelectionRules.members(of: clip.id, in: model.project, linkedSelection: model.linkedSelection, option: false)
            }
            model.selectedKeyframe = KeyframeRef(clipID: clip.id, time: found.diamond.time, parameters: found.diamond.parameters)
            buildKeyframeMenu(menu, clip: clip, diamond: found.diamond)
            return menu
        }
        switch hit {
        case .clip(let id, let trackID, _):
            if !model.selection.contains(id) {
                model.selection = SelectionRules.members(of: id, in: model.project, linkedSelection: model.linkedSelection, option: false)
            }
            buildClipMenu(menu, clipID: id, trackID: trackID, at: time)
        case .transition(let id, _):
            model.selectedTransitionID = id
            buildTransitionMenu(menu, transitionID: id)
        case .emptyTrack(let trackID, let at):
            menu.add("Close gap", icon: "arrow.right.and.line.vertical.and.arrow.left") {
                model.apply(EditBatch(label: "Close gap", commands: [.closeGap(trackID: trackID, at: at)]))
            }
            menu.add("Add marker here", icon: "bookmark") { model.apply(TimelineEdits.addMarker(model.project, at: at)) }
            menu.add("Move playhead here", icon: "arrow.down.to.line") { model.playback.seek(to: at) }
        case .transcript(let at):
            menu.add("Move playhead here", icon: "arrow.down.to.line") { model.playback.seek(to: at) }
        case .nothing:
            return nil
        }
        return menu
    }

    private func buildClipMenu(_ menu: NSMenu, clipID: String, trackID: String, at time: Time) {
        guard let model, let clip = model.project.clip(clipID), let track = model.project.track(trackID) else { return }
        let selection = model.selection
        // Keys show only where the item does exactly what the key does:
        // Cut here cuts at the pointer, the key at the playhead.
        menu.add("Cut here", icon: "scissors", enabled: clip.start < time && time < clip.end) {
            model.apply(TimelineEdits.blade(model.project, clipID: clipID, at: time, allTracks: false))
        }
        menu.add("Delete", command: .lift) { model.apply(TimelineEdits.remove(model.project, clipIDs: selection, ripple: false)) }
        menu.add("Ripple delete", command: .rippleDelete) { model.apply(TimelineEdits.remove(model.project, clipIDs: selection, ripple: true)) }
        menu.addItem(.separator())
        let linked = clip.linkGroup != nil
        menu.add(linked ? "Unlink" : "Link", command: .link, enabled: linked || selection.count > 1) {
            model.apply(TimelineEdits.toggleLink(model.project, selection: selection))
        }
        if linked {
            menu.add("Select linked clips", icon: "link.badge.plus") { model.selection = Set(model.project.linkedClipIDs(of: clipID)) }
        }
        menu.add(clip.enabled ? "Disable" : "Enable", icon: clip.enabled ? "eye.slash" : "eye") {
            let ids = TimelineEdits.ordered(selection, in: model.project)
            model.apply(EditBatch(label: clip.enabled ? "Disable clip" : "Enable clip", commands: ids.map {
                .updateClip(clipID: $0, patch: .object(["enabled": .bool(!clip.enabled)]))
            }))
        }
        if track.kind == .video {
            menu.addSubmenu("Layout", icon: Icons.layoutSection) { sub in
                for preset in LayoutPreset.allCases {
                    sub.add(preset.name, icon: Icons.layout(preset), command: Self.layoutCommand(preset), checked: clip.video?.layoutPreset == preset.rawValue) {
                        model.apply(TimelineEdits.applyLayout(model.project, preset: preset, playhead: model.playback.time, selection: selection))
                    }
                }
            }
        } else {
            let muted = clip.audio?.muted == true
            menu.add(muted ? "Unmute" : "Mute", icon: muted ? "speaker.wave.2" : "speaker.slash") {
                model.apply(EditBatch(label: muted ? "Unmute clip" : "Mute clip", commands: [
                    .updateClip(clipID: clipID, patch: .object(["audio": .object(["muted": .bool(!muted)])]))
                ]))
            }
        }
        menu.addSubmenu("Speed", icon: "speedometer") { sub in
            for speed in [0.5, 0.75, 1, 1.25, 1.5, 2] {
                sub.add("\(Int(speed * 100))%", checked: abs(clip.speed - speed) < 0.001) {
                    model.apply(EditBatch(label: "Speed \(Int(speed * 100))%", commands: [.setSpeed(clipID: clipID, speed: speed, ripple: true)]))
                }
            }
        }
        if let left = track.clip(endingAt: clip.start, excluding: clip.id) {
            menu.add("Add dissolve at start", icon: Icons.transition) {
                model.apply(EditBatch(label: "Add dissolve", commands: [.addTransition(trackID: trackID, transition: Transition(type: .dissolve, duration: TransitionType.dissolve.defaultDuration, fromClipID: left.id, toClipID: clip.id))]))
            }
        }
        if let right = track.clip(startingAt: clip.end, excluding: clip.id) {
            menu.add("Add dissolve at end", icon: Icons.transition) {
                model.apply(EditBatch(label: "Add dissolve", commands: [.addTransition(trackID: trackID, transition: Transition(type: .dissolve, duration: TransitionType.dissolve.defaultDuration, fromClipID: clip.id, toClipID: right.id))]))
            }
        }
        menu.addItem(.separator())
        menu.add("Save selection as segment…", icon: Icons.segment) {
            NSApp.sendAction(#selector(ProjectWindowController.saveSelectionAsSegment(_:)), to: nil, from: nil)
        }
        menu.add("Mark in and out around clip", command: .markClip) {
            model.inPoint = clip.start
            model.outPoint = clip.end
        }
        if let item = model.media(for: clip) {
            menu.add("Show media in Finder", icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.folder.url(for: item)])
            }
        }
    }

    /// The keymap command that applies a layout, where there is one.
    static func layoutCommand(_ preset: LayoutPreset) -> EditorCommand? {
        switch preset {
        case .full: return .layoutFull
        case .pipRight: return .layoutPipRight
        case .pipLeft: return .layoutPipLeft
        case .split: return .layoutSplit
        case .fill: return nil
        }
    }

    /// Easing, delete, and ending the animation.
    private func buildKeyframeMenu(_ menu: NSMenu, clip: Clip, diamond: KeyframeDiamond) {
        guard let model else { return }
        let tolerance = model.keyframeTolerance
        let current = KeyframeEdits.easing(in: clip, at: diamond.time, tolerance: tolerance)
        menu.addItem(withTitle: "Keyframe · \(KeyframeEdits.summary(of: diamond.parameters, in: clip))", action: nil, keyEquivalent: "").isEnabled = false
        for easing in Interpolation.menuOrder {
            menu.add(easing.displayName, checked: current == easing) {
                model.setEasing(easing, in: clip, at: diamond.time, parameters: diamond.parameters)
            }
        }
        menu.addItem(.separator())
        menu.add("Delete keyframe", icon: "trash") {
            model.apply(EditBatch(label: "Remove keyframe", commands: KeyframeEdits.removeKeyframes(in: clip, at: diamond.time, parameters: diamond.parameters, tolerance: tolerance)))
            model.selectedKeyframe = nil
        }
        menu.add("Stop animating \(KeyframeEdits.summary(of: diamond.parameters, in: clip).lowercased())", icon: "xmark.circle") {
            // Every keyframe of these parameters goes; each keeps the value
            // it has at this keyframe.
            var commands: [EditCommand] = []
            for parameter in diamond.parameters {
                guard let value = KeyframeEdits.value(of: parameter, in: clip, at: diamond.time) else { continue }
                commands.append(.setKeyframes(clipID: clip.id, parameter: parameter, keyframes: []))
                if let plain = KeyframeEdits.plainValueCommand(parameter, value: value, in: clip) { commands.append(plain) }
            }
            model.apply(EditBatch(label: "Stop animating", commands: commands))
            model.selectedKeyframe = nil
        }
    }

    private func buildTransitionMenu(_ menu: NSMenu, transitionID: String) {
        guard let model, let location = model.project.location(ofTransition: transitionID) else { return }
        let transition = model.project[location.track].transitions[location.index]
        menu.addSubmenu("Type", icon: Icons.transition) { sub in
            for type in TransitionType.allCases {
                sub.add(type.displayName, checked: transition.type == type) {
                    model.apply(EditBatch(label: "Change transition", commands: [.updateTransition(transitionID: transitionID, patch: .object(["type": .string(type.rawValue)]))]))
                }
            }
        }
        menu.addSubmenu("Duration", icon: "timer") { sub in
            for seconds in [0.25, 0.5, 0.75, 1.0, 1.5] {
                sub.add(String(format: "%.2f s", seconds), checked: abs(transition.duration.seconds - seconds) < 0.01) {
                    model.apply(EditBatch(label: "Transition length", commands: [.updateTransition(transitionID: transitionID, patch: .object(["duration": .number(seconds)]))]))
                }
            }
        }
        menu.addItem(.separator())
        menu.add("Delete transition", icon: "trash") {
            model.apply(EditBatch(label: "Remove transition", commands: [.removeTransition(transitionID: transitionID)]))
        }
    }

    // MARK: - Dropping media and library items

    /// What's being dragged in: project media, or an item from the asset,
    /// title, transition or effect libraries.
    private func libraryDrag(from info: NSDraggingInfo) -> LibraryDrag? {
        let pasteboard = info.draggingPasteboard
        let text = pasteboard.string(forType: .tandemMedia) ?? pasteboard.string(forType: .string) ?? ""
        if let drag = LibraryDrag.parse(text) { return drag }
        // Finder's drags carry files, never a browser drag's media.
        if pasteboard.types?.contains(.fileURL) == true { return nil }
        if let ids = model?.draggedMediaIDs, !ids.isEmpty { return .media(ids) }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFiles = nil
        dropPayload = libraryDrag(from: sender)
        dropTargets = nil
        lastDrop = nil
        return updateDrop(sender)
    }

    /// The times a drag in progress can snap to, found once per drag: the
    /// project doesn't change while it's over the lanes.
    private func dragSnapTargets(_ model: EditorModel) -> SnapTargets {
        if let dropTargets { return dropTargets }
        let targets = SnapTargets.collect(in: model.project, playhead: model.playback.time, inPoint: model.inPoint, outPoint: model.outPoint)
        dropTargets = targets
        return targets
    }

    /// File URLs on the pasteboard, when the drag came from Finder.
    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let pasteboard = info.draggingPasteboard
        guard pasteboard.types?.contains(.fileURL) == true else { return [] }
        return pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDrop()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        _ = updateDrop(sender)
        guard let model else {
            clearDrop()
            return false
        }
        if let files = fileDrop {
            clearDrop()
            model.importFiles(files.files, at: files.time, trackID: files.trackID)
            window?.makeKeyAndOrderFront(nil)
            return true
        }
        if let pending = assetApply {
            clearDrop()
            AssetLibraryHost.shared.dragged = nil
            AssetLibraryHost.shared.apply(pending.asset, to: [pending.clipID], in: model)
            window?.makeKeyAndOrderFront(nil)
            return true
        }
        if let pending = assetDrop {
            clearDrop()
            let host = AssetLibraryHost.shared
            let asset = host.dragged?.id == pending.id ? host.dragged : (try? host.library?.asset(pending.id)) ?? nil
            host.dragged = nil
            guard let asset else {
                model.show(.info, host.library == nil ? "The asset library is still opening. Try again in a moment." : "That asset isn't in the library any more.")
                return false
            }
            host.place(asset, at: pending.time, in: model, insert: NSEvent.modifierFlags.contains(.command))
            window?.makeKeyAndOrderFront(nil)
            return true
        }
        guard let batch = drop?.batch else {
            clearDrop()
            return false
        }
        clearDrop()
        let result = model.apply(batch)
        if let result {
            let created = SelectionRules.pruned(Set(result.createdIDs), in: model.project)
            if !created.isEmpty { model.selection = created }
        }
        model.draggedMediaIDs = []
        window?.makeKeyAndOrderFront(nil)
        return result != nil
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        clearDrop()
    }

    private func updateDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let model, let container else { return [] }
        let local = convert(info.draggingLocation, from: nil)
        guard let dragged = dropPayload else {
            // Files from Finder: they join the project when dropped.
            if draggedFiles == nil { draggedFiles = FileImport.mediaFiles(in: fileURLs(from: info)) }
            guard let files = draggedFiles, !files.isEmpty else { return [] }
            let point = CGPoint(x: local.x, y: local.y + offset)
            var time = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
            snapLine = nil
            if model.snapping, let snapped = dragSnapTargets(model).nearest(to: time, within: model.timeline.scale.duration(forPixels: Theme.Metrics.snapDistance)) {
                time = snapped
            }
            let lane = container.layoutCache.lane(atY: point.y)
            if let fileDrop, fileDrop.time == time, fileDrop.trackID == lane?.trackID, let dragLabel {
                // Still the same frame and track: the label follows the pointer.
                self.snapLine = time
                self.dragLabel = (dragLabel.text, point)
                container.previewChanged()
                return .copy
            }
            fileDrop = (files, time, lane?.trackID)
            drop = nil
            previewProject = nil
            snapLine = time
            let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
            dragLabel = ("Add \(what) at \(Timecode.string(time, rate: model.frameRate))", point)
            container.previewChanged()
            return .copy
        }
        let point = CGPoint(x: local.x, y: local.y + offset)
        var time = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
        snapLine = nil
        if model.snapping, let snapped = dragSnapTargets(model).nearest(to: time, within: model.timeline.scale.duration(forPixels: Theme.Metrics.snapDistance)) {
            time = snapped
            snapLine = snapped
        }
        let lane = container.layoutCache.lane(atY: point.y)
        // Above the top video track or below the last track, the drop
        // makes a track for itself.
        let target = DropTarget.at(y: point.y, in: container.layoutCache)
        let key = DropKey(
            payload: dragged, time: time, target: target, insert: NSEvent.modifierFlags.contains(.command),
            clipID: tester(for: model.project)?.hit(point).clipID
        )
        if let lastDrop, lastDrop.key == key {
            // The same frame, track and clip: the same edit. Only the label
            // follows the pointer.
            snapLine = lastDrop.snapLine
            dragLabel = dragLabel.map { ($0.text, point) }
            container.previewChanged()
            return lastDrop.operation
        }
        let operation = workOutDrop(dragged, at: time, lane: lane, target: target, point: point, model: model)
        lastDrop = (key, operation, snapLine)
        container.previewChanged()
        return operation
    }

    /// The edit a library drag would make at `time` on `lane`, previewed.
    private func workOutDrop(_ dragged: LibraryDrag, at time: Time, lane: TimelineLane?, target: DropTarget, point: CGPoint, model: EditorModel) -> NSDragOperation {
        let at = Timecode.string(time, rate: model.frameRate)
        let batch: EditBatch?
        var label: String
        assetDrop = nil
        assetApply = nil
        switch dragged {
        case .media(let ids):
            let insert = NSEvent.modifierFlags.contains(.command)
            var onNewTrack: EditBatch?
            switch target {
            case .newVideoTrackOnTop:
                onNewTrack = TimelineEdits.placeMediaOnNewTrack(model.project, mediaIDs: ids, at: time, kind: .video, insert: insert)
            case .newAudioTrackAtBottom:
                onNewTrack = TimelineEdits.placeMediaOnNewTrack(model.project, mediaIDs: ids, at: time, kind: .audio, insert: insert)
            case .track:
                break
            }
            batch = onNewTrack ?? TimelineEdits.placeMedia(model.project, mediaIDs: ids, at: time, trackID: lane?.trackID, insert: insert)
            label = (onNewTrack != nil ? "New track · " : "") + (insert ? "Insert at " : "Place at ") + at
        case .asset(let id):
            let host = AssetLibraryHost.shared
            // Drags from the browser say what they carry; anything else is
            // looked up once.
            if host.dragged?.id != id, let known = (try? host.library?.asset(id)) ?? nil { host.dragged = known }
            if let asset = host.dragged?.id == id ? host.dragged : nil, AssetApplying.appliesToClips(asset.kind) {
                // A look or font changes the clip it's dropped on.
                drop = nil
                previewProject = nil
                snapLine = nil
                let clip = tester(for: model.project)?.hit(point).clipID.flatMap { model.project.clip($0) }
                if let clip, !AssetApplying.targets(for: asset, among: [clip.id], in: model.project).isEmpty {
                    assetApply = (asset, clip.id)
                    let name = ClipRenderer.name(of: clip, in: model.project)
                    dragLabel = (AssetApplying.dropLabel(for: asset, clipName: name), point)
                } else {
                    dragLabel = (AssetApplying.dropHint(for: asset), point)
                }
                return assetApply == nil ? [] : .copy
            }
            // Placed once it's downloaded; the line shows where.
            let name = host.dragged.map { $0.id == id ? $0.name : "asset" } ?? "asset"
            assetDrop = (id, time)
            drop = nil
            previewProject = nil
            snapLine = time
            dragLabel = ((NSEvent.modifierFlags.contains(.command) ? "Insert \(name) at " : "Add \(name) at ") + at, point)
            return .copy
        case .transition(let type):
            batch = LibraryDrops.transition(type, at: time, trackID: lane?.trackID, in: model.project)
            label = batch?.label ?? "Drop on a cut"
        case .effect(let type):
            let clipID = tester(for: model.project)?.hit(point).clipID
            batch = LibraryDrops.effect(type, on: clipID, in: model.project)
            let name = clipID.flatMap { model.project.clip($0) }.map { ClipRenderer.name(of: $0, in: model.project) }
            label = batch.map { "\($0.label) to \(name ?? "clip")" } ?? "Drop on a clip"
        case .title(let id):
            batch = TitlePresets.preset(id).flatMap { LibraryDrops.title($0, at: time, in: model.project, target: target == .newAudioTrackAtBottom ? .track(nil) : target) }
            label = (batch?.label ?? "Add title") + " at " + at
        case .template(let id):
            batch = BuiltInTemplates.template(id).map { LibraryDrops.template($0, at: time) }
            label = (batch?.label ?? "Add template") + " at " + at
        }
        guard let batch else {
            drop = nil
            previewProject = nil
            dragLabel = (label, point)
            return []
        }
        drop = (batch, lane?.trackID)
        previewProject = EditPreview.apply(batch, to: model.project)
        dragLabel = (label, point)
        return previewProject == nil ? [] : .copy
    }

    private func clearDrop() {
        let drewPreview = previewProject != nil || snapLine != nil || dragLabel != nil || drop != nil
        dropPayload = nil
        dropTargets = nil
        lastDrop = nil
        drop = nil
        assetDrop = nil
        assetApply = nil
        fileDrop = nil
        previewProject = nil
        snapLine = nil
        dragLabel = nil
        if drewPreview { container?.previewChanged() }
    }
}

/// A run of transcript words drawn together.
struct TranscriptPhrase: Equatable {
    var text: String
    var start: Time
    var end: Time

    /// Groups words into phrases, breaking at pauses and long runs.
    static func group(_ words: [(text: String, start: Time, end: Time)], pause: Time = Time(seconds: 0.35), maxWords: Int = 9) -> [TranscriptPhrase] {
        var phrases: [TranscriptPhrase] = []
        var current: [(text: String, start: Time, end: Time)] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            phrases.append(TranscriptPhrase(text: current.map(\.text).joined(separator: " "), start: first.start, end: last.end))
            current = []
        }
        for word in words {
            if let last = current.last, word.start - last.end > pause || current.count >= maxWords {
                flush()
            }
            current.append(word)
        }
        flush()
        return phrases
    }

    /// The run of `groups` playing at `time`, from its first phrase's start
    /// to its last one's end; nil in the pauses between runs.
    static func group(at time: Time, in groups: [Range<Int>], phrases: [TranscriptPhrase]) -> Int? {
        // The last run starting at or before `time`.
        var low = 0
        var high = groups.count
        while low < high {
            let middle = (low + high) / 2
            if phrases[groups[middle].lowerBound].start <= time { low = middle + 1 } else { high = middle }
        }
        let index = low - 1
        guard index >= 0, time < phrases[groups[index].upperBound - 1].end else { return nil }
        return index
    }

    /// Runs of phrases to show one at a time, so each shown phrase has at
    /// least `minWidth` points before the next one. Zoomed out, an eleven
    /// minute take shows every few phrases instead of none; zoomed in,
    /// every phrase shows. Groups start from the first phrase, so they
    /// don't jump about while scrolling.
    static func readableGroups(_ phrases: [TranscriptPhrase], minWidth: CGFloat, x: (Time) -> CGFloat) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        var index = 0
        while index < phrases.count {
            let start = x(phrases[index].start)
            var next = index + 1
            while next < phrases.count, x(phrases[next].start) - start < minWidth { next += 1 }
            groups.append(index..<next)
            index = next
        }
        return groups
    }
}

/// The drag payload for media from the browser.
enum MediaDrag {
    static let prefix = "tandem-media:"

    static func payload(_ ids: [String]) -> String {
        prefix + ids.joined(separator: ",")
    }

    static func ids(from text: String) -> [String] {
        guard text.hasPrefix(prefix) else { return [] }
        return text.dropFirst(prefix.count).split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
}
