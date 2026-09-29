import CoreText
import Foundation
import TandemCore
import TandemMedia

/// A font some titles name that this process can't draw, so they fall back
/// to the system font (SF Pro).
public struct MissingFont: Equatable, Sendable {
    /// As the titles name it: a family, PostScript or full name.
    public var name: String
    /// The text clips that use it, in timeline order per track.
    public var clipIDs: [String]
    /// The built-in preset the font comes from, when the titles have it
    /// from their preset rather than naming it themselves.
    public var presetID: String?
    /// The asset library ID that installs it (`fontsource:tilt-warp`): the
    /// preset's own, or the Fontsource name the font's name suggests.
    public var assetID: String

    public init(name: String, clipIDs: [String], presetID: String? = nil, assetID: String) {
        self.name = name
        self.clipIDs = clipIDs
        self.presetID = presetID
        self.assetID = assetID
    }

    /// What to tell someone, with the fix.
    public var warning: String { warning(count: clipIDs.count) }

    /// The warning for `count` text clips, which may not exist yet.
    public func warning(count: Int) -> String {
        let whose = presetID.map { ", the \($0) preset's font," } ?? ""
        let what = count == 1 ? "1 text clip is" : "\(count) text clips are"
        return "\(name)\(whose) isn't installed, so \(what) drawn in SF Pro instead. Install it with: tandem assets use \(assetID)"
    }
}

/// The fonts a project's titles use, and getting its own fonts into this
/// process.
///
/// Core Text fonts are registered per process. A project carries fonts in
/// `assets/font/` (where `tandem assets use` and archiving put them), and
/// whichever process renders it (the app, `tandem serve`, a CLI command)
/// registers the files there it hasn't seen before it draws. So a font
/// added while the app has the project open reaches the app's renders
/// without a restart, and cached titles drawn in the fallback are dropped.
public enum ProjectFonts {
    static let extensions: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2"]

    /// Where a project keeps its own fonts: `assets/font/`.
    public static func folder(of project: ProjectFolder) -> URL {
        project.assetsFolder.appendingPathComponent("font", isDirectory: true)
    }

    private static let registry = FontRegistry()

    /// Registers the font files in `assets/font/` that this process hasn't
    /// registered yet, or that changed since. Cheap when nothing is new: a
    /// folder listing. Returns the files it registered.
    @discardableResult
    public static func registerNew(in project: ProjectFolder) -> [URL] {
        registerNew(inFolder: folder(of: project))
    }

    /// The same for any folder of fonts.
    @discardableResult
    public static func registerNew(inFolder folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let added = registry.register(files.filter { extensions.contains($0.pathExtension.lowercased()) })
        // Titles drawn before the font arrived were drawn in the fallback.
        if !added.isEmpty { TextRenderer.shared.forgetDrawings() }
        return added
    }

    /// True when titles can be drawn in `name` (a family, PostScript or
    /// full name) rather than falling back to the system font.
    public static func isAvailable(_ name: String) -> Bool {
        TextRenderer.isSystemName(name) || TextRenderer.installedFont(name, size: 24, weight: 400) != nil
    }

    /// Fonts the project's titles use that this process can't draw. With
    /// `drawnOnly`, titles that aren't drawn (turned off, on a hidden track,
    /// hidden in `format`) don't count.
    public static func missing(in project: Project, drawnOnly: Bool = false, format: String? = nil) -> [MissingFont] {
        var order: [String] = []
        var found: [String: MissingFont] = [:]
        for track in project.videoTracks where !(drawnOnly && track.hidden) {
            for clip in track.clips {
                guard case .text(let text) = clip.content else { continue }
                if drawnOnly && (!clip.enabled || clip.isHidden(inFormat: format)) { continue }
                let font = described(text, clipID: clip.id)
                let key = font.name.lowercased()
                if found[key] != nil {
                    found[key]?.clipIDs.append(clip.id)
                } else {
                    order.append(key)
                    found[key] = font
                }
            }
        }
        return order.compactMap { found[$0] }.filter { !isAvailable($0.name) }
    }

    /// The font one title draws with, when this process can't draw it.
    public static func missing(for text: TextContent, clipID: String) -> MissingFont? {
        let font = described(text, clipID: clipID)
        return isAvailable(font.name) ? nil : font
    }

    /// A title's font with where it comes from and the asset that installs
    /// it, whether or not it's installed.
    static func described(_ text: TextContent, clipID: String) -> MissingFont {
        let name = TitlePresets.style(for: text).font
        let preset = TitlePresets.preset(text.preset)
        let fromPreset = preset.flatMap { $0.style.font?.caseInsensitiveCompare(name) == .orderedSame ? $0 : nil }
        return MissingFont(name: name, clipIDs: [clipID], presetID: fromPreset?.id, assetID: fromPreset?.fontAsset ?? fontsourceID(for: name))
    }

    /// The Fontsource asset ID a font's name suggests: `Tilt Warp` and
    /// `TiltWarp-Regular` are both `fontsource:tilt-warp`, the way
    /// Fontsource names Google Fonts.
    public static func fontsourceID(for name: String) -> String {
        var family = name
        if !family.contains(" "), let dash = family.firstIndex(of: "-") {
            // A PostScript name: the part before the style, split where
            // the words join ("TiltWarp" is "Tilt Warp").
            family = String(family[..<dash])
            var spaced = ""
            for (index, character) in family.enumerated() {
                if index > 0, character.isUppercase, let last = spaced.last, last.isLowercase || last.isNumber { spaced.append(" ") }
                spaced.append(character)
            }
            family = spaced
        }
        let words = family.lowercased().split { !$0.isLetter && !$0.isNumber }
        return "fontsource:" + words.joined(separator: "-")
    }
}

/// Which font files this process has registered, with the size and date
/// each had then, so a file is registered once and again only if it
/// changes.
final class FontRegistry: @unchecked Sendable {
    private struct Stamp: Equatable {
        var size: Int
        var modified: Date
    }

    private let lock = NSLock()
    private var stamps: [String: Stamp] = [:]

    /// Registers the files it hasn't seen as they are now. Returns the ones
    /// now registered, which includes fonts something else in the process
    /// registered first (the asset library does, for its own copies).
    func register(_ files: [URL]) -> [URL] {
        lock.withLock {
            var added: [URL] = []
            for url in files.sorted(by: { $0.path < $1.path }) {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard let size = values?.fileSize, let modified = values?.contentModificationDate else { continue }
                let stamp = Stamp(size: size, modified: modified)
                let key = url.standardizedFileURL.path
                guard stamps[key] != stamp else { continue }
                if stamps[key] != nil {
                    // Replaced in place: Core Text still has the old one.
                    CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
                }
                var error: Unmanaged<CFError>?
                let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
                // Remembered even when it failed, so a broken file costs one
                // attempt rather than one every render.
                stamps[key] = stamp
                if registered || code == CTFontManagerError.alreadyRegistered.rawValue || code == CTFontManagerError.duplicatedName.rawValue {
                    added.append(url)
                }
            }
            return added
        }
    }
}
