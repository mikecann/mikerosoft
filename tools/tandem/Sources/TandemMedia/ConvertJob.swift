import Foundation
import TandemCore

/// A copy macOS can decode of a video it can't (`MediaItem.undecodableCodec`),
/// such as a QuickTime Animation or PNG sticker: HEVC with the alpha kept,
/// the same size and frame times, video only (the sound, if any, plays from
/// the original). See `HEVCTranscoder`.
enum ConvertJob {
    static let file = "video.mov"

    static func run(source: URL, item: MediaItem, ffmpeg: FFmpeg?, into folder: URL, context: JobContext) async throws {
        let codec = item.undecodableCodecName ?? "this video"
        guard let ffmpeg else {
            throw MediaError.failed("macOS can't decode \(codec), and converting it needs ffmpeg: \(FFmpeg.installHint)")
        }
        context.progress(0, message: "Converting \(codec) to HEVC")
        try await HEVCTranscoder.transcode(source, to: folder.appendingPathComponent(file), ffmpeg: ffmpeg, includeAudio: false, alphaHint: item.hasAlpha, qos: context.qos)
    }
}

extension MediaItem {
    /// `undecodableCodec` as a name for people: "QuickTime Animation",
    /// "PNG video".
    public var undecodableCodecName: String? {
        undecodableCodec.map(Self.codecName)
    }

    /// "rle " for `kCMVideoCodecType_Animation`: the code's four characters,
    /// or its number when they aren't printable.
    public static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(code) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A name for a four-character video codec code macOS can't decode.
    public static func codecName(_ code: String) -> String {
        switch code {
        case "rle ": return "QuickTime Animation"
        case "png ": return "PNG video"
        case "smc ": return "QuickTime Graphics"
        case "rpza": return "Apple Video"
        case "cvid": return "Cinepak"
        case "SVQ1", "SVQ3": return "Sorenson Video"
        case "AVdn": return "DNxHD"
        case "AVdh": return "DNxHR"
        case "CFHD": return "CineForm"
        case "Hap1", "Hap5", "HapY", "HapM", "HapA", "Hap7": return "HAP"
        default: return "\(code.trimmingCharacters(in: .whitespaces)) video"
        }
    }
}
