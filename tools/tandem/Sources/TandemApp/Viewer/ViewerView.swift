import AVFoundation
import AppKit
import TandemCore

/// The viewer canvas. Plays the composition through an `AVPlayerLayer`
/// when the render module can build one; until then it draws a schematic of
/// what's under the playhead (each layer's box, text and solids) from the
/// same transform maths, so layouts can be checked without a render.
@MainActor
final class ViewerView: NSView, CaptureAware {
    let model: EditorModel
    private let playerHost = PlayerHostView()
    private let overlay = ViewerOverlayView()
    private var loops: [ObservationLoop] = []
    /// 1 fits the canvas. Above that it's magnified; below, it's smaller
    /// than the viewer, with room around it. Either way it pans.
    var zoom: CGFloat = 1 {
        didSet { needsLayout = true; setNeedsDisplayEverywhere() }
    }
    var pan: CGPoint = .zero {
        didSet { needsLayout = true; setNeedsDisplayEverywhere() }
    }
    static let zoomRange: ClosedRange<CGFloat> = 0.25...8
    /// Tells the transport bar when a pinch or the wheel changes the zoom.
    var onZoomChange: ((CGFloat) -> Void)?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        wantsLayer = true
        clipsToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = Theme.viewer.cg
        playerHost.host(model.playback.playerLayers + [model.playback.stillLayer])
        addSubview(playerHost)
        overlay.viewer = self
        addSubview(overlay)
        loops.append(ObservationLoop(read: { [weak self] in self?.readState() }, onChange: { [weak self] in
            self?.needsLayout = true
            self?.setNeedsDisplayEverywhere()
        }))
        // Drags here or in the inspector move the picture itself, not just
        // its outline: the player draws the previews until the edit lands.
        loops.append(ObservationLoop(read: { [weak self] in _ = self?.model.videoPreview }, onChange: { [weak self] in
            guard let self else { return }
            self.model.playback.previewVideo(self.model.videoPreview)
        }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private func readState() {
        _ = model.project
        _ = model.playback.time
        _ = model.playback.hasComposition
        _ = model.playback.renderMessage
        _ = model.selection
        _ = model.showSafeMargins
        _ = model.videoPreview
    }

    func setNeedsDisplayEverywhere() {
        needsDisplay = true
        overlay.needsDisplay = true
    }

    var canvasRect: CGRect {
        CanvasGeometry.canvasRect(in: bounds, width: model.project.settings.width, height: model.project.settings.height, zoom: zoom, pan: pan)
    }

    override func layout() {
        super.layout()
        let canvas = canvasRect
        playerHost.frame = canvas
        playerHost.isHidden = !model.playback.hasComposition
        overlay.frame = bounds
        // Stills are rendered at the size they're shown, in pixels.
        let scale = window?.backingScaleFactor ?? 2
        model.playback.stillSize = CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
    }

    // MARK: - Schematic

    /// The video clips under the playhead, bottom track first, with the
    /// properties they have at this moment.
    func visibleLayers() -> [(clip: Clip, track: Track, video: VideoProperties)] {
        let project = model.project
        let time = model.playback.time
        var layers: [(Clip, Track, VideoProperties)] = []
        for track in project.videoTracks where !track.hidden {
            guard let clip = track.clip(at: time), clip.enabled else { continue }
            if case .adjustment = clip.content { continue }
            let video = model.videoPreview[clip.id] ?? clip.resolvedVideo(at: time - clip.start)
            layers.append((clip, track, video))
        }
        return layers
    }

    func frame(of clip: Clip, video: VideoProperties) -> CGRect {
        CanvasGeometry.frame(source: CanvasGeometry.sourceSize(of: clip, in: model.project), transform: video.transform, canvas: canvasRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(Theme.viewer.cg)
        context.fill(bounds)
        let canvas = canvasRect
        if model.playback.hasComposition {
            // The player layer draws the picture; a window capture can't see
            // it, so draw the current frame into the capture instead.
            guard WindowSnapshot.isCapturing, let frame = model.playback.currentFrame() else { return }
            context.saveGState()
            context.translateBy(x: canvas.minX, y: canvas.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(frame, in: CGRect(origin: .zero, size: canvas.size))
            context.restoreGState()
            return
        }
        context.setFillColor(Theme.canvas.cg)
        context.fill(canvas)
        context.saveGState()
        context.clip(to: canvas)
        for (clip, _, video) in visibleLayers() {
            drawLayer(clip, video: video, canvas: canvas, in: context)
        }
        context.restoreGState()
        context.setStrokeColor(Theme.sheetDivider.cg)
        context.setLineWidth(1)
        context.stroke(canvas.insetBy(dx: -0.5, dy: -0.5))
        if let message = model.playback.renderMessage, !model.playback.hasComposition {
            let font = Theme.Fonts.ui(10.5)
            let text = "Layout preview · \(message)"
            (text as NSString).draw(at: CGPoint(x: canvas.minX + 10, y: canvas.maxY - 20), withAttributes: [.font: font, .foregroundColor: Theme.textFaint.ns])
        }
    }

    private func drawLayer(_ clip: Clip, video: VideoProperties, canvas: CGRect, in context: CGContext) {
        let project = model.project
        let full = frame(of: clip, video: video)
        let visible = CanvasGeometry.cropped(full, crop: video.crop)
        guard visible.width > 1, visible.height > 1 else { return }
        context.saveGState()
        context.setAlpha(CGFloat(min(max(video.opacity, 0), 1)))
        // Rotate about the centre of the uncropped source.
        context.translateBy(x: full.midX, y: full.midY)
        context.rotate(by: CGFloat(video.transform.rotation) * .pi / 180)
        context.translateBy(x: -full.midX, y: -full.midY)
        let item = clip.mediaID.flatMap { project.media($0) }
        let scaleFactor = canvas.height / 1080
        switch clip.content {
        case .solid(let color):
            context.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a))
            context.fill(visible)
        case .text(let text):
            drawText(text, in: visible, canvas: canvas, scaleFactor: scaleFactor, context: context)
        case .graphic(let graphic):
            fill(visible, Theme.graphicClip, context)
            label(clip.name ?? graphic.template, in: visible, colour: Theme.graphicClip.label, context: context)
        case .adjustment:
            break
        case .media:
            let role = item?.role ?? .other
            switch role {
            case .camera:
                let cutout = video.cutout?.enabled == true
                if !cutout { fill(visible, Theme.cameraClip, context) }
                drawPerson(in: visible, cutout: cutout, context: context)
            case .screen:
                fill(visible, Theme.screenClip, context)
                drawScreenChrome(in: visible, context: context)
            default:
                fill(visible, Theme.brollClip, context)
            }
            let name = ClipRenderer.name(of: clip, in: project)
            label(name, in: visible, colour: Theme.textSecondary, context: context)
        }
        context.restoreGState()
    }

    private func fill(_ rect: CGRect, _ style: Theme.ClipStyle, _ context: CGContext) {
        context.setFillColor(style.fill.cg)
        context.fill(rect)
        context.setStrokeColor(style.border.cg)
        context.setLineWidth(1)
        context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
    }

    private func label(_ text: String, in rect: CGRect, colour: Swatch, context: CGContext) {
        guard rect.width > 40, rect.height > 18 else { return }
        let font = Theme.Fonts.ui(min(11, max(9, rect.height / 14)), .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: CGRect(x: rect.minX + 8, y: rect.minY + 6, width: rect.width - 16, height: font.pointSize + 5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: font, .foregroundColor: colour.ns, .paragraphStyle: paragraph])
    }

    /// A head-and-shoulders outline standing in for the camera picture.
    private func drawPerson(in rect: CGRect, cutout: Bool, context: CGContext) {
        let unit = min(rect.width / 16, rect.height / 9)
        let centreX = rect.midX
        let head = CGRect(x: centreX - unit * 1.9, y: rect.maxY - unit * 7.6, width: unit * 3.8, height: unit * 4.3)
        let shoulders = CGMutablePath()
        shoulders.move(to: CGPoint(x: centreX - unit * 4.8, y: rect.maxY))
        shoulders.addCurve(to: CGPoint(x: centreX + unit * 4.8, y: rect.maxY), control1: CGPoint(x: centreX - unit * 4.4, y: rect.maxY - unit * 3.6), control2: CGPoint(x: centreX + unit * 4.4, y: rect.maxY - unit * 3.6))
        shoulders.closeSubpath()
        context.setFillColor((cutout ? Theme.cutoutFigure : Theme.cameraClip.detail).cg)
        context.fillEllipse(in: head)
        context.addPath(shoulders)
        context.fillPath()
    }

    /// A few window bars standing in for a screen recording.
    private func drawScreenChrome(in rect: CGRect, context: CGContext) {
        context.setFillColor(Theme.screenClip.detail.cg)
        let bar = rect.height * 0.06
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bar))
        let lines = 6
        for index in 0..<lines {
            let y = rect.minY + bar * 2.2 + CGFloat(index) * rect.height * 0.12
            let width = rect.width * (index % 3 == 0 ? 0.62 : 0.44)
            context.fill(CGRect(x: rect.minX + rect.width * 0.08, y: y, width: width, height: max(2, rect.height * 0.035)))
        }
    }

