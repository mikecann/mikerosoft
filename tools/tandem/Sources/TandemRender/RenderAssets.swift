import CoreMedia
import Foundation
import TandemCore
import TandemMedia

/// What the renderer needs from background analysis: proxies, cutout
/// mattes, isolated voice and measured loudness. `MediaAnalysis` provides
/// all of it; tests and tools can supply files directly. Every method may
/// return nil (not analysed yet), and rendering degrades gracefully: no
/// proxy means the original, no matte means no cutout, no isolated voice
/// means the original sound, no loudness means no normalisation.
public protocol RenderAssets: Sendable {
    func proxyURL(for item: MediaItem) -> URL?
    func matteURL(for item: MediaItem) -> URL?
    func isolatedVoiceURL(for item: MediaItem) -> URL?
    func loudness(for item: MediaItem) -> Loudness?
}

extension MediaAnalysis: RenderAssets {}

extension Time {
    /// Flicks fit a `CMTimeScale` exactly, so conversions are lossless.
    static let cmTimescale = CMTimeScale(Time.flicksPerSecond)

    var cmTime: CMTime { CMTime(value: flicks, timescale: Time.cmTimescale) }

    init(cmTime: CMTime) {
        guard cmTime.isNumeric else {
            self.init(flicks: 0)
            return
        }
        let converted = CMTimeConvertScale(cmTime, timescale: Time.cmTimescale, method: .roundHalfAwayFromZero)
        self.init(flicks: converted.value)
    }
}

extension TimeRange {
    var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }
}
