import Foundation

/// Mike's section card: a full-screen card of about three seconds between
/// the cold open, the intro and each section, so viewers get a breather.
/// Convex's yellow, red and purple bands sweep across to wipe it in, the
/// dark card holds a number chip, the title (Anton), a letter-spaced
/// subtitle and the progress bars, and the bands sweep across again to
/// wipe it out.
///
/// It's one clip: `ClipContent.graphic` with `template: "sectionCard"`,
/// drawn by TandemRender at the output size. The props are plain
/// `GraphicContent.props` values, so the inspector, agents and templates
/// all edit the same thing. The motion here (band geometry, timing and
/// easing) is shared by the renderer and by `addSectionCards`, which needs
/// to know when the card hides the whole frame.
public enum SectionCard {
    /// `GraphicContent.template` for a section card.
    public static let template = "sectionCard"

    /// A card's usual length, and the shortest a card fitted to its words
    /// gets (`fittedDuration(for:)`). The wipes keep their length when a
    /// card is longer or shorter; only the hold between them changes.
    public static let defaultDuration = Time(seconds: 3.2)

    /// Prop keys in `GraphicContent.props`.
    public enum Key {
        public static let title = "title"
        public static let subtitle = "subtitle"
        /// Shown in the chip, like "01". A number is written with two digits.
        public static let number = "number"
        /// How many sections there are, for the progress bars. 0 hides them.
        public static let total = "total"
        /// "Section", or "Tip" in a list video: shown as "SECTION 1 OF 3"
        /// beside the chip.
        public static let kicker = "kicker"
        /// The first band, the chip, the subtitle and the lit bars.
        public static let accent = "accent"
        /// The second and third bands.
        public static let band2 = "band2"
        public static let band3 = "band3"
        /// The card behind the words.
        public static let background = "background"
        /// A text cursor blinking after the title's last letter. On unless
        /// this is false.
        public static let cursor = "cursor"

        public static let all = [title, subtitle, number, total, kicker, accent, band2, band3, background, cursor]
    }

    public struct Colors: Hashable, Sendable {
        public var accent: RGBA
        public var band2: RGBA
        public var band3: RGBA
        public var background: RGBA

        public init(accent: RGBA, band2: RGBA, band3: RGBA, background: RGBA) {
            self.accent = accent
            self.band2 = band2
            self.band3 = band3
            self.background = background
        }

        /// Convex's yellow #F3B01C, red #EE342F and purple #8D2676 on
        /// #141418.
        public static let convex = Colors(
            accent: RGBA(hex: 0xF3B01C),
            band2: RGBA(hex: 0xEE342F),
            band3: RGBA(hex: 0x8D2676),
            background: RGBA(hex: 0x141418)
        )

        /// The bands in drawing order: the first sweeps in front of the
        /// others and the last is drawn on top.
        public var bands: [RGBA] { [accent, band2, band3] }
    }

    /// A card's words and colours, read leniently from the clip's props.
    public struct Props: Hashable, Sendable {
        public var title: String
        public var subtitle: String
        /// What the chip says, like "01". Empty hides the chip.
        public var number: String
        /// How many sections there are; 0 hides the progress bars.
        public var total: Int
        /// "Section" or "Tip"; empty shows no words beside the chip.
        public var kicker: String
        public var colors: Colors
        /// A text cursor in the accent colour after the title's last letter,
        /// blinking like a terminal's once the title lands.
        public var cursor: Bool

        public init(title: String = "", subtitle: String = "", number: String = "", total: Int = 0, kicker: String = "", colors: Colors = .convex, cursor: Bool = true) {
            self.title = title
            self.subtitle = subtitle
            self.number = number
            self.total = max(0, total)
            self.kicker = kicker
            self.colors = colors
            self.cursor = cursor
        }

