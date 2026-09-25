import AVFoundation
import CoreImage
import Foundation
import QuartzCore
import Observation
import TandemCore
import TandemMedia
import TandemRender

/// Plays the timeline and owns the playhead.
///
/// The render module builds the project into a composition that plays
/// through `AVPlayer`, from 1080p proxies where they exist (`useProxies`).
/// It can also lay an exact frame from the originals over a paused player
/// (`stillsFromOriginals`), rendered by `FrameRenderer` at the viewer's
/// size; that's off for now, see the flag.
///
/// Two players take turns. A rebuilt composition loads into the one that's
/// hidden, seeks to the playhead and swaps in once its first frame is up,
/// so an edit never flashes the viewer black or loses the playhead. If a
/// build fails, a clock moves the playhead instead, so transport, J K L and
/// the timeline behave the same either way.
@MainActor
@Observable
final class PlaybackController {
    /// Where the playhead is.
    private(set) var time: Time = .zero
    /// 0 when stopped. Negative plays backwards. J and L step through
    /// 1, 2, 4 and 8.
    private(set) var rate: Double = 0
    var isPlaying: Bool { rate != 0 }
    /// The end of the timeline.
    private(set) var duration: Time = .zero
    private(set) var frameRate: FrameRate = .fps30
    /// True once a composition is on screen.
    private(set) var hasComposition = false
    /// Why there's no picture, shown on the placeholder canvas.
    private(set) var renderMessage: String? = "Starting the viewer"
    /// Where the preview can't match the export yet, from the latest build:
    /// a cutout matte still being made, a missing file.
    private(set) var warnings: [String] = []
    /// Play from 1080p proxies where they exist.
    var useProxies = true {
        didSet { if oldValue != useProxies { scheduleRebuild(delay: 0) } }
    }

    /// The layers the viewer hosts: the two players (one hidden) and the
    /// paused still above them. The controller shows and hides them.
    @ObservationIgnored let playerLayers: [AVPlayerLayer]
    @ObservationIgnored let stillLayer = CALayer()
    /// Supplies what to build from. Set by the editor model.
    @ObservationIgnored var makeContext: (() -> RenderContext)?
    /// The canvas size in pixels, so stills are rendered no bigger than
    /// they're shown. Set by the viewer.
    @ObservationIgnored var stillSize = CGSize(width: 1920, height: 1080)
    /// How long the last composition took to build, for `describe`.
    @ObservationIgnored private(set) var lastBuildSeconds: Double = 0

    @ObservationIgnored private let players: [AVPlayer]
    @ObservationIgnored private var outputs: [AVPlayerItemVideoOutput?] = [nil, nil]
    /// The player on screen.
    @ObservationIgnored private var front = 0
    @ObservationIgnored private var timeObservers: [Any] = []
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var readyObservation: NSKeyValueObservation?
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var lastTick: TimeInterval = 0
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var pendingSeek: Time?
    @ObservationIgnored private var rebuildWork: DispatchWorkItem?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var buildGeneration = 0
    /// Bumped whenever the project changes, so stills made from an older
    /// project aren't shown.
    @ObservationIgnored private var projectVersion = 0
    @ObservationIgnored private var renderer: FrameRenderer?
    @ObservationIgnored private var rendererVersion = -1
    @ObservationIgnored private var stillWork: DispatchWorkItem?
    @ObservationIgnored private var stillTask: Task<Void, Never>?
    /// The playhead time the still on screen shows, nil when hidden.
    @ObservationIgnored private var stillTime: Time?
    @ObservationIgnored private var stillImage: CGImage?
    @ObservationIgnored private var loadStarted: TimeInterval = 0
    @ObservationIgnored private var lastFrame: CGImage?
    @ObservationIgnored private var lastFrameTime: CMTime?
    @ObservationIgnored private lazy var imageContext = CIContext()

