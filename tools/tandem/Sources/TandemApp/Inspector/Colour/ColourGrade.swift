import Foundation
import TandemCore

/// The Colour tab's sections, top to bottom. Each is backed by an effect
/// that's only added once something in the section changes, so an
/// ungraded clip carries no effects. Light and Colour share one
/// `colorAdjust` until one of them needs its own on/off switch.
enum ColourSection: String, CaseIterable, Identifiable, Hashable {
    case light, colour, wheels, mixer, vignette, sharpen, lut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .colour: return "Colour"
        case .wheels: return "Colour wheels"
        case .mixer: return "Colour mixer"
        case .vignette: return "Vignette"
        case .sharpen: return "Sharpen"
        case .lut: return "LUT"
        }
    }

    var effectType: String {
        switch self {
        case .light, .colour: return "colorAdjust"
        case .wheels: return "colorWheels"
        case .mixer: return "hsl"
        case .vignette: return "vignette"
        case .sharpen: return "sharpen"
        case .lut: return "lut"
        }
    }

    /// The parameters the section shows, in order.
    var keys: [String] {
        switch self {
        case .light: return ["exposure", "contrast", "highlights", "shadows", "blackLevel"]
        case .colour: return ["temperature", "tint", "saturation", "vibrance"]
        case .wheels: return ColourWheels.keys
        case .mixer: return Self.mixerColours.flatMap { colour in Self.mixerAspects.map { colour + $0 } }
        case .vignette: return ["amount", "size", "feather"]
        case .sharpen: return ["amount"]
        case .lut: return ["path", "intensity"]
        }
    }

    /// The section that shares this one's effect.
    var partner: ColourSection? {
        switch self {
        case .light: return .colour
        case .colour: return .light
        default: return nil
        }
    }

    /// What a control shows before the section has an effect, and what a
    /// double-click puts back: no change. That's the effect's default,
    /// except that the vignette and sharpen defaults are Mike's usual
    /// amounts, which here start at none.
    func neutral(_ key: String, registry: EffectRegistry = .standard) -> ParamValue {
        switch (self, key) {
        case (.vignette, "amount"), (.sharpen, "amount"): return .number(0)
        default: return registry.definition(effectType)?.param(key)?.defaultValue ?? .number(0)
        }
    }

    // The mixer's eight colours, as the HSL effect names its ranges.
    static let mixerColours = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
    static let mixerAspects = ["Hue", "Saturation", "Luminance"]
    /// Where each range is centred, HSV degrees (see the HSL kernel).
    static let mixerHues: [String: Double] = [
        "red": 0, "orange": 30, "yellow": 60, "green": 120, "aqua": 180, "blue": 240, "purple": 270, "magenta": 300
    ]
}

/// A change the Colour tab makes: the effect list it leads to, plus what
/// the effect list alone can't say for a clip: which values it sets (so
/// animated ones become keyframes at the playhead) and which animations
/// follow a parameter to another effect.
struct ColourChange: Equatable {
    struct SetValue: Equatable {
        var effectID: String
        var key: String
        var value: ParamValue
    }

    struct Move: Equatable {
        var key: String
        var from: String
        /// Nil drops the animation.
        var to: String?
    }

    var effects: [Effect]
    var label: String
    var sets: [SetValue] = []
    var moves: [Move] = []
}

/// The fixed sections over a list of effects (a file's look or a clip's
/// own video effects): which effect backs each section, what it shows,
/// and how a change to a section changes the list.
///
/// Each section is backed by the first effect of its type. Light and
/// Colour both use the first `colorAdjust`, unless there's a second one
/// and the two are cleanly split (the first has no colour values, the
/// second no light ones), which is what turning one of them off makes.
/// Anything else is left for the tab to list as it is (`others`), so
/// nothing is hidden.
struct ColourGrade {
    let effects: [Effect]
    /// Animated parameters by effect ID. They count as set even without a
    /// plain value.
    let animated: [String: Set<String>]
    let registry: EffectRegistry
    /// Index into `effects` of each section's effect.
    let backing: [ColourSection: Int]

    init(_ effects: [Effect], animated: [String: Set<String>] = [:], registry: EffectRegistry = .standard) {
        self.effects = effects
        self.animated = animated
        self.registry = registry
        var backing: [ColourSection: Int] = [:]
        let adjusts = effects.indices.filter { effects[$0].type == "colorAdjust" }
        if let first = adjusts.first {
            backing[.light] = first
            backing[.colour] = first
            if adjusts.count > 1,
               !Self.sets(effects[first], ColourSection.colour.keys, animated),
               !Self.sets(effects[adjusts[1]], ColourSection.light.keys, animated) {
                backing[.colour] = adjusts[1]
            }
        }
        for section in ColourSection.allCases where section.partner == nil {
            if let index = effects.firstIndex(where: { $0.type == section.effectType }) {
                backing[section] = index
            }
        }
        self.backing = backing
    }

    private static func sets(_ effect: Effect, _ keys: [String], _ animated: [String: Set<String>]) -> Bool {
        keys.contains { effect.params[$0] != nil || animated[effect.id]?.contains($0) == true }
    }

