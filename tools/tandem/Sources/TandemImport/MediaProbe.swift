import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import TandemCore

/// The facts about a media file an importer needs to make clips that pass
/// the validator: how long it is, and whether it has picture and sound.
public struct ProbedMedia: Equatable, Sendable {
    public var kind: MediaKind
    /// Nil for stills.
    public var duration: Time?
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var hasAlpha: Bool
    public var width: Int?
    public var height: Int?
    public var frameRate: FrameRate?
    /// True when frames have varying durations, as screen recordings do.
    public var variableFrameRate: Bool
    /// More than one frame in a still format (an animated GIF or WebP).
    public var animatedImage: Bool

    public init(
        kind: MediaKind,
        duration: Time? = nil,
        hasVideo: Bool = false,
        hasAudio: Bool = false,
        hasAlpha: Bool = false,
        width: Int? = nil,
        height: Int? = nil,
        frameRate: FrameRate? = nil,
        variableFrameRate: Bool = false,
        animatedImage: Bool = false
    ) {
        self.kind = kind
        self.duration = duration
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.hasAlpha = hasAlpha
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.variableFrameRate = variableFrameRate
        self.animatedImage = animatedImage
    }

    /// A video file with sound, the common case in tests.
    public static func video(_ seconds: Double, audio: Bool = true, width: Int = 3840, height: Int = 2160, fps: FrameRate = .fps30) -> ProbedMedia {
        ProbedMedia(kind: .video, duration: Time(seconds: seconds), hasVideo: true, hasAudio: audio, width: width, height: height, frameRate: fps)
    }

    public static func audio(_ seconds: Double) -> ProbedMedia {
        ProbedMedia(kind: .audio, duration: Time(seconds: seconds), hasAudio: true)
    }

    public static func image(width: Int = 1920, height: Int = 1080, alpha: Bool = false) -> ProbedMedia {
        ProbedMedia(kind: .image, hasVideo: true, hasAlpha: alpha, width: width, height: height)
    }
}

/// Something that can look inside media files.
///
/// Importers take one of these so tests can run without media. The real
/// one is `AVFoundationProbe`.
public protocol MediaProbing: Sendable {
    func exists(_ url: URL) -> Bool
    func probe(_ url: URL) async throws -> ProbedMedia
}

extension MediaProbing {
    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// Probes files with AVFoundation, and ImageIO for stills.
///
/// This is the importer's own probe, standing in for `MediaScanner.probe`,
/// which is still a stub on this branch. When the media module lands its
/// probe, wrap it in a `MediaProbing` and pass that to the importers.
///
/// Files with an extension AVFoundation doesn't know (Filmora keeps some
/// library MP3s as `.cof`) are opened by content type, sniffed from their
/// first bytes.
public struct AVFoundationProbe: MediaProbing {
    public init() {}

    public func probe(_ url: URL) async throws -> ProbedMedia {
        guard exists(url) else { throw ImportError.unreadable("\(url.path) (no such file)") }
        let sniffed = FileSniffer.sniff(url)
        if let sniffed, sniffed.kind == .image {
            return try probeImage(url)
        }
        if sniffed?.fileExtension == "webm" {
            throw ImportError.unreadable("\(url.lastPathComponent) (WebM isn't supported by AVFoundation)")
        }
        var options: [String: Any] = [:]
        if let sniffed, !FileSniffer.avFoundationExtensions.contains(url.pathExtension.lowercased()) {
            options[AVURLAssetOverrideMIMETypeKey] = sniffed.mimeType
        }
        let asset = AVURLAsset(url: url, options: options)
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ImportError.unreadable("\(url.lastPathComponent) (\(error.localizedDescription))")
        }
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
            throw ImportError.unreadable("\(url.lastPathComponent) (no picture or sound AVFoundation can read)")
        }
        var result = ProbedMedia(kind: videoTracks.isEmpty ? .audio : .video)
        if duration.isValid, !duration.isIndefinite, duration.seconds > 0 {
            result.duration = Time(seconds: duration.seconds)
        }
        result.hasVideo = !videoTracks.isEmpty
        result.hasAudio = !audioTracks.isEmpty
        if let track = videoTracks.first {
            let (size, transform, nominal, minimum, formats) = try await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration, .formatDescriptions
            )
            let shown = size.applying(transform)
            result.width = Int(abs(shown.width).rounded())
            result.height = Int(abs(shown.height).rounded())
            let peak = minimum.isValid && minimum.seconds > 0 ? 1 / minimum.seconds : 0
            let average = Double(nominal)
            // Screen recordings write frames only when something changes:
            // the average rate sits well under the peak rate.
            result.variableFrameRate = peak > 0 && average > 0 && abs(peak - average) > 0.5
            result.frameRate = Self.frameRate(result.variableFrameRate ? peak : (average > 0 ? average : peak))
            result.hasAlpha = formats.contains { description in
                (CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool) ?? false
            }
        }
        return result
    }

    private func probeImage(_ url: URL) throws -> ProbedMedia {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ImportError.unreadable("\(url.lastPathComponent) (ImageIO can't read it)")
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let alpha = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        var result = ProbedMedia.image(width: width ?? 0, height: height ?? 0, alpha: alpha)
        if width == nil { result.width = nil }
        if height == nil { result.height = nil }
        result.animatedImage = CGImageSourceGetCount(source) > 1
        return result
    }

    /// Snaps a measured rate to the exact fraction it almost certainly is.
    static func frameRate(_ fps: Double) -> FrameRate? {
        guard fps > 0, fps.isFinite else { return nil }
        let common = [
            FrameRate(24000, 1001), FrameRate(24), FrameRate(25), FrameRate(30000, 1001), FrameRate(30),
            FrameRate(48), FrameRate(50), FrameRate(60000, 1001), FrameRate(60), FrameRate(120)
        ]
        if let hit = common.first(where: { abs($0.framesPerSecond - fps) < 0.02 }) { return hit }
        return FrameRate(Int64((fps * 1000).rounded()), 1000)
    }
}

