import AppKit
import TandemCore
import TandemMedia

/// Thumbnails and waveforms from the media module's analysis cache, loaded
/// once and kept in memory. Everything returns nil until the analysis for a
/// file exists, and the timeline draws placeholders until then.
@MainActor
final class MediaArtwork {
    private let analysis: MediaAnalysis
    private let images = NSCache<NSString, NSImage>()
    private var strips: [String: (strip: ThumbnailStrip, folder: URL)] = [:]
    private var waveforms: [String: Waveform] = [:]
    private var misses: [String: Date] = [:]

    init(analysis: MediaAnalysis) {
        self.analysis = analysis
        images.countLimit = 600
    }

    /// Forgets cached lookups so new analysis results get picked up.
    func invalidate() {
        strips.removeAll()
        waveforms.removeAll()
        misses.removeAll()
    }

    private func recentlyMissed(_ key: String) -> Bool {
        guard let date = misses[key] else { return false }
        return Date().timeIntervalSince(date) < 5
    }

    func thumbnailStrip(for item: MediaItem) -> (strip: ThumbnailStrip, folder: URL)? {
        let key = "thumbs:" + item.id
        if let strip = strips[key] { return strip }
        guard !recentlyMissed(key) else { return nil }
        guard let found = analysis.thumbnails(for: item), !found.strip.files.isEmpty else {
            misses[key] = Date()
            return nil
        }
        strips[key] = found
        return found
    }

    /// The thumbnail nearest `mediaTime`, loaded lazily.
    func thumbnail(for item: MediaItem, at mediaTime: Time) -> NSImage? {
        guard let (strip, folder) = thumbnailStrip(for: item) else { return nil }
        let index = min(max(Int((mediaTime.seconds / max(strip.interval, 0.001)).rounded(.down)), 0), strip.files.count - 1)
        let path = folder.appendingPathComponent(strip.files[index]).path
        if let image = images.object(forKey: path as NSString) { return image }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        images.setObject(image, forKey: path as NSString)
        return image
    }

    func waveform(for item: MediaItem) -> Waveform? {
        let key = "wave:" + item.id
        if let waveform = waveforms[key] { return waveform }
        guard !recentlyMissed(key) else { return nil }
        guard let waveform = analysis.waveform(for: item), !waveform.peaks.isEmpty else {
            misses[key] = Date()
            return nil
        }
        waveforms[key] = waveform
        return waveform
    }

    func transcript(for item: MediaItem) -> Transcript? {
        analysis.transcript(for: item)
    }
}