    /// A clip's own video effects, with its animated effect parameters.
    init(clip: Clip, registry: EffectRegistry = .standard) {
        var animated: [String: Set<String>] = [:]
        for path in clip.keyframes.keys where !(clip.keyframes[path] ?? []).isEmpty {
            let parts = path.split(separator: ".", maxSplits: 3).map(String.init)
            guard parts.count == 4, parts[0] == "video", parts[1] == "effects" else { continue }
            animated[parts[2], default: []].insert(parts[3])
        }
        self.init(clip.video?.effects ?? [], animated: animated, registry: registry)
    }

    // MARK: - Reading

    func effect(_ section: ColourSection) -> Effect? {
        backing[section].map { effects[$0] }
    }

    /// True when Light and Colour are on the same effect.
    func isShared(_ section: ColourSection) -> Bool {
        guard let partner = section.partner, let index = backing[section] else { return false }
        return backing[partner] == index
    }

    /// A section's values: its effect's (from `shown` when given, which may
    /// be the effects at the playhead), else no change.
    func values(_ section: ColourSection, shown: [Effect]? = nil) -> [String: ParamValue] {
        var values = Dictionary(uniqueKeysWithValues: section.keys.map { ($0, section.neutral($0, registry: registry)) })
        guard let backed = effect(section) else { return values }
        let source = shown?.first { $0.id == backed.id } ?? backed
        let resolved = registry.definition(section.effectType)?.resolvedParams(source) ?? source.params
        for key in section.keys {
            if let value = resolved[key] { values[key] = value }
        }
        return values
    }

    /// Whether a section changes the picture, on or off. A wheel's hue
    /// doesn't count while its amount is 0; an animated value always does.
    func isChanged(_ section: ColourSection, shown: [Effect]? = nil) -> Bool {
        guard let effect = effect(section) else { return false }
        // Animated, it changes somewhere even if not at the playhead.
        if let keys = animated[effect.id], section.keys.contains(where: keys.contains) { return true }
        let values = values(section, shown: shown)
        return section.keys.contains { key in
            if section == .wheels, let wheel = ColourWheels.Wheel.allCases.first(where: { $0.hueKey == key }) {
                return (values[wheel.amountKey]?.number ?? 0) != 0 && values[key] != section.neutral(key, registry: registry)
            }
            return values[key] != section.neutral(key, registry: registry)
        }
    }

    /// Off only when the section's effect is turned off.
    func isOn(_ section: ColourSection) -> Bool {
        effect(section)?.enabled ?? true
    }

    /// The effects no section shows, in order.
    var others: [Effect] {
        let used = Set(backing.values)
        return effects.indices.filter { !used.contains($0) }.map { effects[$0] }
    }

    // MARK: - Changes

    /// Sets values in a section. A section without an effect gets one; one
    /// that's off is turned back on, since a change you can't see is no
    /// use. When Light and Colour share an effect that's off and the other
    /// one has values, this section moves to an effect of its own so the
    /// other stays off.
    func setting(_ section: ColourSection, _ values: [String: ParamValue], label: String, newID: () -> String = { IDs.make("fx") }) -> ColourChange? {
        var list = effects
        var moves: [ColourChange.Move] = []
        let target: Int
        if let index = backing[section] {
            if !effects[index].enabled, isShared(section), let partner = section.partner, isChanged(partner) {
                let split = split(&list, at: index, newID: newID())
                moves = split.moves
                target = section == .colour ? split.colour : index
            } else {
                target = index
            }
            list[target].enabled = true
        } else {
            var effect = Effect(id: newID(), type: section.effectType)
            // Written out where "no change" isn't the effect's default,
            // so adding it changes only what was asked.
            for key in section.keys {
                let neutral = section.neutral(key, registry: registry)
                if neutral != registry.definition(section.effectType)?.param(key)?.defaultValue { effect.params[key] = neutral }
            }
            target = insertionIndex(for: section)
            list.insert(effect, at: target)
        }
        let id = list[target].id
        var sets: [ColourChange.SetValue] = []
        for key in section.keys where values[key] != nil {
            list[target].params[key] = values[key]
            sets.append(ColourChange.SetValue(effectID: id, key: key, value: values[key]!))
        }
        let change = ColourChange(effects: list, label: label, sets: sets, moves: moves)
        // Setting what's already there changes nothing, unless it's
        // animated, where it sets the keyframe at the playhead.
        if list == effects, !sets.contains(where: { animated[$0.effectID]?.contains($0.key) == true }) { return nil }
        return change
    }

    /// Turns a section off or back on. When Light and Colour share an
    /// effect and the other one has values, they're split first so only
    /// this one changes.
    func toggling(_ section: ColourSection, newID: () -> String = { IDs.make("fx") }) -> ColourChange? {
        guard let index = backing[section] else { return nil }
        var list = effects
        var moves: [ColourChange.Move] = []
        var target = index
        if isShared(section), let partner = section.partner, isChanged(partner) {
            let split = split(&list, at: index, newID: newID())
            moves = split.moves
            target = section == .colour ? split.colour : index
        }
        list[target].enabled.toggle()
        let label = "\(list[target].enabled ? "Turn on" : "Turn off") \(section.title.lowercased())"
        return ColourChange(effects: list, label: label, moves: moves)
    }