/// Recognises media files by their first bytes, for files whose extension
/// lies (Filmora's `.cof` library files are MP3s).
enum FileSniffer {
    struct Match: Equatable {
        var fileExtension: String
        var mimeType: String
        var kind: MediaKind
    }

    /// Formats AVFoundation can't play: Filmora's animated stickers are WebM.
    static let unplayableExtensions: Set<String> = ["webm", "mkv", "ogg", "ogv"]

    /// Extensions AVFoundation opens without help.
    static let avFoundationExtensions: Set<String> = ["mov", "mp4", "m4v", "m4a", "mp3", "wav", "aif", "aiff", "aifc", "caf", "aac", "3gp"]

    static func sniff(_ url: URL) -> Match? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16), data.count >= 4 else { return nil }
        return sniff(bytes: [UInt8](data))
    }

    static func sniff(bytes b: [UInt8]) -> Match? {
        func ascii(_ range: Range<Int>) -> String {
            guard range.upperBound <= b.count else { return "" }
            return String(decoding: b[range], as: UTF8.self)
        }
        if ascii(0..<3) == "ID3" || (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 && (b[1] & 0x06) != 0) {
            return Match(fileExtension: "mp3", mimeType: "audio/mpeg", kind: .audio)
        }
        if ascii(4..<12) == "ftypheic" || ascii(4..<12) == "ftypmif1" {
            return Match(fileExtension: "heic", mimeType: "image/heic", kind: .image)
        }
        if ascii(4..<8) == "ftyp" {
            let brand = ascii(8..<12)
            if brand.hasPrefix("M4A") { return Match(fileExtension: "m4a", mimeType: "audio/mp4", kind: .audio) }
            if brand == "qt  " { return Match(fileExtension: "mov", mimeType: "video/quicktime", kind: .video) }
            return Match(fileExtension: "mp4", mimeType: "video/mp4", kind: .video)
        }
        if ascii(4..<8) == "moov" || ascii(4..<8) == "wide" || ascii(4..<8) == "mdat" {
            return Match(fileExtension: "mov", mimeType: "video/quicktime", kind: .video)
        }
        if ascii(0..<4) == "RIFF" && ascii(8..<12) == "WAVE" { return Match(fileExtension: "wav", mimeType: "audio/wav", kind: .audio) }
        if ascii(0..<4) == "RIFF" && ascii(8..<12) == "WEBP" { return Match(fileExtension: "webp", mimeType: "image/webp", kind: .image) }
        if ascii(0..<4) == "FORM" && ascii(8..<11) == "AIF" { return Match(fileExtension: "aiff", mimeType: "audio/aiff", kind: .audio) }
        if ascii(0..<4) == "caff" { return Match(fileExtension: "caf", mimeType: "audio/x-caf", kind: .audio) }
        if b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3 {
            return Match(fileExtension: "webm", mimeType: "video/webm", kind: .video)
        }
        if b[0] == 0x89 && ascii(1..<4) == "PNG" { return Match(fileExtension: "png", mimeType: "image/png", kind: .image) }
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return Match(fileExtension: "jpg", mimeType: "image/jpeg", kind: .image) }
        if ascii(0..<4) == "GIF8" { return Match(fileExtension: "gif", mimeType: "image/gif", kind: .image) }
        if ascii(0..<4) == "OggS" { return Match(fileExtension: "ogg", mimeType: "audio/ogg", kind: .audio) }
        if ascii(0..<4) == "fLaC" { return Match(fileExtension: "flac", mimeType: "audio/flac", kind: .audio) }
        return nil
    }
}
