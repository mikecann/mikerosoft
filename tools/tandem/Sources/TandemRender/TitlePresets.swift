import Foundation
import TandemCore

/// A title style: the look and motion a text clip gets from
/// `TextContent.preset`. Any field the clip's own `style` sets wins over
/// the preset's, and fields neither sets come from `TextStyle.defaults`.
public struct TitlePreset: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var style: TextStyle
    public var animationIn: String?
    public var animationOut: String?
    public var animationDuration: Time
    /// Where the title sits when the clip has no transform of its own.
    public var position: Point
    /// Colour of the word being spoken, for captions with word timings.
    public var highlightColor: RGBA?
    /// For two-line titles: the first line's size relative to the rest.
    public var firstLineScale: Double?
    /// For two-line titles: the first line's colour.
    public var firstLineColor: RGBA?

    public init(
        id: String,
        name: String,
        summary: String,
        style: TextStyle,
        animationIn: String? = nil,
        animationOut: String? = nil,
        animationDuration: Time = Time(seconds: 0.4),
        position: Point = Point(x: 0.5, y: 0.5),
        highlightColor: RGBA? = nil,
        firstLineScale: Double? = nil,
        firstLineColor: RGBA? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.style = style
        self.animationIn = animationIn
        self.animationOut = animationOut
        self.animationDuration = animationDuration
        self.position = position
        self.highlightColor = highlightColor
        self.firstLineScale = firstLineScale
        self.firstLineColor = firstLineColor
    }
}

/// The built-in title styles, taken from the four Filmora templates Mike
/// used across 51 projects (Basic 1, Cute Pop Text 02, Title 2 and Pop in
/// Title 01) plus the word-by-word captions from his shorts.
public enum TitlePresets {
    /// Convex-ish warm yellow used for accents.
    static let accent = RGBA(r: 1.0, g: 0.8, b: 0.16)

    public static let builtIn: [TitlePreset] = [
        TitlePreset(
            id: "label",
            name: "Label",
            summary: "Plain label such as JAMIES SCREEN, 8x or VS.",
            style: TextStyle(size: 64, weight: 800, uppercase: true, shadow: true),
            animationIn: "fade",
            animationOut: "fade",
            animationDuration: Time(seconds: 0.25)
        ),
        TitlePreset(
            id: "callout",
            name: "Pop callout",
            summary: "Punchy boxed callout such as 14 TIPS or FULL VIDEO LINKED BELOW.",
            style: TextStyle(size: 88, weight: 900, color: RGBA(r: 0.07, g: 0.07, b: 0.07), backgroundColor: accent, uppercase: true, shadow: true),
            animationIn: "pop",
            animationOut: "pop",
            animationDuration: Time(seconds: 0.35)
        ),
        TitlePreset(
            id: "sectionHeader",
            name: "Section header",
            summary: "Two lines: a small accent line over a big title, such as TIP 1 / CURSOR DOCS.",
            style: TextStyle(size: 104, weight: 900, uppercase: true, shadow: true, lineSpacing: 0.05),
            animationIn: "slideUp",
            animationOut: "fade",
            animationDuration: Time(seconds: 0.45),
            firstLineScale: 0.55,
            firstLineColor: accent
        ),
        TitlePreset(
            id: "version",
            name: "Version number",
            summary: "Big version number at the start of a release video, such as v1.46.0.",
            style: TextStyle(size: 170, weight: 900, shadow: true),
            animationIn: "pop",
            animationOut: "fade",
            animationDuration: Time(seconds: 0.4)
        ),
        TitlePreset(
            id: "caption",
            name: "Word caption",
            summary: "Short-form caption that highlights each word as it's spoken.",
            style: TextStyle(font: "Tilt Warp", size: 72, weight: 400, strokeColor: .black, strokeWidth: 6),
            animationIn: "fade",
            animationOut: "fade",
            animationDuration: Time(seconds: 0.1),
            position: Point(x: 0.5, y: 0.42),
            highlightColor: RGBA(r: 1.0, g: 0.84, b: 0.2)
        )
    ]

    public static func preset(_ id: String?) -> TitlePreset? {
        guard let id else { return nil }
        return builtIn.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// What a text clip is drawn with: its own style over its preset's,
    /// over the defaults.
    public static func style(for content: TextContent) -> TextStyle.Resolved {
        content.style.resolved(over: presetStyle(content.preset))
    }

    /// What a clip gets from its preset alone, which is what a field goes
    /// back to when the clip stops setting it.
    public static func presetStyle(_ presetID: String?) -> TextStyle.Resolved {
        (preset(presetID)?.style ?? TextStyle()).resolved()
    }
}

enum TextAnimation: Equatable {
    case fade, pop, slideUp, typewriter

    /// Accepts the names agents and presets use: `fade`, `fadeIn`, `pop`,
    /// `popIn`, `slideUp`, `typewriter`... `none` (or any name it doesn't
    /// know) is no animation, which is how a clip switches its preset's off.
    init?(name: String?) {
        guard let name else { return nil }
        switch name.lowercased() {
        case "none", "off": return nil
        case "fade", "fadein", "fadeout", "dissolve": self = .fade
        case "pop", "popin", "popout", "scale": self = .pop
        case "slide", "slideup", "slideupin", "rise": self = .slideUp
        case "typewriter", "type", "typing": self = .typewriter
        default: return nil
        }
    }
}

/// A text clip with its preset merged in.
struct ResolvedText {
    var text: String
    var style: TextStyle.Resolved
    var animationIn: TextAnimation?
    var animationOut: TextAnimation?
    var animationDuration: Time
    var position: Point?
    var highlightColor: RGBA
    var firstLineScale: Double
    var firstLineColor: RGBA?
    var words: [TimedWord]?

    init(_ content: TextContent) {
        let preset = TitlePresets.preset(content.preset)
        let style = TitlePresets.style(for: content)
        self.style = style

        animationIn = TextAnimation(name: content.animationIn ?? preset?.animationIn)
        animationOut = TextAnimation(name: content.animationOut ?? preset?.animationOut)
        animationDuration = content.animationDuration ?? preset?.animationDuration ?? TextContent.defaultAnimationDuration
        position = preset?.position
        highlightColor = preset?.highlightColor ?? TitlePresets.builtIn.first { $0.id == "caption" }?.highlightColor ?? TitlePresets.accent
        firstLineScale = preset?.firstLineScale ?? 1
        firstLineColor = preset?.firstLineColor

        if let words = content.words, !words.isEmpty {
            self.words = words
            text = words.map(\.text).joined(separator: " ")
        } else {
            words = nil
            text = content.text
        }
        if style.uppercase { text = text.uppercased() }
    }

    /// The word being spoken at a clip-relative time: the last one that has
    /// started, so the highlight doesn't flicker off in the gaps.
    func currentWord(at clipTime: Time) -> Int? {
        guard let words else { return nil }
        return words.lastIndex { $0.start <= clipTime }
    }

    /// UTF-16 range of word `index` in `text`, for attributed strings.
    func utf16Range(ofWord index: Int) -> Range<Int>? {
        guard let words, index < words.count else { return nil }
        let word = { (i: Int) -> Int in
            (self.style.uppercase ? words[i].text.uppercased() : words[i].text).utf16.count
        }
        var start = 0
        for i in 0..<index { start += word(i) + 1 }
        return start..<(start + word(index))
    }
}
