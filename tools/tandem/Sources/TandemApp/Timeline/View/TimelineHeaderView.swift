import AppKit
import QuartzCore
import TandemCore

/// Track names down the left, with lock, mute and hide toggles and a menu
/// for track settings. Drag a name up or down to reorder, double-click it
/// to rename, and right-click to add, move or delete tracks.
@MainActor
final class TimelineHeaderView: TimelineChildView, NSTextFieldDelegate {
    private var model: EditorModel? { container?.model }
    private var hoverTrackID: String?
    private var trackingArea: NSTrackingArea?
    /// A name pressed, which becomes a reorder once it moves.
    private var press: (trackID: String, kind: TrackKind, y: CGFloat)?
    /// The track being dragged and where it would show among its kind.
    private var reorder: (trackID: String, kind: TrackKind, position: Int)?
    private var renameField: NSTextField?
    private var renamingTrackID: String?

    private enum Toggle: CaseIterable { case lock, visibility }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let id = lane(at: event)?.trackID
        if id != hoverTrackID {
            hoverTrackID = id
            needsDisplay = true
        }
        (resizeLane(at: event) != nil ? CursorKind.rowResize : .arrow).set()
    }

    /// The lane whose bottom edge is under the pointer, for resizing.
    private func resizeLane(at event: NSEvent) -> TimelineLane? {
        guard let container else { return nil }
        let y = convert(event.locationInWindow, from: nil).y + offset
        return container.layoutCache.lanes.first { lane in
            lane.trackID != nil && abs(lane.maxY + Theme.Metrics.trackGap / 2 - y) <= Theme.Metrics.trackResizeGrab
        }
    }

    private var resizing: (trackID: String, startY: CGFloat, startHeight: CGFloat)?

    override func mouseDragged(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        if let resizing, let model {
            let height = min(max(resizing.startHeight + y - resizing.startY, 16), 160)
            model.timeline.trackHeights[resizing.trackID] = height.rounded()
            return
        }
        guard let press, let container else { return }
        guard reorder != nil || abs(y - press.y) > 4 else { return }
        let position = TrackEdits.position(forDropAt: y + offset, dragging: press.trackID, kind: press.kind, lanes: container.layoutCache.lanes)
        if reorder?.position != position || reorder == nil {
            reorder = (press.trackID, press.kind, position)
            needsDisplay = true
        }
        CursorKind.grabbing.set()
    }

    override func mouseUp(with event: NSEvent) {
        resizing = nil
        press = nil
        guard let reorder, let model else { return }
        self.reorder = nil
        needsDisplay = true
        NSCursor.arrow.set()
        if let batch = TrackEdits.move(reorder.trackID, toPosition: reorder.position, in: model.project) {
            model.apply(batch)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTrackID = nil
        needsDisplay = true
    }

    private var offset: CGFloat { model?.timeline.verticalOffset ?? 0 }

    private func lane(at event: NSEvent) -> TimelineLane? {
        let point = convert(event.locationInWindow, from: nil)
        return container?.layoutCache.lane(atY: point.y + offset)
    }

    /// The toggle icons' rectangles for a lane, right-aligned.
    private func toggleRects(_ lane: TimelineLane, offset: CGFloat) -> [(Toggle, CGRect)] {
        let size: CGFloat = 14
        let y = lane.y - offset + (lane.height - size) / 2
        return [
            (.visibility, CGRect(x: bounds.width - 8 - size, y: y, width: size, height: size)),
            (.lock, CGRect(x: bounds.width - 8 - size * 2 - 4, y: y, width: size, height: size))
        ]
    }

    override func draw(_ dirtyRect: NSRect) {
        let started = CACurrentMediaTime()
        defer { DrawTiming.record("headers", CACurrentMediaTime() - started) }
        guard let container, let context = NSGraphicsContext.current?.cgContext else { return }
        // The container's copy of the model, never the model itself: see
        // `TimelineDrawState`.
        let project = container.displayedProject
        let offset = container.contentOrigin.y
        context.setFillColor(Theme.window.cg)
        context.fill(dirtyRect.intersection(bounds))
        for lane in container.layoutCache.lanes {
            let rect = CGRect(x: 0, y: lane.y - offset, width: bounds.width, height: lane.height)
            guard rect.intersects(dirtyRect) else { continue }
            guard let trackID = lane.trackID, let track = project.track(trackID) else {
                drawKindIcon(Self.transcriptSymbol, color: Theme.textFaint, midY: rect.midY)
                draw("Transcript", at: CGPoint(x: Self.nameX, y: rect.midY - 7), font: Theme.Fonts.ui(10.5), color: Theme.textFaint)
                continue
            }
            let nameFont = Theme.Fonts.ui(11, .semibold)
            let nameY = rect.midY - 7
            let dimmed = track.hidden || (track.kind == .audio && track.muted)
            let hovering = hoverTrackID == trackID
            // Names use the full width unless the toggles are showing.
            let togglesShown = hovering || track.locked || track.hidden || (track.kind == .audio && track.muted)
            let nameMaxX = bounds.width - (togglesShown ? 44 : 6)
            if reorder?.trackID == trackID {
                context.setFillColor(Theme.rowSelected.cg)
                context.fill(rect)
            }
            if lane.height >= 14 {
                drawKindIcon(Self.symbol(for: track.kind), color: dimmed ? Theme.textFainter : Theme.textFaint, midY: rect.midY)
            }
            if renamingTrackID != trackID {
                draw(track.name, at: CGPoint(x: Self.nameX, y: nameY), font: nameFont, color: dimmed ? Theme.textFaint : Theme.textStrong, maxX: nameMaxX)
            }
            for (toggle, box) in toggleRects(lane, offset: offset) where lane.height >= 18 {
                let active: Bool
                switch toggle {
                case .lock: active = track.locked
                case .visibility: active = track.kind == .video ? track.hidden : track.muted
                }
                guard active || hovering else { continue }
                drawIcon(toggle, kind: track.kind, active: active, in: box, context: context)
            }
        }
        if let reorder, let y = insertionY(for: reorder) {
            context.setFillColor(Theme.amber.cg)
            context.fill(CGRect(x: 4, y: y - offset - 1, width: bounds.width - 8, height: 2))
        }
    }

    /// Where the amber line goes while dragging a track: between the tracks
    /// of its kind it would land between.
    private func insertionY(for reorder: (trackID: String, kind: TrackKind, position: Int)) -> CGFloat? {
        guard let container else { return nil }
        let others = container.layoutCache.lanes.filter { $0.kind == reorder.kind && $0.trackID != nil && $0.trackID != reorder.trackID }
        guard !others.isEmpty else { return nil }
        if reorder.position < others.count { return others[reorder.position].y - Theme.Metrics.trackGap / 2 }
        return others[others.count - 1].maxY + Theme.Metrics.trackGap / 2
    }

    /// Where names start, after the icon that says what kind of track
    /// it is.
    static let nameX: CGFloat = 30
    static let transcriptSymbol = "captions.bubble"

    /// Picture tracks and sound tracks look alike otherwise.
    static func symbol(for kind: TrackKind) -> String {
        kind == .video ? "film" : "waveform"
    }

    private var symbols: [String: NSImage] = [:]

    private func drawKindIcon(_ name: String, color: Swatch, midY: CGFloat) {
        let key = "\(name)|\(color.ns)"
        let image: NSImage
        if let cached = symbols[key] {
            image = cached
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium).applying(.init(paletteColors: [color.ns]))
            guard let made = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
            symbols[key] = made
            image = made
        }
        let size = image.size
        let box = CGRect(x: 12 + (12 - size.width) / 2, y: midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func draw(_ text: String, at point: CGPoint, font: NSFont, color: Swatch, maxX: CGFloat? = nil) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let width = (maxX ?? bounds.width - 4) - point.x
        (text as NSString).draw(with: CGRect(x: point.x, y: point.y, width: max(width, 10), height: font.pointSize + 5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: font, .foregroundColor: color.ns, .paragraphStyle: paragraph])
    }

    private func drawIcon(_ toggle: Toggle, kind: TrackKind, active: Bool, in box: CGRect, context: CGContext) {
        let colour = active ? Theme.amber : Theme.textFaint
        context.saveGState()
        context.setStrokeColor(colour.cg)
        context.setFillColor(colour.cg)
        context.setLineWidth(1.2)
        switch toggle {
        case .lock:
            let body = CGRect(x: box.minX + 3, y: box.minY + 6.5, width: box.width - 6, height: 6)
            context.addPath(CGPath(roundedRect: body, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
            context.fillPath()
            let shackle = CGMutablePath()
            shackle.addArc(center: CGPoint(x: box.midX, y: box.minY + 5.5), radius: 3, startAngle: .pi, endAngle: 0, clockwise: false)
            context.addPath(shackle)
            context.strokePath()
        case .visibility:
            if kind == .video {
                let eye = CGMutablePath()
                eye.move(to: CGPoint(x: box.minX + 1, y: box.midY))
                eye.addQuadCurve(to: CGPoint(x: box.maxX - 1, y: box.midY), control: CGPoint(x: box.midX, y: box.minY + 1))
                eye.addQuadCurve(to: CGPoint(x: box.minX + 1, y: box.midY), control: CGPoint(x: box.midX, y: box.maxY - 1))
                context.addPath(eye)
                context.strokePath()
                context.fillEllipse(in: CGRect(x: box.midX - 2, y: box.midY - 2, width: 4, height: 4))
            } else {
                let speaker = CGMutablePath()
                speaker.move(to: CGPoint(x: box.minX + 2, y: box.midY - 2.5))
                speaker.addLine(to: CGPoint(x: box.minX + 5, y: box.midY - 2.5))
                speaker.addLine(to: CGPoint(x: box.minX + 8.5, y: box.minY + 2))
                speaker.addLine(to: CGPoint(x: box.minX + 8.5, y: box.maxY - 2))
                speaker.addLine(to: CGPoint(x: box.minX + 5, y: box.midY + 2.5))
                speaker.addLine(to: CGPoint(x: box.minX + 2, y: box.midY + 2.5))
                speaker.closeSubpath()
                context.addPath(speaker)
                context.fillPath()
            }
            if active {
                context.move(to: CGPoint(x: box.minX + 1, y: box.maxY - 1))
                context.addLine(to: CGPoint(x: box.maxX - 1, y: box.minY + 1))
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        // Clicking here takes the keys back from any text field.
        window?.makeFirstResponder(self)
        if let lane = resizeLane(at: event), let trackID = lane.trackID {
            if event.clickCount == 2 {
                // Double-click the edge to go back to the standard height.
                model?.timeline.trackHeights[trackID] = nil
                return
            }
            resizing = (trackID, convert(event.locationInWindow, from: nil).y, lane.height)
            return
        }
        guard let model, let lane = lane(at: event), let trackID = lane.trackID, let track = model.project.track(trackID) else { return }
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, !toggleRects(lane, offset: offset).contains(where: { $0.1.insetBy(dx: -3, dy: -3).contains(point) }) {
            beginRename(trackID)
            return
        }
        for (toggle, box) in toggleRects(lane, offset: offset) where box.insetBy(dx: -3, dy: -3).contains(point) {
            switch toggle {
            case .lock:
                update(track, ["locked": .bool(!track.locked)], label: track.locked ? "Unlock track" : "Lock track")
            case .visibility:
                if track.kind == .video {
                    update(track, ["hidden": .bool(!track.hidden)], label: track.hidden ? "Show track" : "Hide track")
                } else {
                    update(track, ["muted": .bool(!track.muted)], label: track.muted ? "Unmute track" : "Mute track")
                }
            }
            return
        }
        // Clicking a name selects everything on the track; dragging it
        // moves the track.
        model.selection = Set(track.clips.map(\.id))
        press = (trackID, track.kind, point.y)
    }

    private func update(_ track: Track, _ fields: [String: JSONValue], label: String) {
        model?.apply(EditBatch(label: label, commands: [.updateTrack(trackID: track.id, patch: .object(fields))]))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        guard let lane = lane(at: event), let trackID = lane.trackID, let track = model.project.track(trackID) else {
            // Below the tracks, or on the transcript lane.
            return Self.addMenu(model: model)
        }
        let menu = NSMenu()
        menu.add(track.locked ? "Unlock" : "Lock", icon: track.locked ? "lock.open" : "lock", checked: track.locked) {
            model.apply(EditBatch(label: track.locked ? "Unlock track" : "Lock track", commands: [.updateTrack(trackID: trackID, patch: .object(["locked": .bool(!track.locked)]))]))
        }
        if track.kind == .video {
            menu.add("Hidden", icon: "eye.slash", checked: track.hidden) {
                model.apply(EditBatch(label: track.hidden ? "Show track" : "Hide track", commands: [.updateTrack(trackID: trackID, patch: .object(["hidden": .bool(!track.hidden)]))]))
            }
        } else {
            menu.add("Muted", icon: "speaker.slash", checked: track.muted) {
                model.apply(EditBatch(label: track.muted ? "Unmute track" : "Mute track", commands: [.updateTrack(trackID: trackID, patch: .object(["muted": .bool(!track.muted)]))]))
            }
            menu.add("Solo", icon: "headphones", checked: track.solo) {
                model.apply(EditBatch(label: track.solo ? "Unsolo track" : "Solo track", commands: [.updateTrack(trackID: trackID, patch: .object(["solo": .bool(!track.solo)]))]))
            }
        }
        menu.add("Targeted for cuts", icon: "scope", checked: track.targeted) {
            model.apply(EditBatch(label: track.targeted ? "Untarget track" : "Target track", commands: [.updateTrack(trackID: trackID, patch: .object(["targeted": .bool(!track.targeted)]))]))
        }
        menu.addSubmenu("Ripple", icon: "arrow.right.to.line") { sub in
            let options: [(RippleMode, String)] = [(.cut, "Cut with the take"), (.follow, "Follow the take"), (.off, "Stay put")]
            for (mode, title) in options {
                sub.add(title, checked: track.rippleMode == mode) {
                    model.apply(EditBatch(label: "Ripple mode", commands: [.updateTrack(trackID: trackID, patch: .object(["rippleMode": .string(mode.rawValue)]))]))
                }
            }
        }
        menu.addItem(.separator())
        menu.add("Rename…", icon: "pencil") { [weak self] in self?.beginRename(trackID) }
        if track.kind == .video {
            menu.add("Add video track above", icon: "plus.rectangle") { model.addTrack(.video, beside: trackID, side: .above) }
            menu.add("Add video track below", icon: "plus.rectangle") { model.addTrack(.video, beside: trackID, side: .below) }
            menu.add("Add audio track at the bottom", icon: "waveform.badge.plus") { model.addTrack(.audio) }
        } else {
            menu.add("Add audio track above", icon: "waveform.badge.plus") { model.addTrack(.audio, beside: trackID, side: .above) }
            menu.add("Add audio track below", icon: "waveform.badge.plus") { model.addTrack(.audio, beside: trackID, side: .below) }
            menu.add("Add video track on top", icon: "plus.rectangle") { model.addTrack(.video) }
        }
        menu.addItem(.separator())
        let up = TrackEdits.move(trackID, up: true, in: model.project)
        let down = TrackEdits.move(trackID, up: false, in: model.project)
        menu.add("Move up", icon: "arrow.up", enabled: up != nil) { model.apply(up) }
        menu.add("Move down", icon: "arrow.down", enabled: down != nil) { model.apply(down) }
        menu.addItem(.separator())
        let remove = TrackEdits.remove(trackID, in: model.project)
        menu.add(TrackEdits.removeTitle(for: track), icon: "trash", enabled: remove != nil) { model.apply(remove) }
        return menu
    }

    /// Adding a track where no track was clicked: the header corner's
    /// button and the space below the tracks.
    static func addMenu(model: EditorModel) -> NSMenu {
        let menu = NSMenu()
        menu.add("Add video track on top", icon: "plus.rectangle") { model.addTrack(.video) }
        menu.add("Add audio track at the bottom", icon: "waveform.badge.plus") { model.addTrack(.audio) }
        return menu
    }

    // MARK: - Renaming

    /// Opens a new track's name for typing once it's on the timeline.
    func syncRename() {
        guard let model, let trackID = model.timeline.renamingTrackID else { return }
        model.timeline.renamingTrackID = nil
        beginRename(trackID)
    }

    /// Turns a track's name into a text field: Return keeps the new name,
    /// Escape leaves it, clicking away keeps it.
    func beginRename(_ trackID: String) {
        endRename(keep: true)
        guard let model, let container, let track = model.project.track(trackID) else { return }
        container.relayoutLanes()
        guard let lane = container.layoutCache.lane(forTrack: trackID) else { return }
        // Scroll the lane into view first.
        if lane.y < offset || lane.maxY > offset + bounds.height {
            model.timeline.verticalOffset = max(0, lane.maxY - bounds.height + 8)
            container.clampVerticalOffset()
        }
        // Over the name, centred in the lane.
        let height: CGFloat = 18
        let nameMid = lane.y - offset + lane.height / 2
        let field = NSTextField(frame: CGRect(x: Self.nameX - 4, y: nameMid - height / 2, width: bounds.width - Self.nameX - 2, height: height))
        field.stringValue = track.name
        field.font = Theme.Fonts.ui(11, .semibold)
        field.textColor = Theme.text.ns
        field.backgroundColor = Theme.field.ns
        field.drawsBackground = true
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = self
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        field.layer?.borderWidth = 1
        field.layer?.borderColor = Theme.amber.cg
        addSubview(field)
        renameField = field
        renamingTrackID = trackID
        needsDisplay = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endRename(keep: Bool) {
        guard let field = renameField, let trackID = renamingTrackID else { return }
        renameField = nil
        renamingTrackID = nil
        let name = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        needsDisplay = true
        if window?.firstResponder == nil || window?.firstResponder is NSTextView { window?.makeFirstResponder(self) }
        guard keep, let model, let batch = TrackEdits.rename(trackID, to: name, in: model.project) else { return }
        model.apply(batch)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === renameField else { return }
        endRename(keep: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === renameField else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endRename(keep: false)
            return true
        }
        return false
    }
}

/// The corner above the track headers, left of the ruler: "+ Track" adds a
/// video or audio track.
@MainActor
final class TimelineCornerView: TimelineChildView {
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Add a video or audio track"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    /// The button's box: text and plus, left aligned under the tools.
    private var buttonRect: CGRect { CGRect(x: 8, y: (bounds.height - 18) / 2, width: 62, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(Theme.window.cg)
        context.fill(bounds)
        let box = buttonRect
        if hovering {
            context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.setFillColor(Theme.rowSelected.cg)
            context.fillPath()
        }
        let colour = hovering ? Theme.text : Theme.textMuted
        context.setStrokeColor(colour.cg)
        context.setLineWidth(1.4)
        context.setLineCap(.round)
        let centre = CGPoint(x: box.minX + 9, y: box.midY)
        context.move(to: CGPoint(x: centre.x - 4, y: centre.y))
        context.addLine(to: CGPoint(x: centre.x + 4, y: centre.y))
        context.move(to: CGPoint(x: centre.x, y: centre.y - 4))
        context.addLine(to: CGPoint(x: centre.x, y: centre.y + 4))
        context.strokePath()
        ("Track" as NSString).draw(at: CGPoint(x: box.minX + 17, y: box.midY - 7.5), withAttributes: [.font: Theme.Fonts.ui(11, .medium), .foregroundColor: colour.ns])
    }

    override func mouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        let box = buttonRect
        menu.popUp(positioning: nil, at: CGPoint(x: box.minX, y: box.maxY + 4), in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model = container?.model else { return nil }
        return TimelineHeaderView.addMenu(model: model)
    }
}
