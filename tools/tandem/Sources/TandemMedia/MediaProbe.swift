import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import TandemCore

/// What probing a file found. `MediaScanner.probe` turns it into a
/// `MediaItem`; the jobs use the extra detail.
struct MediaProbe: Sendable {
    var kind: MediaKind
    var duration: Time?
    var frameRate: FrameRate?
    /// Display size, with the track's rotation applied.
    var width: Int?
    var height: Int?
    var hasVideo = false
    var hasAudio = false
    var hasAlpha = false
    var variableFrameRate = false
    /// The file's creation-date metadata, used to line up takes.
    var creationDate: Date?
    /// Number of video frames, when there's a video track.
    var frameCount: Int?

    func apply(to item: inout MediaItem) {
        item.kind = kind
        item.duration = duration
        item.frameRate = frameRate
        item.width = width
        item.height = height
        item.hasVideo = hasVideo
        item.hasAudio = hasAudio
        item.hasAlpha = hasAlpha
        item.variableFrameRate = variableFrameRate
    }

    static func probe(_ url: URL) async throws -> MediaProbe {
        guard let kind = MediaScanner.mediaKind(forPath: url.path) else {
            throw MediaError.unreadable(url.lastPathComponent, "not a media file")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MediaError.unreadable(url.lastPathComponent, "the file is missing")
        }
        return kind == .image ? try probeImage(url) : try await probeAudioVisual(url)
    }

    // MARK: - Images

    static func probeImage(_ url: URL) throws -> MediaProbe {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw MediaError.unreadable(url.lastPathComponent, "ImageIO can't read it") }
        // EXIF orientations 5 to 8 are rotated a quarter turn.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        var probe = MediaProbe(kind: .image)
        probe.width = rotated ? pixelHeight : pixelWidth
        probe.height = rotated ? pixelWidth : pixelHeight
        probe.hasVideo = true
        probe.hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        return probe
    }

    // MARK: - Audio and video

    static func probeAudioVisual(_ url: URL) async throws -> MediaProbe {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (duration, tracks, creation) = try await asset.load(.duration, .tracks, .creationDate)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        guard !videoTracks.isEmpty || !audioTracks.isEmpty, duration.isNumeric, duration.seconds > 0 else {
            // A movie still being written has no index yet.
            throw MediaError.unreadable(url.lastPathComponent, "no playable audio or video yet")
        }

        var probe = MediaProbe(kind: videoTracks.isEmpty ? .audio : .video)
        probe.duration = Time(seconds: duration.seconds)
        probe.hasAudio = !audioTracks.isEmpty
        probe.hasVideo = !videoTracks.isEmpty
        if let creation { probe.creationDate = try? await creation.load(.dateValue) }

        if let track = videoTracks.first {
            let (size, transform, nominalRate, formats, timescale, canCursor) = try await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions, .naturalTimeScale, .canProvideSampleCursors
            )
            let display = size.applying(transform)
            probe.width = Int(abs(display.width).rounded())
            probe.height = Int(abs(display.height).rounded())
            probe.hasAlpha = formats.contains(where: containsAlpha)

            var timing: FrameTiming?
            if canCursor, let times = presentationTimes(of: track) {
                timing = FrameTiming(presentationTimes: times, timescale: timescale)
                probe.frameCount = times.count
            }
            probe.variableFrameRate = timing?.isVariable ?? false
            probe.frameRate = timing?.rate ?? FrameTiming.snap(framesPerSecond: Double(nominalRate))
        }
        return probe
    }

    /// Presentation time stamps of every sample, in the track's timescale,
    /// read from the sample table without touching the media data.
    static func presentationTimes(of track: AVAssetTrack) -> [Int64]? {
        guard let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return nil }
        let timescale = cursor.presentationTimeStamp.timescale
        guard timescale > 0 else { return nil }
        var times: [Int64] = []
        repeat {
            let pts = cursor.presentationTimeStamp
            guard pts.isNumeric else { break }
            times.append(pts.timescale == timescale ? pts.value : CMTimeConvertScale(pts, timescale: timescale, method: .roundHalfAwayFromZero).value)
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        return times.isEmpty ? nil : times.sorted()
    }

    static func containsAlpha(_ format: CMFormatDescription) -> Bool {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        if codec == kCMVideoCodecType_HEVCWithAlpha { return true }
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        if extensions[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool == true { return true }
        // Codecs that carry alpha when stored with 32-bit depth.
        let alphaCapable: Set<FourCharCode> = [
            kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
            kCMVideoCodecType_Animation, FourCharCode(0x706E_6720) // "png "
        ]
        if alphaCapable.contains(codec), extensions[kCMFormatDescriptionExtension_Depth as String] as? Int == 32 { return true }
        return false
    }
}