        /// From `GraphicContent.props`. Missing values are empty (no chip,
        /// no subtitle, no bars), colours default to Convex's and the cursor
        /// is on. The number can be text ("01") or a number (1, written
        /// "01"); the total a number or text; the cursor a switch, "off" or 0.
        public init(_ props: [String: ParamValue]) {
            func text(_ key: String) -> String {
                switch props[key] {
                case .string(let value)?: return value
                case .number(let value)?: return SectionCard.number(value)
                case .bool(let value)?: return value ? "true" : ""
                default: return ""
                }
            }
            func colour(_ key: String, _ fallback: RGBA) -> RGBA {
                if case .color(let value)? = props[key] { return value }
                if case .string(let value)? = props[key], let parsed = RGBA(hexString: value) { return parsed }
                return fallback
            }
            var number = text(Key.number)
            if case .number(let value)? = props[Key.number], value == value.rounded(), value >= 0, value < 1_000 {
                number = SectionCard.numberText(Int(value))
            }
            var total = 0
            switch props[Key.total] {
            case .number(let value)?: total = value.isFinite ? Int(max(0, min(value, 999)).rounded()) : 0
            case .string(let value)?: total = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
            default: break
            }
            var cursor = true
            switch props[Key.cursor] {
            case .bool(let value)?: cursor = value
            case .number(let value)?: cursor = value != 0
            case .string(let value)?: cursor = !["false", "off", "no", "0", "none"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
            default: break
            }
            let defaults = Colors.convex
            self.init(
                title: text(Key.title),
                subtitle: text(Key.subtitle),
                number: number,
                total: total,
                kicker: text(Key.kicker),
                colors: Colors(
                    accent: colour(Key.accent, defaults.accent),
                    band2: colour(Key.band2, defaults.band2),
                    band3: colour(Key.band3, defaults.band3),
                    background: colour(Key.background, defaults.background)
                ),
                cursor: cursor
            )
        }

        /// As `GraphicContent.props`: empty words, a zero total, Convex's
        /// colours and the cursor on are left out, so a card only says
        /// what's its own.
        public var params: [String: ParamValue] {
            var result: [String: ParamValue] = [:]
            if !title.isEmpty { result[Key.title] = .string(title) }
            if !subtitle.isEmpty { result[Key.subtitle] = .string(subtitle) }
            if !number.isEmpty { result[Key.number] = .string(number) }
            if total > 0 { result[Key.total] = .number(Double(total)) }
            if !kicker.isEmpty { result[Key.kicker] = .string(kicker) }
            let defaults = Colors.convex
            if colors.accent != defaults.accent { result[Key.accent] = .color(colors.accent) }
            if colors.band2 != defaults.band2 { result[Key.band2] = .color(colors.band2) }
            if colors.band3 != defaults.band3 { result[Key.band3] = .color(colors.band3) }
            if colors.background != defaults.background { result[Key.background] = .color(colors.background) }
            if !cursor { result[Key.cursor] = .bool(false) }
            return result
        }

        /// The words a viewer reads, as `fittedDuration(for:)` counts them:
        /// the title, the subtitle and the kicker as the card shows it
        /// ("Section 1 of 3"), one space between words. The chip's number
        /// and the progress count are taken in at a glance, so they aren't.
        public var readingText: String {
            [title, subtitle, kickerLine ?? ""]
                .flatMap { $0.split(whereSeparator: { $0.isWhitespace }) }
                .joined(separator: " ")
        }

        /// The number as a whole number, when it is one ("01" is 1).
        public var index: Int? {
            let digits = number.trimmingCharacters(in: .whitespaces)
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let value = Int(digits), value > 0 else { return nil }
            return value
        }

        /// The words beside the chip, like "Section 1 of 3", or nil.
        public var kickerLine: String? {
            let word = kicker.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { return nil }
            guard let index else { return word }
            return total > 0 ? "\(word) \(index) of \(total)" : "\(word) \(index)"
        }

        /// The progress row under the subtitle: one bar per section, lit up
        /// to this one, for up to six; past six, a bar filled in proportion
        /// with a count, like "1 / 14". Nil without a total, or when the
        /// number isn't a section in it.
        public var progress: Progress? {
            guard total > 0, let index, index <= total else { return nil }
            return total <= Progress.maxBars ? .bars(count: total, lit: index) : .proportional(index: index, total: total)
        }

        /// The clip's name on the timeline: "01 Methodology".
        public var label: String {
            let parts = [number, title].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let text = parts.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
            return text.isEmpty ? "Section card" : text
        }
    }

    public enum Progress: Hashable, Sendable {
        /// Bars at most, one a section.
        public static let maxBars = 6

        case bars(count: Int, lit: Int)
        case proportional(index: Int, total: Int)

        /// The count beside a proportional bar.
        public var countText: String? {
            if case .proportional(let index, let total) = self { return "\(index) / \(total)" }
            return nil
        }
    }

