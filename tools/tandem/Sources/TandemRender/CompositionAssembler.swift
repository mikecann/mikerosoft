import AVFoundation
import CoreImage
import Foundation
import TandemCore
import TandemMedia

/// A media file loaded for composition: its first video and audio tracks
/// with the properties the builder needs.
struct LoadedSource: @unchecked Sendable {
    var asset: AVURLAsset
    var video: AVAssetTrack?
    var videoRange: CMTimeRange = .zero
    var naturalSize: CGSize = .zero
    var preferredTransform: CGAffineTransform = .identity
    var audio: AVAssetTrack?
    var audioRange: CMTimeRange = .zero
}

/// Loaded sources by file, reused across builds (the viewer rebuilds the
/// composition after every edit). Entries are dropped when the file changes.
final class SourceCache: @unchecked Sendable {
    static let shared = SourceCache()
    private let lock = NSLock()
    private var entries: [String: (stamp: String, source: LoadedSource)] = [:]

    func source(for url: URL) async throws -> LoadedSource {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attributes else { throw RenderError.media("Missing media file \(url.path).") }
        let stamp = "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attributes[.size] as? Int ?? 0)"
        let cached: LoadedSource? = lock.withLock {
            guard let entry = entries[url.path], entry.stamp == stamp else { return nil }
            return entry.source
        }
        if let cached { return cached }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var source = LoadedSource(asset: asset)
        if let video = try await asset.loadTracks(withMediaType: .video).first {
            let (size, transform, range) = try await video.load(.naturalSize, .preferredTransform, .timeRange)
            source.video = video
            source.naturalSize = size
            source.preferredTransform = transform
            source.videoRange = range
        }
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            source.audio = audio
            source.audioRange = try await audio.load(.timeRange)
        }
        lock.withLock { entries[url.path] = (stamp, source) }
        return source
    }
}

/// A tiny black movie that underlies every composition, so the video always
/// spans the whole timeline, even when it holds only titles or ends in a
/// gap. The compositor never asks for its frames.
actor BaseVideo {
    static let shared = BaseVideo()
    private var ready: URL?

    func url() async throws -> URL {
        // The temporary folder can be cleaned while the app runs.
        if let ready, FileManager.default.fileExists(atPath: ready.path) { return ready }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TandemRender", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("base-black-v1.mov")
        if await Self.usable(url) {
            ready = url
            return url
        }
        let temporary = folder.appendingPathComponent("base-black-\(UUID().uuidString).mov")
        try await Self.write(to: temporary)
        // Another process (the CLI next to the app) may be doing the same:
        // if the shared name is taken by then, use it, or keep our own copy.
        if (try? FileManager.default.moveItem(at: temporary, to: url)) != nil || FileManager.default.fileExists(atPath: url.path) {
            if FileManager.default.fileExists(atPath: temporary.path) { try? FileManager.default.removeItem(at: temporary) }
            ready = url
        } else {
            ready = temporary
        }
        return ready!
    }

    private static func usable(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video) else { return false }
        return !tracks.isEmpty
    }

    /// One black 64x64 frame lasting a second.
    private static func write(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RenderError.media("Couldn't write the base video.") }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw RenderError.media("Couldn't make a pixel buffer.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        for i in stride(from: 3, to: CVPixelBufferGetDataSize(buffer), by: 4) {
            CVPixelBufferGetBaseAddress(buffer)!.storeBytes(of: 255, toByteOffset: i, as: UInt8.self)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        adaptor.append(buffer, withPresentationTime: .zero)
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? RenderError.media("Couldn't write the base video.") }
    }
}

