import CoreGraphics
import Foundation
import TandemCore

/// Maps timeline time to horizontal pixels and back.
///
/// `x` is measured from the left edge of the lanes (after the track
/// headers), so `x(scrollSeconds) == 0`. Zooming keeps the time under a
/// chosen anchor still, the way Premiere zooms around the playhead or the
/// mouse.
struct TimelineScale: Equatable {
    /// Most zoomed out: about two hours across a laptop screen.
    static let minimumPixelsPerSecond = 0.15
    /// Most zoomed in: a 30 fps frame is about 100 pixels wide.
    static let maximumPixelsPerSecond = 3_000.0

    var pixelsPerSecond: Double {
        didSet { pixelsPerSecond = Self.clampZoom(pixelsPerSecond) }
    }
    /// The time at the left edge of the lanes.
    var scrollSeconds: Double {
        didSet { scrollSeconds = max(0, scrollSeconds) }
    }

    init(pixelsPerSecond: Double = 20, scrollSeconds: Double = 0) {
        self.pixelsPerSecond = Self.clampZoom(pixelsPerSecond)
        self.scrollSeconds = max(0, scrollSeconds)
    }

    static func clampZoom(_ value: Double) -> Double {
        min(max(value, minimumPixelsPerSecond), maximumPixelsPerSecond)
    }

    func x(_ time: Time) -> CGFloat {
        x(seconds: time.seconds)
    }

    func x(seconds: Double) -> CGFloat {
        CGFloat((seconds - scrollSeconds) * pixelsPerSecond)
    }

    func seconds(atX x: CGFloat) -> Double {
        scrollSeconds + Double(x) / pixelsPerSecond
    }

    /// The time under `x`, rounded to the nearest frame and never below 0.
    func time(atX x: CGFloat, rate: FrameRate) -> Time {
        max(.zero, Time(seconds: seconds(atX: x)).roundedToFrame(rate))
    }

    /// A pixel distance as a duration, for snapping tolerances and drags.
    func duration(forPixels pixels: CGFloat) -> Time {
        Time(seconds: Double(pixels) / pixelsPerSecond)
    }

    func width(of duration: Time) -> CGFloat {
        CGFloat(duration.seconds * pixelsPerSecond)
    }

    /// Zooms by `factor` keeping the time under `anchorX` where it is.
    mutating func zoom(by factor: Double, anchorX: CGFloat) {
        let anchor = seconds(atX: anchorX)
        pixelsPerSecond = pixelsPerSecond * factor
        scrollSeconds = anchor - Double(anchorX) / pixelsPerSecond
    }

    /// Fits `duration` into `width` pixels with a little room at the end.
    static func fitting(_ duration: Time, width: CGFloat) -> TimelineScale {
        let seconds = max(duration.seconds, 1)
        let usable = max(Double(width) - 24, 40)
        return TimelineScale(pixelsPerSecond: usable / seconds, scrollSeconds: 0)
    }

    /// Scrolls just enough to bring `time` into view with a margin.
    mutating func reveal(_ time: Time, width: CGFloat, margin: CGFloat = 40) {
        let position = x(time)
        if position < margin {
            scrollSeconds = time.seconds - Double(margin) / pixelsPerSecond
        } else if position > width - margin {
            scrollSeconds = time.seconds - Double(width - margin) / pixelsPerSecond
        }
    }

    /// Ruler label spacing: the smallest step (in seconds) that leaves at
    /// least `minimumGap` pixels between labels, from a list that reads well
    /// in minutes and seconds.
    func rulerStep(minimumGap: CGFloat = 90, rate: FrameRate = .fps30) -> Double {
        let frame = 1 / rate.framesPerSecond
        let steps: [Double] = [frame, frame * 2, frame * 5, frame * 10, 0.5, 1, 2, 5, 10, 15, 20, 30, 60, 120, 300, 600, 900, 1_800, 3_600]
        for step in steps where CGFloat(step * pixelsPerSecond) >= minimumGap {
            return step
        }
        return steps.last!
    }
}

/// Timecode strings in the design's style: `05:26:04` is 5 minutes, 26
/// seconds and frame 4. Past an hour it becomes `1:05:26:04`.
enum Timecode {
    static func string(_ time: Time, rate: FrameRate) -> String {
        let frame = max(Int64(0), time.frameIndex(at: rate))
        let fps = Int64(max(1, rate.framesPerSecond.rounded()))
        let frames = frame % fps
        let totalSeconds = frame / fps
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3_600
        if hours > 0 {
            return String(format: "%lld:%02lld:%02lld:%02lld", hours, minutes, seconds, frames)
        }
        return String(format: "%02lld:%02lld:%02lld", minutes, seconds, frames)
    }

    /// `05:20` for ruler labels, or `05:20:15` when the step is below a second.
    static func rulerLabel(_ seconds: Double, step: Double, rate: FrameRate) -> String {
        if step < 1 {
            return string(Time(seconds: seconds), rate: rate)
        }
        return clock(seconds)
    }

    /// `m:ss` or `h:mm:ss` without frames, for durations in lists.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3_600
        let m = (total / 60) % 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// Short durations for lists: `0:05`, `2:04`, `1:02:03`.
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3_600
        let m = (total / 60) % 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Parses `mm:ss:ff`, `h:mm:ss:ff`, `mm:ss` or plain seconds.
    static func parse(_ text: String, rate: FrameRate) -> Time? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed) { return Time(seconds: seconds) }
        let parts = trimmed.split(separator: ":").map(String.init)
        guard (2...4).contains(parts.count), parts.allSatisfy({ Int($0) != nil }) else { return nil }
        let numbers = parts.compactMap { Int64($0) }
        let fps = Int64(max(1, rate.framesPerSecond.rounded()))
        var frames: Int64 = 0
        switch numbers.count {
        case 2: frames = (numbers[0] * 60 + numbers[1]) * fps
        case 3: frames = (numbers[0] * 60 + numbers[1]) * fps + numbers[2]
        default: frames = ((numbers[0] * 60 + numbers[1]) * 60 + numbers[2]) * fps + numbers[3]
        }
        return Time.frames(frames, at: rate)
    }
}
