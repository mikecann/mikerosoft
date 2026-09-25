import Foundation
import TandemCore

/// A keyframe as the timeline and inspector point at it: a clip, a
/// clip-relative time, and the parameters that have a keyframe there.
struct KeyframeRef: Equatable {
    var clipID: String
    var time: Time
    var parameters: [String]
}

/// Keyframe editing for the timeline, the inspector and the viewer. Every
/// change is a `setKeyframes` command (plus, when a parameter stops
/// animating, a patch that keeps the value it ended on), so it goes
/// through the coordinator like any other edit and undoes in one step.
///
/// Times here are relative to the clip start, as keyframes store them,
/// unless a function says otherwise.
enum KeyframeEdits {
    /// Transform parameters, which Option-K keys together on a clip that
    /// isn't animated yet.
    static let startParameters = ["video.transform.position", "video.transform.scale"]

    /// Keyframes within half a frame of a time count as at it.
    static func tolerance(_ rate: FrameRate) -> Time {
        Time(flicks: max(1, Time.frames(1, at: rate).flicks / 2))
    }

    // MARK: - Reading

    static func isAnimated(_ parameter: String, in clip: Clip) -> Bool {
        !(clip.keyframes[parameter] ?? []).isEmpty
    }

    /// A parameter's value at a clip-relative time, with keyframes applied.
    static func value(of parameter: String, in clip: Clip, at time: Time, registry: EffectRegistry = .standard) -> ParamValue? {
        if parameter.hasPrefix("audio.") {
            let audio = clip.resolvedAudio(at: time)
            if parameter == "audio.gainDB" { return .number(audio.gainDB) }
            return effectValue(parameter, effects: audio.effects, registry: registry)
        }
        let video = clip.resolvedVideo(at: time)
        switch parameter {
        case "video.transform.position": return .point(video.transform.position)
        case "video.transform.scale": return .number(video.transform.scale)
        case "video.transform.rotation": return .number(video.transform.rotation)
        case "video.opacity": return .number(video.opacity)
        case "video.crop.left": return .number(video.crop.left)
        case "video.crop.top": return .number(video.crop.top)
        case "video.crop.right": return .number(video.crop.right)
        case "video.crop.bottom": return .number(video.crop.bottom)
        default: return effectValue(parameter, effects: video.effects, registry: registry)
        }
    }

    private static func effectValue(_ parameter: String, effects: [Effect], registry: EffectRegistry) -> ParamValue? {
        guard let (effectID, key) = effectParameter(parameter), let effect = effects.first(where: { $0.id == effectID }) else { return nil }
        return registry.definition(effect.type)?.resolvedParams(effect)[key] ?? effect.params[key]
    }

    /// `video.effects.<id>.<param>` split into the effect and the parameter.
    static func effectParameter(_ parameter: String) -> (effectID: String, key: String)? {
        let parts = parameter.split(separator: ".", maxSplits: 3).map(String.init)
        guard parts.count == 4, parts[1] == "effects" else { return nil }
        return (parts[2], parts[3])
    }

    /// The clip-relative times that have a keyframe, sorted, with times
    /// within the tolerance counted once.
    static func times(in clip: Clip, parameters: [String]? = nil, tolerance: Time) -> [Time] {
        let lists = clip.keyframes.filter { parameters?.contains($0.key) ?? true }.values
        var result: [Time] = []
        for time in lists.flatMap({ $0.map(\.time) }).sorted() {
            if let last = result.last, abs((time - last).flicks) <= tolerance.flicks { continue }
            result.append(time)
        }
        return result
    }

    /// The parameters with a keyframe at a time, in a stable order.
    static func parameters(in clip: Clip, keyedAt time: Time, tolerance: Time, among parameters: [String]? = nil) -> [String] {
        clip.keyframes.keys.sorted(by: order).filter { key in
            (parameters?.contains(key) ?? true) && (clip.keyframes[key] ?? []).contains { near($0.time, time, tolerance) }
        }
    }

    /// The easing of the keyframes at a time, when there are any.
    static func easing(in clip: Clip, at time: Time, tolerance: Time) -> Interpolation? {
        for key in clip.keyframes.keys.sorted(by: order) {
            if let keyframe = clip.keyframes[key]?.first(where: { near($0.time, time, tolerance) }) { return keyframe.interpolation }
        }
        return nil
    }

    /// The first keyframe after a timeline time, in timeline time.
    static func next(after time: Time, in clip: Clip, tolerance: Time) -> Time? {
        times(in: clip, tolerance: tolerance).map { clip.start + $0 }.first { $0 - time > tolerance }
    }