/// Turns a render plan into AVFoundation objects.
enum CompositionAssembler {
    static func build(_ context: RenderContext) async throws -> BuiltComposition {
        let project = context.project
        let plan = RenderPlanner.plan(project, format: context.format, assets: context.assets)
        guard plan.duration > .zero else { throw RenderError.emptyTimeline }
        var warnings = RenderPlanner.Warnings()
        plan.warnings.forEach { warnings.add($0) }
        let media = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let clips = Dictionary(project.videoTracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let frameDuration = project.settings.frameRate.frameDuration

        // Which file each segment reads.
        func url(for segment: PlannedSegment) -> URL? {
            guard let item = media[segment.mediaID] else { return nil }
            switch segment.role {
            case .picture:
                if context.useProxies, let proxy = context.assets?.proxyURL(for: item) { return proxy }
                return context.folder.url(for: item)
            case .matte:
                let cutout = clips[segment.clipID]?.video?.cutout ?? Cutout()
                return context.assets?.matteURL(for: item, cutout: cutout)
            case .sound: return context.folder.url(for: item)
            case .isolatedVoice: return context.assets?.isolatedVoiceURL(for: item)
            }
        }
        var sources: [URL: LoadedSource] = [:]
        for segment in plan.videoSegments + plan.audioSegments {
            guard let u = url(for: segment), sources[u] == nil else { continue }
            do {
                sources[u] = try await SourceCache.shared.source(for: u)
            } catch {
                warnings.add("Couldn't open \(u.lastPathComponent): \(error)")
            }
        }

        let composition = AVMutableComposition()
        // The black base spans the whole timeline.
        let baseURL = try await BaseVideo.shared.url()
        let base = try await SourceCache.shared.source(for: baseURL)
        if let baseTrack = base.video, let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(base.videoRange, of: baseTrack, at: .zero)
            track.scaleTimeRange(CMTimeRange(start: .zero, duration: base.videoRange.duration), toDuration: plan.duration.cmTime)
        }

        // Video pool.
        var videoTracks: [AVMutableCompositionTrack] = []
        for _ in 0..<plan.videoTrackCount {
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw RenderError.compositor("couldn't add a video track")
            }
            videoTracks.append(track)
        }
        var videoEnds = Array(repeating: Time.zero, count: videoTracks.count)
        var pictureTransforms: [String: CGAffineTransform] = [:]
        var matteTransforms: [String: CGAffineTransform] = [:]
        var pictureSources: [String: SourceTrack] = [:]
        var matteSources: [String: SourceTrack] = [:]
        var pictureRecovery: [String: TimeRange] = [:]
        var matteRecovery: [String: TimeRange] = [:]
        for segment in plan.videoSegments.sorted(by: { $0.timeline.start < $1.timeline.start }) {
            guard let u = url(for: segment), let source = sources[u], let assetTrack = source.video else { continue }
            do {
                let leading = LeadingFrameCache.shared.map(for: u)
                let bad = leading.flatMap { Self.undecodableStart(of: segment, in: $0) }
                // A segment that starts on leading frames AVFoundation can't
                // decode from a seek (it shows a stale frame, or a reader
                // stalls) goes in from their keyframe; the compositor decodes
                // the frames before it directly.
                if let bad {
                    if let rest = bad.rest {
                        try insert(rest, into: videoTracks[segment.track], from: assetTrack, available: source.videoRange,
                                   end: &videoEnds[segment.track], holdLastFrame: true, frameDuration: frameDuration)
                    }
                } else {
                    try insert(segment, into: videoTracks[segment.track], from: assetTrack, available: source.videoRange,
                               end: &videoEnds[segment.track], holdLastFrame: true, frameDuration: frameDuration)
                }
                let direct = SourceTrack(url: u, asset: source.asset, track: assetTrack, timeRange: source.videoRange, leading: leading)
                if segment.role == .picture {
                    pictureTransforms[segment.clipID] = source.preferredTransform
                    pictureSources[segment.clipID] = direct
                    pictureRecovery[segment.clipID] = bad?.timeline
                } else {
                    matteTransforms[segment.clipID] = source.preferredTransform
                    matteSources[segment.clipID] = direct
                    matteRecovery[segment.clipID] = bad?.timeline
                }
            } catch {
                warnings.add("Couldn't place \(u.lastPathComponent) for clip \(segment.clipID): \(error)")
            }
        }

