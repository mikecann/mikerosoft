import AVFoundation
import CoreMedia
import Foundation
import TandemCore
import TandemMedia
import VideoToolbox

/// The export pipeline behind `Exporter`.
///
/// 1. Plan the preset for the project (`ExportPreset.plan(for:)`: the frame,
///    size and bitrate) and build the composition for it.
/// 2. Measure the mix's loudness in a fast audio-only pass. When the limiter
///    will bite, a second pass tries a few gains through it at once and
///    picks the one that lands on the target.
/// 3. Read composed frames (the same compositor as the viewer), encode them
///    with VideoToolbox (hardware, speed priority, preset bitrate), and mux
///    them with the mastered audio (gain, true-peak limiter, AAC 48 kHz
///    stereo) into AVAssetWriter.
/// 4. Write a snapshot of the project beside the file.
final class ExportPipeline: @unchecked Sendable {
    let context: RenderContext
    /// As given until `run` plans it for the project, then the plan's.
    private(set) var preset: ExportPreset
    let output: URL
    let progress: @Sendable (Double) -> Void

    private let lock = NSLock()
    private var cancelled = false
    /// The encoder in use, so cancel can wake anything waiting on it.
    private var activeEncoder: VideoEncoder?
    /// Longest wait for the next composed frame before giving up, in
    /// seconds. AVFoundation can stall without failing; an export must not.
    var stallTimeout = 120.0
    /// Seconds spent in each phase, for diagnostics and benchmarks.
    private(set) var timings: [(phase: String, seconds: Double)] = []
    /// Each loudness measurement: the gain it was made at and the result.
    private(set) var loudnessPasses: [(gainDB: Double, limited: Bool, lufs: Double)] = []
    private var storedWarnings: [String] = []
    /// What renders differently from the project, once the composition is
    /// built: a matte not made yet, a file that couldn't be converted.
    var warnings: [String] { lock.withLock { storedWarnings } }

    private func timed<T>(_ phase: String, _ work: () async throws -> T) async rethrows -> T {
        let started = Date()
        let result = try await work()
        let seconds = Date().timeIntervalSince(started)
        lock.withLock { timings.append((phase, seconds)) }
        return result
    }

