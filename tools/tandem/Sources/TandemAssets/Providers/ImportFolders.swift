import AVFoundation
import CoreServices
import CryptoKit
import Foundation

/// The licence note an import folder carries, as `tandem-licence.json` in
/// the folder. It covers everything in the folder, so a folder should hold
/// one library's downloads (Envato in one, Mixkit in another).
///
/// ```json
/// {
///   "source": "Envato Elements",
///   "licence": "Envato Elements licence",
///   "licenceClass": "subscription",
///   "url": "https://elements.envato.com/license-terms",
///   "kind": "sfx",
///   "notes": "Register each video on Envato before publishing."
/// }
/// ```
public struct FolderLicence: Codable, Equatable, Sendable {
    public static let fileName = "tandem-licence.json"

    /// Where the files came from, for people and credits.
    public var source: String
    /// The licence's name.
    public var licence: String
    public var licenceClass: LicenceClass
    public var url: URL?
    /// A credit line for the description, when the licence wants one.
    public var credit: String?
    /// A licence certificate or subscription ID.
    public var certificate: String?
    /// What the files are when their names don't say (sfx, music...).
    public var kind: AssetKind?
    public var notes: String?

    public init(source: String, licence: String, licenceClass: LicenceClass, url: URL? = nil, credit: String? = nil, certificate: String? = nil, kind: AssetKind? = nil, notes: String? = nil) {
        self.source = source
        self.licence = licence
        self.licenceClass = licenceClass
        self.url = url
        self.credit = credit
        self.certificate = certificate
        self.kind = kind
        self.notes = notes
    }

    /// Notes for the libraries the research found Mike is likely to use.
    public static let presets: [String: FolderLicence] = [
        "envato": FolderLicence(
            source: "Envato Elements", licence: "Envato Elements licence", licenceClass: .subscription,
            url: URL(string: "https://elements.envato.com/license-terms"),
            notes: "Register each video on Envato when you download for it; the licence covers registered projects made while subscribed."
        ),
        "mixkit": FolderLicence(
            source: "Mixkit", licence: "Mixkit Free License", licenceClass: .noCredit,
            url: URL(string: "https://mixkit.co/license/"),
            notes: "Free for commercial videos, no credit needed. Music uses the Mixkit Stock Music Free License."
        ),
        "pixabay": FolderLicence(
            source: "Pixabay", licence: "Pixabay Content License", licenceClass: .noCredit,
            url: URL(string: "https://pixabay.com/service/license-summary/"),
            notes: "Free to use without attribution. Don't redistribute the files unaltered."
        ),
        "sonniss": FolderLicence(
            source: "Sonniss GDC Game Audio Bundle", licence: "Sonniss royalty-free licence", licenceClass: .noCredit,
            url: URL(string: "https://sonniss.com/gameaudiogdc"), kind: .sfx,
            notes: "Royalty free for commercial projects, no attribution. Don't resell or share the sounds as they are."
        ),
        "youtube": FolderLicence(
            source: "YouTube Audio Library", licence: "YouTube Audio Library licence", licenceClass: .creditNeeded,
            url: URL(string: "https://www.youtube.com/audiolibrary"),
            notes: "Some tracks need the attribution text shown in the library; put it in the credit field, or move no-attribution tracks to a folder marked noCredit."
        ),
        "epidemic": FolderLicence(
            source: "Epidemic Sound", licence: "Epidemic Sound subscription", licenceClass: .subscription,
            url: URL(string: "https://www.epidemicsound.com/licensing/"),
            notes: "Covered while subscribed on a plan that allows this channel. Keep the channel registered with Epidemic."
        ),
        "artlist": FolderLicence(
            source: "Artlist", licence: "Artlist licence", licenceClass: .subscription,
            url: URL(string: "https://artlist.io/license"),
            notes: "Personal plans exclude company or client work."
        ),
        "motion-array": FolderLicence(
            source: "Motion Array", licence: "Motion Array licence", licenceClass: .subscription,
            url: URL(string: "https://motionarray.com/license/")
        ),
        "storyblocks": FolderLicence(
            source: "Storyblocks", licence: "Storyblocks licence", licenceClass: .subscription,
            url: URL(string: "https://www.storyblocks.com/license"),
            notes: "Individual plans exclude company or client work."
        )
    ]