    /// "01" for 1: two digits, as the chip shows them.
    public static func numberText(_ value: Int) -> String {
        value < 10 && value >= 0 ? "0\(value)" : String(value)
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    /// The content for a card with these props.
    public static func content(_ props: Props) -> ClipContent {
        .graphic(GraphicContent(template: template, props: props.params))
    }

    /// True for a section card's content.
    public static func isCard(_ content: ClipContent) -> Bool {
        if case .graphic(let graphic) = content { return graphic.template == template }
        return false
    }

    /// A clip's card props, or nil when it isn't a section card.
    public static func props(of clip: Clip) -> Props? {
        guard case .graphic(let graphic) = clip.content, graphic.template == template else { return nil }
        return Props(graphic.props)
    }
}

// MARK: - Length

extension SectionCard {
    /// How long a card's words need on screen, for `fittedDuration(for:)`.
    ///
    /// The words are fully shown from about 0.7 s (they've faded in) until
    /// about 0.7 s before the end (the first band of the wipe out reaches
    /// them), so 1.4 s of a card isn't for reading. The rest is read at 17
    /// characters a second, spaces included: the reading speed Netflix
    /// sets for adult subtitles, and about the BBC's 160 to 180 words a
    /// minute. A usual card, METHODOLOGY / LET'S KEEP IT FAIR (30
    /// characters), then needs 3.2 s, the length cards have always had.
    public enum Reading {
        public static let charactersPerSecond = 17.0
        /// The wipes' share of a card, in seconds.
        public static let wipes = 1.4
        /// A card is never shorter than it's always been.
        public static let shortest = SectionCard.defaultDuration
        /// About 78 characters. Longer than this a card stops being a
        /// breather; shorten the words instead.
        public static let longest = Time(seconds: 6)
    }

    /// The length a card needs for its words (`Props.readingText`): 1.4 s
    /// for the wipes plus the characters at 17 a second, rounded up to a
    /// tenth of a second and kept to 3.2...6 s. With `frameRate`, rounded
    /// up to a whole frame too.
    public static func fittedDuration(for props: Props, frameRate: FrameRate? = nil) -> Time {
        let reading = Reading.wipes + Double(props.readingText.count) / Reading.charactersPerSecond
        let clamped = min(max(reading, Reading.shortest.seconds), Reading.longest.seconds)
        let tenths = (clamped * 10 - 1e-9).rounded(.up) / 10
        guard let frameRate else { return Time(seconds: tenths) }
        let frames = (tenths * frameRate.framesPerSecond - 1e-6).rounded(.up)
        return Time.frames(Int64(frames), at: frameRate)
    }
}

// MARK: - Motion

extension SectionCard {
    /// How a card moves, in seconds from its start and in units of the
    /// frame's width (x right, y down), for a card `duration` seconds long
    /// on a frame `aspect` (height over width) high.
    ///
    /// These are the mockup's numbers: each band is 46% of the width wide,
    /// 140% of the height tall and skewed 16 degrees, sweeping across in
    /// 0.72 s with `cubic-bezier(.65, 0, .35, 1)`, 0.08 s after the one
    /// before. The sweep in starts with the card and the sweep out ends
    /// with it (the out sweep starts 0.88 s before the end), so a longer
    /// card only holds longer. The words come in 0.52 s after the start,
    /// rising 2.5% of the width and growing from 98% over 0.45 s with
    /// `cubic-bezier(.16, 1, .3, 1)`. The bands travel 372% of their
    /// width (the mockup's 360% left a sliver bottom right), or more on a
    /// tall frame, so they always leave it.
    public struct Motion: Hashable, Sendable {
        public static let sweep = 0.72
        public static let stagger = 0.08
        /// The out sweep's first band starts this long before the end.
        public static let outLead = 0.88
        public static let contentStart = 0.52
        public static let contentLength = 0.45
        /// Fractions of the width.
        public static let bandWidth = 0.46
        public static let bandLeft = -0.62
        /// Fractions of the height.
        public static let bandTop = -0.2
        public static let bandHeight = 1.4
        public static let skewDegrees = 16.0
        public static let contentRise = 0.025
        public static let contentScale = 0.98
        public static let sweepEasing = CubicBezier(0.65, 0, 0.35, 1)
        public static let contentEasing = CubicBezier(0.16, 1, 0.3, 1)

        public let duration: Double
        public let aspect: Double