/// Frame timing from presentation time stamps: the base rate and whether
/// frames arrive irregularly (record-it screen recordings hold a frame for
/// as long as the screen doesn't change, up to 20 s).
struct FrameTiming: Equatable, Sendable {
    var rate: FrameRate?
    var isVariable: Bool
    /// Intervals that are more than half a frame off the usual one.
    var irregularIntervals: Int
    var intervals: Int

    init(presentationTimes sorted: [Int64], timescale: CMTimeScale) {
        var deltas: [Int64] = []
        deltas.reserveCapacity(max(0, sorted.count - 1))
        for i in 1..<max(1, sorted.count) where sorted[i] > sorted[i - 1] {
            deltas.append(sorted[i] - sorted[i - 1])
        }
        intervals = deltas.count
        guard !deltas.isEmpty, timescale > 0 else {
            rate = nil
            isVariable = false
            irregularIntervals = 0
            return
        }
        // The most common interval is the frame duration the source aims for.
        var counts: [Int64: Int] = [:]
        for delta in deltas { counts[delta, default: 0] += 1 }
        let modal = counts.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }!.key
        let regular = deltas.filter { abs($0 - modal) * 2 <= modal }
        irregularIntervals = deltas.count - regular.count
        // A few dropped frames don't make a file VFR; a screen recording
        // that holds frames for seconds at a time does.
        isVariable = irregularIntervals > max(2, deltas.count / 200)
        // Averaging the regular intervals recovers 29.97 from 600-based
        // timescales that alternate 20 and 21.
        let mean = Double(regular.reduce(0, +)) / Double(max(1, regular.count))
        rate = FrameTiming.snap(framesPerSecond: Double(timescale) / mean)
    }

    /// An exact fraction for a measured rate: integer rates and the NTSC
    /// 1000/1001 rates snap, anything else keeps two decimals.
    static func snap(framesPerSecond fps: Double) -> FrameRate? {
        guard fps.isFinite, fps > 0 else { return nil }
        let whole = fps.rounded()
        if abs(fps - whole) / fps < 0.001 { return FrameRate(Int64(whole)) }
        let ntsc = (fps * 1.001).rounded()
        if abs(fps - ntsc * 1000 / 1001) / fps < 0.0005 { return FrameRate(Int64(ntsc) * 1000, 1001) }
        let hundredths = Int64((fps * 100).rounded())
        let divisor = gcd(hundredths, 100)
        return FrameRate(hundredths / divisor, 100 / divisor)
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return max(1, x)
    }
}

/// Errors from the media module.
public enum MediaError: Error, LocalizedError, Equatable, Sendable {
    /// The file can't be read (yet): missing, still being written, or not media.
    case unreadable(String, String)
    /// The file changed while it was being analysed.
    case fileChanged(String)
    /// The analysis doesn't apply to this media, for example a matte for audio.
    case notApplicable(String)
    /// The work failed.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let file, let reason): return "Can't read \(file): \(reason)"
        case .fileChanged(let file): return "\(file) changed during analysis"
        case .notApplicable(let what): return what
        case .failed(let what): return what
        }
    }
}
