import AppKit
import AVFoundation

/// Shows the phone's screen edge to edge and turns mouse and keyboard input into touches and typing.
final class MirrorView: NSView {
    enum TouchPhase { case began, moved, ended }

    let previewLayer = AVCaptureVideoPreviewLayer()
    /// The phone's screen size in pixels, used to find where the video sits inside the view.
    var videoSize: CGSize = .zero

    var onTouch: ((TouchPhase, TouchSample) -> Void)?
    var onRightClick: ((TouchSample) -> Void)?
    /// Scroll deltas in view points and where the mouse was, as a fraction of the screen.
    var onScroll: ((NSEvent, CGPoint) -> Void)?
    var onKey: ((NSEvent) -> Void)?
    var onPaste: (() -> Void)?

    private let status = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // A layer-backed view (not layer-hosting) so the status label can sit on top.
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor

        status.alignment = .center
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 13)
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: centerXAnchor),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { previewLayer }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func showStatus(_ text: String?) {
        status.stringValue = text ?? ""
        status.isHidden = text == nil
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let sample = sample(for: event) else { return }
        showTouch(at: convert(event.locationInWindow, from: nil))
        onTouch?(.began, sample)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let sample = sample(for: event, clamped: true) else { return }
        onTouch?(.moved, sample)
    }

    override func mouseUp(with event: NSEvent) {
        guard let sample = sample(for: event, clamped: true) else { return }
        onTouch?(.ended, sample)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let sample = sample(for: event) else { return }
        showTouch(at: convert(event.locationInWindow, from: nil))
        onRightClick?(sample)
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let fraction = MirrorSizing.fraction(of: location, in: bounds.size, video: videoSize, clamped: true) else { return }
        onScroll?(event, fraction)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // ⌘ shortcuts stay with the Mac; everything else is typed on the phone.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
        } else {
            onKey?(event)
        }
    }

    @objc func paste(_ sender: Any?) {
        onPaste?()
    }

    // MARK: - Helpers

    private func sample(for event: NSEvent, clamped: Bool = false) -> TouchSample? {
        let location = convert(event.locationInWindow, from: nil)
        guard let fraction = MirrorSizing.fraction(of: location, in: bounds.size, video: videoSize, clamped: clamped) else { return nil }
        return TouchSample(point: fraction, time: event.timestamp)
    }

    /// A ripple where the click landed, so it's clear where the tap went while the phone catches up.
    private func showTouch(at point: CGPoint) {
        let size: CGFloat = 36
        let ripple = CAShapeLayer()
        ripple.path = CGPath(ellipseIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size), transform: nil)
        ripple.position = point
        ripple.fillColor = NSColor.white.withAlphaComponent(0.35).cgColor
        ripple.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        ripple.lineWidth = 2
        previewLayer.addSublayer(ripple)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        CATransaction.begin()
        CATransaction.setCompletionBlock { ripple.removeFromSuperlayer() }
        ripple.opacity = 0
        ripple.add(group, forKey: "touch")
        CATransaction.commit()
    }
}