    init(context: RenderContext, preset: ExportPreset, output: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.context = context
        self.preset = preset
        self.output = output
        self.progress = progress
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Asks the export to stop. Only a flag: every thread reading a reader
    /// checks it after each sample and stops, and the reader is cancelled
    /// once nobody is inside it. Cancelling an AVAssetReader while another
    /// thread is in `copyNextSampleBuffer` crashes AVFoundation.
    func cancel() {
        let encoder: VideoEncoder? = lock.withLock {
            cancelled = true
            return activeEncoder
        }
        encoder?.abort()
    }

    private func throwIfCancelled() throws {
        if isCancelled { throw RenderError.cancelled }
    }

    /// Refuses outputs that could destroy work: anything but a movie file
    /// (the snapshot beside `Video` would be `Video.tandem`, the project's
    /// own name) or a file the project uses as media.
    func checkOutput() throws {
        guard ["mp4", "mov", "m4v"].contains(output.pathExtension.lowercased()) else {
            throw RenderError.export("export to a .mp4, .mov or .m4v file, not \(output.lastPathComponent)")
        }
        if let reason = RenderOutputs.protectedReason(output, project: context.project, folder: context.folder) {
            throw RenderError.export("\(reason); export somewhere else")
        }
        // Re-exporting over an earlier Tandem export is normal, and those
        // have their snapshot beside them. Anything else at that path (an
        // old Filmora render, a download) isn't ours to replace.
        let fm = FileManager.default
        let snapshot = output.appendingPathExtension(ProjectFile.fileExtension)
        if fm.fileExists(atPath: output.path) && !fm.fileExists(atPath: snapshot.path) {
            throw RenderError.export("\(output.lastPathComponent) already exists and isn't a Tandem export; pick another name or move it first")
        }
    }

    /// AAC can overshoot the limited mix by a few tenths of a dB, which put
    /// finished files over the ceiling when measured with ffmpeg, so the
    /// limiter aims this much lower (on top of its own 0.1 dB).
    static let aacPeakMargin = 0.5

    func run() async throws -> ExportResult {
        let started = Date()
        try checkOutput()
        // The same plan the CLI and the Export dialog show. A preset that's
        // already a plan comes back unchanged.
        let sizesTheFrame = preset.width != nil || preset.resolution != nil
        let plan = try preset.plan(for: context.project.settings, format: preset.format ?? context.format)
        preset = plan.preset
        var renderContext = context
        renderContext.useProxies = false
        renderContext.format = plan.format
        if sizesTheFrame {
            renderContext.sizeOverride = CGSize(width: plan.width, height: plan.height)
        }
        let (ready, notes) = await timed("convert") { await ConvertedMedia.prepare(renderContext) }
        let built = try await timed("build") { try await CompositionAssembler.build(ready) }
        lock.withLock { storedWarnings = notes + built.warnings }
        let range = exportRange(built.duration)
        guard range.duration > .zero else { throw RenderError.export("the export range is empty") }
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        let fps = context.project.settings.frameRate

        // Loudness passes take the first tenth of the progress bar.
        var gainDB = 0.0
        let ceiling = preset.truePeakCeiling.map { $0 - Self.aacPeakMargin }
        if let target = preset.loudnessTarget, !audioTracks.isEmpty {
            let first = try await timed("loudness") {
                try await measure(built, tracks: audioTracks, range: range, gains: [0], ceiling: nil) { self.report(0.04 * $0) }[0]
            }
            if first.integratedLUFS.isFinite {
                gainDB = min(max(target - first.integratedLUFS, -40), 30)
                if let ceiling, first.truePeakDBTP + gainDB > ceiling {
                    // The limiter takes some level off with the peaks, so the
                    // gain has to be a little higher. Measure a few candidate
                    // gains through it in one pass and interpolate.
                    let candidates = [0, 0.75, 1.5, 2.5].map { min(gainDB + $0, 30) }
                    let limited = try await timed("loudness through the limiter") {
                        try await measure(built, tracks: audioTracks, range: range, gains: candidates, ceiling: ceiling) { self.report(0.04 + 0.05 * $0) }
                    }
                    let points = zip(candidates, limited).map { (gain: $0, lufs: $1.integratedLUFS) }
                    if let best = Self.gainForTarget(target, points: points) {
                        gainDB = min(max(best, -40), 30)
                    }
                }
            }
        }
        if isCancelled { throw RenderError.cancelled }

        await EncoderLock.shared.acquire(priority: .export)
        let loudness: Loudness
        do {
            loudness = try await timed("encode") {
                try await encode(built, video: videoTracks, audio: audioTracks, range: range, gainDB: gainDB, ceiling: ceiling, fps: fps)
            }
            await EncoderLock.shared.release()
        } catch {
            await EncoderLock.shared.release()
            try? FileManager.default.removeItem(at: output)
            throw isCancelled ? RenderError.cancelled : error
        }
        try writeSnapshot(range: range, loudness: loudness)
        report(1, force: true)
        return ExportResult(
            path: output.path,
            duration: range.duration,
            integratedLUFS: loudness.integratedLUFS.isFinite ? loudness.integratedLUFS : nil,
            truePeakDBTP: loudness.truePeakDBTP.isFinite ? loudness.truePeakDBTP : nil,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    func exportRange(_ duration: Time) -> TimeRange {
        guard let range = preset.range else { return TimeRange(start: .zero, duration: duration) }
        let start = min(max(range.start, .zero), duration)
        return TimeRange(start: start, end: min(max(range.end, start), duration))
    }

    // MARK: - Progress

    private var lastReported = -1.0

    private func report(_ value: Double, force: Bool = false) {
        let clamped = min(max(value, 0), 1)
        let send: Bool = lock.withLock {
            guard force || clamped - lastReported >= 0.005 else { return false }
            lastReported = clamped
            return true
        }
        if send { progress(clamped) }
    }

    // MARK: - Loudness

    /// Integrated loudness and true peak of the mix over `range`, after each
    /// of `gains` (dB) and, with a ceiling, the limiter. The mix is decoded
    /// once and every gain runs as its own chain, side by side.
    private func measure(
        _ built: BuiltComposition,
        tracks: [AVAssetTrack],
        range: TimeRange,
        gains: [Double],
        ceiling: Double?,
        progress: (Double) -> Void
    ) async throws -> [Loudness] {
        try throwIfCancelled()
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = range.cmTimeRange
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: AudioBuffers.readerSettings)
        output.audioMix = built.audioMix
        output.audioTimePitchAlgorithm = .spectral
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RenderError.export("couldn't read the mix") }

        final class Chain: @unchecked Sendable {
            let gain: Float
            var limiter: TruePeakLimiter?
            var meter = LoudnessMeter(sampleRate: Double(AudioBuffers.sampleRate), channels: AudioBuffers.channels)

            init(gainDB: Double, ceiling: Double?) {
                gain = Float(AudioEnvelope.gain(dB: gainDB))
                limiter = ceiling.map { TruePeakLimiter(channels: AudioBuffers.channels, ceilingDBTP: $0) }
            }

            func process(_ input: [Float]) {
                var samples = input
                if gain != 1 { for i in samples.indices { samples[i] *= gain } }
                limiter?.process(&samples)
                meter.process(interleaved: samples)
            }

            func finish() -> Loudness {
                if var limiter {
                    meter.process(interleaved: limiter.flush())
                    self.limiter = limiter
                }
                return meter.result()
            }
        }
        let chains = gains.map { Chain(gainDB: $0, ceiling: ceiling) }
        let total = Double(range.duration.seconds * Double(AudioBuffers.sampleRate))
        var frames = 0
        while let buffer = output.copyNextSampleBuffer() {
            let samples = AudioBuffers.samples(in: buffer)
            if chains.count == 1 {
                chains[0].process(samples)
            } else {
                DispatchQueue.concurrentPerform(iterations: chains.count) { chains[$0].process(samples) }
            }
            frames += samples.count / AudioBuffers.channels
            progress(Double(frames) / max(total, 1))
            if isCancelled { break }
        }
        if isCancelled {
            // This thread was the only reader, so cancelling is safe here.
            reader.cancelReading()
            throw RenderError.cancelled
        }
        if reader.status == .failed { throw reader.error ?? RenderError.export("couldn't read the mix") }
        let results = chains.map { $0.finish() }
        lock.withLock {
            for (gain, result) in zip(gains, results) {
                loudnessPasses.append((gain, ceiling != nil, result.integratedLUFS))
            }
        }
        return results
    }

    /// Where to start reading for an export that starts at `start`: a
    /// little earlier if a layer's file is on leading frames AVFoundation
    /// can't seek to there (a reader starting on them stalls). The frames
    /// in between are read and dropped.
    static func readStart(_ start: Time, instructions: [any AVVideoCompositionInstructionProtocol]) -> Time {
        var time = start
        for _ in 0..<8 {
            guard let instruction = instructions.first(where: { CMTimeRangeContainsTime($0.timeRange, time: time.cmTime) }) as? TandemInstruction else { break }
            var earliest = time
            for layer in instruction.stack.flatMap(\.layers) {
                guard let clip = instruction.scene.clips[layer.clipID], !clip.clip.freezeFrame else { continue }
                let used: [(SourceTrack?, Int?, TimeRange?)] = [
                    (clip.picture, layer.pictureTrack, clip.pictureRecovery),
                    (clip.matte, layer.matteTrack, clip.matteRecovery)
                ]
                for (source, track, leftOut) in used {
                    // Frames left out of the composition are decoded directly.
                    guard track != nil, let map = source?.leading, !(leftOut?.contains(time) ?? false) else { continue }
                    let media = Time(cmTime: clip.mediaTime(at: time))
                    guard let window = map.window(containing: media) else { continue }
                    let speed = max(clip.clip.speed, 0.0001)
                    let back = time - (media - window.start).scaled(by: 1 / speed) - instruction.scene.frameDuration
                    earliest = min(earliest, back)
                }
            }
            if earliest >= time { break }
            time = max(.zero, earliest)
        }
        return time
    }

    /// The gain that brings the limited mix to `target`, from measurements
    /// at several gains. Loudness rises with gain, but less than a dB per dB
    /// once the limiter works, so this interpolates between the two
    /// measurements either side of the target.
    static func gainForTarget(_ target: Double, points: [(gain: Double, lufs: Double)]) -> Double? {
        let usable = points.filter { $0.lufs.isFinite }.sorted { $0.gain < $1.gain }
        guard let first = usable.first, let last = usable.last else { return nil }
        if usable.count == 1 { return first.gain + (target - first.lufs) }
        for (a, b) in zip(usable, usable.dropFirst()) where target >= a.lufs && target <= b.lufs {
            let span = b.lufs - a.lufs
            return span > 1e-9 ? a.gain + (b.gain - a.gain) * (target - a.lufs) / span : a.gain
        }
        // Outside the measured range: carry on along the nearest slope.
        let (a, b) = target < first.lufs ? (usable[0], usable[1]) : (usable[usable.count - 2], last)
        let slope = min(max((b.lufs - a.lufs) / max(b.gain - a.gain, 1e-9), 0.3), 1.2)
        let anchor = target < first.lufs ? first : last
        return anchor.gain + (target - anchor.lufs) / slope
    }

    // MARK: - Encode and mux

    private func encode(
        _ built: BuiltComposition,
        video videoTracks: [AVAssetTrack],
        audio audioTracks: [AVAssetTrack],
        range: TimeRange,
        gainDB: Double,
        ceiling: Double?,
        fps: FrameRate
    ) async throws -> Loudness {
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        try throwIfCancelled()
        let reader = try AVAssetReader(asset: built.composition)
        // Reading may start a little early (see `readStart`); frames and
        // sound before the range are dropped.
        let readFrom = Self.readStart(range.start, instructions: built.videoComposition.instructions)
        reader.timeRange = CMTimeRange(start: readFrom.cmTime, end: range.end.cmTime)
        let pictures = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ])
        pictures.videoComposition = built.videoComposition
        pictures.alwaysCopiesSampleData = false
        reader.add(pictures)
        var mix: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: AudioBuffers.readerSettings)
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            reader.add(output)
            mix = output
        }
        guard reader.startReading() else { throw reader.error ?? RenderError.export("couldn't start reading") }

        let size = built.renderSize
        let encoder = try VideoEncoder(size: size, codec: preset.codec, bitrate: preset.videoBitrate, fps: fps)
        let alreadyCancelled: Bool = lock.withLock {
            activeEncoder = encoder
            return cancelled
        }
        if alreadyCancelled { encoder.abort() }
        defer {
            lock.withLock { activeEncoder = nil }
            encoder.invalidate()
        }
        let firstWanted = range.start.cmTime
        let frameDuration = CMTime(value: fps.denominator, timescale: CMTimeScale(fps.numerator))
        let base = 0.1

        // Feed composed frames to the encoder on their own thread. It holds
        // the reader too: an output read after its reader is gone crashes.
        let source = Unchecked((reader: reader, output: pictures))
        let stop = StopFlag()
        let fed = DispatchGroup()
        fed.enter()
        let feeder = Thread { [weak self] in
            // When reading starts early, the frame showing at the range's
            // start is the last one before it: it goes in at the start.
            var showing: CVImageBuffer?
            while !stop.isSet, !(self?.isCancelled ?? true), let sample = source.value.output.copyNextSampleBuffer() {
                encoder.noteProgress()
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                if CMTimeCompare(time, firstWanted) < 0 {
                    showing = pixels
                    continue
                }
                if let held = showing, CMTimeCompare(time, firstWanted) > 0 {
                    encoder.encode(held, at: firstWanted, duration: CMTimeSubtract(time, firstWanted))
                }
                showing = nil
                encoder.encode(pixels, at: time, duration: frameDuration)
            }
            if let held = showing, !stop.isSet {
                encoder.encode(held, at: firstWanted, duration: frameDuration)
            }
            encoder.finish()
            fed.leave()
        }
        feeder.name = "Tandem export encoder feed"
        feeder.qualityOfService = .userInitiated
        feeder.start()
        // Every way out stops the feed and waits for it, then (if it didn't
        // run to the end) cancels the reader, now that nothing is inside it.
        // A feed stuck inside AVFoundation is left alone rather than raced.
        func stopFeeding(cancel: Bool) async {
            stop.set()
            let stopped = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async {
                    done.resume(returning: fed.wait(timeout: .now() + 10) == .success)
                }
            }
            if !stopped {
                NSLog("TandemRender: the export's frame reader is stuck; leaving it")
                return
            }
            if cancel { reader.cancelReading() }
        }
        // Nothing should stall, but if AVFoundation does, fail rather than
        // wait forever.
        let watchdog = Task.detached { [stallTimeout] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if encoder.secondsSinceProgress > stallTimeout {
                    encoder.abort(stalled: true)
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        guard let hint = encoder.waitForFormat() else {
            await stopFeeding(cancel: true)
            if isCancelled { throw RenderError.cancelled }
            if encoder.stalled { throw RenderError.export("reading the timeline stalled") }
            throw encoder.error ?? reader.error ?? RenderError.export("the encoder produced nothing")
        }
        do {
            let loudness = try await mux(reader: reader, encoder: encoder, hint: hint, mix: mix, range: range, gainDB: gainDB, ceiling: ceiling, progressBase: base)
            // Finished: the feed has already run out.
            await stopFeeding(cancel: false)
            return loudness
        } catch {
            await stopFeeding(cancel: true)
            throw error
        }
    }

    /// Writes the encoded frames and the mastered mix into the file.
    private func mux(
        reader: AVAssetReader,
        encoder: VideoEncoder,
        hint: CMFormatDescription,
        mix: AVAssetReaderAudioMixOutput?,
        range: TimeRange,
        gainDB: Double,
        ceiling: Double?,
        progressBase base: Double
    ) async throws -> Loudness {
        let fileType: AVFileType
        switch output.pathExtension.lowercased() {
        case "mov": fileType = .mov
        case "m4v": fileType = .m4v
        default: fileType = .mp4
        }
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        videoInput.expectsMediaDataInRealTime = false
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioBuffers.sampleRate,
            AVNumberOfChannelsKey: AudioBuffers.channels,
            AVEncoderBitRateKey: preset.audioBitrate
        ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { throw writer.error ?? RenderError.export("couldn't start writing") }
        writer.startSession(atSourceTime: range.start.cmTime)

        let master = try MasterAudio(
            mix: mix, start: range.start.cmTime,
            frames: Int((range.duration.seconds * Double(AudioBuffers.sampleRate)).rounded()),
            gainDB: gainDB, ceiling: ceiling
        )
        let durationSeconds = range.duration.seconds
        let startSeconds = range.start.seconds
        let io = Unchecked((writer: writer, video: videoInput, audio: audioInput))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            group.enter()
            io.value.video.requestMediaDataWhenReady(on: DispatchQueue(label: "com.mikerosoft.tandem.export.video")) { [weak self] in
                let (writer, input, _) = io.value
                while input.isReadyForMoreMediaData {
                    guard let sample = encoder.nextEncoded(), !(self?.isCancelled ?? true), writer.status == .writing else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    input.append(sample)
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds - startSeconds
                    self?.report(base + (1 - base) * 0.99 * t / max(durationSeconds, 0.001))
                }
            }
            io.value.audio.requestMediaDataWhenReady(on: DispatchQueue(label: "com.mikerosoft.tandem.export.audio")) { [weak self] in
                let (writer, _, input) = io.value
                while input.isReadyForMoreMediaData {
                    guard !(self?.isCancelled ?? true), writer.status == .writing, let sample = master.next() else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    input.append(sample)
                }
            }
            group.notify(queue: .global()) { done.resume() }
        }

        // The reader is cancelled by the caller once the feed has stopped.
        if isCancelled || writer.status != .writing {
            let failure = writer.error
            writer.cancelWriting()
            if isCancelled { throw RenderError.cancelled }
            throw failure ?? RenderError.export("writing stopped")
        }
        if encoder.stalled { writer.cancelWriting(); throw RenderError.export("reading the timeline stalled") }
        if let failure = encoder.error { writer.cancelWriting(); throw failure }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? RenderError.export("reading failed") }
        writer.endSession(atSourceTime: range.end.cmTime)
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? RenderError.export("couldn't finish the file") }
        return master.loudness
    }

    // MARK: - Snapshot

    /// The project as rendered, beside the output (`<output>.tandem`), with
    /// media paths made absolute so it opens from anywhere.
    private func writeSnapshot(range: TimeRange, loudness: Loudness) throws {
        var project = context.project
        for i in project.media.indices {
            project.media[i].path = context.folder.url(for: project.media[i]).path
        }
        project.metadata["export.output"] = output.lastPathComponent
        project.metadata["export.preset"] = preset.name
        project.metadata["export.date"] = ISO8601DateFormatter().string(from: Date())
        project.metadata["export.range"] = "\(range.start.seconds)-\(range.end.seconds)"
        if let format = preset.format, format != OutputFrames.main { project.metadata["export.format"] = format }
        if let width = preset.width, let height = preset.height {
            project.metadata["export.video"] = "\(width)x\(height) \(preset.codec.displayName) at \(ExportPlan.megabits(preset.videoBitrate))"
        }
        if loudness.integratedLUFS.isFinite {
            project.metadata["export.loudness"] = String(format: "%.2f LUFS, %.2f dBTP", loudness.integratedLUFS, loudness.truePeakDBTP)
        }
        struct Snapshot: Encodable {
            var revision: Int
            var project: Project
        }
        let data = try ProjectFile.encoder().encode(Snapshot(revision: 0, project: project))
        try data.write(to: URL(fileURLWithPath: output.path + ".tandem"), options: .atomic)
    }
}