    private func drawText(_ text: TextContent, in rect: CGRect, canvas: CGRect, scaleFactor: CGFloat, context: CGContext) {
        let style = text.style
        let size = max(6, CGFloat(style.size) * scaleFactor)
        let weight: NSFont.Weight = style.weight >= 750 ? .heavy : (style.weight >= 650 ? .bold : (style.weight >= 550 ? .semibold : .regular))
        let font = NSFont(name: style.font, size: size).map { NSFontManager.shared.convert($0, toHaveTrait: style.weight >= 650 ? .boldFontMask : []) } ?? NSFont.systemFont(ofSize: size, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment == "left" ? .left : (style.alignment == "right" ? .right : .center)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(srgbRed: style.color.r, green: style.color.g, blue: style.color.b, alpha: style.color.a),
            .paragraphStyle: paragraph
        ]
        if style.shadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = size * 0.08
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.03)
            attributes[.shadow] = shadow
        }
        let string = style.uppercase ? text.text.uppercased() : text.text
        let bounding = (string as NSString).boundingRect(with: CGSize(width: rect.width * 0.9, height: rect.height), options: [.usesLineFragmentOrigin], attributes: attributes)
        let box = CGRect(x: rect.midX - bounding.width / 2, y: rect.midY - bounding.height / 2, width: bounding.width, height: bounding.height)
        if let background = style.backgroundColor {
            let padded = box.insetBy(dx: -size * 0.35, dy: -size * 0.15)
            context.addPath(CGPath(roundedRect: padded, cornerWidth: size * 0.15, cornerHeight: size * 0.15, transform: nil))
            context.setFillColor(CGColor(srgbRed: background.r, green: background.g, blue: background.b, alpha: background.a))
            context.fillPath()
        }
        (string as NSString).draw(with: box, options: [.usesLineFragmentOrigin], attributes: attributes)
    }

    // MARK: - Zoom and pan

    /// Zooms to `newZoom` keeping `point` (viewer coordinates) still, or
    /// about the middle.
    func setZoom(_ newZoom: CGFloat, about point: CGPoint? = nil) {
        let clamped = min(max(newZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard abs(clamped - zoom) > 0.0001 else { return }
        let settings = model.project.settings
        let anchor = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        pan = abs(clamped - 1) < 0.001 ? .zero : CanvasGeometry.pan(keeping: anchor, in: bounds, width: settings.width, height: settings.height, from: zoom, to: clamped, pan: pan)
        zoom = clamped
        onZoomChange?(zoom)
    }

    func zoomToFit() {
        pan = .zero
        setZoom(1)
        onZoomChange?(zoom)
    }

    /// Command or Option with the wheel (or a pinch) zooms about the
    /// pointer, as on the timeline. Away from fit, the wheel pans.
    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            dx *= 8
            dy *= 8
        }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            setZoom(zoom * pow(1.01, dy + dx), about: convert(event.locationInWindow, from: nil))
            return
        }
        guard zoom != 1 || pan != .zero else { return super.scrollWheel(with: event) }
        pan = CGPoint(x: pan.x + dx, y: pan.y + dy)
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), about: convert(event.locationInWindow, from: nil))
    }
}

