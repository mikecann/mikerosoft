import Foundation

// Keyframe evaluation. Keyframe times are relative to the clip start, and a
// segment eases with the interpolation of the keyframe it starts from.
//
// Animatable parameter paths:
//   video.transform.position   point
//   video.transform.scale      number
//   video.transform.rotation   number (degrees)
//   video.opacity              number 0...1
//   video.crop.left/top/right/bottom
//   video.effects.<effectID>.<param>
//   audio.gainDB               number
//   audio.effects.<effectID>.<param>

public enum AnimatableParameter {
    public static let fixed: [String] = [
        "video.transform.position",
        "video.transform.scale",
        "video.transform.rotation",
        "video.opacity",
        "video.crop.left",
        "video.crop.top",
        "video.crop.right",
        "video.crop.bottom",
        "audio.gainDB"
    ]

    public static func isKnown(_ path: String) -> Bool {
        fixed.contains(path) || path.hasPrefix("video.effects.") || path.hasPrefix("audio.effects.")
    }
}

public enum Easing {
    /// Maps linear progress 0...1 to eased progress.
    public static func apply(_ interpolation: Interpolation, _ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch interpolation {
        case .linear: return t
        case .hold: return 0
        case .easeIn: return t * t * t
        case .easeOut:
            let u = 1 - t
            return 1 - u * u * u
        case .easeInOut:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
    }
}

extension ParamValue {
    /// Blends two values. Numbers, points and colours interpolate; bools and
    /// strings hold the first value until the second keyframe.
    public static func interpolate(_ a: ParamValue, _ b: ParamValue, _ t: Double) -> ParamValue {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return .number(x + (y - x) * t)
        case (.point(let p), .point(let q)):
            return .point(Point(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
        case (.color(let c), .color(let d)):
            return .color(RGBA(
                r: c.r + (d.r - c.r) * t,
                g: c.g + (d.g - c.g) * t,
                b: c.b + (d.b - c.b) * t,
                a: c.a + (d.a - c.a) * t
            ))
        default:
            return t < 1 ? a : b
        }
    }
}

extension Array where Element == Keyframe {
    /// The animated value at a clip-relative time. Before the first keyframe
    /// it holds the first value, after the last it holds the last.
    public func value(at time: Time) -> ParamValue? {
        guard let first = first else { return nil }
        let sorted = self.sorted { $0.time < $1.time }
        if time <= first.time || sorted.count == 1 { return sorted[0].value }
        guard let last = sorted.last, time < last.time else { return sorted.last?.value }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            if time >= a.time && time < b.time {
                let span = Double((b.time - a.time).flicks)
                let linear = span > 0 ? Double((time - a.time).flicks) / span : 1
                return ParamValue.interpolate(a.value, b.value, Easing.apply(a.interpolation, linear))
            }
        }
        return sorted.last?.value
    }
}

enum KeyframeEditing {
    static func shifted(_ keyframes: [String: [Keyframe]], by delta: Time) -> [String: [Keyframe]] {
        guard delta != .zero else { return keyframes }
        return keyframes.mapValues { list in
            list.map { var k = $0; k.time += delta; return k }
        }
    }

    static func scaled(_ keyframes: [String: [Keyframe]], by factor: Double) -> [String: [Keyframe]] {
        keyframes.mapValues { list in
            list.map { var k = $0; k.time = k.time.scaled(by: factor); return k }
        }
    }

    /// Drops keyframes that can't affect `0...duration`, keeping the nearest
    /// one on each side so the curve inside the clip is unchanged.
    static func pruned(_ keyframes: [String: [Keyframe]], duration: Time) -> [String: [Keyframe]] {
        var result: [String: [Keyframe]] = [:]
        for (path, list) in keyframes {
            let sorted = list.sorted { $0.time < $1.time }
            let before = sorted.last { $0.time < .zero }
            let after = sorted.first { $0.time > duration }
            var kept = sorted.filter { $0.time >= .zero && $0.time <= duration }
            if let before { kept.insert(before, at: 0) }
            if let after { kept.append(after) }
            if !kept.isEmpty { result[path] = kept }
        }
        return result
    }
}

extension Clip {
    /// Video properties at a time inside the clip (relative to its start)
    /// with keyframes applied. Clips without video properties get defaults.
    public func resolvedVideo(at clipTime: Time) -> VideoProperties {
        var video = self.video ?? VideoProperties()
        for (path, list) in keyframes where path.hasPrefix("video.") {
            guard let value = list.value(at: clipTime) else { continue }
            switch path {
            case "video.transform.position":
                if case .point(let p) = value { video.transform.position = p }
            case "video.transform.scale":
                if let n = value.number { video.transform.scale = n }
            case "video.transform.rotation":
                if let n = value.number { video.transform.rotation = n }
            case "video.opacity":
                if let n = value.number { video.opacity = n }
            case "video.crop.left":
                if let n = value.number { video.crop.left = n }
            case "video.crop.top":
                if let n = value.number { video.crop.top = n }
            case "video.crop.right":
                if let n = value.number { video.crop.right = n }
            case "video.crop.bottom":
                if let n = value.number { video.crop.bottom = n }
            default:
                let parts = path.split(separator: ".", maxSplits: 3).map(String.init)
                if parts.count == 4, parts[1] == "effects",
                   let index = video.effects.firstIndex(where: { $0.id == parts[2] }) {
                    video.effects[index].params[parts[3]] = value
                }
            }
        }
        return video
    }

    /// Audio properties at a clip-relative time with keyframes applied.
    public func resolvedAudio(at clipTime: Time) -> AudioProperties {
        var audio = self.audio ?? AudioProperties()
        for (path, list) in keyframes where path.hasPrefix("audio.") {
            guard let value = list.value(at: clipTime) else { continue }
            if path == "audio.gainDB", let n = value.number {
                audio.gainDB = n
                continue
            }
            let parts = path.split(separator: ".", maxSplits: 3).map(String.init)
            if parts.count == 4, parts[1] == "effects",
               let index = audio.effects.firstIndex(where: { $0.id == parts[2] }) {
                audio.effects[index].params[parts[3]] = value
            }
        }
        return audio
    }
}