/// Files a render (an export, a review clip, a frame, a screenshot) must
/// never write over.
public enum RenderOutputs {
    /// Why writing `output` would destroy work, or nil when it wouldn't: it
    /// is a Tandem project (this one or any other), or a file this project
    /// plays. Paths are compared after resolving links, which also brings a
    /// differently cased spelling back to the file's own name.
    public static func protectedReason(_ output: URL, project: Project, folder: ProjectFolder) -> String? {
        if output.pathExtension.lowercased() == ProjectFile.fileExtension {
            return "\(output.lastPathComponent) is a Tandem project"
        }
        let target = output.standardizedFileURL.resolvingSymlinksInPath().path
        if project.media.contains(where: { folder.url(for: $0).standardizedFileURL.resolvingSymlinksInPath().path == target }) {
            return "\(output.lastPathComponent) is media in this project"
        }
        return nil
    }
}

/// A flag set from one thread and read from another.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

/// Hands a non-Sendable AVFoundation object to a callback queue. Each is
/// only used from one queue at a time.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Hardware VideoToolbox encoding with speed priority. Encoded samples queue
/// up in order for the muxer.
final class VideoEncoder: @unchecked Sendable {
    private let session: VTCompressionSession
    private let condition = NSCondition()
    private var queue: [CMSampleBuffer] = []
    private var submitted = 0
    private var completed = 0
    private var inputDone = false
    private var aborted = false
    private(set) var stalled = false
    private var lastProgress = Date()
    private(set) var error: Error?

