import Foundation

/// A point in time or a duration, stored as an integer number of flicks.
///
/// A flick is 1/705,600,000 of a second. That divides evenly into every
/// common frame rate (24, 25, 30, 48, 50, 60) and every common audio sample
/// rate (44.1 kHz, 48 kHz, 96 kHz), so frame and sample boundaries are exact
/// integers and edits never accumulate floating point drift.
///
/// In JSON a `Time` is written as seconds (a number rounded to 6 decimals) so
/// people and agents can read it. Decoding snaps back to the 48 kHz sample
/// grid, which makes the round trip exact for any sample-aligned value.
public struct Time: Hashable, Comparable, Sendable {
    public static let flicksPerSecond: Int64 = 705_600_000
    /// Flicks per sample at the project audio rate (48 kHz).
    public static let flicksPerSample48k: Int64 = 14_700

    public var flicks: Int64

    public init(flicks: Int64) {
        self.flicks = flicks
    }

    public init(seconds: Double) {
        self.flicks = Time.snapToSampleGrid(seconds: seconds)
    }

    public static let zero = Time(flicks: 0)

    public var seconds: Double {
        Double(flicks) / Double(Time.flicksPerSecond)
    }

    /// The whole frame index this time falls in (floor), at `rate`.
    public func frameIndex(at rate: FrameRate) -> Int64 {
        let perFrame = rate.flicksPerFrame
        return flicks >= 0 ? flicks / perFrame : -((-flicks + perFrame - 1) / perFrame)
    }

    /// This time moved to the nearest frame boundary at `rate`.
    public func roundedToFrame(_ rate: FrameRate) -> Time {
        let perFrame = rate.flicksPerFrame
        let half = perFrame / 2
        let adjusted = flicks >= 0 ? (flicks + half) / perFrame : -((-flicks + half) / perFrame)
        return Time(flicks: adjusted * perFrame)
    }

    public static func frames(_ count: Int64, at rate: FrameRate) -> Time {
        Time(flicks: count * rate.flicksPerFrame)
    }

    public static func + (lhs: Time, rhs: Time) -> Time { Time(flicks: lhs.flicks + rhs.flicks) }
    public static func - (lhs: Time, rhs: Time) -> Time { Time(flicks: lhs.flicks - rhs.flicks) }
    public static prefix func - (value: Time) -> Time { Time(flicks: -value.flicks) }
    public static func += (lhs: inout Time, rhs: Time) { lhs.flicks += rhs.flicks }
    public static func -= (lhs: inout Time, rhs: Time) { lhs.flicks -= rhs.flicks }
    public static func < (lhs: Time, rhs: Time) -> Bool { lhs.flicks < rhs.flicks }

    /// Scales a duration, for example by a clip speed. Rounds to the sample grid.
    public func scaled(by factor: Double) -> Time {
        Time(seconds: seconds * factor)
    }

    static func snapToSampleGrid(seconds: Double) -> Int64 {
        let samples = (seconds * 48_000).rounded()
        return Int64(samples) * flicksPerSample48k
    }
}

extension Time: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let seconds = try container.decode(Double.self)
        self.init(seconds: seconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // Six decimals is 1 µs, well inside half a 48 kHz sample (10.4 µs),
        // so decoding always lands back on the same sample.
        let rounded = (seconds * 1_000_000).rounded() / 1_000_000
        try container.encode(rounded)
    }
}

extension Time: CustomStringConvertible {
    /// `mm:ss.mmm`, or `h:mm:ss.mmm` past an hour. Used in logs and the CLI.
    public var description: String {
        let totalMillis = Int64((seconds * 1000).rounded())
        let sign = totalMillis < 0 ? "-" : ""
        let millis = abs(totalMillis)
        let hours = millis / 3_600_000
        let minutes = (millis / 60_000) % 60
        let secs = (millis / 1000) % 60
        let ms = millis % 1000
        if hours > 0 {
            return String(format: "%@%lld:%02lld:%02lld.%03lld", sign, hours, minutes, secs, ms)
        }
        return String(format: "%@%02lld:%02lld.%03lld", sign, minutes, secs, ms)
    }
}

/// A frame rate as an exact fraction, for example 30/1 or 30000/1001.
public struct FrameRate: Codable, Hashable, Sendable {
    public var numerator: Int64
    public var denominator: Int64

    public init(_ numerator: Int64, _ denominator: Int64 = 1) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public static let fps30 = FrameRate(30)
    public static let fps25 = FrameRate(25)
    public static let fps60 = FrameRate(60)

    public var framesPerSecond: Double { Double(numerator) / Double(denominator) }

    /// Flicks per frame. Exact for integer rates. NTSC rates (1001
    /// denominators) round to the nearest flick, which is fine for display
    /// but the project should use an integer rate.
    public var flicksPerFrame: Int64 {
        (Time.flicksPerSecond * denominator + numerator / 2) / numerator
    }

    public var frameDuration: Time { Time(flicks: flicksPerFrame) }
}

/// A half-open range `[start, start + duration)`.
public struct TimeRange: Codable, Hashable, Sendable {
    public var start: Time
    public var duration: Time

    public init(start: Time, duration: Time) {
        self.start = start
        self.duration = duration
    }

    public init(start: Time, end: Time) {
        self.start = start
        self.duration = end - start
    }

    public var end: Time { start + duration }
    public var isEmpty: Bool { duration.flicks <= 0 }

    public func contains(_ time: Time) -> Bool {
        time >= start && time < end
    }

    public func overlaps(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }

    public func intersection(_ other: TimeRange) -> TimeRange? {
        let s = max(start, other.start)
        let e = min(end, other.end)
        return s < e ? TimeRange(start: s, end: e) : nil
    }
}
