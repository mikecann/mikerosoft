import CoreGraphics
import CoreImage
import CoreText
import Foundation
import TandemCore

/// Graphic templates Tandem draws itself rather than from a rendered file.
enum BuiltInGraphics {
    static func renders(_ template: String) -> Bool {
        template == SectionCard.template
    }

    /// A graphic clip's frame at `clipTime`, the size of the canvas with its
    /// origin at 0, 0, or nil when nothing shows.
    static func image(_ graphic: GraphicContent, clipTime: Time, clipDuration: Time, canvas: CGSize) -> CIImage? {
        switch graphic.template {
        case SectionCard.template:
            return SectionCardRenderer.shared.image(SectionCard.Props(graphic.props), size: canvas, time: clipTime.seconds, duration: clipDuration.seconds)
        default:
            return nil
        }
    }
}

/// Frames of a section card, for previews such as the library tile and the
/// inspector. The same drawing the compositor uses.
public enum SectionCardArt {
    /// The card `time` seconds in, at `size` pixels; nil when nothing shows
    /// then.
    public static func image(_ props: SectionCard.Props, size: CGSize, time: Double, duration: Double = SectionCard.defaultDuration.seconds) -> CGImage? {
        let motion = SectionCard.Motion(duration: duration, aspect: size.height / max(size.width, 1))
        return SectionCardRenderer.shared.draw(props, size: size, motion: motion, time: time)
    }

    /// The card as it holds: every word in, the cursor lit, no bands.
    public static func still(_ props: SectionCard.Props, size: CGSize) -> CGImage? {
        let motion = SectionCard.Motion(duration: SectionCard.defaultDuration.seconds)
        return image(props, size: size, time: motion.cursorLands + 0.01)
    }
}

/// Draws Mike's section card with Core Graphics and Core Text at the
/// output size, so it's sharp at 4K and the viewer, frame grabs and export
/// all show the same frame. The design is card B of the title card mockup
/// (the bands) with card D's progress row; `SectionCard.Motion` has the
/// timing. Sizes are in cqw, a hundredth of the frame's width, as the
/// mockup's CSS has them.
///
/// The words are laid out and drawn once per card and size; each frame
/// fills the card, draws the words over it (fading and rising in) with the
/// cursor when it's lit, clips the card to where the wipes have got to,
/// and draws the bands on top. The hold, where only the cursor changes, is
/// drawn once with it lit and once without.
final class SectionCardRenderer: @unchecked Sendable {
    static let shared = SectionCardRenderer()

    private final class Key: NSObject {
        let props: SectionCard.Props
        let width: Int
        let height: Int
        /// For the hold: whether the cursor is lit.
        let lit: Bool

        init(_ props: SectionCard.Props, _ width: Int, _ height: Int, lit: Bool = false) {
            self.props = props
            self.width = width
            self.height = height
            self.lit = lit
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(props)
            hasher.combine(width)
            hasher.combine(height)
            hasher.combine(lit)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return other.props == props && other.width == width && other.height == height && other.lit == lit
        }
    }

    /// The words, chip and bars, and where the cursor goes (Core Graphics'
    /// way up).
    private final class Layer {
        let image: CGImage?
        let cursor: CGRect?
        init(_ image: CGImage?, cursor: CGRect?) {
            self.image = image
            self.cursor = cursor
        }
    }

    private final class Hold {
        let image: CIImage?
        init(_ image: CIImage?) { self.image = image }
    }

    private let layers: NSCache<Key, Layer> = {
        let cache = NSCache<Key, Layer>()
        cache.countLimit = 16
        return cache
    }()

    private let holds: NSCache<Key, Hold> = {
        let cache = NSCache<Key, Hold>()
        cache.countLimit = 16
        return cache
    }()

    /// The frame `t` seconds into a card `duration` long.
    func image(_ props: SectionCard.Props, size: CGSize, time t: Double, duration: Double) -> CIImage? {
        guard size.width >= 2, size.height >= 2 else { return nil }
        let motion = SectionCard.Motion(duration: duration, aspect: size.height / size.width)
        let reveal = motion.reveal(at: t)
        if !reveal.hidden, reveal == .whole, motion.bands(at: t).isEmpty, motion.contentProgress(at: t) >= 1 {
            let lit = props.cursor && motion.cursorLit(at: t)
            let key = Key(props, Int(size.width.rounded()), Int(size.height.rounded()), lit: lit)
            if let hit = holds.object(forKey: key) { return hit.image }
            let image = draw(props, size: size, motion: motion, time: t).map { CIImage(cgImage: $0) }
            holds.setObject(Hold(image), forKey: key)
            return image
        }
        return draw(props, size: size, motion: motion, time: t).map { CIImage(cgImage: $0) }
    }

