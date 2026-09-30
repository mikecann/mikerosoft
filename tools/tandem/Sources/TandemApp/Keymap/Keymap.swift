import Foundation

/// Everything a key (or a menu item) can ask the editor to do. The raw
/// values are the names used in keymap JSON files.
enum EditorCommand: String, CaseIterable, Codable {
    // Transport
    case playPause, shuttleReverse, shuttleStop, shuttleForward
    case stepBack, stepForward, stepBackFive, stepForwardFive
    case goToStart, goToEnd, previousEdit, nextEdit, previousMarker, nextMarker
    // In and out
    case markIn, markOut, clearIn, clearOut, clearInOut, markClip
    case liftInOut, extractInOut
    // Editing
    case bladeAtPlayhead, rippleTrimStart, rippleTrimEnd
    case lift, rippleDelete
    case nudgeLeft, nudgeRight, nudgeLeftFive, nudgeRightFive
    case link, addMarker, addTransition, addSectionCards
    case toggleKeyframe, previousKeyframe, nextKeyframe
    case addVideoTrack, addAudioTrack
    case layoutFull, layoutPipRight, layoutPipLeft, layoutSplit
    // Selection
    case selectAll, deselectAll, selectForward
    // Timeline view
    case zoomIn, zoomOut, zoomToFit
    case toggleSnapping, toggleLinkedSelection, toggleRipple, toggleTranscriptLane
    // Tools
    case toolSelect, toolBlade, toolRippleTrim, toolRoll, toolSlip, toolSlide
    // Viewer
    case toggleSafeMargins, toggleProxy
    // Review
    case previousAgentChange, nextAgentChange, markAgentChangesReviewed
    // Project
    case undo, redo, save, saveVersion, export, newProject, openProject

    /// Sentence-case names for menus and tooltips.
    var title: String {
        switch self {
        case .playPause: return "Play or pause"
        case .shuttleReverse: return "Play backwards"
        case .shuttleStop: return "Stop"
        case .shuttleForward: return "Play forwards"
        case .stepBack: return "Back one frame"
        case .stepForward: return "Forward one frame"
        case .stepBackFive: return "Back five frames"
        case .stepForwardFive: return "Forward five frames"
        case .goToStart: return "Go to start"
        case .goToEnd: return "Go to end"
        case .previousEdit: return "Previous edit"
        case .nextEdit: return "Next edit"
        case .previousMarker: return "Previous marker"
        case .nextMarker: return "Next marker"
        case .markIn: return "Mark in"
        case .markOut: return "Mark out"
        case .clearIn: return "Clear in"
        case .clearOut: return "Clear out"
        case .clearInOut: return "Clear in and out"
        case .markClip: return "Mark clip"
        case .liftInOut: return "Lift in to out"
        case .extractInOut: return "Extract in to out"
        case .bladeAtPlayhead: return "Blade at playhead"
        case .rippleTrimStart: return "Ripple trim start to playhead"
        case .rippleTrimEnd: return "Ripple trim end to playhead"
        case .lift: return "Delete"
        case .rippleDelete: return "Ripple delete"
        case .nudgeLeft: return "Nudge left"
        case .nudgeRight: return "Nudge right"
        case .nudgeLeftFive: return "Nudge left five frames"
        case .nudgeRightFive: return "Nudge right five frames"
        case .link: return "Link or unlink"
        case .addMarker: return "Add marker"
        case .addTransition: return "Add dissolve"
        case .addSectionCards: return "Add section cards at section markers"
        case .toggleKeyframe: return "Add or remove keyframe"
        case .previousKeyframe: return "Previous keyframe"
        case .nextKeyframe: return "Next keyframe"
        case .addVideoTrack: return "Add video track"
        case .addAudioTrack: return "Add audio track"
        case .layoutFull: return "Layout: full"
        case .layoutPipRight: return "Layout: PiP right"
        case .layoutPipLeft: return "Layout: PiP left"
        case .layoutSplit: return "Layout: split"
        case .selectAll: return "Select all"
        case .deselectAll: return "Deselect all"
        case .selectForward: return "Select everything after the playhead"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case .zoomToFit: return "Zoom to fit"
        case .toggleSnapping: return "Snapping"
        case .toggleLinkedSelection: return "Linked selection"
        case .toggleRipple: return "Ripple trims"
        case .toggleTranscriptLane: return "Transcript lane"
        case .toolSelect: return "Select tool"
        case .toolBlade: return "Blade tool"
        case .toolRippleTrim: return "Ripple trim tool"
        case .toolRoll: return "Roll tool"
        case .toolSlip: return "Slip tool"
        case .toolSlide: return "Slide tool"
        case .toggleSafeMargins: return "Safe margins"
        case .toggleProxy: return "Use proxies"
        case .previousAgentChange: return "Previous agent change"
        case .nextAgentChange: return "Next agent change"
        case .markAgentChangesReviewed: return "Mark agent edits reviewed"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .save: return "Save"
        case .saveVersion: return "Save as version…"
        case .export: return "Export…"
        case .newProject: return "New project…"
        case .openProject: return "Open…"
        }
    }
}

