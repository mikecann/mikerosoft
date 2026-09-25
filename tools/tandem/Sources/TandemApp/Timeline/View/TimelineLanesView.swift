import AppKit
import TandemCore
import TandemMedia

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
    private var marquee: (start: CGPoint, end: CGPoint)?
    private var snapLine: Time?
    private var dragLabel: (text: String, point: CGPoint)?
    private var drop: (batch: EditBatch, laneID: String?)?
    private var autoscrollTimer: Timer?
    private var lastDragEvent: NSEvent?
    private var trackingArea: NSTrackingArea?
    private var phraseCache: (revision: Int, phrases: [TranscriptPhrase])?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.tandemMedia, .string])
    }

    override var acceptsFirstResponder: Bool { true }

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
        for (index, phrase) in phrases.enumerated() {
            let x0 = model.timeline.scale.x(phrase.start)
            let next = index + 1 < phrases.count ? model.timeline.scale.x(phrases[index + 1].start) : bounds.width + 400
            guard next >= 0, x0 <= bounds.width else { continue }
            let current = phrase.start <= playhead && playhead < phrase.end
            renderer.drawText(phrase.text, at: CGPoint(x: max(x0, 0) + 2, y: y), maxX: min(next - 6, bounds.width), font: font, color: current ? Theme.text : Theme.textFaint)
        }
    }

    /// Words from the take's transcripts placed on the timeline and grouped
    /// into phrases at pauses.
    private func transcriptPhrases(_ project: Project, artwork: MediaArtwork) -> [TranscriptPhrase] {
        guard let model else { return [] }
        let revision = previewProject == nil ? model.revision : -1
        if let cache = phraseCache, cache.revision == revision, revision >= 0 { return cache.phrases }
        var words: [(text: String, start: Time, end: Time)] = []
        // Transcripts live on the camera sound, placed on the Voice track.
        for track in project.audioTracks where track.rippleMode == .cut {
            for clip in track.clips {
                guard let item = clip.mediaID.flatMap({ project.media($0) }), let transcript = artwork.transcript(for: item) else { continue }
                for word in transcript.words where word.end > clip.sourceStart && word.start < clip.sourceEnd {
                    let start = clip.start + Time(seconds: max(0, (word.start - clip.sourceStart).seconds) / clip.speed)
                    let end = clip.start + Time(seconds: max(0, (word.end - clip.sourceStart).seconds) / clip.speed)
                    words.append((word.text, start, min(end, clip.end)))
                }
            }
        }
        let phrases = TranscriptPhrase.group(words.sorted { $0.start < $1.start })
        phraseCache = (revision, phrases)
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
        let hit = tester.hit(lanePoint(event))
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
            if part == .body && model.tool == .select {
                let next = SelectionRules.click(id, in: model.project, current: model.selection, modifiers: mods, linkedSelection: model.linkedSelection)
                model.selection = next
                if mods.shift || mods.command { return }
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
        if let session {
            if let batch = session.finish() {
                model.apply(batch)
            } else if session.distance < 2, case .clip(let id, _, .body) = pressHit, !(pressModifiers.shift || pressModifiers.command) {
                // A plain click on a selected clip picks just that clip (and
                // its links), like Premiere.
                model.selection = SelectionRules.members(of: id, in: model.project, linkedSelection: model.linkedSelection, option: pressModifiers.option)
            }
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

    // MARK: - Dropping media

    private func mediaIDs(from info: NSDraggingInfo) -> [String] {
        let pasteboard = info.draggingPasteboard
        let text = pasteboard.string(forType: .tandemMedia) ?? pasteboard.string(forType: .string) ?? ""
        if text.hasPrefix(MediaDrag.prefix) {
            return MediaDrag.ids(from: text)
        }
        return model?.draggedMediaIDs ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrop(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDrop()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        _ = updateDrop(sender)
        guard let batch = drop?.batch, let model else {
            clearDrop()
            return false
        }
        clearDrop()
        let result = model.apply(batch)
        if let result {
            model.selection = SelectionRules.pruned(Set(result.createdIDs), in: model.project)
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
        let ids = mediaIDs(from: info)
        guard !ids.isEmpty else { return [] }
        let local = convert(info.draggingLocation, from: nil)
        let point = CGPoint(x: local.x, y: local.y + offset)
        var time = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
        if model.snapping {
            let targets = SnapTargets.collect(in: model.project, playhead: model.playback.time, inPoint: model.inPoint, outPoint: model.outPoint)
            if let snapped = targets.nearest(to: time, within: model.timeline.scale.duration(forPixels: Theme.Metrics.snapDistance)) {
                time = snapped
                snapLine = snapped
            } else {
                snapLine = nil
            }
        }
        let lane = container.layoutCache.lane(atY: point.y)
        let insert = NSEvent.modifierFlags.contains(.command)
        guard let batch = TimelineEdits.placeMedia(model.project, mediaIDs: ids, at: time, trackID: lane?.trackID, insert: insert) else {
            clearDrop()
            return []
        }
        drop = (batch, lane?.trackID)
        previewProject = EditPreview.apply(batch, to: model.project)
        dragLabel = ((insert ? "Insert at " : "Place at ") + Timecode.string(time, rate: model.frameRate), point)
        container.relayoutLanes()
        container.setAllNeedsDisplay()
        return previewProject == nil ? [] : .copy
    }

    private func clearDrop() {
        drop = nil
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
