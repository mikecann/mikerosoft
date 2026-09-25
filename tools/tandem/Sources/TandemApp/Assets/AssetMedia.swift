import AVFoundation
import Accelerate
import AppKit
import ImageIO
import TandemAssets

/// Pictures and sound for the browser: tile thumbnails, frames for hover
/// scrubbing stickers and video, waveform strips, and the player that
/// auditions audio from the hovered point. Everything loads off the main
/// thread and stays in memory while the app runs.
@MainActor
final class AssetMedia {
    var library: AssetLibrary?
    let player = AVPlayer()
    /// The asset the player has loaded.
    private(set) var auditioning: String?

    private let thumbnails = NSCache<NSString, NSImage>()
    private var loading: [NSString: Task<NSImage?, Never>] = [:]
    private var frameSources: [String: FrameSource] = [:]
    private let frames = NSCache<NSString, CGImage>()
    private var waveforms: [String: [Float]] = [:]
    private var auditionDuration: Double = 0

    init() {
        thumbnails.countLimit = 800
        frames.countLimit = 400
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = PlaybackController.muted
    }

    // MARK: - Thumbnails

    /// The tile picture if it's already loaded, for drawing without a flash.
    func cachedThumbnail(for asset: Asset) -> NSImage? {
        thumbnails.object(forKey: Self.key(asset))
    }

    /// The downloaded thumbnail, or the provider's remote one through the
    /// size-capped preview cache.
    func thumbnail(for asset: Asset) async -> NSImage? {
        let key = Self.key(asset)
        if let image = thumbnails.object(forKey: key) { return image }
        if let task = loading[key] { return await task.value }
        guard let library else { return nil }
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            if let local = library.url(for: asset, .thumbnail), FileManager.default.fileExists(atPath: local.path) {
                return NSImage(contentsOf: local)
            }
            // A look in an import folder is a local file: reading it makes
            // its before and after card, with nothing to download.
            if asset.kind == .lut, asset.provider == "import", let read = try? await library.fetch(asset.id),
               let local = library.url(for: read, .thumbnail), FileManager.default.fileExists(atPath: local.path) {
                return NSImage(contentsOf: local)
            }
            guard let remote = asset.thumbnailURL, let file = try? await library.previews.fetch(remote) else { return nil }
            if file.pathExtension.lowercased() == "svg", let text = try? String(contentsOf: file, encoding: .utf8) {
                return NSImage(data: Data(SVGSizing.readableColours(SVGSizing.sized(text)).utf8))
            }
            return NSImage(contentsOf: file)
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image { thumbnails.setObject(image, forKey: key) }
        return image
    }

    private static func key(_ asset: Asset) -> NSString {
        "\(asset.id)|\(asset.files.thumbnail ?? asset.thumbnailURL?.absoluteString ?? "")" as NSString
    }

    // MARK: - Hover frames

    private enum FrameSource {
        case movie(Unchecked<AVAssetImageGenerator>, duration: Double)
        case animation(Unchecked<CGImageSource>, count: Int)
    }

