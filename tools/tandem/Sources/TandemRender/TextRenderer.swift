import CoreGraphics
import CoreImage
import CoreText
import Foundation
import TandemCore

/// Draws text clips with Core Text into images the compositor places like
/// any other layer. Images are cached per content, size and animation state,
/// so a title costs a draw when it changes, not every frame.
final class TextRenderer: @unchecked Sendable {
    static let shared = TextRenderer()

    private init() {
        // A font registered anywhere in this process (a project's own, one
        // the asset library downloaded) may be one a cached title fell back
        // from, so the cache starts again.
        NotificationCenter.default.addObserver(
            forName: Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String), object: nil, queue: nil
        ) { [weak self] _ in
            self?.forgetDrawings()
        }
    }

    /// Everything that changes the drawn pixels. Sizes are output pixels.
    struct Request: Hashable {
        var text: String
        var font: String
        var size: Double
        var weight: Double
        var color: [Double]
        var strokeColor: [Double]?
        var strokeWidth: Double
        var backgroundColor: [Double]?
        var alignment: String
        var shadow: Bool
        var lineSpacing: Double
        /// Lines wrap at this width.
        var maxWidth: Double
        /// UTF-16 range drawn in `highlightColor` (the word being spoken).
        var highlight: Range<Int>?
        var highlightColor: [Double]
        /// Typewriter: UTF-16 length of the visible prefix, nil for all.
        var visibleLength: Int?
        var firstLineScale: Double
        var firstLineColor: [Double]?
    }

    private final class Key: NSObject {
        let request: Request
        init(_ request: Request) { self.request = request }
        override var hash: Int { request.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? Key)?.request == request }
    }

    private final class Box {
        let image: CIImage
        init(_ image: CIImage) { self.image = image }
    }

    private let cache: NSCache<Key, Box> = {
        let cache = NSCache<Key, Box>()
        cache.countLimit = 96
        cache.totalCostLimit = 384 * 1024 * 1024
        return cache
    }()

    /// Drops every cached drawing, for when the fonts they were drawn with
    /// may have changed.
    func forgetDrawings() {
        cache.removeAllObjects()
    }

    /// The text as an image with its origin at 0, 0, or nil for empty text.
    func image(_ request: Request) -> CIImage? {
        let key = Key(request)
        if let hit = cache.object(forKey: key) { return hit.image }
        guard let cg = Self.draw(request) else { return nil }
        let image = CIImage(cgImage: cg)
        cache.setObject(Box(image), forKey: key, cost: cg.bytesPerRow * cg.height)
        return image
    }

    // MARK: - Drawing

    static func draw(_ r: Request) -> CGImage? {
        guard !r.text.isEmpty, r.size > 0 else { return nil }
        let string = r.text as NSString
        let full = NSRange(location: 0, length: string.length)
        let font = makeFont(r.font, size: r.size, weight: r.weight)
        let firstLine = string.range(of: "\n").location == NSNotFound
            ? full
            : NSRange(location: 0, length: string.range(of: "\n").location)
        let hidden = r.visibleLength.map { NSRange(location: min($0, string.length), length: max(0, string.length - $0)) }

        func attributed(stroke: Bool) -> NSAttributedString {
            let text = NSMutableAttributedString(string: r.text)
            text.addAttribute(key(kCTFontAttributeName), value: font, range: full)
            if r.firstLineScale != 1 && firstLine.length < full.length {
                let smaller = makeFont(r.font, size: r.size * r.firstLineScale, weight: r.weight)
                text.addAttribute(key(kCTFontAttributeName), value: smaller, range: firstLine)
            }
            if stroke {
                // Positive width strokes without filling. It's doubled because
                // the fill drawn on top covers the inner half.
                let percent = 2 * r.strokeWidth / r.size * 100
                text.addAttribute(key(kCTStrokeWidthAttributeName), value: percent, range: full)
                text.addAttribute(key(kCTStrokeColorAttributeName), value: cgColor(r.strokeColor ?? [0, 0, 0, 1]), range: full)
                if let hidden { text.addAttribute(key(kCTStrokeColorAttributeName), value: cgColor([0, 0, 0, 0]), range: hidden) }
            } else {
                text.addAttribute(key(kCTForegroundColorAttributeName), value: cgColor(r.color), range: full)
                if let colour = r.firstLineColor, firstLine.length < full.length {
                    text.addAttribute(key(kCTForegroundColorAttributeName), value: cgColor(colour), range: firstLine)
                }
                if let h = r.highlight, h.lowerBound >= 0, h.upperBound <= string.length {
                    text.addAttribute(key(kCTForegroundColorAttributeName), value: cgColor(r.highlightColor), range: NSRange(location: h.lowerBound, length: h.count))
                }
                if let hidden { text.addAttribute(key(kCTForegroundColorAttributeName), value: cgColor([0, 0, 0, 0]), range: hidden) }
            }
            return text
        }

        // Break lines once, on the fill text, and reuse the ranges for the
        // stroke so both passes line up.
        let fillTypesetter = CTTypesetterCreateWithAttributedString(attributed(stroke: false))
        var ranges: [CFRange] = []
        var start = 0
        while start < string.length {
            let count = CTTypesetterSuggestLineBreak(fillTypesetter, start, max(r.maxWidth, r.size))
            if count <= 0 { break }
            ranges.append(CFRange(location: start, length: count))
            start += count
        }
        if string.hasSuffix("\n") { ranges.append(CFRange(location: string.length, length: 0)) }
        let fills = ranges.map { CTTypesetterCreateLine(fillTypesetter, $0) }
        let strokeTypesetter = r.strokeWidth > 0 && r.strokeColor != nil ? CTTypesetterCreateWithAttributedString(attributed(stroke: true)) : nil
        let strokes = strokeTypesetter.map { t in ranges.map { CTTypesetterCreateLine(t, $0) } }

        struct Metrics { var ascent: CGFloat; var descent: CGFloat; var width: CGFloat }
        let fallbackAscent = CTFontGetAscent(font)
        let fallbackDescent = CTFontGetDescent(font)
        let metrics: [Metrics] = fills.map { line in
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            if CTLineGetGlyphCount(line) == 0 {
                return Metrics(ascent: fallbackAscent, descent: fallbackDescent, width: 0)
            }
            return Metrics(ascent: ascent, descent: descent, width: max(0, width))
        }
        guard !metrics.isEmpty else { return nil }

        let gap = CGFloat(r.lineSpacing * r.size)
        let blockWidth = metrics.map(\.width).max() ?? 0
        let blockHeight = metrics.reduce(0) { $0 + $1.ascent + $1.descent } + gap * CGFloat(metrics.count - 1)
        let size = CGFloat(r.size)
        let boxX: CGFloat = r.backgroundColor != nil ? size * 0.35 : 0
        let boxY: CGFloat = r.backgroundColor != nil ? size * 0.18 : 0
        let shadowPad: CGFloat = r.shadow ? size * 0.3 : 0
        let pad = ceil(CGFloat(r.strokeWidth) + shadowPad + 2)
        let width = Int(ceil(blockWidth + 2 * boxX + 2 * pad))
        let height = Int(ceil(blockHeight + 2 * boxY + 2 * pad))
        guard width > 0, height > 0, width < 16_384, height < 16_384,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setLineJoin(.round)
        context.setAllowsFontSmoothing(false)
        let shadowOffset = CGSize(width: 0, height: -size * 0.04)
        let shadowBlur = size * 0.12
        let shadowColour = cgColor([0, 0, 0, 0.6])

        if let background = r.backgroundColor {
            let box = CGRect(x: pad, y: pad, width: blockWidth + 2 * boxX, height: blockHeight + 2 * boxY)
            context.saveGState()
            if r.shadow { context.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColour) }
            context.setFillColor(cgColor(background))
            context.addPath(CGPath(roundedRect: box, cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil))
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        if r.shadow && r.backgroundColor == nil {
            context.setShadow(offset: shadowOffset, blur: shadowBlur, color: shadowColour)
            // One transparency layer so the stroke and fill cast one shadow.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        var top = CGFloat(height) - pad - boxY
        for (i, line) in fills.enumerated() {
            let m = metrics[i]
            let x: CGFloat
            switch r.alignment.lowercased() {
            case "left", "leading": x = pad + boxX
            case "right", "trailing": x = pad + boxX + blockWidth - m.width
            default: x = pad + boxX + (blockWidth - m.width) / 2
            }
            let baseline = top - m.ascent
            if let strokes {
                context.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(strokes[i], context)
            }
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            top -= m.ascent + m.descent + gap
        }
        if r.shadow && r.backgroundColor == nil { context.endTransparencyLayer() }
        context.restoreGState()
        return context.makeImage()
    }

    private static func key(_ name: CFString) -> NSAttributedString.Key {
        NSAttributedString.Key(name as String)
    }

    static func cgColor(_ c: [Double]) -> CGColor {
        let v = c.count == 4 ? c : [0, 0, 0, 1]
        return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: v.map { CGFloat($0) }) ?? CGColor(gray: 0, alpha: 1)
    }

    // MARK: - Fonts

    /// CSS-style weights (100 thin ... 900 black) to Core Text weight traits.
    static func weightTrait(_ weight: Double) -> CGFloat {
        let table: [(Double, CGFloat)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        if weight <= table[0].0 { return table[0].1 }
        for (a, b) in zip(table, table.dropFirst()) where weight <= b.0 {
            let f = CGFloat((weight - a.0) / (b.0 - a.0))
            return a.1 + (b.1 - a.1) * f
        }
        return table.last!.1
    }

    private static let systemNames: Set<String> = ["", "system", "system-ui", "-apple-system", "sf pro", "sf pro display", "sf pro text", "san francisco"]

    /// True for the names that mean the system font (SF Pro).
    static func isSystemName(_ name: String) -> Bool {
        systemNames.contains(name.lowercased())
    }

    /// The named family at the nearest weight, or the system font (SF Pro)
    /// when the family isn't installed.
    static func makeFont(_ name: String, size: Double, weight: Double) -> CTFont {
        if !isSystemName(name), let font = installedFont(name, size: size, weight: weight) { return font }
        let traits = [kCTFontWeightTrait: weightTrait(weight)] as CFDictionary
        let system = CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil) ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(size), nil)
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(system), [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, CGFloat(size), nil)
    }

    /// The named font at the nearest weight, looked up as a family and then
    /// as a PostScript or full name ("Kanit-Bold"). Nil when this process
    /// can't draw it: it isn't installed or registered.
    static func installedFont(_ name: String, size: Double, weight: Double) -> CTFont? {
        let traits = [kCTFontWeightTrait: weightTrait(weight)] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: name,
            kCTFontTraitsAttribute: traits
        ] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(size), nil)
        if (CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(name) == .orderedSame {
            return font
        }
        let named = CTFontCreateWithName(name as CFString, CGFloat(size), nil)
        let names = [CTFontCopyPostScriptName(named), CTFontCopyFullName(named)].map { $0 as String }
        if names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return named
        }
        return nil
    }
}

