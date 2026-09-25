import AppKit
import QuartzCore
import TandemCore
import TandemMedia
import TandemRender

extension NSPasteboard.PasteboardType {
    /// Media IDs dragged from the browser, comma separated.
    static let tandemMedia = NSPasteboard.PasteboardType("com.mikerosoft.tandem.media")
}

/// The lanes: clips, transitions, the transcript and every edit gesture.
///
/// Drags are planned by `DragPlanner` and previewed by drawing the project
/// as it would be after the edit; nothing is committed until mouse up, when
/// the planned batch goes to the model in one piece.
@MainActor
final class TimelineLanesView: TimelineChildView {
    private var model: EditorModel? { container?.model }

    /// The project as it would be after the drag or drop in progress.
    private(set) var previewProject: Project?
    private var session: DragSession?
    private var pressPoint: CGPoint = .zero
    private var pressSeconds: Double = 0
    private var pressHit: TimelineHit = .nothing
    private var pressModifiers = SelectionRules.Modifiers()
    private var selectionAtPress: Set<String> = []
    /// A selected clip Cmd-pressed: deselected on mouse up unless dragged.
    private var pendingCommandToggle: String?
    private var marquee: (start: CGPoint, end: CGPoint)?
    private var snapLine: Time?
    private var dragLabel: (text: String, point: CGPoint)?
    private var drop: (batch: EditBatch, laneID: String?)?
    /// An asset library item on its way: placed at `time` once it's
    /// downloaded and copied into the project.
    private var assetDrop: (id: String, time: Time)?
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.tandemMedia, .string, .fileURL])
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

    func playheadMoved() {
        // The transcript highlights the phrase under the playhead.
        if model?.showTranscript == true, let lane = container?.layoutCache.lanes.first(where: \.isTranscript) {
            setNeedsDisplay(CGRect(x: 0, y: lane.y - offset, width: bounds.width, height: lane.height))
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let started = CACurrentMediaTime()
        defer { DrawTiming.record("lanes", CACurrentMediaTime() - started) }
        guard let model, let container, let context = NSGraphicsContext.current?.cgContext else { return }
        let project = container.displayedProject
        let layout = container.layoutCache
        let scale = model.timeline.scale
        context.setFillColor(Theme.window.cg)
        context.fill(dirtyRect.intersection(bounds))

        // In to out.
        if let inPoint = model.inPoint ?? (model.outPoint != nil ? .zero : nil) {
            let end = model.outPoint ?? project.duration
            let x0 = scale.x(inPoint)
            let x1 = scale.x(max(end, inPoint))
            if x1 > x0 {
                context.setFillColor(Theme.inOutFill.cg)
                context.fill(CGRect(x: x0, y: 0, width: x1 - x0, height: bounds.height))
            }
        }

        let renderer = ClipRenderer(project: project, scale: scale, artwork: container.artwork, visible: dirtyRect.minX...dirtyRect.maxX)
        let selected = model.selection
        let linkedGroups = Set(selected.compactMap { project.clip($0)?.linkGroup })
        let changed = previewChangedClipIDs(project)

        for lane in layout.lanes {
            let rect = CGRect(x: 0, y: lane.y - offset, width: bounds.width, height: lane.height)
            guard rect.intersects(dirtyRect) else { continue }
            if lane.isTranscript {
                drawTranscript(lane: lane, project: project, rect: rect, renderer: renderer, in: context)
                continue
            }
            guard let trackID = lane.trackID, let track = project.track(trackID) else { continue }
            if drop?.laneID == trackID {
                context.setFillColor(Theme.dropTarget.cg)
                context.fill(rect)
            }
            let shifted = TimelineLane(trackID: lane.trackID, kind: lane.kind, style: lane.style, y: lane.y - offset, height: lane.height)
            for clip in track.clips {
                let x0 = scale.x(clip.start)
                let x1 = scale.x(clip.end)
                guard x1 >= dirtyRect.minX - 2, x0 <= dirtyRect.maxX + 2 else { continue }
                let clipRect = CGRect(x: x0, y: shifted.y, width: max(1, x1 - x0), height: shifted.height)
                var state = ClipDrawState()
                state.selected = selected.contains(clip.id)
                state.linked = !state.selected && clip.linkGroup.map(linkedGroups.contains) == true
                state.previewed = changed.contains(clip.id) && !state.selected
                if let keyframe = model.selectedKeyframe, keyframe.clipID == clip.id {
                    state.selectedKeyframe = keyframeDrag?.clip.id == clip.id ? keyframeDrag?.time : keyframe.time
                }
                renderer.draw(clip, lane: shifted, rect: clipRect, state: state, in: context)
            }
            for transition in track.transitions {
                renderer.drawTransition(transition, on: track, lane: shifted, selected: model.selectedTransitionID == transition.id, in: context)
            }
            if track.locked {
                drawLockedHatch(rect, in: context)
            } else if track.hidden || (track.kind == .audio && track.muted) {
                context.setFillColor(Theme.window.opacity(0.45).cg)
                context.fill(rect)
            }
        }

        if let snapLine {
            let x = scale.x(snapLine).rounded() + 0.5
            context.setStrokeColor(Theme.amber.opacity(0.9).cg)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }

        if let marquee {
            let rect = CGRect(
                x: min(marquee.start.x, marquee.end.x), y: min(marquee.start.y, marquee.end.y) - offset,
                width: abs(marquee.end.x - marquee.start.x), height: abs(marquee.end.y - marquee.start.y)
            )
            context.setFillColor(Theme.marqueeFill.cg)
            context.fill(rect)
            context.setStrokeColor(Theme.amber.opacity(0.7).cg)
            context.setLineWidth(1)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }

        if let dragLabel {
            let font = Theme.Fonts.digits(10.5, .semibold)
            let size = (dragLabel.text as NSString).size(withAttributes: [.font: font])
            let box = CGRect(x: min(dragLabel.point.x + 12, bounds.width - size.width - 14), y: max(2, dragLabel.point.y - offset - 22), width: size.width + 10, height: 16)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.setFillColor(Theme.raised.cg)
            context.fillPath()
            renderer.drawText(dragLabel.text, at: CGPoint(x: box.minX + 5, y: box.minY + 1.5), maxX: box.maxX, font: font, color: Theme.text)
        }
    }

    /// Clips that exist or moved in the preview, for highlighting a drop or drag.
    private func previewChangedClipIDs(_ project: Project) -> Set<String> {
        guard let model, previewProject != nil else { return [] }
        var before: [String: Clip] = [:]
        for clip in model.project.allTracks.flatMap(\.clips) { before[clip.id] = clip }
        var changed = Set<String>()
        for track in project.allTracks {
            for clip in track.clips {
                guard let old = before[clip.id] else {
                    if drop != nil { changed.insert(clip.id) }
                    continue
                }
                if old.start != clip.start || old.duration != clip.duration || old.sourceStart != clip.sourceStart || model.project.track(containingClip: clip.id)?.id != track.id {
                    changed.insert(clip.id)
                }
            }
        }
        return changed
    }

    private func drawLockedHatch(_ rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.setStrokeColor(Theme.textFaint.opacity(0.18).cg)
        context.setLineWidth(1)
        var x = rect.minX - rect.height
        while x < rect.maxX {
            context.move(to: CGPoint(x: x, y: rect.maxY))
            context.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 8
        }
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Transcript lane

    private func drawTranscript(lane: TimelineLane, project: Project, rect: CGRect, renderer: ClipRenderer, in context: CGContext) {
        guard let model, let container else { return }
        let phrases = transcriptPhrases(project, artwork: container.artwork)
        let font = Theme.Fonts.ui(10.5)
        let y = rect.minY + (rect.height - 14) / 2
        if phrases.isEmpty {
            let hasTake = project.allTracks.flatMap(\.clips).contains { clip in
                clip.mediaID.flatMap { project.media($0) }.map { $0.role == .camera && $0.hasAudio } ?? false
            }
            let text = hasTake ? "The transcript shows here once the take is transcribed." : "Place a take to see what's said here."
            renderer.drawText(text, at: CGPoint(x: 6, y: y), maxX: bounds.width - 6, font: font, color: Theme.textFainter)
            return
        }
        let playhead = model.playback.time
        let scale = model.timeline.scale
        let groups = TranscriptPhrase.readableGroups(phrases, minWidth: 64) { scale.x($0) }
        for (index, group) in groups.enumerated() {
            let first = phrases[group.lowerBound]
            let x0 = scale.x(first.start)
            let next = index + 1 < groups.count ? scale.x(phrases[groups[index + 1].lowerBound].start) : bounds.width + 400
            guard next >= 0, x0 <= bounds.width else { continue }
            let current = first.start <= playhead && playhead < phrases[group.upperBound - 1].end
            renderer.drawText(first.text, at: CGPoint(x: max(x0, 0) + 2, y: y), maxX: min(next - 6, bounds.width), font: font, color: current ? Theme.text : Theme.textFaint)
        }
    }

    /// Words from the take's transcripts placed on the timeline and grouped
    /// into phrases at pauses.
    private func transcriptPhrases(_ project: Project, artwork: MediaArtwork) -> [TranscriptPhrase] {
        guard let model else { return [] }
        let revision = previewProject == nil ? model.revision : -1
        // A transcript that lands changes the phrases without an edit.
        let artworkRevision = model.artworkRevision
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
        guard let model, let tester = tester(for: model.project) else { return }
        let point = lanePoint(event)
        if model.tool != .blade, let found = tester.keyframe(at: point) {
            updateKeyframeToolTip(found.clipID, diamond: found.diamond, model: model)
            NSCursor.pointingHand.set()
            return
        }
        let hit = tester.hit(point)
        updateToolTip(hit, model: model)
        switch model.tool {
        case .blade:
            if case .clip = hit { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
        case .slip, .slide:
            if case .clip = hit { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        case .select, .rippleTrim, .roll:
            if case .clip(_, _, let part) = hit, part != .body {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    /// "Camera · main-camera", its times and what's on it, for hovering.
    private func updateToolTip(_ hit: TimelineHit, model: EditorModel) {
        var tip: String?
        switch hit {
        case .clip(let id, let trackID, let part):
            guard let clip = model.project.clip(id), let track = model.project.track(trackID) else { break }
            let renderer = ClipRenderer(project: model.project, scale: model.timeline.scale, artwork: nil, visible: 0...0)
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
        selectionAtPress = model.selection
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
        case .emptyTrack, .transcript, .nothing:
            marquee = (point, point)
            if !(mods.shift || mods.command) {
                model.selection = []
                model.selectedTransitionID = nil
            }
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
            container.relayoutLanes()
            container.setAllNeedsDisplay()
            return
        }
        if var session {
            let deltaX = point.x - model.timeline.scale.x(seconds: pressSeconds)
            let travelled = hypot(point.x - pressPoint.x, point.y - pressPoint.y)
            let flags = event.modifierFlags
            session.update(DragPointer(deltaX: deltaX, y: point.y, insert: flags.contains(.command), invertSnap: flags.contains(.shift)), travelled: travelled)
            self.session = session
            previewProject = session.distance >= 2 ? session.preview : nil
            snapLine = session.distance >= 2 ? session.plan.snappedTo : nil
            if session.distance >= 2 {
                let delta = session.plan.delta
                let sign = delta < .zero ? "−" : "+"
                var text = sign + Timecode.string(Time(flicks: abs(delta.flicks)), rate: model.frameRate)
                if case .move = session.kind, flags.contains(.command) { text += "  insert" }
                dragLabel = (text, point)
            }
            container.relayoutLanes()
            container.setAllNeedsDisplay()
            return
        }
        if var box = marquee, let tester = tester(for: model.project) {
            box.end = point
            marquee = box
            let rect = CGRect(x: min(box.start.x, box.end.x), y: min(box.start.y, box.end.y), width: abs(box.end.x - box.start.x), height: abs(box.end.y - box.start.y))
            let ids = tester.clips(in: rect)
            let base = pressModifiers.shift || pressModifiers.command ? selectionAtPress : []
            model.selection = SelectionRules.marquee(ids, in: model.project, current: base, modifiers: pressModifiers, linkedSelection: model.linkedSelection)
            needsDisplay = true
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
            container.relayoutLanes()
            container.setAllNeedsDisplay()
            return
        }
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
                }
            }
            pendingCommandToggle = nil
        } else if let box = marquee, hypot(box.end.x - box.start.x, box.end.y - box.start.y) < 3, !(pressModifiers.shift || pressModifiers.command) {
            // A click on empty space moves the playhead there, which is
            // handy on a trackpad.
            model.playback.pause()
            model.playback.seek(to: model.timeline.scale.time(atX: box.start.x, rate: model.frameRate))
        }
        session = nil
        previewProject = nil
        marquee = nil
        snapLine = nil
        dragLabel = nil
        container.relayoutLanes()
        container.setAllNeedsDisplay()
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
            menu.add("Close gap") {
                model.apply(EditBatch(label: "Close gap", commands: [.closeGap(trackID: trackID, at: at)]))
            }
            menu.add("Add marker here") { model.apply(TimelineEdits.addMarker(model.project, at: at)) }
            menu.add("Move playhead here") { model.playback.seek(to: at) }
        case .transcript(let at):
            menu.add("Move playhead here") { model.playback.seek(to: at) }
        case .nothing:
            return nil
        }
        return menu
    }

    private func buildClipMenu(_ menu: NSMenu, clipID: String, trackID: String, at time: Time) {
        guard let model, let clip = model.project.clip(clipID), let track = model.project.track(trackID) else { return }
        let selection = model.selection
        menu.add("Cut here", enabled: clip.start < time && time < clip.end) {
            model.apply(TimelineEdits.blade(model.project, clipID: clipID, at: time, allTracks: false))
        }
        menu.add("Delete") { model.apply(TimelineEdits.remove(model.project, clipIDs: selection, ripple: false)) }
        menu.add("Ripple delete") { model.apply(TimelineEdits.remove(model.project, clipIDs: selection, ripple: true)) }
        menu.addItem(.separator())
        let linked = clip.linkGroup != nil
        menu.add(linked ? "Unlink" : "Link", enabled: linked || selection.count > 1) {
            model.apply(TimelineEdits.toggleLink(model.project, selection: selection))
        }
        if linked {
            menu.add("Select linked clips") { model.selection = Set(model.project.linkedClipIDs(of: clipID)) }
        }
        menu.add(clip.enabled ? "Disable" : "Enable") {
            let ids = TimelineEdits.ordered(selection, in: model.project)
            model.apply(EditBatch(label: clip.enabled ? "Disable clip" : "Enable clip", commands: ids.map {
                .updateClip(clipID: $0, patch: .object(["enabled": .bool(!clip.enabled)]))
            }))
        }
        if track.kind == .video {
            menu.addSubmenu("Layout") { sub in
                for preset in LayoutPreset.allCases {
                    sub.add(preset.name, checked: clip.video?.layoutPreset == preset.rawValue) {
                        model.apply(TimelineEdits.applyLayout(model.project, preset: preset, playhead: model.playback.time, selection: selection))
                    }
                }
            }
        } else {
            let muted = clip.audio?.muted == true
            menu.add(muted ? "Unmute" : "Mute") {
                model.apply(EditBatch(label: muted ? "Unmute clip" : "Mute clip", commands: [
                    .updateClip(clipID: clipID, patch: .object(["audio": .object(["muted": .bool(!muted)])]))
                ]))
            }
        }
        menu.addSubmenu("Speed") { sub in
            for speed in [0.5, 0.75, 1, 1.25, 1.5, 2] {
                sub.add("\(Int(speed * 100))%", checked: abs(clip.speed - speed) < 0.001) {
                    model.apply(EditBatch(label: "Speed \(Int(speed * 100))%", commands: [.setSpeed(clipID: clipID, speed: speed, ripple: true)]))
                }
            }
        }
        if let left = track.clip(endingAt: clip.start, excluding: clip.id) {
            menu.add("Add dissolve at start") {
                model.apply(EditBatch(label: "Add dissolve", commands: [.addTransition(trackID: trackID, transition: Transition(type: .dissolve, duration: TransitionType.dissolve.defaultDuration, fromClipID: left.id, toClipID: clip.id))]))
            }
        }
        if let right = track.clip(startingAt: clip.end, excluding: clip.id) {
            menu.add("Add dissolve at end") {
                model.apply(EditBatch(label: "Add dissolve", commands: [.addTransition(trackID: trackID, transition: Transition(type: .dissolve, duration: TransitionType.dissolve.defaultDuration, fromClipID: clip.id, toClipID: right.id))]))
            }
        }
        menu.addItem(.separator())
        menu.add("Mark in and out around clip") {
            model.inPoint = clip.start
            model.outPoint = clip.end
        }
        if let item = model.media(for: clip) {
            menu.add("Show media in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.folder.url(for: item)])
            }
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
        menu.add("Delete keyframe") {
            model.apply(EditBatch(label: "Remove keyframe", commands: KeyframeEdits.removeKeyframes(in: clip, at: diamond.time, parameters: diamond.parameters, tolerance: tolerance)))
            model.selectedKeyframe = nil
        }
        menu.add("Stop animating \(KeyframeEdits.summary(of: diamond.parameters, in: clip).lowercased())") {
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
        menu.addSubmenu("Type") { sub in
            for type in TransitionType.allCases {
                sub.add(type.displayName, checked: transition.type == type) {
                    model.apply(EditBatch(label: "Change transition", commands: [.updateTransition(transitionID: transitionID, patch: .object(["type": .string(type.rawValue)]))]))
                }
            }
        }
        menu.addSubmenu("Duration") { sub in
            for seconds in [0.25, 0.5, 0.75, 1.0, 1.5] {
                sub.add(String(format: "%.2f s", seconds), checked: abs(transition.duration.seconds - seconds) < 0.01) {
                    model.apply(EditBatch(label: "Transition length", commands: [.updateTransition(transitionID: transitionID, patch: .object(["duration": .number(seconds)]))]))
                }
            }
        }
        menu.addItem(.separator())
        menu.add("Delete transition") {
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
        return updateDrop(sender)
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
        if libraryDrag(from: info) == nil {
            // Files from Finder: they join the project when dropped.
            if draggedFiles == nil { draggedFiles = FileImport.mediaFiles(in: fileURLs(from: info)) }
            guard let files = draggedFiles, !files.isEmpty else { return [] }
            let point = CGPoint(x: local.x, y: local.y + offset)
            var time = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
            snapLine = nil
            if model.snapping {
                let targets = SnapTargets.collect(in: model.project, playhead: model.playback.time, inPoint: model.inPoint, outPoint: model.outPoint)
                if let snapped = targets.nearest(to: time, within: model.timeline.scale.duration(forPixels: Theme.Metrics.snapDistance)) { time = snapped }
            }
            let lane = container.layoutCache.lane(atY: point.y)
            fileDrop = (files, time, lane?.trackID)
            drop = nil
            previewProject = nil
            snapLine = time
            let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
            dragLabel = ("Add \(what) at \(Timecode.string(time, rate: model.frameRate))", point)
            container.relayoutLanes()
            container.setAllNeedsDisplay()
            return .copy
        }
        guard let dragged = libraryDrag(from: info) else { return [] }
        let point = CGPoint(x: local.x, y: local.y + offset)
        var time = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
        snapLine = nil
        if model.snapping {
            let targets = SnapTargets.collect(in: model.project, playhead: model.playback.time, inPoint: model.inPoint, outPoint: model.outPoint)
            if let snapped = targets.nearest(to: time, within: model.timeline.scale.duration(forPixels: Theme.Metrics.snapDistance)) {
                time = snapped
                snapLine = snapped
            }
        }
        let lane = container.layoutCache.lane(atY: point.y)
        let at = Timecode.string(time, rate: model.frameRate)
        let batch: EditBatch?
        var label: String
        assetDrop = nil
        switch dragged {
        case .media(let ids):
            let insert = NSEvent.modifierFlags.contains(.command)
            batch = TimelineEdits.placeMedia(model.project, mediaIDs: ids, at: time, trackID: lane?.trackID, insert: insert)
            label = (insert ? "Insert at " : "Place at ") + at
        case .asset(let id):
            // Placed once it's downloaded; the line shows where.
            let name = AssetLibraryHost.shared.dragged.map { $0.id == id ? $0.name : "asset" } ?? "asset"
            assetDrop = (id, time)
            drop = nil
            previewProject = nil
            snapLine = time
            dragLabel = ((NSEvent.modifierFlags.contains(.command) ? "Insert \(name) at " : "Add \(name) at ") + at, point)
            container.relayoutLanes()
            container.setAllNeedsDisplay()
            return .copy
        case .transition(let type):
            batch = LibraryDrops.transition(type, at: time, trackID: lane?.trackID, in: model.project)
            label = batch?.label ?? "Drop on a cut"
        case .effect(let type):
            let clipID = tester(for: model.project)?.hit(point).clipID
            batch = LibraryDrops.effect(type, on: clipID, in: model.project)
            let name = clipID.flatMap { model.project.clip($0) }.map { ClipRenderer(project: model.project, scale: model.timeline.scale, artwork: nil, visible: 0...0).name(of: $0) }
            label = batch.map { "\($0.label) to \(name ?? "clip")" } ?? "Drop on a clip"
        case .title(let id):
            batch = TitlePresets.preset(id).flatMap { LibraryDrops.title($0, at: time, in: model.project) }
            label = (batch?.label ?? "Add title") + " at " + at
        case .template(let id):
            batch = BuiltInTemplates.template(id).map { LibraryDrops.template($0, at: time) }
            label = (batch?.label ?? "Add template") + " at " + at
        }
        guard let batch else {
            drop = nil
            previewProject = nil
            dragLabel = (label, point)
            container.relayoutLanes()
            container.setAllNeedsDisplay()
            return []
        }
        drop = (batch, lane?.trackID)
        previewProject = EditPreview.apply(batch, to: model.project)
        dragLabel = (label, point)
        container.relayoutLanes()
        container.setAllNeedsDisplay()
        return previewProject == nil ? [] : .copy
    }

    private func clearDrop() {
        drop = nil
        assetDrop = nil
        fileDrop = nil
        previewProject = nil
        snapLine = nil
        dragLabel = nil
        container?.relayoutLanes()
        container?.setAllNeedsDisplay()
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

/// Recent draw times per view, for checking the timeline stays smooth on
/// big projects. `tandem://debug` writes them out.
@MainActor
enum DrawTiming {
    private static var samples: [String: [Double]] = [:]

    static func record(_ name: String, _ seconds: Double) {
        var list = samples[name, default: []]
        list.append(seconds)
        if list.count > 240 { list.removeFirst(list.count - 240) }
        samples[name] = list
    }

    static var summary: String {
        samples.keys.sorted().map { name in
            let list = samples[name] ?? []
            let sorted = list.sorted()
            let average = list.reduce(0, +) / Double(max(list.count, 1))
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return String(format: "%@: %d draws, average %.2f ms, p95 %.2f ms, max %.2f ms", name, list.count, average * 1000, p95 * 1000, (sorted.last ?? 0) * 1000)
        }.joined(separator: "\n")
    }
}