    /// The frame `fraction` of the way through a sticker or clip: from the
    /// downloaded movie, else the provider's animated preview. Nil for
    /// still assets.
    func frame(for asset: Asset, at fraction: Double) async -> CGImage? {
        guard let source = await frameSource(for: asset) else { return nil }
        switch source {
        case .animation(let box, let count):
            let index = min(count - 1, max(0, Int(fraction * Double(count))))
            let key = "\(asset.id)#\(index)" as NSString
            if let cached = frames.object(forKey: key) { return cached }
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 200
                ]
                return CGImageSourceCreateThumbnailAtIndex(box.value, index, options as CFDictionary)
            }.value
            if let image { frames.setObject(image, forKey: key) }
            return image
        case .movie(let box, let duration):
            // Twenty steps across the tile are plenty to scrub with.
            let step = (min(max(fraction, 0), 0.999) * 20).rounded(.down) / 20
            let key = "\(asset.id)@\(step)" as NSString
            if let cached = frames.object(forKey: key) { return cached }
            let time = CMTime(seconds: step * duration, preferredTimescale: 600)
            let image = try? await box.value.image(at: time).image
            if let image { frames.setObject(image, forKey: key) }
            return image
        }
    }

    private func frameSource(for asset: Asset) async -> FrameSource? {
        if let cached = frameSources[asset.id] { return cached }
        guard let library, asset.kind.isVisual else { return nil }
        let url = await Self.localOrPreview(asset, library: library)
        guard let url else { return nil }
        let source: FrameSource?
        if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
            let movie = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: movie)
            generator.maximumSize = CGSize(width: 200, height: 200)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 20)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 20)
            let duration = (try? await movie.load(.duration).seconds) ?? 0
            source = duration > 0 ? .movie(Unchecked(generator), duration: duration) : nil
        } else if let images = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(images) > 1 {
            source = .animation(Unchecked(images), count: CGImageSourceGetCount(images))
        } else {
            source = nil
        }
        if let source { frameSources[asset.id] = source }
        return source
    }

    /// The file the editor would use when it's downloaded, else the
    /// provider's preview (downloaded into the preview cache).
    nonisolated static func localOrPreview(_ asset: Asset, library: AssetLibrary) async -> URL? {
        if let local = library.playableURL(for: asset), FileManager.default.fileExists(atPath: local.path) { return local }
        return try? await library.previewFile(for: asset.id)
    }

    // MARK: - Waveforms

    /// Peaks for a waveform strip: the library's when the asset is
    /// normalised, else measured from the file. Remote assets only get one
    /// once their preview is downloaded (`allowDownload`), so a list of
    /// search results doesn't download every file.
    func waveform(for asset: Asset, allowDownload: Bool) async -> [Float]? {
        if let cached = waveforms[asset.id] { return cached }
        guard let library, asset.kind.isAudio else { return nil }
        let peaks = await Task.detached(priority: .utility) { () -> [Float]? in
            if let waveform = library.waveform(for: asset), !waveform.peaks.isEmpty { return waveform.peaks }
            let file: URL?
            if let local = library.playableURL(for: asset), FileManager.default.fileExists(atPath: local.path) {
                file = local
            } else if allowDownload {
                file = try? await library.previewFile(for: asset.id)
            } else {
                file = nil
            }
            return file.flatMap { AssetMedia.peaks(of: $0) }
        }.value
        if let peaks { waveforms[asset.id] = peaks }
        return peaks
    }

    /// The loudest sample in each of `count` stretches of an audio file.
    nonisolated static func peaks(of url: URL, count: Int = 600) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        let total = Double(file.length)
        var peaks = [Float](repeating: 0, count: count)
        var position: Int64 = 0
        while position < file.length {
            do {
                try file.read(into: buffer, frameCount: chunk)
            } catch {
                break
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            // Each chunk is split at bucket edges, and vDSP finds the
            // loudest sample in each piece.
            var start = 0
            while start < frames {
                let bucket = min(count - 1, Int(Double(position + Int64(start)) / total * Double(count)))
                let bucketEnd = Int64((Double(bucket + 1) / Double(count) * total).rounded(.up))
                let end = min(frames, max(start + 1, Int(bucketEnd - position)))
                for channel in 0..<Int(format.channelCount) {
                    var loudest: Float = 0
                    vDSP_maxmgv(channels[channel] + start, 1, &loudest, vDSP_Length(end - start))
                    peaks[bucket] = max(peaks[bucket], loudest)
                }
                start = end
            }
            position += Int64(frames)
        }
        return peaks
    }

    // MARK: - Auditioning

    /// Plays an audio asset from `fraction` of the way through. The first
    /// call for an asset loads it (downloading its preview if need be).
    func audition(_ asset: Asset, from fraction: Double) async {
        guard let library else { return }
        if auditioning != asset.id {
            auditioning = asset.id
            guard let url = await Self.localOrPreview(asset, library: library), auditioning == asset.id else { return }
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            auditionDuration = (try? await item.asset.load(.duration).seconds) ?? asset.duration ?? 0
            guard auditioning == asset.id else { return }
        }
        let time = WaveformStrip.time(atFraction: fraction, duration: auditionDuration)
        await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        guard auditioning == asset.id else { return }
        player.play()
    }

    func stopAudition() {
        player.pause()
        auditioning = nil
    }

    /// How far through the auditioned asset the player is, 0 to 1.
    func auditionProgress(of asset: Asset) -> Double? {
        guard auditioning == asset.id, auditionDuration > 0, player.rate != 0 else { return nil }
        return min(1, max(0, player.currentTime().seconds / auditionDuration))
    }
}

/// A non-Sendable reference that's safe to read from any thread (image
/// sources and generators are), carried into background work.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
