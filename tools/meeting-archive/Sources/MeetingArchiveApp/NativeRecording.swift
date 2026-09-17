import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

enum NativeRecordingStartOutcome: Equatable, Sendable {
    case started
    case cancelled
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
    var onStarted: (@Sendable () -> Void)?
    var onFailure: (@Sendable (String) -> Void)?

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
        let config = SCStreamConfiguration()
        config.width = 1920
        config.height = 1080
        config.preservesAspectRatio = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 4
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = true
        config.captureMicrophone = true
        // Nil explicitly means the current system-default microphone. Its
        // capture is independent of the meeting application's mute control.
        config.microphoneCaptureDeviceID = nil
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
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
        }
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
        queue.async { self.videoAllowed = allowed }
    }

    func checkHealth() {
        queue.async {
            guard self.acceptsSamples, self.startedUptime > 0 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastMicrophoneUptime > 10 {
                self.report(CaptureFailure.message("The microphone stopped supplying audio. The partial recording has been preserved."))
            } else if !self.announcedStart, now - self.startedUptime > 15 {
                self.report(CaptureFailure.message("Capture did not produce both meeting video and microphone audio within 15 seconds."))
            }
        }
    }

    func stop() async throws -> [String: TrackProgress] {
        // Flip the gate before awaiting ScreenCaptureKit. Samples already
        // queued after this call are discarded even if native shutdown takes
        // time to complete.
        let shouldStopStream = withLifecycle { $0.beginStop() }
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        var stopFailure: Error?
        if shouldStopStream, let stream {
            do { try await stream.stopCapture() } catch { stopFailure = error }
        }
        stream = nil
        let snapshot = queue.sync { (writers, timeline, failure) }
        // A final host timestamp extends a static last frame without creating
        // artificial 15 fps catch-up samples.
        for writer in snapshot.0.values {
            do { try await writer.finish(at: end) } catch { stopFailure = stopFailure ?? error }
        }
        queue.sync { writers.removeAll() }
        withLifecycle { $0.didStop() }
        if let error = snapshot.2 ?? stopFailure { throw error }
        return Dictionary(uniqueKeysWithValues: (snapshot.1?.tracks ?? [:]).map { ($0.key.rawValue, $0.value) })
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard self.reportsFailures else { return }
            self.report(error)
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
                if track != .video { throw CaptureFailure.message("Audio encoder fell behind. The partial recording has been preserved.") }
                consecutiveVideoDrops += 1
                if consecutiveVideoDrops >= 60 { throw CaptureFailure.message("The video encoder stopped accepting frames. The partial recording has been preserved.") }
                return // dropping video must not backlog microphone audio
            }
            try writer.append(sampleBuffer)
            if track == .video { consecutiveVideoDrops = 0 }
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

final class TrackWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var hasSamples = false
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