    // MARK: - Drawing

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func color(_ rgba: RGBA) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [rgba.r, rgba.g, rgba.b, rgba.a].map { CGFloat($0) }) ?? CGColor(gray: 0, alpha: 1)
    }

    private static func context(_ width: Int, _ height: Int) -> CGContext? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setShouldSubpixelPositionFonts(true)
        context.setShouldSubpixelQuantizeFonts(false)
        context.interpolationQuality = .high
        return context
    }

    /// One frame, drawn from scratch.
    func draw(_ props: SectionCard.Props, size: CGSize, motion: SectionCard.Motion, time t: Double) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width >= 2, height >= 2, let context = Self.context(width, height) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let reveal = motion.reveal(at: t)
        if !reveal.hidden {
            context.saveGState()
            if let band = reveal.before { context.addPath(Self.region(leftOf: band, width: w, height: h)); context.clip() }
            if let band = reveal.after { context.addPath(Self.region(rightOf: band, width: w, height: h)); context.clip() }
            context.setFillColor(Self.color(props.colors.background))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let progress = motion.contentProgress(at: t)
            if progress > 0, let layer = contentLayer(props, width: width, height: height) {
                // CSS: opacity 0, translateY(2.5cqw), scale(.98) to none,
                // about the frame's centre.
                let scale = SectionCard.Motion.contentScale + (1 - SectionCard.Motion.contentScale) * progress
                let drop = SectionCard.Motion.contentRise * w * (1 - progress)
                context.setAlpha(CGFloat(min(max(progress, 0), 1)))
                context.translateBy(x: w / 2, y: h / 2 - drop)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -w / 2, y: -h / 2)
                if let image = layer.image { context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)) }
                // The cursor comes in with the words, then blinks.
                if props.cursor, let cursor = layer.cursor, motion.cursorLit(at: t) {
                    context.setFillColor(Self.color(props.colors.accent))
                    context.fill(cursor)
                }
            }
            context.restoreGState()
        }
        let colours = props.colors.bands
        for (index, band) in motion.bands(at: t) {
            context.addPath(Self.band(band, width: w, height: h))
            context.setFillColor(Self.color(colours[index]))
            context.fillPath()
        }
        return context.makeImage()
    }

    /// x of a band's left edge at `y` points up from the bottom (Core
    /// Graphics' way up): the top leans right.
    private static func edge(_ band: SectionCard.Motion.Band, width w: CGFloat, height h: CGFloat, y: CGFloat) -> CGFloat {
        w * CGFloat(band.left - band.lean / 2) + w * CGFloat(band.lean) * y / h
    }

    /// A little past the frame, so edges run off it.
    private static let margin: CGFloat = 4

    static func band(_ band: SectionCard.Motion.Band, width w: CGFloat, height h: CGFloat) -> CGPath {
        let bottom = -margin, top = h + margin
        let x0 = edge(band, width: w, height: h, y: bottom), x1 = edge(band, width: w, height: h, y: top)
        let bandWidth = w * CGFloat(SectionCard.Motion.bandWidth)
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: x0, y: bottom), CGPoint(x: x0 + bandWidth, y: bottom),
            CGPoint(x: x1 + bandWidth, y: top), CGPoint(x: x1, y: top)
        ])
        path.closeSubpath()
        return path
    }

    static func region(leftOf band: SectionCard.Motion.Band, width w: CGFloat, height h: CGFloat) -> CGPath {
        let bottom = -margin, top = h + margin
        let far = -w - margin
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: far, y: bottom), CGPoint(x: edge(band, width: w, height: h, y: bottom), y: bottom),
            CGPoint(x: edge(band, width: w, height: h, y: top), y: top), CGPoint(x: far, y: top)
        ])
        path.closeSubpath()
        return path
    }

    static func region(rightOf band: SectionCard.Motion.Band, width w: CGFloat, height h: CGFloat) -> CGPath {
        let bottom = -margin, top = h + margin
        let far = 2 * w + margin
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: edge(band, width: w, height: h, y: bottom), y: bottom), CGPoint(x: far, y: bottom),
            CGPoint(x: far, y: top), CGPoint(x: edge(band, width: w, height: h, y: top), y: top)
        ])
        path.closeSubpath()
        return path
    }

    /// The words, chip and progress bars on a clear layer the size of the
    /// frame, drawn once per card and size, with where the cursor goes.
    private func contentLayer(_ props: SectionCard.Props, width: Int, height: Int) -> Layer? {
        let key = Key(props, width, height)
        if let hit = layers.object(forKey: key) { return hit }
        let layout = SectionCardLayout(props, size: CGSize(width: width, height: height))
        var image: CGImage?
        if let context = Self.context(width, height) {
            layout.draw(in: context)
            image = context.makeImage()
        }
        let cursor = layout.cursor.map { CGRect(x: $0.minX, y: CGFloat(height) - $0.maxY, width: $0.width, height: $0.height) }
        let layer = Layer(image, cursor: cursor)
        layers.setObject(layer, forKey: key)
        return layer
    }
}

