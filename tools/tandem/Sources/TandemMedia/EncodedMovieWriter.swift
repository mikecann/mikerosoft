import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Encodes frames with VideoToolbox and writes the compressed samples
/// untouched into a QuickTime movie, keeping every presentation time and
/// duration exactly as given. That's what makes proxy and matte time equal
/// source time, even for variable frame rate screen recordings.
///
/// A frame's duration is only known when the next one arrives (decoded
/// frames don't carry one), so each frame is encoded one frame late and the
/// last one lasts until `finish(endTime:)`.
final class EncodedMovieWriter: @unchecked Sendable {
    struct Settings {
        var width: Int
        var height: Int
        var codec: CMVideoCodecType = kCMVideoCodecType_HEVC
        /// Frames between keyframes; 1 is all-intra.
        var keyFrameInterval: Int = 1
        /// VideoToolbox constant quality, 0...1.
        var quality: Double = 0.5
        var prioritizeSpeed = true
        /// Colour tags for the bitstream (primaries, transfer, matrix).
        var colorPrimaries: CFString?
        var transferFunction: CFString?
        var yCbCrMatrix: CFString?
        /// Track timescale; use the source's so its times are exact.
        var timescale: CMTimeScale = 600
        var transform: CGAffineTransform = .identity
        var expectedFrameRate: Double?
    }

    let url: URL
    private let settings: Settings
    private let writer: AVAssetWriter
    private let session: VTCompressionSession
    private var input: AVAssetWriterInput?
    private var pending: (buffer: CVPixelBuffer, time: CMTime)?
    private let lock = NSLock()
    private var failure: Error?
    private let inFlight = DispatchSemaphore(value: 6)
    private(set) var framesWritten = 0

    init(url: URL, settings: Settings) throws {
        self.url = url
        self.settings = settings
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(settings.width), height: Int32(settings.height), codecType: settings.codec,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw MediaError.failed("VideoToolbox couldn't start an encoder (\(status))") }
        session = created
        func set(_ key: CFString, _ value: CFTypeRef?) {
            guard let value else { return }
            VTSessionSetProperty(created, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, settings.keyFrameInterval as CFNumber)
        set(kVTCompressionPropertyKey_Quality, settings.quality as CFNumber)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, settings.prioritizeSpeed ? kCFBooleanTrue : kCFBooleanFalse)
        if settings.codec == kCMVideoCodecType_HEVC { set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel) }
        set(kVTCompressionPropertyKey_ColorPrimaries, settings.colorPrimaries)
        set(kVTCompressionPropertyKey_TransferFunction, settings.transferFunction)
        set(kVTCompressionPropertyKey_YCbCrMatrix, settings.yCbCrMatrix)
        if let rate = settings.expectedFrameRate { set(kVTCompressionPropertyKey_ExpectedFrameRate, rate as CFNumber) }
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Queues a frame shown from `time`. Blocks while the encoder is busy.
    func append(_ buffer: CVPixelBuffer, at time: CMTime) throws {
        try check()
        if let pending {
            try encode(pending.buffer, at: pending.time, duration: time - pending.time)
        }
        pending = (buffer, time)
    }

    /// Encodes the last frame so it lasts until `endTime`, and closes the
    /// file.
    func finish(endTime: CMTime) async throws {
        if let pending {
            var duration = endTime - pending.time
            if !duration.isNumeric || duration <= .zero {
                duration = CMTime(seconds: 1 / (settings.expectedFrameRate ?? 30), preferredTimescale: settings.timescale)
            }
            try encode(pending.buffer, at: pending.time, duration: duration)
            self.pending = nil
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        try check()
        guard let input = lock.withLock({ self.input }) else { throw MediaError.failed("No frames to write") }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw MediaError.failed("Couldn't finish \(url.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }

    /// Stops and deletes the partial file.
    func cancel() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    private func check() throws {
        if let failure = lock.withLock({ self.failure }) { throw failure }
    }

    private func fail(_ error: Error) {
        lock.withLock { if failure == nil { failure = error } }
    }

    private func encode(_ buffer: CVPixelBuffer, at time: CMTime, duration: CMTime) throws {
        inFlight.wait()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time, duration: duration, frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self else { return }
            defer { self.inFlight.signal() }
            guard status == noErr, let sample else {
                self.fail(MediaError.failed("The encoder dropped a frame (\(status))"))
                return
            }
            self.write(sample)
        }
        if status != noErr {
            inFlight.signal()
            throw MediaError.failed("The encoder refused a frame (\(status))")
        }
    }

    /// Called by VideoToolbox, one frame at a time, in order.
    private func write(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        if input == nil {
            let created = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(sample))
            created.expectsMediaDataInRealTime = false
            created.mediaTimeScale = settings.timescale
            created.transform = settings.transform
            guard writer.canAdd(created) else {
                failure = MediaError.failed("Couldn't add a video track to \(url.lastPathComponent)")
                return
            }
            writer.add(created)
            guard writer.startWriting() else {
                failure = MediaError.failed("Couldn't write \(url.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
                return
            }
            // Movie time zero is media time zero, so every sample keeps the
            // time it had in the source.
            writer.startSession(atSourceTime: .zero)
            input = created
        }
        guard let input else { return }
        var waited = 0
        while !input.isReadyForMoreMediaData {
            usleep(1000)
            waited += 1
            if waited > 30_000 || writer.status != .writing {
                failure = MediaError.failed("The movie writer stalled: \(writer.error?.localizedDescription ?? "not ready")")
                return
            }
        }
        if input.append(sample) {
            framesWritten += 1
        } else {
            failure = MediaError.failed("Couldn't write a frame: \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }
}

/// Colour tags of a video track, to copy onto its proxy and matte.
struct ColorTags {
    var primaries: CFString?
    var transfer: CFString?
    var matrix: CFString?
    var fullRange: Bool

    init(_ format: CMFormatDescription?) {
        let extensions = format.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] } ?? [:]
        primaries = (extensions[kCVImageBufferColorPrimariesKey as String] as? String).map { $0 as CFString }
        transfer = (extensions[kCVImageBufferTransferFunctionKey as String] as? String).map { $0 as CFString }
        matrix = (extensions[kCVImageBufferYCbCrMatrixKey as String] as? String).map { $0 as CFString }
        fullRange = extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool ?? false
    }
}
