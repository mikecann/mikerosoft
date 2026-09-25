import AVFoundation
import Foundation
import Observation
import TandemCore
import TandemMedia
import TandemRender

/// Plays the timeline and owns the playhead.
///
/// When the render module can build a composition, playback goes through
/// `AVPlayer` and the viewer shows its layer. Until then (or if a build
/// fails) a clock moves the playhead at the requested rate, so transport,
/// J K L and the timeline behave the same either way.
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
    /// True once a composition is loaded into the player.
    private(set) var hasComposition = false
    /// Why there's no picture, shown on the placeholder canvas.
    private(set) var renderMessage: String? = "Starting the viewer"
    /// Proxies for motion; paused frames use the originals.
    var useProxies = true {
        didSet { if oldValue != useProxies { scheduleRebuild() } }
    }

    @ObservationIgnored let player = AVPlayer()
    /// Supplies what to build from. Set by the editor model.
    @ObservationIgnored var makeContext: (() -> RenderContext)?
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var lastTick: TimeInterval = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var pendingSeek: Time?
    @ObservationIgnored private var rebuildWork: DispatchWorkItem?
    @ObservationIgnored private var buildGeneration = 0

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerAdvanced(to: time) }
        }
    }

    func invalidate() {
        clock?.invalidate()
        clock = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Timeline changes

    /// Called when the project changes: updates the duration and rebuilds
    /// the composition shortly after, so a burst of edits builds once.
    func projectChanged(duration: Time, frameRate: FrameRate) {
        self.duration = duration
        self.frameRate = frameRate
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

    private func rebuild() {
        guard var context = makeContext?() else { return }
        context.useProxies = useProxies
        buildGeneration += 1
        let generation = buildGeneration
        let immutableContext = context
        Task.detached(priority: .userInitiated) {
            let result: Result<BuiltComposition, Error>
            do {
                result = .success(try CompositionBuilder.build(immutableContext))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                self?.finishBuild(result, generation: generation)
            }
        }
    }

    private func finishBuild(_ result: Result<BuiltComposition, Error>, generation: Int) {
        guard generation == buildGeneration else { return }
        switch result {
        case .success(let built):
            let resumeRate = rate
            let item = built.makePlayerItem()
            player.replaceCurrentItem(with: item)
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reachedEnd() }
            }
            hasComposition = true
            renderMessage = nil
            clock?.invalidate()
            clock = nil
            player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            if resumeRate != 0 { player.rate = Float(resumeRate) }
        case .failure(let error):
            hasComposition = false
            player.replaceCurrentItem(with: nil)
            if case EditError.notImplemented = error {
                renderMessage = "Preview arrives with the render module"
            } else {
                renderMessage = "Can't preview: \(error.localizedDescription)"
            }
            if rate != 0 { startClock() }
        }
    }

    // MARK: - Transport

    func seek(to target: Time) {
        let clamped = min(max(target, .zero), max(duration, .zero))
        time = clamped
        guard hasComposition else { return }
        if seeking {
            pendingSeek = clamped
            return
        }
        seeking = true
        player.seek(to: clamped.cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.seeking = false
                    if let next = self.pendingSeek {
                        self.pendingSeek = nil
                        self.seek(to: next)
                    }
                }
            }
        }
    }

    func play(rate newRate: Double = 1) {
        if newRate > 0 && time >= duration { seek(to: .zero) }
        if newRate < 0 && time <= .zero { return }
        rate = newRate
        if hasComposition {
            if newRate < 0, player.currentItem?.canPlayReverse == false {
                // The composition can't run backwards, so the clock steps it.
                player.pause()
                startClock()
            } else {
                player.rate = Float(newRate)
            }
        } else {
            startClock()
        }
    }

    func pause() {
        rate = 0
        player.pause()
        clock?.invalidate()
        clock = nil
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
            seek(to: next)
        }
    }

    private func playerAdvanced(to cmTime: CMTime) {
        guard hasComposition, player.rate != 0, cmTime.isNumeric else { return }
        time = Time(cmTime: cmTime)
    }

    private func reachedEnd() {
        rate = 0
        time = duration
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
