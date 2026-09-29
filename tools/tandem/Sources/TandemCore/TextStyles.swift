import Foundation

extension TextStyle {
    /// A style with every field filled in: what a title is drawn with.
    public struct Resolved: Equatable, Sendable {
        public var font: String
        public var size: Double
        public var weight: Double
        public var color: RGBA
        /// Nil draws no outline.
        public var strokeColor: RGBA?
        public var strokeWidth: Double
        /// Nil draws no box.
        public var backgroundColor: RGBA?
        public var alignment: String
        public var uppercase: Bool
        public var shadow: Bool
        public var lineSpacing: Double

        public init(
            font: String, size: Double, weight: Double, color: RGBA, strokeColor: RGBA?, strokeWidth: Double,
            backgroundColor: RGBA?, alignment: String, uppercase: Bool, shadow: Bool, lineSpacing: Double
        ) {
            self.font = font
            self.size = size
            self.weight = weight
            self.color = color
            self.strokeColor = strokeColor
            self.strokeWidth = strokeWidth
            self.backgroundColor = backgroundColor
            self.alignment = alignment
            self.uppercase = uppercase
            self.shadow = shadow
            self.lineSpacing = lineSpacing
        }

        /// True when an outline is drawn.
        public var hasOutline: Bool { strokeWidth > 0 && strokeColor != nil }
    }

    /// What each field is when neither the clip nor its preset sets it.
    public static let defaults = Resolved(
        font: "SF Pro Display", size: 64, weight: 800, color: .white, strokeColor: nil, strokeWidth: 0,
        backgroundColor: nil, alignment: "center", uppercase: false, shadow: false, lineSpacing: 0
    )

    /// True when the style sets nothing, so the preset decides everything.
    public var isEmpty: Bool { self == TextStyle() }

    /// The JSON names of the fields this style sets, in the order the
    /// inspector lists them.
    public var setFields: [String] {
        var names: [String] = []
        if font != nil { names.append("font") }
        if size != nil { names.append("size") }
        if weight != nil { names.append("weight") }
        if color != nil { names.append("color") }
        if strokeColor != nil { names.append("strokeColor") }
        if strokeWidth != nil { names.append("strokeWidth") }
        if backgroundColor != nil { names.append("backgroundColor") }
        if alignment != nil { names.append("alignment") }
        if uppercase != nil { names.append("uppercase") }
        if shadow != nil { names.append("shadow") }
        if lineSpacing != nil { names.append("lineSpacing") }
        return names
    }

    /// This style's fields laid over `base`: a field this style sets wins,
    /// the rest come from `base`.
    public func over(_ base: TextStyle) -> TextStyle {
        TextStyle(
            font: font ?? base.font,
            size: size ?? base.size,
            weight: weight ?? base.weight,
            color: color ?? base.color,
            strokeColor: strokeColor ?? base.strokeColor,
            strokeWidth: strokeWidth ?? base.strokeWidth,
            backgroundColor: backgroundColor ?? base.backgroundColor,
            alignment: alignment ?? base.alignment,
            uppercase: uppercase ?? base.uppercase,
            shadow: shadow ?? base.shadow,
            lineSpacing: lineSpacing ?? base.lineSpacing
        )
    }

    /// Every field filled in, from this style and then `base`.
    public func resolved(over base: Resolved = TextStyle.defaults) -> Resolved {
        var result = Resolved(
            font: font ?? base.font,
            size: size ?? base.size,
            weight: weight ?? base.weight,
            color: color ?? base.color,
            strokeColor: strokeColor ?? base.strokeColor,
            strokeWidth: strokeWidth ?? base.strokeWidth,
            backgroundColor: backgroundColor ?? base.backgroundColor,
            alignment: alignment ?? base.alignment,
            uppercase: uppercase ?? base.uppercase,
            shadow: shadow ?? base.shadow,
            lineSpacing: lineSpacing ?? base.lineSpacing
        )
        // A see-through box or outline is how a clip switches its preset's
        // off. Drawing it anyway would still pad the text and take its
        // shadow, so it counts as none.
        if let box = result.backgroundColor, box.a <= 0 { result.backgroundColor = nil }
        if let outline = result.strokeColor, outline.a <= 0 { result.strokeColor = nil }
        return result
    }
}

/// Schema 1 wrote every text style field, and a field that matched the
/// default meant "not set": the renderer took the preset's value instead.
/// So a label with `"uppercase": false` still shouted, and a callout
/// couldn't lose its shadow. From schema 2 a field that's there always
/// wins. Reading an older file drops the fields that match the old
/// defaults, so every title looks exactly as it did.
public enum LegacyTextStyles {
    /// The defaults schema 1 treated as "not set".
    static let defaults = TextStyle(
        font: "SF Pro Display", size: 64, weight: 800, color: .white, strokeWidth: 0,
        alignment: "center", uppercase: false, shadow: false, lineSpacing: 0
    )

    /// Every text clip in the project, read the schema 1 way.
    public static func upgrade(_ project: inout Project) {
        for location in project.trackLocations {
            for index in project[location].clips.indices {
                guard case .text(let text) = project[location].clips[index].content else { continue }
                project[location].clips[index].content = .text(upgrade(text))
            }
        }
    }

    /// One title read the schema 1 way: values equal to the old defaults
    /// weren't the clip's own choice, so they go.
    public static func upgrade(_ text: TextContent) -> TextContent {
        var text = text
        var style = text.style
        let d = defaults
        if style.font == d.font { style.font = nil }
        if style.size == d.size { style.size = nil }
        if style.weight == d.weight { style.weight = nil }
        if style.color == d.color { style.color = nil }
        if style.strokeWidth == d.strokeWidth { style.strokeWidth = nil }
        if style.alignment == d.alignment { style.alignment = nil }
        if style.uppercase == d.uppercase { style.uppercase = nil }
        if style.shadow == d.shadow { style.shadow = nil }
        if style.lineSpacing == d.lineSpacing { style.lineSpacing = nil }
        // The outline and box colours had no default, so one that's there
        // was always the clip's own.
        text.style = style
        if text.animationDuration == TextContent.defaultAnimationDuration { text.animationDuration = nil }
        return text
    }
}