    init(size: CGSize, codec: ExportPreset.Codec, bitrate: Int, fps: FrameRate) throws {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(size.width),
            height: Int32(size.height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw RenderError.export("no hardware \(codec.rawValue) encoder (\(status))") }
        session = created
        let rate = fps.framesPerSecond
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: false,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: rate,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: max(1, Int((rate * 2).rounded())),
            kVTCompressionPropertyKey_ProfileLevel: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ pixels: CVImageBuffer, at time: CMTime, duration: CMTime) {
        condition.lock()
        if aborted {
            condition.unlock()
            return
        }
        submitted += 1
        lastProgress = Date()
        condition.unlock()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time, duration: duration, frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self else { return }
            self.condition.lock()
            if let sample, status == noErr {
                self.queue.append(sample)
            } else if status != noErr, self.error == nil {
                self.error = RenderError.export("encoding a frame failed (\(status))")
            }
            self.completed += 1
            self.lastProgress = Date()
            self.condition.broadcast()
            self.condition.unlock()
        }
        if status != noErr {
            condition.lock()
            completed += 1
            if error == nil { error = RenderError.export("the encoder refused a frame (\(status))") }
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Flushes the encoder; call once all frames are in.
    func finish() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        condition.lock()
        inputDone = true
        condition.broadcast()
        condition.unlock()
    }

