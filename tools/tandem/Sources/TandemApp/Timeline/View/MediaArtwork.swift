import AppKit
import ImageIO
import TandemCore
import TandemMedia

/// Thumbnails and waveforms from the media module's analysis cache, loaded
/// once and kept in memory. Everything returns nil until the analysis for a
/// file exists, and the timeline draws placeholders until then.
///
/// Thumbnails are decoded off the main thread, already scaled to the size
/// the timeline draws them, so scrolling a big project only blits small
/// bitmaps. A thumbnail that isn't decoded yet draws as a placeholder and
/// `onDecoded` asks for a redraw when it's ready.
@MainActor
final class MediaArtwork {
    private let analysis: MediaAnalysis
    private let images = NSCache<NSString, CGImage>()
    private var decoding: Set<String> = []
    /// Thumbnails as the timeline draws them: scaled to the pixels they
    /// cover, in the screen's colour space. Drawing the decoded JPEGs made
    /// Core Animation convert every one to the screen's profile and
    /// resample it on every redraw, which at fit zoom was most of a frame.
    private let fitted = NSCache<NSString, CGImage>()
    private var fitting: Set<String> = []
    private var redrawPending = false
    private var strips: [String: (strip: ThumbnailStrip, folder: URL)] = [:]
    /// Each strip's image paths, made once: making them from URLs for
    /// every tile drawn was a tenth of the lanes' drawing time.
    private var stripPaths: [String: [String]] = [:]
    private var waveforms: [String: Waveform] = [:]
    private var transcripts: [String: Transcript] = [:]
    private var misses: [String: Date] = [:]
    /// Called (at most every 50 ms) when decoded thumbnails are ready.
    var onDecoded: (() -> Void)?
    /// Counts thumbnails asked for before they were decoded, so a painter
    /// can tell it drew a placeholder that `onDecoded` will replace.
    private(set) var waits = 0
    /// Big enough for the tallest track on a Retina screen.
    static let thumbnailPixels = 240

    init(analysis: MediaAnalysis) {
        self.analysis = analysis
        images.countLimit = 900
        images.totalCostLimit = 96 * 1024 * 1024
        fitted.countLimit = 1_500
        fitted.totalCostLimit = 64 * 1024 * 1024
    }

    /// Looks again for results that weren't there. Results never change
    /// once made (the cache is keyed by the file's content), so found ones
    /// stay.
    func invalidate() {
        misses.removeAll()
        // A better transcript can replace one (the careful pass).
        transcripts.removeAll()
    }

    private func recentlyMissed(_ key: String) -> Bool {
        guard let date = misses[key] else { return false }
        return Date().timeIntervalSince(date) < 5
    }

    func thumbnailStrip(for item: MediaItem) -> (strip: ThumbnailStrip, folder: URL)? {
        let key = "thumbs:\(item.id):\(item.fingerprint ?? "")"
        if let strip = strips[key] { return strip }
        guard !recentlyMissed(key) else { return nil }
        guard let found = analysis.thumbnails(for: item), !found.strip.files.isEmpty else {
            misses[key] = Date()
            return nil
        }
        strips[key] = found
        return found
    }

    /// The thumbnail nearest `mediaTime`, or nil while it's still being
    /// decoded (or doesn't exist). Given the pixels it will cover and the
    /// colour space it will be drawn in, it comes fitted to them once that
    /// copy is made (off the main thread), and as decoded until then.
    func thumbnail(for item: MediaItem, at mediaTime: Time, pixelSize: CGSize?, colorSpace: CGColorSpace?) -> CGImage? {
        guard let (path, image) = decodedThumbnail(for: item, at: mediaTime), let image else { return nil }
        guard let pixelSize, let colorSpace, pixelSize.width >= 1, pixelSize.height >= 1 else { return image }
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        let key = "\(path)|\(width)x\(height)|\(CFHash(colorSpace))" as NSString
        if let fit = fitted.object(forKey: key) { return fit }
        let name = key as String
        guard fitting.insert(name).inserted else { return image }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fit = Self.fit(image, width: width, height: height, colorSpace: colorSpace)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.fitting.remove(name)
                    if let fit { self.fitted.setObject(fit, forKey: key, cost: fit.bytesPerRow * fit.height) }
                }
            }
        }
        return image
    }

    /// `image` redrawn at `width` by `height` pixels in `colorSpace`.
    nonisolated static func fit(_ image: CGImage, width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The decoded thumbnail nearest `mediaTime`, as `thumbnail(for:at:pixelSize:colorSpace:)`
    /// without the fitting.
    func thumbnail(for item: MediaItem, at mediaTime: Time) -> CGImage? {
        decodedThumbnail(for: item, at: mediaTime)?.image
    }

    /// The path of the thumbnail nearest `mediaTime` and its decoded image,
    /// or nil for the image while it's decoding.
    private func decodedThumbnail(for item: MediaItem, at mediaTime: Time) -> (path: String, image: CGImage?)? {
        guard let (strip, folder) = thumbnailStrip(for: item) else { return nil }
        let key = "thumbs:\(item.id):\(item.fingerprint ?? "")"
        let paths = stripPaths[key] ?? {
            // Saying it's a file keeps Foundation from asking the disk
            // whether it's a folder.
            let made = strip.files.map { folder.appendingPathComponent($0, isDirectory: false).path }
            stripPaths[key] = made
            return made
        }()
        let index = min(max(Int((mediaTime.seconds / max(strip.interval, 0.001)).rounded(.down)), 0), paths.count - 1)
        let path = paths[index]
        if let image = images.object(forKey: path as NSString) { return (path, image) }
        waits += 1
        decode(path)
        return (path, nil)
    }

    private func decode(_ path: String) {
        guard decoding.insert(path).inserted else { return }
        let pixels = Self.thumbnailPixels
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.decodeThumbnail(at: path, maxPixels: pixels)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.decoding.remove(path)
                    guard let image else { return }
                    self.images.setObject(image, forKey: path as NSString, cost: image.bytesPerRow * image.height)
                    self.scheduleRedraw()
                }
            }
        }
    }

    private func scheduleRedraw() {
        guard !redrawPending else { return }
        redrawPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.redrawPending = false
                self?.onDecoded?()
            }
        }
    }

    /// A decoded bitmap no bigger than `maxPixels` on its long side.
    nonisolated static func decodeThumbnail(at path: String, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    func waveform(for item: MediaItem) -> Waveform? {
        let key = "wave:\(item.id):\(item.fingerprint ?? "")"
        if let waveform = waveforms[key] { return waveform }
        guard !recentlyMissed(key) else { return nil }
        guard let waveform = analysis.waveform(for: item), !waveform.peaks.isEmpty else {
            misses[key] = Date()
            return nil
        }
        waveforms[key] = waveform
        return waveform
    }

    /// The take's transcript, read from the analysis cache once: reading
    /// it decodes a file, which a drag's preview did for every frame.
    func transcript(for item: MediaItem) -> Transcript? {
        let key = "words:\(item.id):\(item.fingerprint ?? "")"
        if let transcript = transcripts[key] { return transcript }
        guard !recentlyMissed(key) else { return nil }
        guard let transcript = analysis.transcript(for: item) else {
            misses[key] = Date()
            return nil
        }
        transcripts[key] = transcript
        return transcript
    }
}