        public init(duration: Double, aspect: Double = 9.0 / 16.0) {
            self.duration = max(0, duration)
            self.aspect = aspect > 0 ? aspect : 9.0 / 16.0
        }

        public init(duration: Time, width: Int, height: Int) {
            self.init(duration: duration.seconds, aspect: width > 0 && height > 0 ? Double(height) / Double(width) : 9.0 / 16.0)
        }

        /// 1, or less when the card is too short for both wipes, which
        /// then shrink together.
        public var timeScale: Double {
            let both = 2 * Self.outLead
            return duration >= both ? 1 : duration / both
        }

        public var sweepLength: Double { Self.sweep * timeScale }

        /// When band `index` (0 first) starts its sweep in, and its sweep out.
        public func inStart(_ index: Int) -> Double { Double(index) * Self.stagger * timeScale }
        public func outStart(_ index: Int) -> Double { duration - (Self.outLead - Double(index) * Self.stagger) * timeScale }

        /// How far the bottom of a band leans left of its top: the skew
        /// across the frame's height, in widths.
        var lean: Double { tan(Self.skewDegrees * .pi / 180) * aspect }

        /// A band's left edge at rest (at the frame's vertical middle), in
        /// widths: off the frame to the left, top corner included.
        public var restLeft: Double { min(Self.bandLeft, -(Self.bandWidth + lean / 2) - 0.005) }

        /// How far a band travels in a sweep, in widths: past the frame,
        /// bottom corner included.
        public var travel: Double { max(3.72 * Self.bandWidth, 1 - restLeft + lean / 2 + 0.005) }

        /// A band's shape: its left edge's x at `y` (in widths from the top;
        /// the frame's bottom is `aspect`) is `left + lean * (0.5 - y / aspect)`,
        /// and its right edge is `bandWidth` further right.
        public struct Band: Hashable, Sendable {
            /// The left edge's x at the frame's vertical middle, in widths.
            public var left: Double
            public var lean: Double
            public var aspect: Double

            public func leftEdge(atY y: Double) -> Double { left + lean * (0.5 - y / aspect) }
            public func rightEdge(atY y: Double) -> Double { leftEdge(atY: y) + Motion.bandWidth }
        }

        /// Band `index` in a sweep that started at `start`, at time `t`, or
        /// nil when the sweep isn't under way. Before it starts a band waits
        /// off the frame to the left, and afterwards it's gone past the right.
        public func band(_ index: Int, sweepStartingAt start: Double, at t: Double) -> Band? {
            let length = sweepLength
            guard length > 0, t >= start, t < start + length else { return nil }
            let progress = Self.sweepEasing.value(at: (t - start) / length)
            return Band(left: restLeft + progress * travel, lean: lean, aspect: aspect)
        }

        /// The bands of the sweep in and the sweep out on screen at `t`,
        /// first band first.
        public func bands(at t: Double) -> [(index: Int, band: Band)] {
            var result: [(Int, Band)] = []
            for index in 0..<3 {
                if let band = band(index, sweepStartingAt: inStart(index), at: t) { result.append((index, band)) }
            }
            for index in 0..<3 {
                if let band = band(index, sweepStartingAt: outStart(index), at: t) { result.append((index, band)) }
            }
            return result
        }

        /// Where the card shows at `t`. The first band reveals it on the way
        /// in (the card is left of that band's left edge) and the last band
        /// takes it away on the way out (right of its left edge), so the
        /// shots either side show through ahead of and behind the bands.
        public struct Reveal: Hashable, Sendable {
            /// The card shows left of this edge; nil for no limit.
            public var before: Band?
            /// The card shows right of this edge; nil for no limit.
            public var after: Band?
            /// The card doesn't show at all.
            public var hidden: Bool

            public static let whole = Reveal(before: nil, after: nil, hidden: false)
        }

        public func reveal(at t: Double) -> Reveal {
            guard t >= 0, t < duration else { return Reveal(before: nil, after: nil, hidden: true) }
            var reveal = Reveal.whole
            let first = inStart(0)
            if t < first { return Reveal(before: nil, after: nil, hidden: true) }
            reveal.before = band(0, sweepStartingAt: first, at: t)
            let last = outStart(2)
            if t >= last + sweepLength { return Reveal(before: nil, after: nil, hidden: true) }
            reveal.after = band(2, sweepStartingAt: last, at: t)
            return reveal
        }