/// How a text clip moves at a moment: the in and out animations.
struct TextAnimationState: Equatable {
    var opacity = 1.0
    var scale = 1.0
    /// Vertical offset as a fraction of the canvas height, down positive.
    var offsetY = 0.0
    /// Typewriter: how much of the text is showing.
    var visibleFraction = 1.0

    static func at(_ clipTime: Time, clipDuration: Time, text: ResolvedText) -> TextAnimationState {
        var state = TextAnimationState()
        let length = min(text.animationDuration.seconds, clipDuration.seconds / 2)
        guard length > 0 else { return state }
        let entering = clipTime.seconds / length
        let leaving = (clipDuration - clipTime).seconds / length
        if let animation = text.animationIn, entering < 1 {
            state.apply(animation, progress: max(entering, 0), entering: true)
        }
        if let animation = text.animationOut, leaving < 1 {
            state.apply(animation, progress: max(leaving, 0), entering: false)
        }
        return state
    }

    /// `progress` runs 0 (hidden) to 1 (fully in) both ways.
    private mutating func apply(_ animation: TextAnimation, progress p: Double, entering: Bool) {
        switch animation {
        case .fade:
            opacity *= Easing.apply(.easeInOut, p)
        case .pop:
            scale *= Self.easeOutBack(p)
            opacity *= min(1, p * 4)
        case .slideUp:
            let eased = 1 - pow(1 - p, 3)
            offsetY += (entering ? 1 : -1) * (1 - eased) * 0.06
            opacity *= eased
        case .typewriter:
            visibleFraction = min(visibleFraction, p)
        }
    }

    /// Overshoots to about 1.1 before settling at 1.
    static func easeOutBack(_ p: Double) -> Double {
        let c1 = 1.70158
        let c3 = c1 + 1
        let x = min(max(p, 0), 1) - 1
        return 1 + c3 * x * x * x + c1 * x * x
    }
}