    private var drained: Bool { aborted || (inputDone && completed == submitted) }

    /// Wakes everything waiting on the encoder: they get nothing more.
    func abort(stalled: Bool = false) {
        condition.lock()
        aborted = true
        if stalled { self.stalled = true }
        condition.broadcast()
        condition.unlock()
    }

    /// The reader produced something (a frame, used or not).
    func noteProgress() {
        condition.lock()
        lastProgress = Date()
        condition.unlock()
    }

    var secondsSinceProgress: Double {
        condition.lock()
        defer { condition.unlock() }
        return Date().timeIntervalSince(lastProgress)
    }

    /// The first encoded frame's format, which the muxer needs up front.
    func waitForFormat() -> CMFormatDescription? {
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty && !drained { condition.wait() }
        if aborted { return nil }
        return queue.first.flatMap { CMSampleBufferGetFormatDescription($0) }
    }

    /// The next encoded frame, waiting for one, or nil when all are out
    /// (or the encode was aborted).
    func nextEncoded() -> CMSampleBuffer? {
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty && !drained { condition.wait() }
        if aborted { return nil }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    func invalidate() {
        VTCompressionSessionInvalidate(session)
    }
}

/// The mastered mix, pulled a chunk at a time by the muxer: master gain,
/// the true-peak limiter (with its delay compensated so sync is exact),
/// silence wherever the mix has none, and a meter on what goes out.
final class MasterAudio: @unchecked Sendable {
    private let mix: AVAssetReaderAudioMixOutput?
    private let start: CMTime
    private let totalFrames: Int
    private let gain: Float
    private var limiter: TruePeakLimiter?
    private var meter = LoudnessMeter(sampleRate: Double(AudioBuffers.sampleRate), channels: AudioBuffers.channels)
    private let format: CMAudioFormatDescription
    private let channels = AudioBuffers.channels
    private let chunk = 4_800