    /// Puts a section back to no change: its effect goes, or, when it
    /// shares one with values of the other section's, just its values do.
    func resetting(_ section: ColourSection) -> ColourChange? {
        guard let index = backing[section] else { return nil }
        var list = effects
        var moves: [ColourChange.Move] = []
        if isShared(section), let partner = section.partner, isChanged(partner) {
            let id = list[index].id
            for key in section.keys {
                list[index].params[key] = nil
                if animated[id]?.contains(key) == true { moves.append(ColourChange.Move(key: key, from: id, to: nil)) }
            }
            if list == effects, moves.isEmpty { return nil }
        } else {
            list.remove(at: index)
        }
        return ColourChange(effects: list, label: "Reset \(section.title.lowercased())", moves: moves)
    }

    /// Light and Colour's shared effect as two: the original keeps the
    /// Light values and its ID, a new one right after it takes the Colour
    /// values (and their animations), on or off as the original was.
    private func split(_ list: inout [Effect], at index: Int, newID: String) -> (colour: Int, moves: [ColourChange.Move]) {
        let original = list[index]
        var colour = Effect(id: newID, type: original.type, enabled: original.enabled)
        var moves: [ColourChange.Move] = []
        for key in ColourSection.colour.keys {
            if let value = original.params[key] {
                colour.params[key] = value
                list[index].params[key] = nil
            }
            if animated[original.id]?.contains(key) == true {
                moves.append(ColourChange.Move(key: key, from: original.id, to: newID))
            }
        }
        list.insert(colour, at: index + 1)
        return (index + 1, moves)
    }

    /// Where a section's new effect goes so the list keeps the tab's
    /// order: before the first effect of a later section, else after the
    /// last of an earlier one, else first.
    func insertionIndex(for section: ColourSection) -> Int {
        let order = ColourSection.allCases
        let position = order.firstIndex(of: section) ?? 0
        let later = order[(position + 1)...].compactMap { backing[$0] }
        if let first = later.min() { return first }
        let earlier = order[..<position].compactMap { backing[$0] }
        if let last = earlier.max() { return last + 1 }
        return 0
    }
}

/// Turns a `ColourChange` into edit commands for a clip.
enum ColourEdits {
    static func path(_ effectID: String, _ key: String) -> String {
        "video.effects.\(effectID).\(key)"
    }

    /// The commands that take a clip's video effects to `change.effects`.
    /// Values the change sets on animated parameters become keyframes at
    /// the playhead (`time`, clip-relative), as the rest of the inspector
    /// does, and animations follow their parameters when an effect splits.
    static func clipCommands(_ clip: Clip, _ change: ColourChange, at time: Time, tolerance: Time) -> [EditCommand] {
        let old = clip.video?.effects ?? []
        let new = change.effects
        let newIDs = Set(new.map(\.id))
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var commands: [EditCommand] = []

        // Animations after the change, by path: moved ones, then values set
        // at the playhead.
        var keyframes: [String: [Keyframe]] = [:]
        for move in change.moves {
            let from = path(move.from, move.key)
            guard let list = clip.keyframes[from], !list.isEmpty else { continue }
            keyframes[from] = []
            if let to = move.to { keyframes[path(to, move.key)] = list }
        }
        var keyedSets: Set<String> = []
        for set in change.sets {
            let p = path(set.effectID, set.key)
            var probe = clip
            if let moved = keyframes[p] { probe.keyframes[p] = moved }
            if case .setKeyframes(_, _, let list)? = KeyframeEdits.setValue(set.value, for: p, in: probe, at: time, tolerance: tolerance) {
                keyframes[p] = list
                keyedSets.insert(p)
            }
        }

        for effect in old where !newIDs.contains(effect.id) {
            commands.append(.removeEffect(clipID: clip.id, effectID: effect.id))
        }
        for (index, effect) in new.enumerated() {
            guard let before = oldByID[effect.id] else {
                commands.append(.addEffect(clipID: clip.id, effect: effect, index: index))
                continue
            }
            var patch: [String: JSONValue] = [:]
            if before.enabled != effect.enabled { patch["enabled"] = .bool(effect.enabled) }
            var params: [String: JSONValue] = [:]
            for key in Set(before.params.keys).union(effect.params.keys).sorted() where before.params[key] != effect.params[key] {
                // An animated value is set by its keyframe, not the plain one.
                if keyedSets.contains(path(effect.id, key)) { continue }
                params[key] = effect.params[key]?.json ?? .null
            }
            if !params.isEmpty { patch["params"] = .object(params) }
            if !patch.isEmpty {
                commands.append(.updateEffect(clipID: clip.id, effectID: effect.id, patch: .object(patch)))
            }
        }
        for (p, list) in keyframes.sorted(by: { $0.key < $1.key }) where clip.keyframes[p] != list {
            commands.append(.setKeyframes(clipID: clip.id, parameter: p, keyframes: list))
        }
        return commands
    }
}
