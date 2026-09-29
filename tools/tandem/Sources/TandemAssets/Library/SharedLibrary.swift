import Darwin
import Foundation

/// Mike's shared library: one visible folder on this Mac for the stickers,
/// graphics, sound effects, music, looks, fonts and saved segments every
/// project can use. It's `~/Movies/Tandem Library` unless Settings moves
/// it; Backblaze backs it up with the rest of the Mac.
///
///     Tandem Library/
///       Stickers/          animated stickers
///       Graphics/          logos, lower thirds, overlays, stills
///       Sound effects/
///       Music/
///       Looks/             colour looks as .cube LUTs
///       Fonts/
///       Segments/<name>/   saved segments: segment.json and their media
///
/// Files dropped in join the asset library as the `shared` source
/// (`SharedLibraryProvider`), watched like an import folder. Unlike an
/// import folder's files, a shared file is used where it is: a project
/// refers to it instead of copying it, so improving a sticker here
/// improves every project that uses it. Archiving a project copies the
/// shared files it uses into it.
public struct SharedLibrary: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// The folder's name by default.
    public static let defaultName = "Tandem Library"
    /// Moves the library for one process (tests, agents).
    public static let environmentKey = "TANDEM_LIBRARY"
    /// Where each folder's note to Mike goes.
    public static let readmeName = "README.txt"

    /// `~/Movies/Tandem Library`.
    public static var standardRoot: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(defaultName, isDirectory: true)
    }

    /// Where the library is for an asset library at `assetsRoot`: the
    /// folder its settings name, otherwise `~/Movies/Tandem Library` for
    /// Mike's own asset library, and `Tandem Library` inside any other (a
    /// test's, or `$TANDEM_ASSETS_ROOT`), so those never touch the real one.
    public static func root(for settings: AssetSettings, assetsRoot: URL) -> URL {
        if let chosen = settings.sharedLibrary {
            return URL(fileURLWithPath: NSString(string: chosen).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        if assetsRoot.standardizedFileURL.path == AssetLibrary.defaultRoot.standardizedFileURL.path { return standardRoot }
        return assetsRoot.appendingPathComponent(defaultName, isDirectory: true)
    }

    /// The library this process uses: `$TANDEM_LIBRARY`, otherwise what the
    /// settings of the asset library the environment names say.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> SharedLibrary {
        if let path = environment[environmentKey], !path.isEmpty {
            return SharedLibrary(root: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true))
        }
        let assetsRoot = AssetLibrary.root(environment: environment)
        return SharedLibrary(root: root(for: AssetSettings.load(from: assetsRoot), assetsRoot: assetsRoot))
    }

    // MARK: - Folders

    /// The folders Tandem makes, each with a README.
    public enum Folder: String, CaseIterable, Sendable {
        case stickers = "Stickers"
        case graphics = "Graphics"
        case soundEffects = "Sound effects"
        case music = "Music"
        case looks = "Looks"
        case fonts = "Fonts"
        case segments = "Segments"

        /// What a file here is, when the file alone could be several
        /// things: a sound in Music is music however short it is.
        public var kind: AssetKind? {
            switch self {
            case .stickers: return .sticker
            case .graphics: return .overlay
            case .soundEffects: return .sfx
            case .music: return .music
            case .looks: return .lut
            case .fonts: return .font
            case .segments: return nil
            }
        }

        /// The folder a path inside the library is in, by its first part.
        public static func of(_ relative: String) -> Folder? {
            guard let first = relative.split(separator: "/").first else { return nil }
            return allCases.first { $0.rawValue.caseInsensitiveCompare(String(first)) == .orderedSame }
        }

        var readme: String {
            switch self {
            case .stickers:
                return """
                Stickers

                Animated stickers for the Graphics track. HEVC with alpha (.mov) plays as it is; WebM, animated GIF and WebP, and Lottie (.json) are converted once, when Tandem first shows them, and again whenever you change them here.

                They show up in the Graphics tab under Stickers, with the Shared library chip. Subfolders are fine: their names become search words.
                """
            case .graphics:
                return """
                Graphics

                Logos, lower thirds, overlays and stills: PNG, JPEG, HEIC, SVG and MOV. They show up in the Graphics tab (overlays under B-roll, SVG icons and logos under Icons) and go on the Graphics track.
                """
            case .soundEffects:
                return """
                Sound effects

                Whooshes, clicks, pops and hits: WAV, AIFF, MP3 or M4A. They show up in the Audio tab under SFX and go on the SFX track at -15 dB.
                """
            case .music:
                return """
                Music

                Beds and stings: WAV, AIFF, MP3 or M4A. They show up in the Audio tab under Music and go on the Music track at -31 dB with a 2 s fade out.
                """
            case .looks:
                return """
                Looks

                Colour looks as .cube LUTs. They show up in the Effects tab under Looks; drop one on a clip to grade it.
                """
            case .fonts:
                return """
                Fonts

                TTF, OTF and TTC fonts for titles. Tandem loads them when it starts, so titles can use them without installing them for the whole Mac. They show up in the Text tab under Fonts.
                """
            case .segments:
                return """
                Segments

                Reusable bits of timeline: an intro, an outro, like and subscribe, comment below. Select clips on the timeline and choose Timeline > Save selection as segment (or right-click a clip). Each segment is a folder with segment.json and copies of the media it uses, so it keeps working whatever happens to the project it came from.

                They show up in the Text tab under Segments. Double-click one to put it at the playhead, or drag it to the timeline. Agents use `tandem segments list`, `save` and `insert`.
                """
            }
        }
    }

    public func url(_ folder: Folder) -> URL {
        root.appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    public var segmentsFolder: URL { url(.segments) }

    /// True when the library's folder is there.
    public var exists: Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    static let rootReadme = """
    Tandem Library

    Everything in here is shared by every Tandem project on this Mac. Drop files into these folders and they show up in Tandem's library tabs straight away, searchable, with the Shared library chip:

      Stickers        animated stickers
      Graphics        logos, lower thirds, overlays and stills
      Sound effects   whooshes, clicks and hits
      Music           beds and stings
      Looks           colour looks as .cube LUTs
      Fonts           fonts for titles
      Segments        reusable bits of timeline saved from Tandem

    A project uses these files where they are rather than copying them, so improving a sticker here improves every project that uses it. Archiving a project (File > Archive project) copies the shared files it uses into the project folder, so an archived project opens on another Mac (Bruce) with nothing missing.

    Licences: put a tandem-licence.json beside files you bought or downloaded, in their folder or any folder above it, so the description credits know their terms. For example:

      {"source": "Envato Elements", "licence": "Envato Elements licence", "licenceClass": "subscription"}

    For things you made yourself use "licenceClass": "noCredit". The nearest note wins; files with none show as Unknown licence.

    Settings (Tandem > Settings) can move this folder.
    """

    /// Makes the library's folder, its subfolders and their READMEs,
    /// leaving anything already there alone (a README Mike edited stays as
    /// he left it). Returns what it made.
    @discardableResult
    public func create() throws -> [URL] {
        let fileManager = FileManager.default
        var made: [URL] = []
        func folder(_ url: URL) throws {
            guard !fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            made.append(url)
        }
        func readme(_ text: String, in url: URL) throws {
            let file = url.appendingPathComponent(Self.readmeName)
            guard !fileManager.fileExists(atPath: file.path) else { return }
            try Data((text + "\n").utf8).write(to: file, options: .withoutOverwriting)
            made.append(file)
        }
        try folder(root)
        try readme(Self.rootReadme, in: root)
        for item in Folder.allCases {
            try folder(url(item))
            try readme(item.readme, in: url(item))
        }
        return made
    }

    // MARK: - Paths

    /// Where `url` is inside the library (`Stickers/wave.mov`), or nil when
    /// it's somewhere else. Links are followed on both sides, so a link to
    /// the library, or a library that is itself a link, still counts.
    public func relativePath(of url: URL) -> String? {
        let file = url.standardizedFileURL
        if let relative = Self.relative(file.path, to: root.path) { return relative }
        guard let realFile = Self.realPath(file.path), let realRoot = Self.realPath(root.path) else { return nil }
        return Self.relative(realFile, to: realRoot)
    }

    /// True when `url` is in the library.
    public func contains(_ url: URL) -> Bool {
        relativePath(of: url) != nil
    }

    static func relative(_ path: String, to base: String) -> String? {
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The path with every link resolved, or nil when nothing is there.
    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True for the notes Tandem writes into each folder.
    static func isReadme(_ name: String) -> Bool {
        name.caseInsensitiveCompare(readmeName) == .orderedSame
    }
}

extension AssetLibrary {
    /// For a file the asset library made from a shared library file (the
    /// converted copy of a WebM or Lottie sticker, which projects play),
    /// where that file is in the shared library, like `Stickers/Spin.webm`.
    /// Nil for anything else.
    public static func sharedOriginal(of file: URL, assetsRoot: URL) -> String? {
        guard let relative = Paths.relative(file, to: assetsRoot) else { return nil }
        let parts = relative.split(separator: "/")
        guard parts.count == 3, parts[0] == Substring(SharedLibraryProvider.providerID) else { return nil }
        let meta = file.deletingLastPathComponent().appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: meta), let decoded = try? JSONDecoder.iso.decode(AssetMeta.self, from: data),
              decoded.asset.provider == SharedLibraryProvider.providerID else { return nil }
        return decoded.asset.providerID
    }

    /// The asset library a process uses: `$TANDEM_ASSETS_ROOT`, or the
    /// per-user one.
    public static func root(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let root = environment["TANDEM_ASSETS_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: NSString(string: root).expandingTildeInPath, isDirectory: true)
        }
        return defaultRoot
    }
}