/// Where the card's words, chip and progress bars go, in pixels from the
/// top left: the mockup's CSS for card B, with card D's kicker beside the
/// chip and its progress row under the subtitle.
///
/// ```
/// .b-content  grid, centred both ways, rows 1.6cqw apart
/// .b-num      JetBrains Mono 700 1.6cqw/1, letter-spacing .08em,
///             padding .55cqw 1cqw, radius .5cqw, accent on the card colour
/// .d-kicker   Instrument Sans 600 1.45cqw/1, letter-spacing .2em, #d9dce1,
///             1.4cqw right of the chip, centred on it
/// .b-title    Anton 9.4cqw/.95, letter-spacing .01em, white, at most
///             84cqw wide, lines balanced
/// .b-sub      Instrument Sans 600 1.7cqw/1, letter-spacing .34em (and the
///             same padding on the left, so it's centred), accent
/// .d-progress .6cqw further down; bars .35cqw by 5cqw, .6cqw apart, lit
///             ones accent, the rest white at 28%; past six sections a
///             30cqw bar in proportion and the count, JetBrains Mono 500
///             1.5cqw, #cfd3d9
/// ```
///
/// Everything but the title is upper case. The progress row centres its
/// bars on the count, where D's CSS left them at the top of the row.
struct SectionCardLayout {
    struct Text {
        enum Role: Equatable { case number, kicker, title, subtitle, count }
        var role: Role
        var string: String
        var line: CTLine
        /// Where the line starts, and its baseline, from the top left.
        var x: CGFloat
        var baseline: CGFloat
        /// Its width, letter-spacing after the last character included.
        var width: CGFloat
    }

    struct Box {
        var rect: CGRect
        var radius: CGFloat
        var color: CGColor
    }

    let size: CGSize
    private(set) var boxes: [Box] = []
    private(set) var texts: [Text] = []
    /// The cursor after the title's last letter, from the top left: a bar
    /// in the accent colour from the baseline up to the capitals' height,
    /// `cursorGap` after the letter (and its letter-spacing). Nil when the
    /// card has no title or its cursor is off. The renderer blinks it.
    private(set) var cursor: CGRect?
    /// The content's bounds (the cursor left out), for tests.
    private(set) var bounds: CGRect = .null

    static let kickerColor = RGBA(hex: 0xD9DCE1)
    static let countColor = RGBA(hex: 0xCFD3D9)
    static let unlitColor = RGBA(r: 1, g: 1, b: 1, a: 0.28)
    /// The cursor's width and the gap before it, in ems of the title.
    static let cursorWidth: CGFloat = 0.1
    static let cursorGap: CGFloat = 0.07

    /// One row of the grid, laid out with its top at 0.
    private struct Row {
        var height: CGFloat
        var marginTop: CGFloat = 0
        var boxes: [Box] = []
        var texts: [Text] = []
        var cursor: CGRect?
    }