    /// Processed samples waiting to go out.
    private var pending: [Float] = []
    /// Input frames consumed, to spot gaps in the mix.
    private var consumed = 0
    private var emitted = 0
    private var latencyToDrop: Int
    private var inputDone = false

    init(mix: AVAssetReaderAudioMixOutput?, start: CMTime, frames: Int, gainDB: Double, ceiling: Double?) throws {
        self.mix = mix
        self.start = start
        self.totalFrames = frames
        self.gain = Float(AudioEnvelope.gain(dB: gainDB))
        self.limiter = ceiling.map { TruePeakLimiter(channels: AudioBuffers.channels, ceilingDBTP: $0) }
        self.latencyToDrop = limiter?.latency ?? 0
        self.format = try AudioBuffers.formatDescription()
    }

    var loudness: Loudness { meter.result() }

    func next() -> CMSampleBuffer? {
        while pending.count / channels < chunk && !inputDone {
            pull()
        }
        let frames = min(chunk, pending.count / channels, totalFrames - emitted)
        guard frames > 0 else { return nil }
        let out = Array(pending[0..<(frames * channels)])
        pending.removeFirst(frames * channels)
        meter.process(interleaved: out)
        let time = CMTimeAdd(start, CMTime(value: CMTimeValue(emitted), timescale: CMTimeScale(AudioBuffers.sampleRate)))
        emitted += frames
        return try? AudioBuffers.sampleBuffer(out, at: time, format: format)
    }

