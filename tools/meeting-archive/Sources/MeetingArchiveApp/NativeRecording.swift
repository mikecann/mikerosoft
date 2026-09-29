import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

enum NativeRecordingStartOutcome: Equatable, Sendable {
    case started
    case cancelled
}

/// Stopping always yields the track timeline, even when a writer or the stream
/// reported an error, so `tracks.json` is never lost with it.
struct NativeRecordingStopResult {
    var tracks: [String: TrackProgress]
    var error: Error?
    /// What the microphone file actually contains (a stereo USB mic writes 2).
    var microphoneChannels: Int?
}

/// ScreenCaptureKit supplies all three sources, so one host-clock origin is used
/// for every writer. No camera capture session is opened by this recorder.
final class NativeRecording: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mikerosoft.meeting-archive.media")
    private let lifecycleLock = NSLock()
    private var stream: SCStream?
    private var writers: [MediaTrack: TrackWriter] = [:]
    private var timeline: CaptureTimeline?
    private var directory: URL?
    private var origin = CMTime.zero
    private var failure: Error?
    private var videoAllowed = true
    private var lifecycle = NativeCaptureLifecycle()
    private var announcedStart = false
    private var startedUptime: TimeInterval = 0
    private var lastMicrophoneUptime: TimeInterval = 0
    private var consecutiveVideoDrops = 0
    private var consecutiveAudioDrops = 0
    private var lastVideoSample: CMSampleBuffer?
    private var lastVideoAppendUptime: TimeInterval = 0
    private var lastVideoTimestamp = CMTime.invalid
    private var videoStallLogged = false
    private var lastMicrophoneRestartUptime: TimeInterval = 0
    private var streamEndedBySystem = false
    var onStarted: (@Sendable () -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    /// ScreenCaptureKit stops the stream itself when the captured window
    /// closes, which is how most meetings end. That is not a failure.
    var onStreamEnded: (@Sendable () -> Void)?

    /// Used by startup error handling to distinguish an empty setup failure
    /// from a partial capture whose successfully appended media must be kept.
    var hasCapturedSamples: Bool {
        withLifecycle { $0.hasCapturedSamples }
    }

    @discardableResult
    func start(windowID: CGWindowID, directory: URL) async throws -> NativeRecordingStartOutcome {
        guard startupPermitted else { return finishCancelledStartup() }
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFailure.message("Allow Meeting Archive in Screen & System Audio Recording, then reopen it.")
        }
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard startupPermitted else { return finishCancelledStartup() }
        guard microphoneAllowed else {
            throw CaptureFailure.message("Microphone access is required to include your voice.")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            if !startupPermitted { return finishCancelledStartup() }
            throw error
        }
        guard startupPermitted else { return finishCancelledStartup() }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureFailure.message("The meeting window is no longer available.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        // A nil microphone device means the current system default. Its capture
        // is independent of the meeting application's mute control.
        let config = SCStreamConfiguration.meetingCapture(microphone: true)
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        queue.sync {
            self.directory = directory
            origin = CMClockGetTime(CMClockGetHostTimeClock())
            timeline = CaptureTimeline(origin: origin.seconds)
            announcedStart = false
            failure = nil
            startedUptime = ProcessInfo.processInfo.systemUptime
            lastMicrophoneUptime = startedUptime
            lastVideoAppendUptime = startedUptime
            streamEndedBySystem = false
        }
        Log.capture.notice("Starting capture of window \(windowID, privacy: .public)")
        guard withLifecycle({ $0.beginActivation() }) else {
            return finishCancelledStartup()
        }
        stream = capture
        do {
            try await capture.startCapture()
        } catch {
            stream = nil
            let wasCancelled = withLifecycle {
                let cancelled = !$0.reportsFailures
                $0.didStop()
                return cancelled
            }
            if wasCancelled { return .cancelled }
            throw error
        }
        guard withLifecycle({ $0.didActivate() }) else {
            var stopError: Error?
            do { try await capture.stopCapture() } catch { stopError = error }
            stream = nil
            withLifecycle { $0.didStop() }
            if let stopError { throw stopError }
            return .cancelled
        }
        return .started
    }

    /// The controller calls this as soon as the requested camera session is no
    /// longer eligible. Checks after every startup suspension then prevent a
    /// stale permission or window lookup result from opening a capture stream.
    func cancelStartup() {
        withLifecycle { $0.cancelStartup() }
    }

    func setVideoAllowed(_ allowed: Bool) {
        queue.async {
            guard self.videoAllowed != allowed else { return }
            self.videoAllowed = allowed
            Log.capture.notice("Meeting video \(allowed ? "allowed" : "withheld", privacy: .public)")
        }
    }

    func checkHealth() {
        queue.async {
            guard self.acceptsSamples, self.startedUptime > 0 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if !self.announcedStart, now - self.startedUptime > 15 {
                self.report(CaptureFailure.message("Capture did not produce both meeting video and microphone audio within 15 seconds."))
                return
            }
            self.fillVideoGap(now: now)
            // A USB microphone that reconfigures (the Yeti does this) can leave
            // ScreenCaptureKit's microphone capture dead. Restart just that
            // source rather than ending video and call audio with it.
            if now - self.lastMicrophoneUptime > 3, now - self.lastMicrophoneRestartUptime > 10 {
                self.lastMicrophoneRestartUptime = now
                Log.capture.error("Microphone silent for \(Int(now - self.lastMicrophoneUptime), privacy: .public)s; restarting microphone capture")
                self.restartMicrophone()
            }
        }
    }

    /// ScreenCaptureKit stops delivering complete frames when a window is
    /// static, hidden, or being dragged. Without this, the video file simply
    /// ends while both audio tracks carry on (one 82-minute call kept 193s of
    /// video). Repeat the last frame about once a second instead.
    private func fillVideoGap(now: TimeInterval) {
        guard now - lastVideoAppendUptime >= 1, let last = lastVideoSample,
              let writer = writers[.video], writer.ready else { return }
        if now - lastVideoAppendUptime > 5, !videoStallLogged {
            videoStallLogged = true
            Log.capture.error("No new meeting video frames for \(Int(now - self.lastVideoAppendUptime), privacy: .public)s; holding the last frame")
        }
        appendRetimedVideo(last, at: CMClockGetTime(CMClockGetHostTimeClock()), writer: writer)
    }

    private func appendRetimedVideo(_ sample: CMSampleBuffer, at time: CMTime, writer: TrackWriter) {
        guard time > lastVideoTimestamp else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
              let copy else { return }
        do {
            try writer.append(copy)
            lastVideoTimestamp = time
            lastVideoAppendUptime = ProcessInfo.processInfo.systemUptime
            try timeline?.accept(track: .video, timestamp: time.seconds, duration: 0)
        } catch {
            Log.capture.error("Could not repeat the last video frame: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restartMicrophone() {
        guard let stream else { return }
        let off = SCStreamConfiguration.meetingCapture(microphone: false)
        let on = SCStreamConfiguration.meetingCapture(microphone: true)
        Task {
            do {
                try await stream.updateConfiguration(off)
                try await stream.updateConfiguration(on)
            } catch {
                Log.capture.error("Microphone restart failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Points the running stream at another window without touching the
    /// writers, so the same files continue with no gap in either audio track.
    func retarget(windowID: CGWindowID) async throws {
        guard let stream else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureFailure.message("The meeting moved to a window that is no longer available.")
        }
        try await stream.updateContentFilter(SCContentFilter(desktopIndependentWindow: window))
        Log.capture.notice("Capture now follows window \(windowID, privacy: .public)")
    }

    func stop() async -> NativeRecordingStopResult {
        // Flip the gate before awaiting ScreenCaptureKit. Samples already
        // queued after this call are discarded even if native shutdown takes
        // time to complete.
        let shouldStopStream = withLifecycle { $0.beginStop() }
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        var stopFailure: Error?
        let endedBySystem = queue.sync { streamEndedBySystem }
        if shouldStopStream, !endedBySystem, let stream {
            do { try await stream.stopCapture() } catch {
                // Already stopped by the system is the normal end of a call.
                Log.capture.notice("stopCapture: \(error.localizedDescription, privacy: .public)")
            }
        }
        stream = nil
        // Hold the final frame to the end so the video is as long as the audio.
        queue.sync {
            if let last = lastVideoSample, let writer = writers[.video], writer.ready {
                appendRetimedVideo(last, at: end, writer: writer)
            }
            lastVideoSample = nil
        }
        let snapshot = queue.sync { (writers, timeline, failure) }
        let microphoneChannels = snapshot.0[.microphone]?.channels
        // A final host timestamp extends a static last frame without creating
        // artificial 15 fps catch-up samples.
        for writer in snapshot.0.values {
            do { try await writer.finish(at: end) } catch { stopFailure = stopFailure ?? error }
        }
        queue.sync { writers.removeAll() }
        withLifecycle { $0.didStop() }
        let tracks = Dictionary(uniqueKeysWithValues: (snapshot.1?.tracks ?? [:]).map { ($0.key.rawValue, $0.value) })
        let error = snapshot.2 ?? stopFailure
        Log.capture.notice("Capture stopped; tracks: \(tracks.keys.sorted().joined(separator: ","), privacy: .public); error: \(error?.localizedDescription ?? "none", privacy: .public)")
        return NativeRecordingStopResult(tracks: tracks, error: error, microphoneChannels: microphoneChannels)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            Log.capture.notice("Stream stopped by the system: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            self.streamEndedBySystem = true
            guard self.reportsFailures else { return }
            self.onStreamEnded?()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard acceptsSamples, CMSampleBufferIsValid(sampleBuffer), let directory else { return }
        let track: MediaTrack
        switch outputType {
        case .screen:
            guard videoAllowed else { return }
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            track = .video
        case .audio: track = .incoming
        case .microphone: track = .microphone
        @unknown default: return
        }
        do {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let sampleDuration = CMSampleBufferGetDuration(sampleBuffer)
            let duration = sampleDuration.isNumeric ? max(0, sampleDuration.seconds) : 0
            // Do not rewrite each track to zero; that would erase offsets.
            guard timestamp.isNumeric, timestamp >= origin else { return }
            if writers[track] == nil {
                writers[track] = try TrackWriter(track: track, directory: directory, sample: sampleBuffer, origin: origin)
            }
            guard let writer = writers[track] else { return }
            guard writer.ready else {
                if track != .video {
                    // One busy moment in the encoder should cost a few
                    // milliseconds of audio, not the rest of the meeting.
                    consecutiveAudioDrops += 1
                    if consecutiveAudioDrops >= 50 { throw CaptureFailure.message("Audio encoder fell behind. The partial recording has been preserved.") }
                    return
                }
                consecutiveVideoDrops += 1
                if consecutiveVideoDrops >= 60 { throw CaptureFailure.message("The video encoder stopped accepting frames. The partial recording has been preserved.") }
                return // dropping video must not backlog microphone audio
            }
            if track == .video, timestamp <= lastVideoTimestamp { return }
            try writer.append(sampleBuffer)
            if track == .video {
                consecutiveVideoDrops = 0
                lastVideoSample = sampleBuffer
                lastVideoTimestamp = timestamp
                lastVideoAppendUptime = ProcessInfo.processInfo.systemUptime
                if videoStallLogged {
                    videoStallLogged = false
                    Log.capture.notice("Meeting video frames resumed")
                }
            } else {
                consecutiveAudioDrops = 0
            }
            if track == .microphone { lastMicrophoneUptime = ProcessInfo.processInfo.systemUptime }
            try timeline?.accept(track: track, timestamp: timestamp.seconds, duration: duration)
            withLifecycle { $0.recordAcceptedSample() }
            if !announcedStart, timeline?.tracks[.video] != nil, timeline?.tracks[.microphone] != nil {
                announcedStart = true
                onStarted?()
            }
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        guard reportsFailures, failure == nil else { return }
        Log.capture.error("Capture failure: \(error.localizedDescription, privacy: .public)")
        failure = error
        onFailure?(error.localizedDescription)
    }

    private var startupPermitted: Bool {
        withLifecycle { $0.startupPermitted }
    }

    private var acceptsSamples: Bool {
        withLifecycle { $0.acceptsSamples }
    }

    private var reportsFailures: Bool {
        withLifecycle { $0.reportsFailures }
    }

    private func finishCancelledStartup() -> NativeRecordingStartOutcome {
        withLifecycle { $0.didStop() }
        return .cancelled
    }

    private func withLifecycle<T>(_ body: (inout NativeCaptureLifecycle) -> T) -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return body(&lifecycle)
    }
}

private extension SCStreamConfiguration {
    /// Restarting the microphone reapplies this with the flag off, then on;
    /// ScreenCaptureKit applies each update to the running stream.
    static func meetingCapture(microphone enabled: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = 1920
        config.height = 1080
        config.preservesAspectRatio = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = true
        config.captureMicrophone = enabled
        config.microphoneCaptureDeviceID = nil
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        return config
    }
}

final class TrackWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var hasSamples = false
    private(set) var channels: Int?
    var ready: Bool { input.isReadyForMoreMediaData }

    init(track: MediaTrack, directory: URL, sample: CMSampleBuffer, origin: CMTime) throws {
        let name = track == .video ? "meeting-view.mov" : "\(track.rawValue).m4a"
        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent(name), fileType: track == .video ? .mov : .m4a)
        let settings: [String: Any]
        if track == .video {
            settings = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
                AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true],
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoMaxKeyFrameIntervalDurationKey: 2]
            ]
        } else {
            guard let format = CMSampleBufferGetFormatDescription(sample),
                  let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
                throw CaptureFailure.message("Audio capture did not provide a usable format.")
            }
            let channels = min(2, max(1, Int(audio.pointee.mChannelsPerFrame)))
            self.channels = channels
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audio.pointee.mSampleRate,
                        AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 96_000 : 128_000]
        }
        input = AVAssetWriterInput(mediaType: track == .video ? .video : .audio, outputSettings: settings,
                                   sourceFormatHint: CMSampleBufferGetFormatDescription(sample))
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureFailure.message("The requested capture encoder is unavailable.") }
        writer.add(input)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        guard writer.startWriting() else { throw writer.error ?? CaptureFailure.message("Could not start the capture file.") }
        writer.startSession(atSourceTime: origin)
    }

    func append(_ sample: CMSampleBuffer) throws {
        guard input.append(sample) else { throw writer.error ?? CaptureFailure.message("Could not write capture samples.") }
        hasSamples = true
    }

    func finish(at timestamp: CMTime) async throws {
        guard hasSamples else { writer.cancelWriting(); return }
        writer.endSession(atSourceTime: timestamp)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CaptureFailure.message("Capture file could not be finalized.") }
    }
}