    init(_ props: SectionCard.Props, size: CGSize) {
        self.size = size
        let w = size.width, h = size.height
        let u = w / 100
        let colours = props.colors
        let accent = SectionCardRenderer.color(colours.accent)
        var rows: [Row] = []

        // The chip and the kicker.
        let number = props.number.trimmingCharacters(in: .whitespacesAndNewlines)
        let kicker = props.kickerLine?.uppercased()
        if !number.isEmpty || kicker != nil {
            var row = Row(height: 0)
            var x: CGFloat = 0
            var items: [(width: CGFloat, height: CGFloat, place: (CGFloat, CGFloat) -> ([Box], [Text]))] = []
            if !number.isEmpty {
                let size = 1.6 * u
                let font = CardFonts.mono(size, weight: 700)
                let (line, width) = Self.line(number, font: font, spacing: 0.08 * size, color: SectionCardRenderer.color(colours.background))
                let chip = CGSize(width: width + 2 * u, height: size + 1.1 * u)
                items.append((chip.width, chip.height, { left, top in
                    let box = Box(rect: CGRect(x: left, y: top, width: chip.width, height: chip.height), radius: 0.5 * u, color: accent)
                    let text = Text(role: .number, string: number, line: line, x: left + u, baseline: Self.baseline(top: top + 0.55 * u, lineHeight: size, font: font), width: width)
                    return ([box], [text])
                }))
            }
            if let kicker {
                let size = 1.45 * u
                let font = CardFonts.sans(size, weight: 600)
                let (line, width) = Self.line(kicker, font: font, spacing: 0.2 * size, color: SectionCardRenderer.color(Self.kickerColor))
                items.append((width, size, { left, top in
                    ([], [Text(role: .kicker, string: kicker, line: line, x: left, baseline: Self.baseline(top: top, lineHeight: size, font: font), width: width)])
                }))
            }
            let gap = 1.4 * u
            let rowWidth = items.map(\.width).reduce(0, +) + gap * CGFloat(max(0, items.count - 1))
            row.height = items.map(\.height).max() ?? 0
            x = (w - rowWidth) / 2
            for item in items {
                let (boxes, texts) = item.place(x, (row.height - item.height) / 2)
                row.boxes += boxes
                row.texts += texts
                x += item.width + gap
            }
            rows.append(row)
        }

        // The title, balanced over as many lines as it needs.
        let title = props.title.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !title.isEmpty {
            let size = 9.4 * u
            let font = CardFonts.title(size)
            let lineHeight = 0.95 * size
            let spacing = 0.01 * size
            let white = SectionCardRenderer.color(.white)
            var row = Row(height: 0)
            for text in Self.wrap(title, font: font, spacing: spacing, maxWidth: 84 * u, balanced: true) {
                let (line, width) = Self.line(text, font: font, spacing: spacing, color: white)
                row.texts.append(Text(role: .title, string: text, line: line, x: (w - width) / 2, baseline: Self.baseline(top: row.height, lineHeight: lineHeight, font: font), width: width))
                row.height += lineHeight
            }
            // The cursor hangs after the last line, which stays centred as
            // the mockup has it, so the words don't shift as it blinks.
            if props.cursor, let last = row.texts.last {
                let capHeight = CTFontGetCapHeight(font)
                row.cursor = CGRect(
                    x: last.x + last.width + Self.cursorGap * size,
                    y: last.baseline - capHeight,
                    width: Self.cursorWidth * size,
                    height: capHeight
                )
            }
            rows.append(row)
        }

        // The subtitle, letter-spaced, with the same space on its left so
        // the words sit in the middle.
        let subtitle = props.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !subtitle.isEmpty {
            let size = 1.7 * u
            let font = CardFonts.sans(size, weight: 600)
            let spacing = 0.34 * size
            var row = Row(height: 0)
            for text in Self.wrap(subtitle, font: font, spacing: spacing, maxWidth: 84 * u, balanced: false) {
                let (line, width) = Self.line(text, font: font, spacing: spacing, color: accent)
                let box = spacing + width
                row.texts.append(Text(role: .subtitle, string: text, line: line, x: (w - box) / 2 + spacing, baseline: Self.baseline(top: row.height, lineHeight: size, font: font), width: width))
                row.height += size
            }
            rows.append(row)
        }

        // Card D's progress row.
        if let progress = props.progress {
            let barHeight = 0.35 * u
            let gap = 0.6 * u
            let unlit = SectionCardRenderer.color(Self.unlitColor)
            var bars: [(width: CGFloat, color: CGColor)] = []
            var count: (text: String, line: CTLine, width: CGFloat, font: CTFont, size: CGFloat)?
            switch progress {
            case .bars(let total, let lit):
                bars = (1...total).map { (5 * u, $0 <= lit ? accent : unlit) }
            case .proportional(let index, let total):
                bars = [
                    (CGFloat(index) / CGFloat(total) * 30 * u, accent),
                    (CGFloat(total - index) / CGFloat(total) * 30 * u, unlit)
                ]
                if let text = progress.countText {
                    let size = 1.5 * u
                    let font = CardFonts.mono(size, weight: 500)
                    let (line, width) = Self.line(text, font: font, spacing: 0, color: SectionCardRenderer.color(Self.countColor))
                    count = (text, line, width, font, size)
                }
            }
            var row = Row(height: max(barHeight, count?.size ?? 0), marginTop: 0.6 * u)
            let items = bars.count + (count == nil ? 0 : 1)
            let rowWidth = bars.map(\.width).reduce(0, +) + (count?.width ?? 0) + gap * CGFloat(max(0, items - 1))
            var x = (w - rowWidth) / 2
            for bar in bars {
                let rect = CGRect(x: x, y: (row.height - barHeight) / 2, width: bar.width, height: barHeight)
                row.boxes.append(Box(rect: rect, radius: min(u, barHeight / 2), color: bar.color))
                x += bar.width + gap
            }
            if let count {
                row.texts.append(Text(role: .count, string: count.text, line: count.line, x: x, baseline: Self.baseline(top: (row.height - count.size) / 2, lineHeight: count.size, font: count.font), width: count.width))
            }
            rows.append(row)
        }

        // The rows, 1.6cqw apart, as a block in the middle of the frame.
        let rowGap = 1.6 * u
        let total = rows.enumerated().reduce(CGFloat(0)) { sum, item in
            sum + item.element.height + item.element.marginTop + (item.offset > 0 ? rowGap : 0)
        }
        var top = (h - total) / 2
        for (index, row) in rows.enumerated() {
            if index > 0 { top += rowGap }
            top += row.marginTop
            for var box in row.boxes {
                box.rect.origin.y += top
                boxes.append(box)
                bounds = bounds.union(box.rect)
            }
            for var text in row.texts {
                text.baseline += top
                texts.append(text)
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                CTLineGetTypographicBounds(text.line, &ascent, &descent, &leading)
                bounds = bounds.union(CGRect(x: text.x, y: text.baseline - ascent, width: text.width, height: ascent + descent))
            }
            if let rect = row.cursor { cursor = rect.offsetBy(dx: 0, dy: top) }
            top += row.height
        }
    }

