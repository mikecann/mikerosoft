import AVFoundation
import Foundation

/// Video AVFoundation can't decode, turned into HEVC it can, with any
/// alpha kept: WebM stickers, and the QuickTime Animation and PNG-in-MOV
/// files stock sticker packs (Storyblocks, Motion Array, older VideoHive)
/// ship.
///
/// ffmpeg decodes the file and writes ProRes 4444 (ProRes 422 HQ without
/// alpha), and AVFoundation's HEVC-with-alpha export preset does the final
/// encode. ffmpeg's own `hevc_videotoolbox` makes alpha files that don't
/// decode, so it isn't used. For WebM the decoder matters: ffmpeg's built-in
/// VP9 decoder drops the alpha channel, `libvpx-vp9` keeps it. RGB sources
/// (Animation, PNG) are converted with the BT.709 matrix and tagged so, like
/// every other sticker Tandem writes.
public enum HEVCTranscoder {
    /// Transcodes `input` into `output`, a QuickTime movie, and returns
    /// whether the copy has alpha.
    ///
    /// - Parameters:
    ///   - includeAudio: keep the first audio track (as the asset library
    ///     does); project copies are video only, the sound plays from the
    ///     original.
    ///   - alphaHint: whether the caller's own probe saw alpha, used when
    ///     ffprobe isn't there to ask. Without either, alpha is assumed: a
    ///     needless alpha channel costs a little space, a lost one ruins
    ///     the sticker.
    @discardableResult
    public static func transcode(_ input: URL, to output: URL, ffmpeg: FFmpeg, includeAudio: Bool = true, alphaHint: Bool? = nil,
                                 qos: DispatchQoS.QoSClass = .utility) async throws -> Bool {
        let video = try await Blocking.run(qos: qos) {
            ((try? ffmpeg.probeStreams(input)) ?? []).first { ($0["codec_type"] as? String) == "video" }
        }
        // Without ffprobe a WebM is taken to be VP9: stickers are why WebM
        // turns up here.
        let codec = video?["codec_name"] as? String ?? (input.pathExtension.lowercased() == "webm" ? "vp9" : nil)
        let pixelFormat = video?["pix_fmt"] as? String
        let hasAlpha: Bool
        var arguments = ["-y", "-v", "error"]
        switch codec {
        case "vp9", "vp8":
            let tags = video?["tags"] as? [String: Any] ?? [:]
            hasAlpha = video == nil || ((tags["alpha_mode"] ?? tags["ALPHA_MODE"]) as? String) == "1"
            arguments += ["-c:v", codec == "vp9" ? "libvpx-vp9" : "libvpx"]
        default:
            hasAlpha = pixelFormat.map(hasAlphaChannel) ?? alphaHint ?? true
        }
        arguments += ["-i", input.path, "-map", "0:v:0"]
        arguments += includeAudio ? ["-map", "0:a:0?", "-c:a", "pcm_s16le"] : ["-an"]
        let intermediateFormat = hasAlpha ? "yuva444p10le" : "yuv422p10le"
        // Animation and PNG frames are RGB, and ffmpeg's default RGB to YUV
        // matrix is BT.601. Convert with BT.709 and tag the frames so:
        // ffmpeg ignores -colorspace and friends here, and untagged the
        // export guesses SMPTE-C for a small picture and turns red orange.
        if pixelFormat.map(isRGB) ?? (codec != "vp9" && codec != "vp8") {
            arguments += ["-vf", "scale=out_color_matrix=bt709:out_range=tv,format=\(intermediateFormat),"
                + "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv"]
        }
        arguments += ["-c:v", "prores_ks", "-profile:v", hasAlpha ? "4444" : "hq", "-pix_fmt", intermediateFormat]
        if hasAlpha { arguments += ["-alpha_bits", "16"] }

        let intermediate = output.deletingLastPathComponent().appendingPathComponent("intermediate-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: intermediate) }
        try await Blocking.run(qos: qos) { try ffmpeg.run(arguments + [intermediate.path]) }

        let asset = AVURLAsset(url: intermediate)
        let preset = hasAlpha ? AVAssetExportPresetHEVCHighestQualityWithAlpha : AVAssetExportPresetHEVCHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaError.failed("No HEVC export session for \(input.lastPathComponent)")
        }
        try? FileManager.default.removeItem(at: output)
        do {
            try await session.export(to: output, as: .mov)
        } catch {
            throw MediaError.failed("Exporting \(input.lastPathComponent) to HEVC: \(error.localizedDescription)")
        }
        return hasAlpha
    }

    /// ffmpeg pixel formats with an alpha channel. Palettes (`pal8`) count:
    /// a PNG's palette can hold transparency.
    static func hasAlphaChannel(_ pixelFormat: String) -> Bool {
        ["yuva", "gbrap", "ya", "argb", "rgba", "abgr", "bgra", "pal8"].contains { pixelFormat.hasPrefix($0) }
    }

    /// ffmpeg pixel formats that hold RGB (or grey) rather than YUV.
    static func isRGB(_ pixelFormat: String) -> Bool {
        ["rgb", "bgr", "argb", "abgr", "0rgb", "0bgr", "gbr", "pal", "gray", "ya", "mono", "x2rgb", "x2bgr"].contains { pixelFormat.hasPrefix($0) }
    }
}
