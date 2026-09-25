import AppKit
import QuartzCore
import TandemCore

/// Track names down the left, with lock, mute and hide toggles and a menu
/// for track settings.
@MainActor
final class TimelineHeaderView: TimelineChildView {
    private var model: EditorModel? { container?.model }
    private var hoverTrackID: String?
    private var trackingArea: NSTrackingArea?

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
        if resizeLane(at: event) != nil { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
    }

    /// The lane whose bottom edge is under the pointer, for resizing.
    private func resizeLane(at event: NSEvent) -> TimelineLane? {
        guard let container else { return nil }
        let y = convert(event.locationInWindow, from: nil).y + offset
        return container.layoutCache.lanes.first { lane in
            lane.trackID != nil && abs(lane.maxY + Theme.Metrics.trackGap / 2 - y) <= 3
        }
    }

    private var resizing: (trackID: String, startY: CGFloat, startHeight: CGFloat)?

    override func mouseDragged(with event: NSEvent) {
        guard let resizing, let model else { return }
        let y = convert(event.locationInWindow, from: nil).y
        let height = min(max(resizing.startHeight + y - resizing.startY, 16), 160)
        model.timeline.trackHeights[resizing.trackID] = height.rounded()
    }

    override func mouseUp(with event: NSEvent) {
        resizing = nil
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
    private func toggleRects(_ lane: TimelineLane) -> [(Toggle, CGRect)] {
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
        let project = container.displayedProject
        context.setFillColor(Theme.window.cg)
        context.fill(dirtyRect.intersection(bounds))
        for lane in container.layoutCache.lanes {
            let rect = CGRect(x: 0, y: lane.y - offset, width: bounds.width, height: lane.height)
            guard rect.intersects(dirtyRect) else { continue }
            guard let trackID = lane.trackID, let track = project.track(trackID) else {
                draw("Transcript", at: CGPoint(x: 14, y: rect.midY - 7), font: Theme.Fonts.ui(10.5), color: Theme.textFaint)
                continue
            }
            let subtitle = Self.subtitle(for: track, in: project)
            let nameFont = Theme.Fonts.ui(11, .semibold)
            let showSubtitle = subtitle != nil && lane.height >= 34
            let nameY = showSubtitle ? rect.midY - 14 : rect.midY - 7
            let dimmed = track.hidden || (track.kind == .audio && track.muted)
            let hovering = hoverTrackID == trackID
            // Names use the full width unless the toggles are showing.
            let togglesShown = hovering || track.locked || track.hidden || (track.kind == .audio && track.muted)
            let nameMaxX = bounds.width - (togglesShown ? 44 : 6)
            draw(track.name, at: CGPoint(x: 14, y: nameY), font: nameFont, color: dimmed ? Theme.textFaint : Theme.textStrong, maxX: nameMaxX)
            if showSubtitle, let subtitle {
                draw(subtitle, at: CGPoint(x: 14, y: nameY + 16), font: Theme.Fonts.ui(10), color: Theme.textFaint, maxX: nameMaxX)
            }
            for (toggle, box) in toggleRects(lane) where lane.height >= 18 {
                let active: Bool
                switch toggle {
                case .lock: active = track.locked
                case .visibility: active = track.kind == .video ? track.hidden : track.muted
                }
                guard active || hovering else { continue }
                drawIcon(toggle, kind: track.kind, active: active, in: box, context: context)
            }
        }
    }

    /// What the design shows under a track name: "cutout · look",
    /// "zoom", "isolated · −14 LUFS".
    static func subtitle(for track: Track, in project: Project) -> String? {
        var parts: [String] = []
        switch track.kind {
        case .video:
            if track.clips.contains(where: { $0.video?.cutout?.enabled == true }) { parts.append("cutout") }
            let mediaIDs = Set(track.clips.compactMap(\.mediaID))
            if project.media.contains(where: { mediaIDs.contains($0.id) && !$0.look.isEmpty }) { parts.append("look") }
            if track.clips.contains(where: { ($0.video?.transform.scale ?? 1) > 1.001 || $0.keyframes["video.transform.scale"] != nil }) { parts.append("zoom") }
        case .audio:
            if track.clips.contains(where: { ($0.audio?.voiceIsolation ?? 0) > 0 }) { parts.append("isolated") }
            if let target = track.clips.compactMap({ $0.audio?.normalizeTo }).first {
                parts.append(String(format: "%.0f LUFS", target).replacingOccurrences(of: "-", with: "−"))
            }
        }
        if track.locked { parts.append("locked") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        for (toggle, box) in toggleRects(lane) where box.insetBy(dx: -3, dy: -3).contains(point) {
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
        // Clicking a name selects everything on the track.
        model.selection = Set(track.clips.map(\.id))
    }

    private func update(_ track: Track, _ fields: [String: JSONValue], label: String) {
        model?.apply(EditBatch(label: label, commands: [.updateTrack(trackID: track.id, patch: .object(fields))]))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model, let lane = lane(at: event), let trackID = lane.trackID, let track = model.project.track(trackID) else { return nil }
        let menu = NSMenu()
        menu.add(track.locked ? "Unlock" : "Lock", checked: track.locked) {
            model.apply(EditBatch(label: track.locked ? "Unlock track" : "Lock track", commands: [.updateTrack(trackID: trackID, patch: .object(["locked": .bool(!track.locked)]))]))
        }
        if track.kind == .video {
            menu.add("Hidden", checked: track.hidden) {
                model.apply(EditBatch(label: track.hidden ? "Show track" : "Hide track", commands: [.updateTrack(trackID: trackID, patch: .object(["hidden": .bool(!track.hidden)]))]))
            }
        } else {
            menu.add("Muted", checked: track.muted) {
                model.apply(EditBatch(label: track.muted ? "Unmute track" : "Mute track", commands: [.updateTrack(trackID: trackID, patch: .object(["muted": .bool(!track.muted)]))]))
            }
            menu.add("Solo", checked: track.solo) {
                model.apply(EditBatch(label: track.solo ? "Unsolo track" : "Solo track", commands: [.updateTrack(trackID: trackID, patch: .object(["solo": .bool(!track.solo)]))]))
            }
        }
        menu.add("Targeted for cuts", checked: track.targeted) {
            model.apply(EditBatch(label: track.targeted ? "Untarget track" : "Target track", commands: [.updateTrack(trackID: trackID, patch: .object(["targeted": .bool(!track.targeted)]))]))
        }
        menu.addSubmenu("Ripple") { sub in
            let options: [(RippleMode, String)] = [(.cut, "Cut with the take"), (.follow, "Follow the take"), (.off, "Stay put")]
            for (mode, title) in options {
                sub.add(title, checked: track.rippleMode == mode) {
                    model.apply(EditBatch(label: "Ripple mode", commands: [.updateTrack(trackID: trackID, patch: .object(["rippleMode": .string(mode.rawValue)]))]))
                }
            }
        }
        menu.addItem(.separator())
        menu.add("Rename…") { [weak self] in self?.rename(track) }
        let index = (track.kind == .video ? model.project.videoTracks : model.project.audioTracks).firstIndex { $0.id == trackID } ?? 0
        // Video tracks are listed bottom to top, so "above" is a higher index.
        menu.add(track.kind == .video ? "Add video track above" : "Add audio track below") {
            model.apply(EditBatch(label: "Add track", commands: [.addTrack(kind: track.kind, index: index + 1)]))
        }
        menu.add("Delete track", enabled: track.clips.isEmpty) {
            model.apply(EditBatch(label: "Delete track", commands: [.removeTrack(trackID: trackID)]))
        }
        return menu
    }

    private func rename(_ track: Track) {
        guard let model else { return }
        let alert = NSAlert()
        alert.messageText = "Rename track"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: track.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != track.name else { return }
        model.apply(EditBatch(label: "Rename track", commands: [.updateTrack(trackID: track.id, patch: .object(["name": .string(name)]))]))
    }
}