    init() {
        players = [AVPlayer(), AVPlayer()]
        playerLayers = players.map { AVPlayerLayer(player: $0) }
        for (index, player) in players.enumerated() {
            player.actionAtItemEnd = .pause
            // For unattended test runs, so a screenshot session makes no sound.
            player.isMuted = Self.muted
            // Local files: start at once rather than buffering first.
            player.automaticallyWaitsToMinimizeStalling = false
            let layer = playerLayers[index]
            layer.videoGravity = .resizeAspect
            layer.isHidden = true
            timeObservers.append(player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.playerAdvanced(to: time, slot: index) }
            })
        }
        stillLayer.contentsGravity = .resizeAspect
        stillLayer.isHidden = true
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, let item, item === self.players[self.front].currentItem else { return }
                self.reachedEnd()
            }
        }
    }

    /// `TANDEM_MUTED=1` silences playback and previews.
    nonisolated static let muted = ProcessInfo.processInfo.environment["TANDEM_MUTED"] == "1"

    func invalidate() {
        clock?.invalidate()
        clock = nil
        rebuildWork?.cancel()
        buildTask?.cancel()
        stillWork?.cancel()
        stillTask?.cancel()
        readyObservation = nil
        for (index, player) in players.enumerated() {
            if index < timeObservers.count { player.removeTimeObserver(timeObservers[index]) }
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        timeObservers = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    // MARK: - Timeline changes

    /// Called when the project changes: updates the duration and rebuilds
    /// the composition shortly after, so a burst of edits builds once.
    func projectChanged(duration: Time, frameRate: FrameRate) {
        self.duration = duration
        self.frameRate = frameRate
        projectVersion += 1
        if time > duration { seek(to: duration) }
        scheduleRebuild()
    }

    func scheduleRebuild(delay: TimeInterval = 0.15) {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Proxy playback composites at 1080p on the short side, which is as
    /// much as the viewer shows; full quality uses the project's size.
    /// Nil when the project is no bigger than that.
    nonisolated static func previewSize(for size: CGSize, shortSide: CGFloat = 1080) -> CGSize? {
        let short = min(size.width, size.height)
        guard short > shortSide else { return nil }
        let scale = shortSide / short
        return CGSize(width: (size.width * scale / 2).rounded() * 2, height: (size.height * scale / 2).rounded() * 2)
    }

    private func rebuild() {
        guard var context = makeContext?() else { return }
        context.useProxies = useProxies
        if useProxies { context.sizeOverride = Self.previewSize(for: context.renderSize) }
        buildGeneration += 1
        let generation = buildGeneration
        let started = ProcessInfo.processInfo.systemUptime
        buildTask?.cancel()
        // The builder is async and loads media off the main thread.
        buildTask = Task { [weak self] in
            let result: Result<BuiltComposition, Error>
            do {
                result = .success(try await CompositionBuilder.build(context))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.lastBuildSeconds = ProcessInfo.processInfo.systemUptime - started
            DrawTiming.record("composition builds", self.lastBuildSeconds)
            self.finishBuild(result, generation: generation)
        }
    }

    private func finishBuild(_ result: Result<BuiltComposition, Error>, generation: Int) {
        guard generation == buildGeneration else { return }
        switch result {
        case .success(let built):
            warnings = built.warnings
            load(built, generation: generation)
        case .failure(let error):
            warnings = []
            hasComposition = false
            readyObservation = nil
            for (index, player) in players.enumerated() {
                player.pause()
                player.replaceCurrentItem(with: nil)
                outputs[index] = nil
                playerLayers[index].isHidden = true
            }
            hideStill()
            if case EditError.notImplemented = error {
                renderMessage = "Preview arrives with the render module"
            } else {
                renderMessage = "Can't preview: \(EditorModel.describe(error))"
            }
            if rate != 0 { startClock() }
        }
    }

    /// Loads a built composition into the hidden player and swaps it in
    /// once it shows the frame at the playhead.
    private func load(_ built: BuiltComposition, generation: Int) {
        let slot = hasComposition ? 1 - front : front
        let player = players[slot]
        let item = built.makePlayerItem()
        // The compositor's own format: no conversion per frame, only when a
        // capture asks for one.
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        player.pause()
        player.replaceCurrentItem(with: item)
        outputs[slot] = output
        readyObservation = nil
        loadStarted = ProcessInfo.processInfo.systemUptime
        player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.whenReady(slot: slot, generation: generation) }
            }
        }
    }

    private func whenReady(slot: Int, generation: Int) {
        guard generation == buildGeneration else { return }
        let layer = playerLayers[slot]
        if layer.isReadyForDisplay {
            show(slot: slot)
            return
        }
        // A hidden layer still decodes its first frame; wait for it, but
        // never leave the viewer on the old cut for long.
        readyObservation = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.buildGeneration else { return }
                    self.show(slot: slot)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.buildGeneration, self.readyObservation != nil else { return }
                self.show(slot: slot)
            }
        }
    }

    private func show(slot: Int) {
        readyObservation = nil
        DrawTiming.record("new cut on screen", ProcessInfo.processInfo.systemUptime - loadStarted)
        let old = front
        let wasShowing = hasComposition
        front = slot
        seeking = false
        pendingSeek = nil
        let player = players[slot]
        // The playhead may have moved while the new cut loaded.
        if player.currentTime() != time.cmTime {
            player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayers[slot].isHidden = false
        if old != slot { playerLayers[old].isHidden = true }
        CATransaction.commit()
        if wasShowing, old != slot {
            players[old].pause()
            players[old].replaceCurrentItem(with: nil)
            outputs[old] = nil
        }
        lastFrame = nil
        lastFrameTime = nil
        hasComposition = true
        renderMessage = nil
        clock?.invalidate()
        clock = nil
        if rate != 0 {
            play(rate: rate)
        } else {
            // The still over the player is from the old cut.
            hideStill()
            scheduleStill()
        }
    }

    // MARK: - Frames

    /// The frame on screen, for window captures (the player layer doesn't
    /// draw into them). Nil when there's no composition or nothing has
    /// decoded yet.
    func currentFrame() -> CGImage? {
        guard hasComposition else { return nil }
        if stillTime != nil, let stillImage { return stillImage }
        guard let output = outputs[front] else { return nil }
        let player = players[front]
        let itemTime = player.currentTime()
        if let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            let image = CIImage(cvPixelBuffer: buffer)
            lastFrame = imageContext.createCGImage(image, from: image.extent)
            lastFrameTime = itemTime
        }
        // A paused player hands each frame out once, so a second capture at
        // the same time reuses it; a frame from another time never stands in.
        if player.rate == 0, let lastFrameTime, lastFrameTime != itemTime { return nil }
        return lastFrame
    }

    /// Paused frames from the originals over the proxy player, so a paused
    /// frame is full resolution. The render module decodes the frames that
    /// remuxed open-GOP files can't seek to (they used to come back black,
    /// v14 at 6:44), so this is safe to leave on.
    static let stillsFromOriginals = true

    /// Once the playhead has rested for a moment, renders the exact frame
    /// from the originals and lays it over the player. Only needed while
    /// the player runs on proxies.
    private func scheduleStill() {
        stillWork?.cancel()
        guard Self.stillsFromOriginals, useProxies, rate == 0, hasComposition else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.renderStill() }
        }
        stillWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func renderStill() {
        guard rate == 0, hasComposition, var context = makeContext?() else { return }
        if renderer == nil || rendererVersion != projectVersion {
            context.useProxies = false
            renderer = FrameRenderer(context: context)
            rendererVersion = projectVersion
        }
        guard let renderer else { return }
        let target = time
        let version = projectVersion
        let size = stillSize
        stillTask?.cancel()
        stillTask = Task { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            guard let image = try? await renderer.image(at: target, maxSize: size) else { return }
            DrawTiming.record("paused stills", ProcessInfo.processInfo.systemUptime - started)
            guard let self, !Task.isCancelled, self.rate == 0, self.time == target, self.projectVersion == version else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.stillLayer.contents = image
            self.stillLayer.isHidden = false
            CATransaction.commit()
            self.stillTime = target
            self.stillImage = image
        }
    }

    private func hideStill() {
        stillTask?.cancel()
        guard stillTime != nil || !stillLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stillLayer.isHidden = true
        stillLayer.contents = nil
        CATransaction.commit()
        stillTime = nil
        stillImage = nil
    }

    // MARK: - Transport

    func seek(to target: Time) {
        let clamped = min(max(target, .zero), max(duration, .zero))
        time = clamped
        if stillTime != clamped { hideStill() }
        scheduleStill()
        guard hasComposition else { return }
        seekPlayer(to: clamped)
    }

    /// Exact seeks, one at a time: while one is running, only the latest
    /// request waits, so scrubbing keeps up without a backlog.
    private func seekPlayer(to target: Time) {
        if seeking {
            pendingSeek = target
            return
        }
        seeking = true
        let slot = front
        players[slot].seek(to: target.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, slot == self.front else { return }
                    self.seeking = false
                    if let next = self.pendingSeek {
                        self.pendingSeek = nil
                        self.seekPlayer(to: next)
                    }
                }
            }
        }
    }

    func play(rate newRate: Double = 1) {
        if newRate > 0 && time >= duration { seek(to: .zero) }
        if newRate < 0 && time <= .zero { return }
        rate = newRate
        stillWork?.cancel()
        hideStill()
        if hasComposition {
            let player = players[front]
            if newRate < 0, player.currentItem?.canPlayReverse == false {
                // The composition can't run backwards, so the clock steps it.
                player.pause()
                startClock()
            } else {
                clock?.invalidate()
                clock = nil
                player.rate = Float(newRate)
            }
        } else {
            startClock()
        }
    }

    func pause() {
        rate = 0
        for player in players { player.pause() }
        clock?.invalidate()
        clock = nil
        scheduleStill()
    }

    func togglePlay() {
        if isPlaying { pause() } else { play(rate: 1) }
    }

    /// L: play forwards, faster each press.
    func shuttleForward() {
        play(rate: rate > 0 ? min(rate * 2, 8) : 1)
    }

    /// J: play backwards, faster each press.
    func shuttleReverse() {
        play(rate: rate < 0 ? max(rate * 2, -8) : -1)
    }

    func step(frames: Int64) {
        pause()
        seek(to: time + Time.frames(frames, at: frameRate))
    }

    // MARK: - Clock

    private func startClock() {
        guard clock == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastTick
        lastTick = now
        guard rate != 0 else { return }
        let next = time + Time(seconds: elapsed * rate)
        if next >= duration {
            seek(to: duration)
            pause()
        } else if next <= .zero {
            seek(to: .zero)
            pause()
        } else {
            time = next
            if hasComposition { seekPlayer(to: next) }
        }
    }

    private func playerAdvanced(to cmTime: CMTime, slot: Int) {
        guard hasComposition, slot == front, players[slot].rate != 0, cmTime.isNumeric else { return }
        time = Time(cmTime: cmTime)
    }

    private func reachedEnd() {
        rate = 0
        time = duration
        scheduleStill()
    }
}

extension Time {
    /// Exact: a flick timescale fits CMTime's 32-bit timescale.
    var cmTime: CMTime { CMTime(value: flicks, timescale: CMTimeScale(Time.flicksPerSecond)) }

    init(cmTime: CMTime) {
        let converted = CMTimeConvertScale(cmTime, timescale: CMTimeScale(Time.flicksPerSecond), method: .roundHalfAwayFromZero)
        self.init(flicks: converted.value)
    }
}