        // Audio pool and its volume envelopes.
        var audioTracks: [AVMutableCompositionTrack] = []
        var mixParameters: [AVMutableAudioMixInputParameters] = []
        for _ in 0..<plan.audioTrackCount {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw RenderError.compositor("couldn't add an audio track")
            }
            audioTracks.append(track)
            let parameters = AVMutableAudioMixInputParameters(track: track)
            // Speed changes keep their pitch.
            parameters.audioTimePitchAlgorithm = .spectral
            mixParameters.append(parameters)
        }
        var audioEnds = Array(repeating: Time.zero, count: audioTracks.count)
        let audioClips = Dictionary(project.audioTracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for segment in plan.audioSegments.sorted(by: { $0.timeline.start < $1.timeline.start }) {
            guard let u = url(for: segment), let source = sources[u], let assetTrack = source.audio else {
                if url(for: segment) != nil { warnings.add("No sound in the file for clip \(segment.clipID).") }
                continue
            }
            do {
                var placed = false
                if !segment.freeze, let clip = audioClips[segment.clipID], let effect = PitchShift.effect(of: clip, registry: context.effects) {
                    // Pitch-shifted sound comes from a rendered copy that
                    // starts at the segment's source start.
                    do {
                        let pitched = try await PitchShift.file(for: segment, clip: clip, effect: effect, source: u, registry: context.effects)
                        let shifted = try await SourceCache.shared.source(for: pitched)
                        if let shiftedTrack = shifted.audio {
                            var fromCopy = segment
                            fromCopy.sourceStart = Time(cmTime: shifted.audioRange.start)
                            try insert(fromCopy, into: audioTracks[segment.track], from: shiftedTrack, available: shifted.audioRange,
                                       end: &audioEnds[segment.track], holdLastFrame: false, frameDuration: frameDuration)
                            placed = true
                        }
                    } catch {
                        warnings.add("Couldn't shift the pitch of clip \(segment.clipID), playing it as it is: \(error)")
                    }
                }
                if !placed {
                    try insert(segment, into: audioTracks[segment.track], from: assetTrack, available: source.audioRange,
                               end: &audioEnds[segment.track], holdLastFrame: false, frameDuration: frameDuration)
                }
                let parameters = mixParameters[segment.track]
                for (a, b) in zip(segment.envelope, segment.envelope.dropFirst()) where b.time > a.time {
                    parameters.setVolumeRamp(
                        fromStartVolume: Float(a.gain), toEndVolume: Float(b.gain),
                        timeRange: CMTimeRange(start: a.time.cmTime, end: b.time.cmTime)
                    )
                }
            } catch {
                warnings.add("Couldn't place \(u.lastPathComponent) for clip \(segment.clipID): \(error)")
            }
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParameters

        // The compositor's view of the clips.
        var sceneClips = RenderEngine.sceneClips(project, folder: context.folder)
        for (id, transform) in pictureTransforms { sceneClips[id]?.pictureTransform = transform }
        for (id, transform) in matteTransforms { sceneClips[id]?.matteTransform = transform }
        for (id, source) in pictureSources { sceneClips[id]?.picture = source }
        for (id, source) in matteSources { sceneClips[id]?.matte = source }
        for (id, range) in pictureRecovery { sceneClips[id]?.pictureRecovery = range }
        for (id, range) in matteRecovery { sceneClips[id]?.matteRecovery = range }
        let canvas = context.renderSize
        let scene = RenderScene(
            canvas: canvas, frameDuration: frameDuration, format: context.format,
            clips: sceneClips, registry: context.effects, folder: context.folder,
            recovery: .shared, overrides: context.liveOverrides
        )
        let trackIDs = videoTracks.map(\.trackID)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = TandemCompositor.self
        videoComposition.renderSize = canvas
        let rate = project.settings.frameRate
        videoComposition.frameDuration = CMTime(value: rate.denominator, timescale: CMTimeScale(rate.numerator))
        // No colour properties here: with them AVFoundation hands the
        // compositor every source frame tagged BT.709 without converting
        // it, so BT.601 footage (Mike's camera) decoded with the wrong
        // matrix (red 180/40/50 came out 192/54/48). Frames keep their own
        // tags, and the compositor tags its output BT.709 itself.
        videoComposition.instructions = plan.instructions.map {
            TandemInstruction(range: $0.range, stack: $0.stack, scene: scene, trackIDs: trackIDs)
        }

        return BuiltComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            renderSize: canvas,
            duration: plan.duration,
            warnings: warnings.list
        )
    }

    /// When a segment starts on leading frames AVFoundation can't decode
    /// from a seek: the stretch of timeline until their keyframe (the whole
    /// segment for a freeze frame), and the rest of the segment, starting
    /// on that keyframe, if any is left.
    static func undecodableStart(of segment: PlannedSegment, in map: LeadingFrameMap) -> (timeline: TimeRange, rest: PlannedSegment?)? {
        guard let window = map.window(containing: segment.sourceStart) else { return nil }
        if segment.freeze { return (segment.timeline, nil) }
        let speed = segment.speed > 0 ? segment.speed : 1
        let source = window.end - segment.sourceStart
        let length = speed == 1 ? source : source.scaled(by: 1 / speed)
        let end = min(segment.timeline.start + length, segment.timeline.end)
        var rest: PlannedSegment?
        if end < segment.timeline.end {
            var after = segment
            after.timeline = TimeRange(start: end, end: segment.timeline.end)
            after.sourceStart = window.end
            rest = after
        }
        return (TimeRange(start: segment.timeline.start, end: end), rest)
    }

    /// Places one segment on its composition track: speed through
    /// `scaleTimeRange`, freeze frames as one frame stretched, and media
    /// that runs out holding its last frame (video) or going quiet (audio).
    static func insert(
        _ segment: PlannedSegment,
        into track: AVMutableCompositionTrack,
        from source: AVAssetTrack,
        available: CMTimeRange,
        end trackEnd: inout Time,
        holdLastFrame: Bool,
        frameDuration: Time
    ) throws {
        let start = segment.timeline.start
        let end = segment.timeline.end
        guard end > start else { return }
        if trackEnd < start {
            track.insertEmptyTimeRange(CMTimeRange(start: trackEnd.cmTime, end: start.cmTime))
        }
        let first = Time(cmTime: available.start)
        let last = Time(cmTime: available.end)
        let frame = min(frameDuration, max(last - first, Time(flicks: 1)))

        if segment.freeze {
            let at = min(max(segment.sourceStart, first), last - frame)
            try track.insertTimeRange(TimeRange(start: at, duration: frame).cmTimeRange, of: source, at: start.cmTime)
            track.scaleTimeRange(TimeRange(start: start, duration: frame).cmTimeRange, toDuration: (end - start).cmTime)
            trackEnd = end
            return
        }

        let speed = segment.speed > 0 ? segment.speed : 1
        let wanted = speed == 1 ? end - start : (end - start).scaled(by: speed)
        var sourceStart = segment.sourceStart
        var position = start
        if sourceStart < first {
            // The file starts later than asked (an audio track starting a
            // few samples in): leave that bit empty.
            let skipped = first - sourceStart
            let skippedTimeline = speed == 1 ? skipped : skipped.scaled(by: 1 / speed)
            let gap = min(skippedTimeline, end - start)
            track.insertEmptyTimeRange(TimeRange(start: position, duration: gap).cmTimeRange)
            position += gap
            sourceStart = first
        }
        let usable = min(wanted - (position - start).scaled(by: speed), last - sourceStart)
        if usable > .zero {
            try track.insertTimeRange(TimeRange(start: sourceStart, duration: usable).cmTimeRange, of: source, at: position.cmTime)
            let timeline: Time
            if position == start && usable == wanted {
                timeline = end - start
            } else {
                timeline = speed == 1 ? usable : usable.scaled(by: 1 / speed)
            }
            if timeline != usable {
                track.scaleTimeRange(TimeRange(start: position, duration: usable).cmTimeRange, toDuration: min(timeline, end - position).cmTime)
            }
            position += min(timeline, end - position)
        }
        if position < end {
            if holdLastFrame && last - frame >= first {
                try track.insertTimeRange(TimeRange(start: last - frame, duration: frame).cmTimeRange, of: source, at: position.cmTime)
                track.scaleTimeRange(TimeRange(start: position, duration: frame).cmTimeRange, toDuration: (end - position).cmTime)
            } else {
                track.insertEmptyTimeRange(TimeRange(start: position, end: end).cmTimeRange)
            }
        }
        trackEnd = end
    }
}
