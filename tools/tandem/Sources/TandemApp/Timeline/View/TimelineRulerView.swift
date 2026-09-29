import AppKit
import QuartzCore
import TandemCore

/// Time labels, ticks, markers and the in and out range. Click or drag to
/// move the playhead; drag a marker to move it; double-click one to rename.
@MainActor
final class TimelineRulerView: TimelineChildView {
    private var model: EditorModel? { container?.model }
    private var draggingMarker: (id: String, offset: Double)?
    private var markerPreview: Time?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let started = CACurrentMediaTime()
        defer { DrawTiming.record("ruler", CACurrentMediaTime() - started) }
        // The container's copy of the model, never the model itself: see
        // `TimelineDrawState`.
        guard let state = container?.drawState, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = state.scale
        let rate = state.frameRate
        context.setFillColor(Theme.window.cg)
        context.fill(bounds)

        // In to out.
        if state.inPoint != nil || state.outPoint != nil {
            let start = state.inPoint ?? .zero
            let end = state.outPoint ?? state.project.duration
            let x0 = scale.x(start)
            let x1 = scale.x(max(start, end))
            context.setFillColor(Theme.amber.opacity(0.14).cg)
            context.fill(CGRect(x: x0, y: bounds.height - 9, width: max(0, x1 - x0), height: 8))
            context.setFillColor(Theme.amber.opacity(0.9).cg)
            if state.inPoint != nil {
                context.fill(CGRect(x: x0, y: bounds.height - 12, width: 1.5, height: 11))
                context.fill(CGRect(x: x0, y: bounds.height - 12, width: 5, height: 1.5))
            }
            if state.outPoint != nil {
                context.fill(CGRect(x: x1 - 1.5, y: bounds.height - 12, width: 1.5, height: 11))
                context.fill(CGRect(x: x1 - 5, y: bounds.height - 12, width: 5, height: 1.5))
            }
        }

        // Markers first, so time labels can make room for them.
        let markerFont = Theme.Fonts.ui(10.5, .semibold)
        var occupied: [CGRect] = []
        var markerDrawings: [(CGRect, Marker, Time)] = []
        let placed = state.project.markers.map { marker -> (Marker, Time) in
            (marker, marker.id == draggingMarker?.id ? (markerPreview ?? marker.time) : marker.time)
        }.sorted { $0.1 < $1.1 }
        for (index, (marker, time)) in placed.enumerated() {
            let x = scale.x(time)
            guard x > -300, x < bounds.width + 10 else { continue }
            var width = (marker.name as NSString).size(withAttributes: [.font: markerFont]).width + 16
            // Labels stop short of the next marker rather than overlapping it.
            if index + 1 < placed.count {
                width = min(width, scale.x(placed[index + 1].1) - x - 4)
            }
            let rect = CGRect(x: x - 4, y: 3, width: max(width, 10), height: 15)
            occupied.append(rect)
            markerDrawings.append((rect, marker, time))
        }

        let step = scale.rulerStep(minimumGap: 110, rate: rate)
        let minor = step / 4
        let firstMinor = (scale.scrollSeconds / minor).rounded(.down) * minor
        let labelFont = Theme.Fonts.digits(10)
        context.setStrokeColor(Theme.tick.cg)
        context.setLineWidth(1)
        var seconds = firstMinor
        let endSeconds = scale.seconds(atX: bounds.width + 60)
        while seconds <= endSeconds {
            let x = scale.x(seconds: seconds).rounded() + 0.5
            let isMajor = abs((seconds / step).rounded() * step - seconds) < minor / 10
            context.move(to: CGPoint(x: x, y: isMajor ? bounds.height - 10 : bounds.height - 5))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            if isMajor {
                let label = Timecode.rulerLabel(max(0, seconds), step: step, rate: rate)
                let size = (label as NSString).size(withAttributes: [.font: labelFont])
                let rect = CGRect(x: x + 4, y: 3, width: size.width, height: 12)
                if !occupied.contains(where: { $0.intersects(rect) }) && seconds >= 0 {
                    (label as NSString).draw(at: CGPoint(x: rect.minX, y: rect.minY), withAttributes: [.font: labelFont, .foregroundColor: Theme.textFaint.ns])
                }
            }
            seconds += minor
        }
        context.strokePath()

