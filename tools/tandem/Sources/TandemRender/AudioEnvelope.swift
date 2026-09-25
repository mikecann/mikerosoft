import Foundation
import TandemCore

/// Turns an audio clip's gain, fades, keyframes and transitions into volume
/// breakpoints. AVAudioMix ramps volume linearly between breakpoints, so
/// curved shapes (equal-power fades, dB keyframes) are sampled finely
/// enough to sound smooth.
enum AudioEnvelope {
    struct Shape {
        var clip: Clip
        /// The segment's timeline range, including transition handles.
        var segment: TimeRange
        /// A transition playing at the clip's head: a crossfade from the clip
        /// before, or a fade in from silence.
        var headWindow: TimeRange?
        /// A transition playing at the clip's tail.
        var tailWindow: TimeRange?
        var microFadeIn: Bool
        var microFadeOut: Bool
    }

    /// Anything at or below this is silence (Filmora mutes with -100 dB).
    static let silenceDB = -96.0

    static func gain(dB: Double) -> Double {
        dB <= silenceDB ? 0 : pow(10, dB / 20)
    }

    /// Equal-power curve: 0 at 0, 1 at 1, and 0.707 in the middle so a
    /// crossfade between unrelated sounds keeps a steady level.
    static func equalPower(_ p: Double) -> Double {
        sin(Double.pi / 2 * min(max(p, 0), 1))
    }

    static func points(_ shape: Shape, constantGain: Double) -> [GainPoint] {
        let clip = shape.clip
        let audio = clip.audio ?? AudioProperties()
        let segment = shape.segment
        guard segment.duration > .zero else { return [] }

        var times = Set<Time>([segment.start, segment.end])
        func add(_ t: Time) {
            if t >= segment.start && t <= segment.end { times.insert(t) }
        }
        func subdivide(_ range: TimeRange, pieces: Int) {
            guard range.duration > .zero, pieces > 0 else { return }
            for i in 0...pieces {
                add(range.start + Time(flicks: range.duration.flicks * Int64(i) / Int64(pieces)))
            }
        }

        // Gain keyframes: dB is curved in amplitude, and eased segments are
        // curved in dB, so sample every 50 ms or so.
        if let keyframes = clip.keyframes["audio.gainDB"], !keyframes.isEmpty {
            let stamps = keyframes.map { clip.start + $0.time }.sorted()
            for t in stamps { add(t) }
            for (a, b) in zip(stamps, stamps.dropFirst()) {
                let span = TimeRange(start: a, end: b)
                subdivide(span, pieces: min(max(Int((span.duration.seconds / 0.05).rounded(.up)), 1), 24))
            }
        }
        if audio.fadeIn > .zero {
            subdivide(TimeRange(start: clip.start, duration: audio.fadeIn), pieces: 8)
        }
        if audio.fadeOut > .zero {
            subdivide(TimeRange(start: clip.end - audio.fadeOut, end: clip.end), pieces: 8)
        }
        if let w = shape.headWindow { subdivide(w, pieces: 8) }
        if let w = shape.tailWindow { subdivide(w, pieces: 8) }
        if shape.microFadeIn {
            add(clip.start)
            add(clip.start + RenderPlanner.microFade)
        }
        if shape.microFadeOut {
            add(clip.end - RenderPlanner.microFade)
            add(clip.end)
        }

        let sorted = times.sorted()
        var result: [GainPoint] = sorted.map { t in
            GainPoint(time: t, gain: constantGain * value(shape, audio: audio, at: t))
        }
        // Drop points in the middle of flat stretches.
        var i = 1
        while i + 1 < result.count {
            if result[i - 1].gain == result[i].gain && result[i].gain == result[i + 1].gain {
                result.remove(at: i)
            } else {
                i += 1
            }
        }
        return result
    }

    /// The clip's gain at a timeline time, before the constant factors.
    static func value(_ shape: Shape, audio: AudioProperties, at t: Time) -> Double {
        let clip = shape.clip
        var g = gain(dB: clip.resolvedAudio(at: t - clip.start).gainDB)
        if audio.fadeIn > .zero {
            g *= equalPower((t - clip.start).seconds / audio.fadeIn.seconds)
        }
        if audio.fadeOut > .zero {
            g *= equalPower((clip.end - t).seconds / audio.fadeOut.seconds)
        }
        if let w = shape.headWindow {
            g *= equalPower((t - w.start).seconds / w.duration.seconds)
        }
        if let w = shape.tailWindow {
            g *= equalPower((w.end - t).seconds / w.duration.seconds)
        }
        let micro = RenderPlanner.microFade.seconds
        if shape.microFadeIn {
            g *= min(max((t - clip.start).seconds / micro, 0), 1)
        }
        if shape.microFadeOut {
            g *= min(max((clip.end - t).seconds / micro, 0), 1)
        }
        return g
    }
}