    /// Reads and processes the next piece of the mix, or pads with silence
    /// once the mix runs out.
    private func pull() {
        if let mix, let buffer = mix.copyNextSampleBuffer() {
            let position = Int((CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(buffer), start).seconds * Double(AudioBuffers.sampleRate)).rounded())
            var samples = AudioBuffers.samples(in: buffer)
            if position < consumed {
                // Sound from before the range (reading started early).
                let skip = min(consumed - position, samples.count / channels)
                samples.removeFirst(skip * channels)
            } else if position > consumed {
                process([Float](repeating: 0, count: (position - consumed) * channels))
            }
            if !samples.isEmpty { process(samples) }
            return
        }
        // The mix is done (or there is none): silence up to the end, then
        // the limiter's tail.
        let remaining = totalFrames - consumed
        if remaining > 0 {
            process([Float](repeating: 0, count: min(remaining, chunk) * channels))
            return
        }
        if var limiter {
            append(limiter.flush())
            self.limiter = limiter
        }
        inputDone = true
    }

    private func process(_ input: [Float]) {
        var samples = input
        consumed += samples.count / channels
        if gain != 1 { for i in samples.indices { samples[i] *= gain } }
        limiter?.process(&samples)
        append(samples)
    }

    private func append(_ samples: [Float]) {
        var slice = samples[...]
        if latencyToDrop > 0 {
            let drop = min(latencyToDrop, samples.count / channels)
            slice = slice.dropFirst(drop * channels)
            latencyToDrop -= drop
        }
        pending.append(contentsOf: slice)
    }
}
