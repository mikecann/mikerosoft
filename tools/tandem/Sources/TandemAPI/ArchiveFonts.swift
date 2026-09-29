import CoreText
import Foundation
import TandemAssets
import TandemCore
import TandemMedia
import TandemRender

/// Where a font's files are.
public enum FontLookup: Equatable, Sendable {
    /// It comes with macOS, so every Mac has it.
    case system
    case files([URL])
    case notFound
}

/// Finds the files behind a font family a title uses. The archive copies
/// them into the project's `assets/font/`, which the app registers when it
/// opens a project.
public protocol FontLocating: Sendable {
    func locate(_ family: String) -> FontLookup
}

/// Fonts installed on this Mac (Core Text), then the asset library's
/// downloaded fonts, which only the app registers (the CLI doesn't).
public struct InstalledFonts: FontLocating {
    public var libraryRoot: URL?

    public init(libraryRoot: URL? = InstalledFonts.defaultLibraryRoot()) {
        self.libraryRoot = libraryRoot
    }

    /// `$TANDEM_ASSETS_ROOT`, or the per-user library.
    public static func defaultLibraryRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let root = environment["TANDEM_ASSETS_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: NSString(string: root).expandingTildeInPath, isDirectory: true)
        }
        return AssetLibrary.defaultRoot
    }

    public func locate(_ family: String) -> FontLookup {
        if ArchiveFonts.isSystemName(family) { return .system }
        let found = Self.installed(family)
        if found.contains(where: { $0.path.hasPrefix("/System/") }) { return .system }
        if !found.isEmpty { return .files(found) }
        if let libraryRoot {
            let files = ArchiveFonts.files(of: family, under: libraryRoot, skipping: ["cache", "staging", "previews", "providers"])
            if !files.isEmpty { return .files(files) }
        }
        return .notFound
    }

    /// Files Core Text knows for a family name, or for a PostScript or full
    /// name, the way the title renderer looks fonts up.
    static func installed(_ name: String) -> [URL] {
        var urls: [URL] = []
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
        let mandatory: Set<CFString> = [kCTFontFamilyNameAttribute]
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, mandatory as CFSet) as? [CTFontDescriptor] ?? []
        for match in matches {
            guard let family = CTFontDescriptorCopyAttribute(match, kCTFontFamilyNameAttribute) as? String,
                  family.caseInsensitiveCompare(name) == .orderedSame,
                  let url = CTFontDescriptorCopyAttribute(match, kCTFontURLAttribute) as? URL else { continue }
            if !urls.contains(url) { urls.append(url) }
        }
        if urls.isEmpty {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            let names = [CTFontCopyPostScriptName(font), CTFontCopyFullName(font)].map { $0 as String }
            if names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
               let url = CTFontDescriptorCopyAttribute(CTFontCopyFontDescriptor(font), kCTFontURLAttribute) as? URL {
                urls.append(url)
            }
        }
        return urls
    }
}

/// Fonts in projects: which families titles use, and which font files a
/// folder holds.
enum ArchiveFonts {
    /// The names the title renderer treats as the system font (SF Pro).
    static let systemNames: Set<String> = ["", "system", "system-ui", "-apple-system", "sf pro", "sf pro display", "sf pro text", "san francisco"]

    static let extensions: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2"]

    static func isSystemName(_ family: String) -> Bool {
        systemNames.contains(family.lowercased())
    }

    /// The family a text clip draws with: its own font, or its preset's.
    static func family(of text: TextContent) -> String {
        TitlePresets.style(for: text).font
    }

    /// Every family a project's titles use, with the clips that use it.
    static func families(in project: Project) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for track in project.videoTracks {
            for clip in track.clips {
                guard case .text(let text) = clip.content else { continue }
                found[family(of: text), default: []].append(clip.id)
            }
        }
        return found
    }

    /// True when a font file holds a face of `name` (a family, PostScript
    /// or full name).
    static func file(_ url: URL, holds name: String) -> Bool {
        FontInstaller.faces(in: url).contains {
            $0.family.caseInsensitiveCompare(name) == .orderedSame || $0.postScriptName.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// The font files of `family` directly in `folder`.
    static func files(of family: String, in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { extensions.contains($0.pathExtension.lowercased()) && file($0, holds: family) }.sorted { $0.path < $1.path }
    }

    /// The font files of `family` anywhere under `root`, leaving out the
    /// top-level folders in `skipping`.
    static func files(of family: String, under root: URL, skipping: Set<String>) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level == 1, skipping.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard extensions.contains(url.pathExtension.lowercased()), file(url, holds: family) else { continue }
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }
}