        /// How far the words have come in, 0 to 1.
        public func contentProgress(at t: Double) -> Double {
            let start = Self.contentStart * timeScale
            let length = Self.contentLength * timeScale
            guard length > 0 else { return 1 }
            return Self.contentEasing.value(at: (t - start) / length)
        }

        /// The cursor is on this long, then off this long, with hard steps:
        /// Windows' standard caret blink, 530 ms.
        public static let cursorBlink = 0.53

        /// When the title has landed: the words are all the way in.
        public var cursorLands: Double { (Self.contentStart + Self.contentLength) * timeScale }

        /// Whether the cursor after the title shows at `t`. It comes in with
        /// the words, is lit as the title lands, then goes off and on every
        /// 0.53 s, and it's gone once the wipe out starts. A lit spell the
        /// wipe out would cut to under half its length isn't started, so it
        /// never flashes for a frame or two before the wipe.
        public func cursorLit(at t: Double) -> Bool {
            let end = outStart(0)
            guard t >= Self.contentStart * timeScale, t < end else { return false }
            let lands = cursorLands
            guard t >= lands else { return true }
            let spell = ((t - lands) / Self.cursorBlink).rounded(.down)
            guard Int(spell) % 2 == 0 else { return false }
            let spellStart = lands + spell * Self.cursorBlink
            return spell == 0 || end - spellStart >= Self.cursorBlink / 2
        }

        /// When the card first hides the whole frame (the first band's right
        /// edge has passed it) and when the shot after it first shows (the
        /// last band's left edge comes in at the top). A cut in between is
        /// never seen. Nil when a card is too short to cover the frame.
        public var covered: ClosedRange<Double>? {
            let steps = 400
            func time(_ lower: Double, _ upper: Double, _ test: (Double) -> Bool) -> Double? {
                // The first time in lower...upper where test holds, to a
                // fraction of a frame.
                var previous = lower
                for step in 0...steps {
                    let t = lower + (upper - lower) * Double(step) / Double(steps)
                    if test(t) {
                        var a = previous, b = t
                        for _ in 0..<30 {
                            let m = (a + b) / 2
                            if test(m) { b = m } else { a = m }
                        }
                        return b
                    }
                    previous = t
                }
                return nil
            }
            let inStart = self.inStart(0)
            let outStart = self.outStart(2)
            // The first band's right edge is past the frame at the bottom
            // (its left-most point), or the sweep is over.
            guard let start = time(inStart, inStart + sweepLength, { t in
                guard let band = band(0, sweepStartingAt: inStart, at: t) else { return t >= inStart + sweepLength }
                return band.rightEdge(atY: aspect) >= 1
            }) else { return nil }
            // The last band's left edge is on the frame at the top (its
            // right-most point).
            let end = time(outStart, outStart + sweepLength, { t in
                guard let band = band(2, sweepStartingAt: outStart, at: t) else { return t >= outStart + sweepLength }
                return band.leftEdge(atY: 0) > 0
            }) ?? duration
            guard end > start else { return nil }
            return start...end
        }
    }
}

/// A CSS `cubic-bezier(x1, y1, x2, y2)` timing function.
public struct CubicBezier: Hashable, Sendable {
    public var x1: Double, y1: Double, x2: Double, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    /// The eased value at linear progress `x`, clamped to 0...1.
    public func value(at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        return curve(y1, y2, parameter(for: x))
    }

    private func curve(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    private func slope(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
    }

    /// The curve parameter whose x is `x`: Newton's method, then bisection
    /// where the slope is too flat, as browsers do.
    private func parameter(for x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let error = curve(x1, x2, t) - x
            if abs(error) < 1e-9 { return t }
            let d = slope(x1, x2, t)
            if abs(d) < 1e-6 { break }
            t -= error / d
        }
        var lower = 0.0, upper = 1.0
        t = x
        for _ in 0..<60 {
            let value = curve(x1, x2, t)
            if abs(value - x) < 1e-9 { return t }
            if value < x { lower = t } else { upper = t }
            t = (lower + upper) / 2
        }
        return t
    }
}

extension RGBA: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(r)
        hasher.combine(g)
        hasher.combine(b)
        hasher.combine(a)
    }
}

extension RGBA {
    /// From a 24-bit hex number like 0xF3B01C.
    public init(hex: Int, alpha: Double = 1) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255,
            a: alpha
        )
    }

    /// From "#F3B01C" or "F3B01C".
    public init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// "#F3B01C".
    public var hexString: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