        for (rect, marker, _) in markerDrawings {
            let colour: Swatch = marker.kind == .todo ? Theme.red : Theme.amber
            let centre = CGPoint(x: rect.minX + 4, y: 11)
            let diamond = CGMutablePath()
            diamond.move(to: CGPoint(x: centre.x, y: centre.y - 4))
            diamond.addLine(to: CGPoint(x: centre.x + 4, y: centre.y))
            diamond.addLine(to: CGPoint(x: centre.x, y: centre.y + 4))
            diamond.addLine(to: CGPoint(x: centre.x - 4, y: centre.y))
            diamond.closeSubpath()
            context.addPath(diamond)
            context.setFillColor(colour.cg)
            context.fillPath()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let labelWidth = rect.width - 12
            if labelWidth > 8 {
                (marker.name as NSString).draw(
                    with: CGRect(x: rect.minX + 11, y: 4, width: labelWidth, height: 14),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: [.font: markerFont, .foregroundColor: Theme.textStrong.ns, .paragraphStyle: paragraph]
                )
            }
        }

        context.setFillColor(Theme.rulerLine.cg)
        context.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1))
    }

    // MARK: - Mouse

    private func marker(at point: CGPoint) -> Marker? {
        guard let model else { return nil }
        let font = Theme.Fonts.ui(10.5, .semibold)
        return model.project.markers.last { marker in
            let x = model.timeline.scale.x(marker.time)
            let width = (marker.name as NSString).size(withAttributes: [.font: font]).width
            return CGRect(x: x - 6, y: 0, width: width + 18, height: 18).contains(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking here takes the keys back from any text field.
        window?.makeFirstResponder(self)
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let marker = marker(at: point) {
            if event.clickCount == 2 {
                rename(marker)
                return
            }
            draggingMarker = (marker.id, model.timeline.scale.seconds(atX: point.x) - marker.time.seconds)
            markerPreview = marker.time
            return
        }
        model.playback.pause()
        scrub(to: point, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let drag = draggingMarker {
            var time = Time(seconds: max(0, model.timeline.scale.seconds(atX: point.x) - drag.offset)).roundedToFrame(model.frameRate)
            if model.snapping, let snapped = SnapTargets.collect(in: model.project, playhead: model.playback.time).nearest(to: time, within: model.timeline.scale.duration(forPixels: Theme.Metrics.snapDistance)) {
                time = snapped
            }
            markerPreview = time
            needsDisplay = true
            return
        }
        scrub(to: point, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        if let drag = draggingMarker, let time = markerPreview,
           let marker = model.project.markers.first(where: { $0.id == drag.id }), marker.time != time {
            model.apply(EditBatch(label: "Move marker", commands: [.updateMarker(markerID: drag.id, patch: .object(["time": .number(time.seconds)]))]))
        }
        draggingMarker = nil
        markerPreview = nil
        needsDisplay = true
    }

    /// Moves the playhead; Shift snaps it to edits and markers.
    private func scrub(to point: CGPoint, event: NSEvent) {
        guard let model else { return }
        var time = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
        if event.modifierFlags.contains(.shift) {
            let targets = SnapTargets.collect(in: model.project, inPoint: model.inPoint, outPoint: model.outPoint)
            if let snapped = targets.nearest(to: time, within: model.timeline.scale.duration(forPixels: 12)) { time = snapped }
        }
        model.playback.seek(to: time)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let time = model.timeline.scale.time(atX: point.x, rate: model.frameRate)
        let menu = NSMenu()
        if let marker = marker(at: point) {
            menu.add("Rename marker…") { [weak self] in self?.rename(marker) }
            menu.addSubmenu("Kind") { sub in
                for kind in [MarkerKind.marker, .section, .chapter, .todo] {
                    sub.add(kind.rawValue.capitalized, checked: marker.kind == kind) {
                        model.apply(EditBatch(label: "Marker kind", commands: [.updateMarker(markerID: marker.id, patch: .object(["kind": .string(kind.rawValue)]))]))
                    }
                }
            }
            menu.add("Delete marker") {
                model.apply(EditBatch(label: "Delete marker", commands: [.removeMarker(markerID: marker.id)]))
            }
            menu.addItem(.separator())
        }
        menu.add("Add marker here") { model.apply(TimelineEdits.addMarker(model.project, at: time)) }
        menu.add("Mark in here") { model.inPoint = time }
        menu.add("Mark out here") { model.outPoint = time }
        menu.add("Clear in and out", enabled: model.inPoint != nil || model.outPoint != nil) {
            model.inPoint = nil
            model.outPoint = nil
        }
        return menu
    }

    private func rename(_ marker: Marker) {
        guard let model else { return }
        let alert = NSAlert()
        alert.messageText = "Rename marker"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: marker.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != marker.name else { return }
        model.apply(EditBatch(label: "Rename marker", commands: [.updateMarker(markerID: marker.id, patch: .object(["name": .string(name)]))]))
    }
}
