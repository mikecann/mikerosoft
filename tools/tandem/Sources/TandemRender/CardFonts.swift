import CoreText
import Foundation

/// The section card's typefaces, which ship with Tandem (SIL Open Font
/// Licence, the licences beside them in `Resources/Fonts`): Anton for the
/// title, Instrument Sans for the subtitle and the kicker, JetBrains Mono
/// for the number and the count. They're read from the resource bundle
/// straight into font descriptors, so nothing is installed and every
/// process (the app, the CLI, tests, another Mac) draws the card the same.
/// When the bundle can't be found the card falls back to faces macOS has:
/// Impact, the system font and SF Mono or Menlo.
enum CardFonts {
    private final class Marker {}

    /// The fonts' folder in the resource bundle, wherever it sits: an
    /// app's Resources (the app, and the CLI inside it), beside the
    /// executable (a `swift build` binary), or beside a test bundle.
    static let folder: URL? = {
        let name = "Tandem_TandemRender.bundle"
        var candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle(for: Marker.self).resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()
        ]
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] {
            candidates.insert(URL(fileURLWithPath: override).deletingLastPathComponent(), at: 0)
        }
        for candidate in candidates.compactMap({ $0 }) {
            for bundle in [candidate.appendingPathComponent(name), candidate.appendingPathComponent("Contents/Resources").appendingPathComponent(name)] {
                for fonts in [bundle.appendingPathComponent("Fonts"), bundle.appendingPathComponent("Contents/Resources/Fonts")] {
                    if FileManager.default.fileExists(atPath: fonts.appendingPathComponent("Anton-Regular.ttf").path) { return fonts }
                }
            }
        }
        return nil
    }()

    private static func descriptor(_ file: String) -> CTFontDescriptor? {
        guard let url = folder?.appendingPathComponent(file), let data = try? Data(contentsOf: url) else { return nil }
        let list = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]
        return list?.first
    }

    private static let anton = descriptor("Anton-Regular.ttf")
    private static let instrumentSans = descriptor("InstrumentSans-Variable.ttf")
    private static let jetBrainsMono = descriptor("JetBrainsMono-Variable.ttf")

    /// True when the bundled faces are there (tests check it).
    static var bundled: Bool { anton != nil && instrumentSans != nil && jetBrainsMono != nil }

    /// The 'wght' variation axis.
    private static let weightAxis = 0x7767_6874

    private static func variable(_ base: CTFontDescriptor, weight: Double, size: CGFloat) -> CTFont {
        let weighted = CTFontDescriptorCreateCopyWithVariation(base, weightAxis as CFNumber, CGFloat(weight))
        return CTFontCreateWithFontDescriptor(weighted, size, nil)
    }

    /// Anton, for the title (Impact without it).
    static func title(_ size: CGFloat) -> CTFont {
        if let anton { return CTFontCreateWithFontDescriptor(anton, size, nil) }
        for name in ["Impact", "HelveticaNeue-CondensedBlack"] {
            let font = CTFontCreateWithName(name as CFString, size, nil)
            if (CTFontCopyPostScriptName(font) as String) == name { return font }
        }
        return TextRenderer.makeFont("system", size: Double(size), weight: 900)
    }

    /// Instrument Sans at a CSS weight (the system font without it).
    static func sans(_ size: CGFloat, weight: Double) -> CTFont {
        if let instrumentSans { return variable(instrumentSans, weight: weight, size: size) }
        return TextRenderer.makeFont("system", size: Double(size), weight: weight)
    }

    /// JetBrains Mono at a CSS weight (SF Mono or Menlo without it).
    static func mono(_ size: CGFloat, weight: Double) -> CTFont {
        if let jetBrainsMono { return variable(jetBrainsMono, weight: weight, size: size) }
        let name = weight >= 600 ? "SFMono-Bold" : "SFMono-Medium"
        let font = CTFontCreateWithName(name as CFString, size, nil)
        if (CTFontCopyPostScriptName(font) as String) == name { return font }
        return CTFontCreateWithName((weight >= 600 ? "Menlo-Bold" : "Menlo-Regular") as CFString, size, nil)
    }
}