    /// The last keyframe before a timeline time, in timeline time.
    static func previous(before time: Time, in clip: Clip, tolerance: Time) -> Time? {
        times(in: clip, tolerance: tolerance).map { clip.start + $0 }.last { time - $0 > tolerance }
    }

    private static func near(_ a: Time, _ b: Time, _ tolerance: Time) -> Bool {
        abs((a - b).flicks) <= tolerance.flicks
    }

    // MARK: - Names

    /// "Scale", "Crop left", "Gain", "Vignette amount".
    static func name(of parameter: String, in clip: Clip? = nil, registry: EffectRegistry = .standard) -> String {
        switch parameter {
        case "video.transform.position": return "Position"
        case "video.transform.scale": return "Scale"
        case "video.transform.rotation": return "Rotation"
        case "video.opacity": return "Opacity"
        case "video.crop.left": return "Crop left"
        case "video.crop.top": return "Crop top"
        case "video.crop.right": return "Crop right"
        case "video.crop.bottom": return "Crop bottom"
        case "audio.gainDB": return "Gain"
        default:
            guard let (effectID, key) = effectParameter(parameter) else { return parameter }
            let effects = (clip?.video?.effects ?? []) + (clip?.audio?.effects ?? [])
            guard let effect = effects.first(where: { $0.id == effectID }), let definition = registry.definition(effect.type) else { return key }
            let param = definition.param(key)?.name ?? key
            return "\(definition.name) \(param.lowercased())"
        }
    }

    /// "Position and scale", "Position, scale and opacity".
    static func summary(of parameters: [String], in clip: Clip? = nil) -> String {
        let names = parameters.sorted(by: order).map { name(of: $0, in: clip) }
        guard let first = names.first else { return "" }
        let rest = names.dropFirst().map { $0.prefix(1).lowercased() + $0.dropFirst() }
        switch rest.count {
        case 0: return first
        case 1: return "\(first) and \(rest[0])"
        default: return ([first] + rest.dropLast()).joined(separator: ", ") + " and " + rest.last!
        }
    }

    /// The inspector's order: transform, opacity, crop, gain, then effects.
    static func order(_ a: String, _ b: String) -> Bool {
        let fixed = AnimatableParameter.fixed
        switch (fixed.firstIndex(of: a), fixed.firstIndex(of: b)) {
        case let (x?, y?): return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return a < b
        }
    }

    // MARK: - Commands

    /// Gives an animated parameter a value at a time: the keyframe there
    /// changes (keeping its easing), or a new one goes in. Nil when the
    /// parameter isn't animated, so the caller patches the plain value.
    static func setValue(_ value: ParamValue, for parameter: String, in clip: Clip, at time: Time, tolerance: Time) -> EditCommand? {
        guard var keyframes = clip.keyframes[parameter], !keyframes.isEmpty else { return nil }
        let time = clamp(time, clip)
        if let index = keyframes.firstIndex(where: { near($0.time, time, tolerance) }) {
            keyframes[index].value = value
        } else {
            keyframes.append(Keyframe(time: time, value: value))
        }
        return .setKeyframes(clipID: clip.id, parameter: parameter, keyframes: keyframes.sorted { $0.time < $1.time })
    }

    /// A keyframe at a time holding the value the parameter has there, so
    /// nothing moves until it's changed. Starts the animation if there
    /// wasn't one. Nil when there's already a keyframe there.
    static func addKeyframe(_ parameter: String, in clip: Clip, at time: Time, tolerance: Time, registry: EffectRegistry = .standard) -> EditCommand? {
        let time = clamp(time, clip)
        var keyframes = clip.keyframes[parameter] ?? []
        guard !keyframes.contains(where: { near($0.time, time, tolerance) }),
              let value = value(of: parameter, in: clip, at: time, registry: registry) else { return nil }
        keyframes.append(Keyframe(time: time, value: value))
        return .setKeyframes(clipID: clip.id, parameter: parameter, keyframes: keyframes.sorted { $0.time < $1.time })
    }

    /// Removes the keyframes at a time. A parameter left with none keeps
    /// the value it had at that keyframe rather than jumping back to its
    /// plain value.
    static func removeKeyframes(in clip: Clip, at time: Time, parameters: [String], tolerance: Time, registry: EffectRegistry = .standard) -> [EditCommand] {
        var commands: [EditCommand] = []
        var kept: [EditCommand] = []
        for parameter in parameters.sorted(by: order) {
            guard let keyframes = clip.keyframes[parameter], let removed = keyframes.first(where: { near($0.time, time, tolerance) }) else { continue }
            let remaining = keyframes.filter { !near($0.time, time, tolerance) }
            commands.append(.setKeyframes(clipID: clip.id, parameter: parameter, keyframes: remaining))
            if remaining.isEmpty, let patch = plainValueCommand(parameter, value: removed.value, in: clip, registry: registry) {
                kept.append(patch)
            }
        }
        return commands + kept
    }