    /// Reads the note in `folder`, if there is one.
    public static func read(in folder: URL) -> FolderLicence? {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FolderLicence.self, from: data)
    }

    /// Writes the note into `folder`.
    public func write(in folder: URL) throws {
        try JSONEncoder.sorted.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

extension FolderLicence {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "Import folder"
        licence = try c.decodeIfPresent(String.self, forKey: .licence) ?? "Unknown licence"
        licenceClass = try c.decodeIfPresent(LicenceClass.self, forKey: .licenceClass) ?? .unknown
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        credit = try c.decodeIfPresent(String.self, forKey: .credit)
        certificate = try c.decodeIfPresent(String.self, forKey: .certificate)
        kind = try c.decodeIfPresent(AssetKind.self, forKey: .kind)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// What a scan of one import folder changed.
public struct ImportScanReport: Codable, Equatable, Sendable {
    public var folderID: String
    public var added: Int = 0
    public var updated: Int = 0
    public var removed: Int = 0
    public var unchanged: Int = 0
    /// Files that aren't media, relative to the folder.
    public var skipped: [String] = []
    /// True when the folder has no `tandem-licence.json`.
    public var missingLicence: Bool = false
}

/// Watched folders of assets downloaded by hand: Envato, Mixkit, Pixabay
/// SFX, Sonniss and anything else. Files stay where they are; the library
/// indexes them, normalises copies into its own folder on first use and
/// reads the folder's licence note.
public final class ImportFolderProvider: AssetProvider, @unchecked Sendable {
    public let id = "import"
    public let displayName = "Import folders"
    public let kinds: Set<AssetKind> = [.music, .sfx, .sticker, .overlay, .video, .image, .font, .icon, .logo, .lut]
    public let capabilities = ProviderCapabilities(search: false)
    public let rules = ProviderRules(cacheTTL: 0, notes: ["Each folder's tandem-licence.json says what its files may be used for."])
    let catalog: AssetCatalog

    public init(catalog: AssetCatalog) {
        self.catalog = catalog
    }

    public func status() async -> ProviderStatus {
        let folders = (try? catalog.importFolders()) ?? []
        return folders.isEmpty ? ProviderStatus(.ready, "No import folders yet") : .ready
    }

    /// Import folders are searched through the catalogue, not here.
    public func search(_ query: ProviderQuery) async throws -> [Asset] { [] }

    public func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal {
        guard let path = asset.files.original, FileManager.default.fileExists(atPath: path) else {
            throw AssetError.notFound("\(asset.name): the file has moved or been deleted from its import folder")
        }
        return FetchedOriginal(asset: asset, file: URL(fileURLWithPath: path))
    }

    public func licence(for asset: Asset) async throws -> AssetLicence {
        let folderID = asset.remote["folder"] ?? String(asset.providerID.split(separator: "/").first ?? "")
        let record = try catalog.importFolders().first { $0.id == folderID }
        let note = record.flatMap { FolderLicence.read(in: URL(fileURLWithPath: $0.path)) }
        guard let note else {
            return AssetLicence(
                name: "No licence note", licenceClass: .unknown,
                notes: "The import folder has no \(FolderLicence.fileName). Add one so this asset's terms are on record."
            )
        }
        let text = (try? JSONEncoder.sorted.encode(note)).flatMap { String(data: $0, encoding: .utf8) }
        return AssetLicence(
            name: note.licence, licenceClass: note.licenceClass, url: note.url, text: text, holder: note.source,
            creditLine: note.credit, certificate: note.certificate, sourceURL: note.url, notes: note.notes
        )
    }

    // MARK: - Scanning

    /// A stable ID for a folder: its name plus a short hash of its path.
    public static func folderID(for url: URL) -> String {
        let slug = LocalMatcher.tokens(url.lastPathComponent).joined(separator: "-")
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
        return "\(slug.isEmpty ? "folder" : String(slug.prefix(40)))-\(digest)"
    }

    /// Indexes the files in one import folder: new files are added, changed
    /// ones refreshed, and missing ones removed (or, if a project used
    /// them, kept and marked missing so their credits survive).
    public func scan(_ record: AssetCatalog.ImportFolderRecord) async throws -> ImportScanReport {
        let root = URL(fileURLWithPath: record.path, isDirectory: true).standardizedFileURL
        var report = ImportScanReport(folderID: record.id)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw AssetError.notFound("import folder \(record.path)")
        }
        let note = FolderLicence.read(in: root)
        report.missingLicence = note == nil

        let existing = try catalog.search(AssetQuery(providers: [id], limit: Int.max)).filter { $0.remote["folder"] == record.id }
        var known = Dictionary(existing.map { ($0.providerID, $0) }, uniquingKeysWith: { first, _ in first })
        let pinned = try catalog.pinnedIDs()

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var changes: [Asset] = []
        while let file = enumerator?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if file.lastPathComponent == FolderLicence.fileName { continue }
            let format = FormatSniffer.fromExtension(file.pathExtension)
            let isLottie = file.pathExtension.lowercased() == "json" && FormatSniffer.isLottie(file)
            guard format != .unknown || isLottie else {
                report.skipped.append(relative)
                continue
            }
            let providerID = "\(record.id)/\(relative)"
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let signature = "\(size)-\(Int(modified))"
            if let old = known.removeValue(forKey: providerID), old.remote["signature"] == signature, old.remote["missing"] == nil {
                report.unchanged += 1
                continue
            }
            let isNew = !existing.contains { $0.providerID == providerID }
            var asset = await describe(file: file, relative: relative, format: isLottie ? .lottie : format, folderID: record.id, note: note)
            asset.size = size
            asset.remote["signature"] = signature
            if let old = existing.first(where: { $0.providerID == providerID }) {
                // Keep what the library made from the old file only if the
                // file is the same; a changed file needs normalising again.
                asset.addedAt = old.addedAt
            }
            changes.append(asset)
            if isNew { report.added += 1 } else { report.updated += 1 }
        }
        try catalog.upsert(changes)

        // Whatever is left in `known` has gone from the folder.
        for (_, gone) in known {
            if pinned.contains(gone.id) {
                var kept = gone
                kept.state = .remote
                kept.remote["missing"] = "1"
                try catalog.upsert(kept)
            } else {
                try catalog.delete(id: gone.id)
            }
            report.removed += 1
        }
        var updated = record
        updated.lastScan = Date()
        try catalog.saveImportFolder(updated)
        return report
    }

    /// An asset for a file, with its kind guessed from the folder note, its
    /// path and its length.
    func describe(file: URL, relative: String, format: AssetFormat, folderID: String, note: FolderLicence?) async -> Asset {
        let name = ProviderFiles.title(file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".", with: " "))
        let folders = relative.split(separator: "/").dropLast().map(String.init)
        var asset = Asset(
            provider: id,
            providerID: "\(folderID)/\(relative)",
            kind: .image,
            name: name,
            tags: folders + LocalMatcher.tokens(file.deletingPathExtension().lastPathComponent),
            summary: note.map { "From \($0.source)" },
            state: .original,
            licenceClass: note?.licenceClass ?? .unknown,
            creditLine: note?.credit,
            remote: ["folder": folderID, "relativePath": relative]
        )
        asset.files.original = file.standardizedFileURL.path
        let lowerPath = relative.lowercased()

        if format.isAudio {
            if let audio = try? AVAudioFile(forReading: file) {
                asset.duration = Double(audio.length) / audio.fileFormat.sampleRate
            }
            asset.kind = note?.kind ?? Self.audioKind(path: lowerPath, duration: asset.duration)
        } else if format == .mov || format == .mp4 {
            if let info = try? await MediaProbe.video(file) {
                asset.duration = info.duration
                asset.width = info.width
                asset.height = info.height
                asset.hasAlpha = info.hasAlpha
            }
            asset.kind = note?.kind ?? (asset.hasAlpha || lowerPath.contains("overlay") ? .overlay : .video)
        } else if format == .webm || format == .lottie || format == .gif {
            asset.kind = note?.kind ?? (lowerPath.contains("overlay") ? .overlay : .sticker)
            asset.hasAlpha = true
        } else if format == .svg {
            asset.kind = note?.kind ?? (lowerPath.contains("logo") ? .logo : .icon)
            asset.hasAlpha = true
        } else if format.isFont {
            asset.kind = .font
        } else if format == .cube {
            asset.kind = .lut
        } else if format.isStillOrAnimatedImage {
            if let info = MediaProbe.image(file) {
                asset.width = info.width
                asset.height = info.height
                asset.hasAlpha = info.hasAlpha
                if info.frames > 1 { asset.kind = note?.kind ?? .sticker }
            }
            if asset.kind == .image {
                asset.kind = note?.kind ?? (lowerPath.contains("overlay") ? .overlay : .image)
            }
        }
        return asset
    }

    /// Music or a sound effect: the path decides when it says, otherwise
    /// anything over 45 seconds is music.
    static func audioKind(path: String, duration: Double?) -> AssetKind {
        let words = Set(LocalMatcher.tokens(path))
        if !words.isDisjoint(with: ["music", "song", "songs", "track", "tracks", "bed", "beds", "score"]) { return .music }
        if !words.isDisjoint(with: ["sfx", "fx", "foley", "effects", "effect", "whoosh", "whooshes", "ui", "click", "clicks"]) { return .sfx }
        return (duration ?? 0) > 45 ? .music : .sfx
    }
}

