import Foundation
import ImageIO
import TandemCore
import TandemMedia

/// What normalising produced, in the asset's folder.
public struct NormalisedAsset: Codable, Equatable, Sendable {
    /// What the original turned out to be.
    public var format: AssetFormat
    /// The file the editor uses, relative to the folder. Nil when the
    /// original plays as it is (MP4 and MOV video, PNG and JPEG, fonts).
    public var file: String?
    public var thumbnail: String?
    /// Waveform peaks for audio (`peaks.bin`).
    public var peaks: String?
    public var loudness: Loudness?
    /// What it becomes in a project; nil for fonts and LUTs.
    public var mediaKind: MediaKind?
    /// Seconds.
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var hasAlpha: Bool
    public var hasAudio: Bool
    public var hasVideo: Bool
    /// The faces in a font file.
    public var fonts: [FontFace]

    public init(format: AssetFormat, file: String? = nil, thumbnail: String? = nil, peaks: String? = nil, loudness: Loudness? = nil, mediaKind: MediaKind? = nil, duration: Double? = nil, width: Int? = nil, height: Int? = nil, frameRate: Double? = nil, hasAlpha: Bool = false, hasAudio: Bool = false, hasVideo: Bool = false, fonts: [FontFace] = []) {
        self.format = format
        self.file = file
        self.thumbnail = thumbnail
        self.peaks = peaks
        self.loudness = loudness
        self.mediaKind = mediaKind
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.hasAlpha = hasAlpha
        self.hasAudio = hasAudio
        self.hasVideo = hasVideo
        self.fonts = fonts
    }
}

/// Turns whatever a source hands over into files the editor plays
/// directly:
///
/// - Audio: 48 kHz 24-bit WAV, with loudness (`loudness.json`) and
///   waveform peaks (`peaks.bin`). 48 kHz PCM files and beds over 20
///   minutes are measured but used as they are.
/// - Animated GIF, WebP and APNG: HEVC with alpha, via ImageIO.
/// - WebM: HEVC with alpha, via ffmpeg's `libvpx-vp9` and ProRes 4444.
/// - Lottie: rendered offscreen with alpha into HEVC with alpha.
/// - SVG: PNG at twice the size it's likely to be shown.
/// - Fonts: registered with Core Text.
/// - MOV, MP4, PNG, JPEG and HEIC are used as they are.
///
/// Every asset gets a thumbnail.
public struct AssetNormaliser: Sendable {
    public var ffmpeg: FFmpeg?
    /// Long side of rasterised SVGs, in pixels.
    public var svgLongSide: Int
    /// Long side of rendered Lottie animations, in pixels.
    public var lottieLongSide: Int
    /// Register fonts with Core Text for this process as they're normalised.
    public var registersFonts: Bool

    public init(ffmpeg: FFmpeg? = FFmpeg.locate(), svgLongSide: Int = 2048, lottieLongSide: Int = 1024, registersFonts: Bool = true) {
        self.ffmpeg = ffmpeg
        self.svgLongSide = svgLongSide
        self.lottieLongSide = lottieLongSide
        self.registersFonts = registersFonts
    }

    /// Whether Lottie animations can be rendered in this build.
    public static var canRenderLottie: Bool { LottieRenderer.isAvailable }