    /// Moves the keyframes at `from` to `to`, kept inside the clip. A
    /// keyframe already at `to` is replaced by the one moved there.
    static func moveKeyframes(in clip: Clip, from: Time, to: Time, parameters: [String], tolerance: Time, value: ParamValue? = nil) -> [EditCommand] {
        let target = clamp(to, clip)
        var commands: [EditCommand] = []
        for parameter in parameters.sorted(by: order) {
            guard let keyframes = clip.keyframes[parameter], var moved = keyframes.first(where: { near($0.time, from, tolerance) }) else { continue }
            guard !near(moved.time, target, Time(flicks: 0)) || value.map({ $0 != moved.value }) == true else { continue }
            moved.time = target
            if let value { moved.value = value }
            var rest = keyframes.filter { !near($0.time, from, tolerance) && !near($0.time, target, tolerance) }
            rest.append(moved)
            commands.append(.setKeyframes(clipID: clip.id, parameter: parameter, keyframes: rest.sorted { $0.time < $1.time }))
        }
        return commands
    }

    /// Changes how the values move on from the keyframes at a time.
    static func setEasing(_ interpolation: Interpolation, in clip: Clip, at time: Time, parameters: [String], tolerance: Time) -> [EditCommand] {
        var commands: [EditCommand] = []
        for parameter in parameters.sorted(by: order) {
            guard var keyframes = clip.keyframes[parameter], keyframes.contains(where: { near($0.time, time, tolerance) && $0.interpolation != interpolation }) else { continue }
            for index in keyframes.indices where near(keyframes[index].time, time, tolerance) {
                keyframes[index].interpolation = interpolation
            }
            commands.append(.setKeyframes(clipID: clip.id, parameter: parameter, keyframes: keyframes))
        }
        return commands
    }

    /// Option-K: removes the keyframes at the time if there are any, else
    /// keys every animated parameter there, else starts animating position
    /// and scale (or gain on a sound clip).
    static func toggle(in clip: Clip, at time: Time, trackKind: TrackKind, tolerance: Time) -> EditBatch? {
        let time = clamp(time, clip)
        let here = parameters(in: clip, keyedAt: time, tolerance: tolerance)
        if !here.isEmpty {
            return EditBatch(label: "Remove keyframe", commands: removeKeyframes(in: clip, at: time, parameters: here, tolerance: tolerance))
        }
        let domain = trackKind == .audio ? "audio." : "video."
        let animated = clip.keyframes.keys.filter { $0.hasPrefix(domain) }.sorted(by: order)
        let parameters = animated.isEmpty ? (trackKind == .audio ? ["audio.gainDB"] : startParameters) : animated
        let commands = parameters.compactMap { addKeyframe($0, in: clip, at: time, tolerance: tolerance) }
        guard !commands.isEmpty else { return nil }
        return EditBatch(label: "Add keyframe", commands: commands + layoutCleared(for: parameters, in: clip))
    }

    /// Clears the layout preset name once position or scale animate: the
    /// clip no longer sits where "PiP right" says.
    static func layoutCleared(for parameters: [String], in clip: Clip) -> [EditCommand] {
        guard clip.video?.layoutPreset != nil, parameters.contains(where: { $0.hasPrefix("video.transform.") }) else { return [] }
        return [.updateClip(clipID: clip.id, patch: .object(["video": .object(["layoutPreset": .null])]))]
    }

    /// The patch that sets a parameter's plain (unanimated) value.
    static func plainValueCommand(_ parameter: String, value: ParamValue, in clip: Clip, registry: EffectRegistry = .standard) -> EditCommand? {
        if let (effectID, key) = effectParameter(parameter) {
            return .updateEffect(clipID: clip.id, effectID: effectID, patch: .object(["params": .object([key: value.json])]))
        }
        let path = parameter.split(separator: ".").map(String.init)
        guard path.count >= 2, AnimatableParameter.fixed.contains(parameter) else { return nil }
        var patch: JSONValue = value.json
        for key in path.reversed() { patch = .object([key: patch]) }
        return .updateClip(clipID: clip.id, patch: patch)
    }

    /// Keyframes live inside the clip.
    private static func clamp(_ time: Time, _ clip: Clip) -> Time {
        min(max(time, .zero), clip.duration)
    }
}
