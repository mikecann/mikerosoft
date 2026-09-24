import Foundation

struct PrompterSettings: Equatable {
    enum Alignment: String, Codable, CaseIterable {
        case leading
        case center
    }

    static let fontSizeRange: ClosedRange<Double> = 20...200
    static let lineSpacingRange: ClosedRange<Double> = 0...60
    static let itemSpacingRange: ClosedRange<Double> = 0...120
    static let sideMarginRange: ClosedRange<Double> = 0...400
    static let readingLineRange: ClosedRange<Double> = 0.1...0.9
    static let opacityRange: ClosedRange<Double> = 0.1...1
    static let scrollSpeedRange: ClosedRange<Double> = 5...500

    var fontSize: Double = 56
    var lineSpacing: Double = 8
    var itemSpacing: Double = 28
    var sideMargin: Double = 60
    var alignment: Alignment = .leading
    var textColor = "#FFFFFF"
    var backgroundColor = "#000000"
    var highlightColor = "#FFC933"
    /// How bright upcoming lines are. Lines already read are dimmer still.
    var upcomingOpacity: Double = 0.5
    /// Where the current line sits, as a fraction of the window height.
    var readingLine: Double = 0.35
    var showReadingMarker = true
    var mirrorHorizontally = false
    /// Auto-scroll speed in points per second.
    var scrollSpeed: Double = 60
    /// Page Up / Page Down (what presentation clickers send) work in any app.
    var clickerKeysGlobal = true
    /// ⌃⌥← / ⌃⌥→ / ⌃⌥Space work in any app.
    var globalShortcuts = true
    var keepOnTop = false
    /// Jump to the Elgato Prompter whenever it is switched on.
    var followPrompter = true

    static let defaults = PrompterSettings()

    func clamped() -> PrompterSettings {
        var copy = self
        copy.fontSize = fontSize.clamped(to: Self.fontSizeRange)
        copy.lineSpacing = lineSpacing.clamped(to: Self.lineSpacingRange)
        copy.itemSpacing = itemSpacing.clamped(to: Self.itemSpacingRange)
        copy.sideMargin = sideMargin.clamped(to: Self.sideMarginRange)
        copy.readingLine = readingLine.clamped(to: Self.readingLineRange)
        copy.upcomingOpacity = upcomingOpacity.clamped(to: Self.opacityRange)
        copy.scrollSpeed = scrollSpeed.clamped(to: Self.scrollSpeedRange)
        return copy
    }

    private static let storageKey = "settings.v1"

    static func load(from defaults: UserDefaults = .standard) -> PrompterSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(PrompterSettings.self, from: data)
        else { return .defaults }
        return settings.clamped()
    }

    static func save(_ settings: PrompterSettings, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

extension PrompterSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case fontSize, lineSpacing, itemSpacing, sideMargin, alignment
        case textColor, backgroundColor, highlightColor, upcomingOpacity
        case readingLine, showReadingMarker, mirrorHorizontally, scrollSpeed
        case clickerKeysGlobal, globalShortcuts, keepOnTop, followPrompter
    }

    // Every key is optional so settings saved by an older build still load
    // after new options are added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PrompterSettings.defaults
        func value<T: Decodable>(_ key: CodingKeys, _ defaultValue: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? defaultValue
        }
        fontSize = value(.fontSize, fallback.fontSize)
        lineSpacing = value(.lineSpacing, fallback.lineSpacing)
        itemSpacing = value(.itemSpacing, fallback.itemSpacing)
        sideMargin = value(.sideMargin, fallback.sideMargin)
        alignment = value(.alignment, fallback.alignment)
        textColor = value(.textColor, fallback.textColor)
        backgroundColor = value(.backgroundColor, fallback.backgroundColor)
        highlightColor = value(.highlightColor, fallback.highlightColor)
        upcomingOpacity = value(.upcomingOpacity, fallback.upcomingOpacity)
        readingLine = value(.readingLine, fallback.readingLine)
        showReadingMarker = value(.showReadingMarker, fallback.showReadingMarker)
        mirrorHorizontally = value(.mirrorHorizontally, fallback.mirrorHorizontally)
        scrollSpeed = value(.scrollSpeed, fallback.scrollSpeed)
        clickerKeysGlobal = value(.clickerKeysGlobal, fallback.clickerKeysGlobal)
        globalShortcuts = value(.globalShortcuts, fallback.globalShortcuts)
        keepOnTop = value(.keepOnTop, fallback.keepOnTop)
        followPrompter = value(.followPrompter, fallback.followPrompter)
    }
}

enum HexColor {
    static func components(_ hex: String) -> [Double]? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return [
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255,
        ]
    }

    static func string(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((value.clamped(to: 0...1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