    /// Normalises `original`, writing results into `folder`. `fallbacks`
    /// are other copies of the same asset to try when the original can't
    /// be handled, for example the animated WebP fetched next to a Lottie
    /// file.
    public func normalise(_ original: URL, into folder: URL, fallbacks: [URL] = []) async throws -> NormalisedAsset {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            return try await normaliseOne(original, into: folder)
        } catch {
            for fallback in fallbacks {
                if let result = try? await normaliseOne(fallback, into: folder) { return result }
            }
            throw error
        }
    }

    private func normaliseOne(_ original: URL, into folder: URL) async throws -> NormalisedAsset {
        let format = FormatSniffer.format(of: original)
        switch format {
        case .wav, .aiff, .mp3, .m4a, .caf, .flac, .ogg:
            return try await audio(original, format: format, into: folder)
        case .gif, .webp, .png:
            if let info = MediaProbe.image(original), info.frames > 1 {
                return try await animated(original, format: format, into: folder)
            }
            return try still(original, format: format, into: folder)
        case .jpeg, .heic:
            return try still(original, format: format, into: folder)
        case .tiff:
            return try convertStill(original, format: format, into: folder)
        case .svg:
            return try svg(original, into: folder)
        case .lottie:
            let output = folder.appendingPathComponent("normalised.mov")
            let info = try await LottieRenderer.render(original, to: output, longSide: lottieLongSide)
            return try await video(output, format: format, info: info, file: output.lastPathComponent, into: folder)
        case .webm:
            guard let ffmpeg else { throw AssetError.normaliseFailed("WebM needs ffmpeg; install it or set TANDEM_FFMPEG") }
            let output = folder.appendingPathComponent("normalised.mov")
            let info = try await WebMConverter.convert(original, to: output, ffmpeg: ffmpeg)
            return try await video(output, format: format, info: info, file: output.lastPathComponent, into: folder)
        case .mov, .mp4:
            let info = try await MediaProbe.video(original)
            return try await video(original, format: format, info: info, file: nil, into: folder)
        case .ttf, .otf, .ttc, .woff, .woff2:
            return try await font(original, format: format, into: folder)
        case .cube:
            return NormalisedAsset(format: format)
        case .unknown:
            throw AssetError.unsupported("Tandem doesn't know what \(original.lastPathComponent) is")
        }
    }

    // MARK: - Kinds

    private func audio(_ original: URL, format: AssetFormat, into folder: URL) async throws -> NormalisedAsset {
        let output = folder.appendingPathComponent("normalised.wav")
        let ffmpeg = self.ffmpeg
        let rewrite = !AudioNormaliser.canUseAsIs(original, format: format)
        if !rewrite { try? FileManager.default.removeItem(at: output) }
        let analysis = try await Self.offload { try AudioNormaliser.normalise(input: original, output: rewrite ? output : nil, ffmpeg: ffmpeg) }
        let peaks = folder.appendingPathComponent("peaks.bin")
        try AudioNormaliser.writePeaks(analysis.waveform, to: peaks)
        let loudness = AssetCatalog.finite(analysis.loudness)
        try JSONEncoder.sorted.encode(loudness).write(to: folder.appendingPathComponent("loudness.json"), options: .atomic)
        let thumbnail = try? Thumbnailer.waveform(analysis.waveform, into: folder)
        return NormalisedAsset(
            format: format, file: analysis.wroteOutput ? output.lastPathComponent : nil, thumbnail: thumbnail, peaks: peaks.lastPathComponent,
            loudness: loudness, mediaKind: .audio, duration: analysis.duration, hasAudio: true
        )
    }

    private func animated(_ original: URL, format: AssetFormat, into folder: URL) async throws -> NormalisedAsset {
        let output = folder.appendingPathComponent("normalised.mov")
        let image = try AnimatedImage(url: original)
        let info = try await image.writeHEVCWithAlpha(to: output)
        return try await video(output, format: format, info: info, file: output.lastPathComponent, into: folder)
    }

    private func still(_ original: URL, format: AssetFormat, into folder: URL) throws -> NormalisedAsset {
        guard let info = MediaProbe.image(original) else { throw AssetError.normaliseFailed("can't read \(original.lastPathComponent)") }
        let thumbnail = try? Thumbnailer.image(original, into: folder)
        return NormalisedAsset(format: format, thumbnail: thumbnail, mediaKind: .image, width: info.width, height: info.height, hasAlpha: info.hasAlpha, hasVideo: true)
    }

    private func convertStill(_ original: URL, format: AssetFormat, into folder: URL) throws -> NormalisedAsset {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AssetError.normaliseFailed("can't read \(original.lastPathComponent)")
        }
        let output = folder.appendingPathComponent("normalised.png")
        try ImageFiles.write(image, to: output, type: .png)
        var result = try still(output, format: format, into: folder)
        result.file = output.lastPathComponent
        return result
    }

    private func svg(_ original: URL, into folder: URL) throws -> NormalisedAsset {
        let output = folder.appendingPathComponent("normalised.png")
        let size = try SVGRasteriser.rasterise(original, to: output, longSide: svgLongSide)
        let thumbnail = try? Thumbnailer.image(output, into: folder)
        return NormalisedAsset(format: .svg, file: output.lastPathComponent, thumbnail: thumbnail, mediaKind: .image, width: size.width, height: size.height, hasAlpha: true, hasVideo: true)
    }

    private func video(_ file: URL, format: AssetFormat, info: VideoInfo, file name: String?, into folder: URL) async throws -> NormalisedAsset {
        let thumbnail = info.hasVideo ? try? await Thumbnailer.video(file, into: folder) : nil
        return NormalisedAsset(
            format: format, file: name, thumbnail: thumbnail, mediaKind: info.hasVideo ? .video : .audio,
            duration: info.duration, width: info.width, height: info.height, frameRate: info.frameRate,
            hasAlpha: info.hasAlpha, hasAudio: info.hasAudio, hasVideo: info.hasVideo
        )
    }

    private func font(_ original: URL, format: AssetFormat, into folder: URL) async throws -> NormalisedAsset {
        let faces = FontInstaller.faces(in: original)
        guard !faces.isEmpty else { throw AssetError.normaliseFailed("no fonts in \(original.lastPathComponent)") }
        if registersFonts {
            let failures = await FontInstaller.register([original])
            if let reason = failures.values.first { throw AssetError.normaliseFailed("registering \(original.lastPathComponent): \(reason)") }
        }
        let thumbnail = try? Thumbnailer.font(original, into: folder)
        return NormalisedAsset(format: format, thumbnail: thumbnail, fonts: faces)
    }

    /// Runs blocking work (decoding, Core Graphics) off the cooperative
    /// thread pool.
    static func offload<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
