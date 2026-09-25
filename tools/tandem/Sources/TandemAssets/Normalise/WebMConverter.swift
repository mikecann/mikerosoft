import AVFoundation
import Foundation

/// WebM stickers and overlays to HEVC with alpha.
///
/// AVFoundation can't open WebM, so ffmpeg decodes it. The decoder matters:
/// ffmpeg's built-in VP9 decoder drops the alpha channel, `libvpx-vp9`
/// keeps it. ffmpeg writes ProRes 4444 and AVFoundation's HEVC-with-alpha
/// export preset does the final encode. (ffmpeg's `hevc_videotoolbox` makes
/// alpha files that don't decode, so it's not used.)
enum WebMConverter {
    static func convert(_ input: URL, to output: URL, ffmpeg: FFmpeg) async throws -> VideoInfo {
        let streams = (try? ffmpeg.probeStreams(input)) ?? []
        let video = streams.first { ($0["codec_type"] as? String) == "video" }
        let codec = video?["codec_name"] as? String ?? "vp9"
        let tags = video?["tags"] as? [String: Any] ?? [:]
        let alphaTag = (tags["alpha_mode"] ?? tags["ALPHA_MODE"]) as? String
        // Without ffprobe, assume alpha: stickers are why WebM turns up here.
        let hasAlpha = video == nil ? true : alphaTag == "1"

        let intermediate = output.deletingLastPathComponent().appendingPathComponent("intermediate-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: intermediate) }
        var arguments = ["-y", "-v", "error"]
        if codec == "vp9" { arguments += ["-c:v", "libvpx-vp9"] } else if codec == "vp8" { arguments += ["-c:v", "libvpx"] }
        arguments += ["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "prores_ks", "-profile:v", hasAlpha ? "4444" : "hq"]
        arguments += hasAlpha ? ["-pix_fmt", "yuva444p10le", "-alpha_bits", "16"] : ["-pix_fmt", "yuv422p10le"]
        arguments += ["-c:a", "pcm_s16le", intermediate.path]
        try ffmpeg.run(arguments)

        let asset = AVURLAsset(url: intermediate)
        let preset = hasAlpha ? AVAssetExportPresetHEVCHighestQualityWithAlpha : AVAssetExportPresetHEVCHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AssetError.normaliseFailed("no HEVC export session for \(input.lastPathComponent)")
        }
        try? FileManager.default.removeItem(at: output)
        do {
            try await session.export(to: output, as: .mov)
        } catch {
            throw AssetError.normaliseFailed("exporting \(input.lastPathComponent) to HEVC: \(error.localizedDescription)")
        }
        return try await MediaProbe.video(output)
    }
}