/// Watches import folders with FSEvents and calls back (debounced) with
/// the folders that changed.
public final class ImportFolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "tandem.assets.import-watcher")
    private let handler: @Sendable ([String]) -> Void
    /// Watched folders as given, keyed by their real path. FSEvents reports
    /// real paths (`/private/var/...` for `/var/...`), so matching needs both.
    private var roots: [(real: String, given: String)] = []

    /// Starts watching `paths`. `handler` gets the watched folders (as
    /// passed in) that saw changes, at most every `latency` seconds.
    public init(paths: [String], latency: TimeInterval = 1, handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
        guard !paths.isEmpty else { return }
        roots = paths.map { (Self.realPath($0), $0) }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ImportFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            watcher.deliver(Array(changed.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        let watched = roots.map(\.real) as CFArray
        stream = FSEventStreamCreate(nil, callback, &context, watched, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    /// The path with every symlink resolved. Foundation's
    /// `resolvingSymlinksInPath` strips `/private`, which is the opposite of
    /// what FSEvents reports.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func deliver(_ paths: [String]) {
        // The licence note changing matters too, so every file counts.
        let touched = roots.filter { root in paths.contains { $0 == root.real || $0.hasPrefix(root.real + "/") } }.map(\.given)
        guard !touched.isEmpty else { return }
        handler(touched)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
