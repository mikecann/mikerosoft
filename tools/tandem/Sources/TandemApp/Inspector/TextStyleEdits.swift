import Foundation
import TandemCore

/// What the Text inspector's style controls send: fields for a merge patch
/// of `content.text.style`. A field the clip sets wins over its preset, and
/// `null` takes it out so the preset's value comes back.
enum TextStyleEdits {
    /// Takes `fields` out of the clip's own style, back to the preset's.
    static func reset(_ fields: [String]) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0, JSONValue.null) })
    }

    /// Switches the box behind the text off. When the preset has no box,
    /// taking out the clip's own is enough; when it has one, it takes a
    /// see-through box of the clip's own to beat it.
    static func noBackground(preset: TextStyle.Resolved) -> [String: JSONValue] {
        ["backgroundColor": preset.backgroundColor == nil ? .null : ParamValue.color(RGBA(r: 0, g: 0, b: 0, a: 0)).json]
    }

    /// An outline `width` points wide, 0 for none. An outline needs a
    /// colour, so a title that has none gets black.
    static func outline(width: Double, current: TextStyle.Resolved) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["strokeWidth": .number(width)]
        if width > 0, current.strokeColor == nil { fields["strokeColor"] = ParamValue.color(.black).json }
        return fields
    }

    /// The tooltip on a reset button: what the preset would give back.
    static func resetHelp(preset name: String?, value: String) -> String {
        "This clip's own. Click for \(name.map { "the \($0) preset's" } ?? "the default"): \(value)."
    }
}