/// One window per phone. It remembers where it was for that phone, follows rotation,
/// and sends clicks, drags, scrolling and typing to the phone through its helper.
@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    let device: AVCaptureDevice
    /// Called after the window closes, whether the user closed it or the phone was unplugged.
    var onClose: ((MirrorWindowController) -> Void)?

    private let capture: PhoneCaptureSession
    private let runner: AgentRunner
    private let mirrorView = MirrorView()
    private var videoSize: CGSize = .zero
    private let restoredFrame: Bool

    private var touchSamples: [TouchSample] = []
    private var scrollDelta = CGVector.zero
    private var scrollAnchor = CGPoint(x: 0.5, y: 0.5)
    private var scrollFlush: DispatchWorkItem?

    var isFloating: Bool { window?.level == .floating }

    init(device: AVCaptureDevice) {
        self.device = device
        capture = PhoneCaptureSession(device: device)
        runner = AgentRunner(phoneName: device.localizedName)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: MirrorSizing.placeholderSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = device.localizedName
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = mirrorView
        // Keyed by the capture device so each phone reopens where it was last left.
        let autosaveName = "PhoneMirror.\(device.uniqueID)"
        restoredFrame = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        if !restoredFrame { window.center() }
        super.init(window: window)
        window.delegate = self
        window.initialFirstResponder = mirrorView

        mirrorView.previewLayer.session = capture.session
        mirrorView.showStatus("Waiting for \(device.localizedName)…\nUnlock it, and tap Trust if it asks.")
        capture.onVideoSize = { [weak self] size in self?.apply(videoSize: size) }
        capture.onError = { [weak self] message in self?.mirrorView.showStatus(message) }
        runner.onStateChange = { [weak self] _ in self?.updateSubtitle() }
        connectInput()
        updateSubtitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func start() {
        showWindow(nil)
        capture.start()
        runner.start()
    }

    func toggleFloating() {
        window?.level = isFloating ? .normal : .floating
    }

    /// Sizes the window so one phone pixel is one screen pixel.
    func showActualSize() {
        guard let window, videoSize != .zero else { return }
        let scale = window.backingScaleFactor
        resize(window, toContent: CGSize(width: videoSize.width / scale, height: videoSize.height / scale))
    }

    func pressHome() {
        runner.agent?.pressHome()
    }

    /// Stops the phone's helper so it doesn't outlive the app.
    func stopHelper() {
        runner.stop()
    }

    /// Handles `phonemirror://` commands for testing control from the terminal:
    /// `tap?x=0.5&y=0.5` (fractions of the screen), `type?text=hello`, `swipe?dy=-300`, `home`.
    func perform(_ url: URL) {
        guard let agent = runner.agent else {
            Log.info("url \(url.absoluteString): helper not ready (\(runner.state))")
            return
        }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { $1 }
        )
        let number = { (name: String, fallback: Double) in Double(query[name] ?? "") ?? fallback }
        let screen = agent.screenSize
        switch url.host?.lowercased() {
        case "tap":
            agent.tap(GestureClassifier.phonePoint(CGPoint(x: number("x", 0.5), y: number("y", 0.5)), on: screen))
        case "type":
            agent.type(query["text"] ?? "")
        case "swipe":
            let anchor = GestureClassifier.phonePoint(CGPoint(x: 0.5, y: 0.5), on: screen)
            agent.drag(ScrollSwipe.path(anchor: anchor, delta: CGVector(dx: number("dx", 0), dy: number("dy", 0)), screen: screen), holdAtEnd: 0.1)
        case "home":
            agent.pressHome()
        default:
            Log.info("url \(url.absoluteString): unknown command")
        }
    }

    func windowWillClose(_ notification: Notification) {
        runner.stop()
        capture.stop()
        onClose?(self)
    }

    // MARK: - Input

    private func connectInput() {
        mirrorView.onTouch = { [weak self] phase, sample in self?.touch(phase, sample) }
        mirrorView.onRightClick = { [weak self] sample in
            guard let agent = self?.runner.agent else { return }
            agent.longPress(GestureClassifier.phonePoint(sample.point, on: agent.screenSize), duration: 0.8)
        }
        mirrorView.onScroll = { [weak self] event, fraction in self?.scroll(event, at: fraction) }
        mirrorView.onKey = { [weak self] event in
            guard let text = PhoneKeys.text(keyCode: event.keyCode, characters: event.characters) else { return }
            self?.runner.agent?.type(text)
        }
        mirrorView.onPaste = { [weak self] in
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
            self?.runner.agent?.type(text)
        }
    }

    private func touch(_ phase: MirrorView.TouchPhase, _ sample: TouchSample) {
        switch phase {
        case .began:
            touchSamples = [sample]
        case .moved:
            // Presses that started outside the phone's screen (in the letterbox) are ignored.
            guard !touchSamples.isEmpty else { return }
            touchSamples.append(sample)
        case .ended:
            guard !touchSamples.isEmpty else { return }
            touchSamples.append(sample)
            defer { touchSamples = [] }
            guard let agent = runner.agent,
                  let gesture = GestureClassifier.gesture(from: touchSamples, screen: agent.screenSize) else { return }
            switch gesture {
            case .tap(let point): agent.tap(point)
            case .longPress(let point, let duration): agent.longPress(point, duration: duration)
            case .drag(let path): agent.drag(path)
            }
        }
    }

    /// Collects scrolling for a moment, then sends it as one finger drag. The drag holds still
    /// before lifting so the phone scrolls exactly that far instead of flinging.
    private func scroll(_ event: NSEvent, at fraction: CGPoint) {
        guard let agent = runner.agent, videoSize.width > 0 else { return }
        let screen = agent.screenSize
        let shownWidth = MirrorSizing.videoRect(in: mirrorView.bounds.size, video: videoSize).width
        // Trackpads report view points; mouse wheels report lines.
        let scale = event.hasPreciseScrollingDeltas ? screen.width / max(shownWidth, 1) : 30
        scrollDelta.dx += event.scrollingDeltaX * scale
        scrollDelta.dy += event.scrollingDeltaY * scale
        scrollAnchor = fraction

        scrollFlush?.cancel()
        let flush = DispatchWorkItem { [weak self] in self?.flushScroll() }
        scrollFlush = flush
        let longEnough = abs(scrollDelta.dy) > 300 || abs(scrollDelta.dx) > 300
        DispatchQueue.main.asyncAfter(deadline: .now() + (longEnough ? 0 : 0.08), execute: flush)
    }

    private func flushScroll() {
        defer { scrollDelta = .zero }
        guard let agent = runner.agent, abs(scrollDelta.dx) >= 4 || abs(scrollDelta.dy) >= 4 else { return }
        let screen = agent.screenSize
        let anchor = GestureClassifier.phonePoint(scrollAnchor, on: screen)
        agent.drag(ScrollSwipe.path(anchor: anchor, delta: scrollDelta, screen: screen), holdAtEnd: 0.1)
    }

    // MARK: - Window

    private func updateSubtitle() {
        guard let window else { return }
        switch runner.state {
        case .idle: window.subtitle = ""
        case .starting: window.subtitle = "Starting touch control…"
        case .building: window.subtitle = "Setting up touch control for this phone…"
        case .locked: window.subtitle = "Unlock the phone to control it"
        case .ready: window.subtitle = "Click to tap · drag to swipe · type to type"
        case .failed(let message): window.subtitle = message
        }
    }

    private func apply(videoSize newSize: CGSize) {
        guard newSize != videoSize, let window else { return }
        let isFirstFrame = videoSize == .zero
        videoSize = newSize
        mirrorView.videoSize = newSize
        mirrorView.showStatus(nil)
        window.contentAspectRatio = newSize
        if !isFirstFrame { runner.agent?.updateScreenSize() }

        let current = window.contentRect(forFrameRect: window.frame).size
        if isFirstFrame && !restoredFrame {
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            resize(window, toContent: MirrorSizing.initialContentSize(for: newSize, visibleFrame: visible))
            window.center()
        } else {
            resize(window, toContent: MirrorSizing.contentSize(for: newSize, keepingLongEdgeOf: current))
        }
    }

    private func resize(_ window: NSWindow, toContent size: CGSize) {
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        window.setFrame(MirrorSizing.frame(window.frame, resizedTo: frameSize), display: true)
    }
}
