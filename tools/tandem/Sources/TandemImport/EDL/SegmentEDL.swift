import Foundation

/// The JSON EDL agents cut decision-models with: a list of segments of one
/// long take, each shown as the full camera (`cam`) or as the screen with
/// the camera in the corner (`screen`).
///
/// Times are seconds on the take's own clock (the recording sessions laid
/// end to end), not timeline times. The timeline is the segments played
/// one after another.
///
/// ```json
/// {"segments": [{"start": 24.05, "end": 26.15, "layout": "cam"},
///               {"start": 1188.1, "end": 1195.6, "layout": "cam", "broll": [[1193.7, 3.0]]}],
///  "overlays": [{"tl": 2, "dur": 4, "screen_at": 40}]}
/// ```
public struct SegmentEDL: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, Sendable {
        /// The camera fills the frame.
        case cam
        /// The screen recording fills the frame with the camera as a
        /// cut-out picture in picture.
        case screen
    }

    public struct Segment: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var layout: Layout
        /// Seconds to shift the screen recording against the camera, for a
        /// screen that was out of step with the voice.
        public var screenOffset: Double?
        /// Screen shown full frame over this segment while the voice keeps
        /// going, as (take time, duration) pairs.
        public var broll: [[Double]]?

        public init(start: Double, end: Double, layout: Layout, screenOffset: Double? = nil, broll: [[Double]]? = nil) {
            self.start = start
            self.end = end
            self.layout = layout
            self.screenOffset = screenOffset
            self.broll = broll
        }

        enum CodingKeys: String, CodingKey {
            case start, end, layout, broll
            case screenOffset = "screen_offset"
        }
    }

    /// Screen shown full frame at a point on the EDL's own timeline (the
    /// segments laid end to end), from take time `screenAt`.
    public struct Overlay: Codable, Equatable, Sendable {
        public var timeline: Double
        public var duration: Double
        public var screenAt: Double

        public init(timeline: Double, duration: Double, screenAt: Double) {
            self.timeline = timeline
            self.duration = duration
            self.screenAt = screenAt
        }

        enum CodingKeys: String, CodingKey {
            case timeline = "tl"
            case duration = "dur"
            case screenAt = "screen_at"
        }
    }

    public var segments: [Segment]
    public var overlays: [Overlay]?

    public init(segments: [Segment], overlays: [Overlay]? = nil) {
        self.segments = segments
        self.overlays = overlays
    }

    public static func load(from url: URL) throws -> SegmentEDL {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadable(url.path)
        }
        do {
            return try JSONDecoder().decode(SegmentEDL.self, from: data)
        } catch {
            throw ImportError.invalid("\(url.lastPathComponent) isn't a segment EDL: \(error)")
        }
    }
}