/// Hosts the playback layers (two players and the paused still), all
/// sized to the canvas.
final class PlayerHostView: NSView {
    private var hosted: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func host(_ layers: [CALayer]) {
        hosted = layers
        for layer in layers { self.layer?.addSublayer(layer) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in hosted { layer.frame = bounds }
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Selection box, safe margins and the drags that move, scale and zoom.
@MainActor
final class ViewerOverlayView: NSView {
    weak var viewer: ViewerView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    private enum Drag {
        case move(clipID: String, start: CGPoint, original: VideoProperties)
        case scale(clipID: String, start: CGPoint, centre: CGPoint, original: VideoProperties)
        case zoomRect(start: CGPoint, end: CGPoint)
    }
    private var drag: Drag?

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var model: EditorModel? { viewer?.model }

    /// The selected video clip under the playhead, with its box.
    private func selectedLayer() -> (clip: Clip, video: VideoProperties, frame: CGRect)? {
        guard let viewer, let model else { return nil }
        for (clip, _, video) in viewer.visibleLayers().reversed() where model.selection.contains(clip.id) {
            let full = viewer.frame(of: clip, video: video)
            return (clip, video, CanvasGeometry.cropped(full, crop: video.crop))
        }
        return nil
    }

    private func handles(for rect: CGRect) -> [CGRect] {
        let size: CGFloat = 7
        return [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
        ].map { CGRect(x: $0.x - size / 2, y: $0.y - size / 2, width: size, height: size) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let viewer, let model, let context = NSGraphicsContext.current?.cgContext else { return }
        let canvas = viewer.canvasRect
        // The edge of the frame, so it's clear what's in the video, zoomed
        // out especially.
        context.setStrokeColor(Theme.textFaint.opacity(0.6).cg)
        context.setLineWidth(1)
        context.stroke(canvas.insetBy(dx: -0.5, dy: -0.5))
        if model.showSafeMargins {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 4])
            context.stroke(canvas.insetBy(dx: canvas.width * 0.05, dy: canvas.height * 0.05))
            context.stroke(canvas.insetBy(dx: canvas.width * 0.1, dy: canvas.height * 0.1))
            context.setLineDash(phase: 0, lengths: [])
        }
        if let (_, _, frame) = selectedLayer() {
            context.setStrokeColor(Theme.amber.cg)
            context.setLineWidth(1.5)
            context.stroke(frame.insetBy(dx: 0.75, dy: 0.75))
            context.setFillColor(Theme.amber.cg)
            for handle in handles(for: frame) { context.fill(handle) }
        }
        if case .zoomRect(let start, let end) = drag {
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            context.setFillColor(Theme.amber.opacity(0.1).cg)
            context.fill(rect)
            context.setStrokeColor(Theme.amber.cg)
            context.setLineWidth(1)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking here takes the keys back from any text field.
        window?.makeFirstResponder(self)
        guard let viewer, let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if model.zoomKeyHeld {
            drag = .zoomRect(start: point, end: point)
            return
        }
        if event.clickCount == 2 {
            viewer.zoomToFit()
            return
        }
        if let (clip, video, frame) = selectedLayer() {
            if handles(for: frame).contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) {
                let full = viewer.frame(of: clip, video: video)
                drag = .scale(clipID: clip.id, start: point, centre: CGPoint(x: full.midX, y: full.midY), original: video)
                return
            }
            if frame.contains(point) {
                drag = .move(clipID: clip.id, start: point, original: video)
                return
            }
        }
        // Select the top clip under the pointer.
        for (clip, _, video) in viewer.visibleLayers().reversed() {
            let rect = CanvasGeometry.cropped(viewer.frame(of: clip, video: video), crop: video.crop)
            if rect.contains(point) {
                model.selection = SelectionRules.members(of: clip.id, in: model.project, linkedSelection: model.linkedSelection, option: event.modifierFlags.contains(.option))
                model.focusedClipID = clip.id
                drag = .move(clipID: clip.id, start: point, original: video)
                return
            }
        }
        model.selection = []
    }

    override func mouseDragged(with event: NSEvent) {
        guard let viewer, let model, let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .move(let id, let start, let original):
            var video = original
            video.transform = CanvasGeometry.moved(original.transform, by: CGSize(width: point.x - start.x, height: point.y - start.y), canvas: viewer.canvasRect)
            model.videoPreview[id] = video
        case .scale(let id, let start, let centre, let original):
            var video = original
            video.transform = CanvasGeometry.scaled(original.transform, centre: centre, from: start, to: point)
            model.videoPreview[id] = video
        case .zoomRect(let start, _):
            self.drag = .zoomRect(start: start, end: point)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let viewer, let model, let drag else { return }
        self.drag = nil
        switch drag {
        case .move(let id, _, let original), .scale(let id, _, _, let original):
            let preview = model.videoPreview[id]
            model.videoPreview[id] = nil
            guard let preview, preview.transform != original.transform, let clip = model.project.clip(id) else { return }
            let transform = preview.transform
            let label = transform.scale != original.transform.scale ? "Scale in viewer" : "Move in viewer"
            // Animated position or scale get a keyframe at the playhead; the
            // rest changes the plain transform.
            let time = model.clipTime(of: clip)
            var commands: [EditCommand] = []
            var plain = (clip.video ?? VideoProperties()).transform
            var plainChanged = false
            if transform.position != original.transform.position {
                if let keyed = KeyframeEdits.setValue(.point(transform.position), for: "video.transform.position", in: clip, at: time, tolerance: model.keyframeTolerance) {
                    commands.append(keyed)
                } else {
                    plain.position = transform.position
                    plainChanged = true
                }
            }
            if transform.scale != original.transform.scale {
                if let keyed = KeyframeEdits.setValue(.number(transform.scale), for: "video.transform.scale", in: clip, at: time, tolerance: model.keyframeTolerance) {
                    commands.append(keyed)
                } else {
                    plain.scale = transform.scale
                    plainChanged = true
                }
            }
            if plainChanged {
                commands += InspectorEdits.transform(id, plain, label: label).commands
            } else {
                commands += KeyframeEdits.layoutCleared(for: ["video.transform.position"], in: clip)
            }
            model.apply(EditBatch(label: label, commands: commands))
        case .zoomRect(let start, let end):
            needsDisplay = true
            let selectionRect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            // Zoom the screen recording (or the bottom layer) under the box.
            let layers = viewer.visibleLayers()
            let target = layers.first { model.project.media($0.clip.mediaID ?? "")?.role == .screen } ?? layers.first
            guard let target, let rect = CanvasGeometry.sourceRect(for: selectionRect, clipFrame: viewer.frame(of: target.clip, video: target.video)) else { return }
            let animated = !event.modifierFlags.contains(.option)
            model.apply(EditBatch(label: animated ? "Zoom in at playhead" : "Zoom in", commands: [
                .zoomToRegion(clipID: target.clip.id, rect: rect, at: animated ? model.playback.time : nil, duration: animated ? Time(seconds: 0.5) : nil)
            ]))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let viewer, let model else { return nil }
        let layers = viewer.visibleLayers()
        guard !layers.isEmpty else { return nil }
        let menu = NSMenu()
        if let screen = layers.first(where: { model.project.media($0.clip.mediaID ?? "")?.role == .screen }) {
            menu.add("Zoom back out at playhead", icon: "minus.magnifyingglass") {
                model.apply(EditBatch(label: "Zoom out at playhead", commands: [
                    .zoomToRegion(clipID: screen.clip.id, rect: Rect(x: 0, y: 0, width: 1, height: 1), at: model.playback.time, duration: Time(seconds: 0.5))
                ]))
            }
            menu.addItem(.separator())
        }
        for preset in LayoutPreset.allCases {
            menu.add("Layout: \(preset.name)", icon: Icons.layout(preset), command: TimelineLanesView.layoutCommand(preset)) {
                model.apply(TimelineEdits.applyLayout(model.project, preset: preset, playhead: model.playback.time, selection: model.selection))
            }
        }
        menu.addItem(.separator())
        menu.add("Safe margins", command: .toggleSafeMargins, checked: model.showSafeMargins) { model.showSafeMargins.toggle() }
        return menu
    }
}
