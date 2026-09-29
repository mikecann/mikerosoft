import AVFoundation
import Foundation
import ImageIO
import TandemCore
import TandemMedia

/// What a video file holds.
struct VideoInfo: Sendable {
    var duration: Double
    var width: Int
    var height: Int
    var frameRate: Double?
    var hasAlpha: Bool
    var hasAudio: Bool
    var hasVideo: Bool
    /// The video codec's four-character code when AVFoundation can't
    /// decode it (QuickTime Animation "rle ", PNG "png ").
    var undecodableCodec: String? = nil
}

/// Reads durations, sizes and alpha with AVFoundation and ImageIO. The
/// media module owns full probing of project files; this covers what the
/// asset library needs for its own files.
enum MediaProbe {
    static func video(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var info = VideoInfo(duration: duration.seconds.isFinite ? duration.seconds : 0, width: 0, height: 0, frameRate: nil, hasAlpha: false, hasAudio: !audioTracks.isEmpty, hasVideo: !videoTracks.isEmpty)
        if let track = videoTracks.first {
            let (size, transform, rate, formats, decodable) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions, .isDecodable)
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            info.width = Int(abs(rect.width).rounded())
            info.height = Int(abs(rect.height).rounded())
            info.frameRate = rate > 0 ? Double(rate) : nil
            info.hasAlpha = formats.contains(where: hasAlpha)
            if !decodable { info.undecodableCodec = formats.first.map { MediaItem.fourCharacterCode(CMFormatDescriptionGetMediaSubType($0)) } ?? "????" }
        }
        return info
    }

    /// True when a video format carries alpha: HEVC with alpha, or ProRes
    /// 4444, Animation or PNG with a 32-bit depth.
    static func hasAlpha(_ format: CMFormatDescription) -> Bool {
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        if let contains = extensions["ContainsAlphaChannel"] as? Bool, contains { return true }
        if let contains = extensions["ContainsAlphaChannel"] as? NSNumber, contains.boolValue { return true }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let alphaCapable: Set<FourCharCode> = [
            kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ, kCMVideoCodecType_Animation, FourCharCode(0x706E_6720) // "png "
        ]
        if alphaCapable.contains(codec) {
            let depth = (extensions[kCMFormatDescriptionExtension_Depth as String] as? NSNumber)?.intValue ?? 32
            return depth == 32
        }
        return false
    }

    /// Size and alpha of a still image.
    static func image(_ url: URL) -> (width: Int, height: Int, hasAlpha: Bool, frames: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        return (width, height, hasAlpha, CGImageSourceGetCount(source))
    }
}