    /// Draws the chip, bars and words (Core Graphics' way up).
    func draw(in context: CGContext) {
        let h = size.height
        for box in boxes {
            let rect = CGRect(x: box.rect.minX, y: h - box.rect.maxY, width: box.rect.width, height: box.rect.height)
            let radius = min(box.radius, rect.width / 2, rect.height / 2)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(box.color)
            context.fillPath()
        }
        for text in texts {
            context.textPosition = CGPoint(x: text.x, y: h - text.baseline)
            CTLineDraw(text.line, context)
        }
    }

    // MARK: - Text

    private static func attributed(_ text: String, font: CTFont, spacing: CGFloat, color: CGColor?) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): spacing
        ]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// A line of text and its width. Like CSS letter-spacing, the spacing
    /// follows every character, the last one too.
    static func line(_ text: String, font: CTFont, spacing: CGFloat, color: CGColor) -> (CTLine, CGFloat) {
        let line = CTLineCreateWithAttributedString(attributed(text, font: font, spacing: spacing, color: color))
        return (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// Where the baseline sits in a CSS line box: the font's ascent and
    /// descent centred in the line height (half-leading either side).
    static func baseline(top: CGFloat, lineHeight: CGFloat, font: CTFont) -> CGFloat {
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        return top + (lineHeight - (ascent + descent)) / 2 + ascent
    }

    /// Lines of at most `maxWidth`, broken between words. Balanced, like CSS
    /// `text-wrap: balance`, finds the narrowest width that needs no more
    /// lines, so a two-line title isn't one long line and one word.
    static func wrap(_ text: String, font: CTFont, spacing: CGFloat, maxWidth: CGFloat, balanced: Bool) -> [String] {
        text.components(separatedBy: "\n").flatMap { paragraph -> [String] in
            let words = paragraph.trimmingCharacters(in: .whitespaces)
            guard !words.isEmpty else { return [] }
            let typesetter = CTTypesetterCreateWithAttributedString(attributed(words, font: font, spacing: spacing, color: nil))
            let string = words as NSString
            func lines(_ width: CGFloat) -> [String] {
                var result: [String] = []
                var start = 0
                while start < string.length {
                    let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                    guard count > 0 else { break }
                    let piece = string.substring(with: NSRange(location: start, length: count)).trimmingCharacters(in: .whitespaces)
                    if !piece.isEmpty { result.append(piece) }
                    start += count
                }
                return result
            }
            let greedy = lines(maxWidth)
            guard balanced, greedy.count > 1 else { return greedy }
            var low = maxWidth / CGFloat(greedy.count + 1), high = maxWidth
            var best = greedy
            for _ in 0..<24 {
                let middle = (low + high) / 2
                let attempt = lines(middle)
                if attempt.count <= greedy.count {
                    best = attempt
                    high = middle
                } else {
                    low = middle
                }
            }
            return best
        }
    }
}