/// A key and its modifiers, written in keymap files as `cmd+shift+z`,
/// `shift+,`, `space` or `'`.
struct KeyChord: Hashable, CustomStringConvertible {
    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let shift = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let control = Modifiers(rawValue: 8)
    }

    /// Named keys that aren't a single printable character.
    static let namedKeys: Set<String> = [
        "space", "delete", "forwarddelete", "return", "enter", "escape", "tab",
        "left", "right", "up", "down", "home", "end", "pageup", "pagedown",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"
    ]

    private static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command,
        "shift": .shift,
        "opt": .option, "option": .option, "alt": .option,
        "ctrl": .control, "control": .control
    ]

    /// Lowercase: a letter, digit or punctuation character, or a named key.
    let key: String
    let modifiers: Modifiers

    init(key: String, modifiers: Modifiers = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Parses `cmd+shift+z`. A lone `+` is the plus key; `shift++` is shift
    /// and plus. Returns nil for unknown modifiers or keys.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        var parts = trimmed.components(separatedBy: "+")
        var keyPart: String
        if trimmed.hasSuffix("++") || trimmed == "+" {
            // The key itself is "+".
            parts = Array(trimmed.dropLast(trimmed == "+" ? 1 : 2).components(separatedBy: "+").filter { !$0.isEmpty })
            keyPart = "+"
        } else {
            keyPart = parts.removeLast()
        }
        var modifiers: Modifiers = []
        for part in parts where !part.isEmpty {
            guard let modifier = Self.modifierNames[part] else { return nil }
            modifiers.insert(modifier)
        }
        if keyPart == "backspace" { keyPart = "delete" }
        if keyPart == "esc" { keyPart = "escape" }
        guard keyPart.count == 1 || Self.namedKeys.contains(keyPart) else { return nil }
        self.init(key: keyPart, modifiers: modifiers)
    }

    /// The canonical spelling: modifiers in the order cmd, ctrl, option, shift.
    var description: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// How macOS menus show it, for example `⇧⌘Z`.
    var symbol: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let names: [String: String] = [
            "space": "Space", "delete": "⌫", "forwarddelete": "⌦", "return": "↩", "enter": "⌤",
            "escape": "⎋", "tab": "⇥", "left": "←", "right": "→", "up": "↑", "down": "↓",
            "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟"
        ]
        text += names[key] ?? key.uppercased()
        return text
    }
}

enum KeymapError: Error, LocalizedError, Equatable {
    case invalid([String])

    var errorDescription: String? {
        switch self {
        case .invalid(let problems): return "The keymap has problems: " + problems.joined(separator: "; ")
        }
    }
}

/// Key bindings loaded from JSON:
///
///     { "name": "Premiere", "bindings": { "space": "playPause", "cmd+b": "bladeAtPlayhead" } }
///
/// A user keymap merges over the defaults, and `null` removes a binding.
struct Keymap: Equatable {
    var name: String
    private(set) var bindings: [KeyChord: EditorCommand]

    init(name: String, bindings: [KeyChord: EditorCommand]) {
        self.name = name
        self.bindings = bindings
    }

    static let empty = Keymap(name: "Empty", bindings: [:])

    private struct File: Decodable {
        var name: String?
        var bindings: [String: String?]
    }

    /// Parses a keymap file. With `allowRemovals`, `null` values are kept
    /// as removals for `merged(with:)`; they're returned separately.
    static func parse(_ data: Data) throws -> (keymap: Keymap, removals: Set<KeyChord>) {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw KeymapError.invalid(["it isn't valid keymap JSON (\(error.localizedDescription))"])
        }
        var problems: [String] = []
        var bindings: [KeyChord: EditorCommand] = [:]
        var removals = Set<KeyChord>()
        var spelled: [KeyChord: String] = [:]
        for (text, name) in file.bindings.sorted(by: { $0.key < $1.key }) {
            guard let chord = KeyChord(text) else {
                problems.append("\"\(text)\" isn't a key")
                continue
            }
            if let earlier = spelled[chord] {
                problems.append("\"\(text)\" and \"\(earlier)\" are the same key")
                continue
            }
            spelled[chord] = text
            guard let name else {
                removals.insert(chord)
                continue
            }
            guard let command = EditorCommand(rawValue: name) else {
                problems.append("\"\(name)\" (on \(text)) isn't a command")
                continue
            }
            bindings[chord] = command
        }
        if !problems.isEmpty { throw KeymapError.invalid(problems) }
        return (Keymap(name: file.name ?? "Custom", bindings: bindings), removals)
    }

    static func load(_ data: Data) throws -> Keymap {
        try parse(data).keymap
    }

    /// This keymap with `overrides` on top: its bindings replace ours and
    /// its removals drop ours.
    func merged(with overrides: Keymap, removing removals: Set<KeyChord> = []) -> Keymap {
        var result = bindings
        for chord in removals { result.removeValue(forKey: chord) }
        for (chord, command) in overrides.bindings { result[chord] = command }
        return Keymap(name: overrides.name, bindings: result)
    }

    func command(for chord: KeyChord) -> EditorCommand? {
        bindings[chord]
    }

    /// Every chord bound to `command`, simplest first (fewest modifiers,
    /// then shortest), for menus and tooltips.
    func chords(for command: EditorCommand) -> [KeyChord] {
        bindings.filter { $0.value == command }.map(\.key).sorted { a, b in
            let ac = a.modifiers.rawValue.nonzeroBitCount
            let bc = b.modifiers.rawValue.nonzeroBitCount
            if ac != bc { return ac < bc }
            if a.key.count != b.key.count { return a.key.count < b.key.count }
            return a.description < b.description
        }
    }

    /// The preferred chord for a menu item: the one with a Cmd modifier if
    /// there is one (menus can't show plain letters as shortcuts sensibly),
    /// otherwise the simplest.
    func menuChord(for command: EditorCommand) -> KeyChord? {
        let all = chords(for: command)
        return all.first { $0.modifiers.contains(.command) } ?? all.first
    }
}
