import Foundation
import TandemCore

/// Times as people and agents type them: seconds (`83.5`, `83.5s`) or clock
/// form (`1:23.5`, `01:23.500`, `1:02:03.250`). Output uses `Time`'s
/// `mm:ss.mmm` description.
public enum TimeText {
    public static func parse(_ text: String) -> Time? {
        var s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("-") {
            negative = true
            s.removeFirst()
        }
        if s.hasSuffix("s") { s.removeLast() }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber || $0 == "." }), let value = Double(part), value.isFinite else {
                return nil
            }
            let isLast = index == parts.count - 1
            // Only the seconds may have a fraction, and minutes and seconds
            // after the first field stay under 60.
            if !isLast && part.contains(".") { return nil }
            if index > 0 && value >= 60 { return nil }
            total = total * 60 + value
        }
        return Time(seconds: negative ? -total : total)
    }

    /// A duration for reading: `0.450s` under a minute, `01:02.500` above.
    public static func duration(_ time: Time) -> String {
        let seconds = time.seconds
        if abs(seconds) < 60 { return String(format: "%.3fs", seconds) }
        return time.description
    }

    /// A time for file names, with dots instead of colons: `01.23.500`.
    public static func fileSafe(_ time: Time) -> String {
        time.description.replacingOccurrences(of: ":", with: ".")
    }

    /// Rounds up to the next frame boundary (or stays on one).
    static func ceilToFrame(_ time: Time, _ rate: FrameRate) -> Time {
        let perFrame = rate.flicksPerFrame
        let frames = time.flicks >= 0 ? (time.flicks + perFrame - 1) / perFrame : -((-time.flicks) / perFrame)
        return Time(flicks: frames * perFrame)
    }

    /// Rounds down to the previous frame boundary (or stays on one).
    static func floorToFrame(_ time: Time, _ rate: FrameRate) -> Time {
        Time(flicks: time.frameIndex(at: rate) * rate.flicksPerFrame)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a time given as seconds or as a `mm:ss.mmm` string.
    func decodeTime(_ key: Key) throws -> Time? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let seconds = try? decode(Double.self, forKey: key) {
            return Time(seconds: seconds)
        }
        let text = try decode(String.self, forKey: key)
        guard let time = TimeText.parse(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "\"\(text)\" isn't a time. Use seconds (83.5) or mm:ss.mmm (01:23.500)."
            )
        }
        return time
    }

    /// Decodes a number of seconds given as a number or a time string.
    func decodeSeconds(_ key: Key) throws -> Double? {
        try decodeTime(key)?.seconds
    }
}
