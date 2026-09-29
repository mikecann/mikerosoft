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

    /// A short fingerprint of a note (or of having none), stored on each
    /// asset so a changed note can be noticed.
    static func signature(_ note: FolderLicence?) -> String {
        guard let note, let data = try? JSONEncoder.sorted.encode(note) else { return "none" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
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
    /// Unchanged files whose licence changed because the folder's note did.
    public var relicensed: Int = 0
    /// Files that aren't media, relative to the folder.
    public var skipped: [String] = []
    /// True when the folder has no `tandem-licence.json`.
    public var missingLicence: Bool = false
    /// Parts of the folder that couldn't be read. When there are any,
    /// nothing is removed from the index, since missing isn't the same as
    /// deleted.
    public var unreadable: [String] = []
    /// Why the whole scan failed, when it did (from `rescanImportFolders`).
    public var error: String?
    /// Assets deleted from the catalogue because their file went, so the
    /// library can delete what it made from them.
    public var removedIDs: [String] = []
    /// Assets whose file changed, so what the library made from them (a
    /// converted sticker a project plays) can be made again.
    public var updatedIDs: [String] = []
    /// Identifies the scan that made this report. Callers who shared a scan
    /// get the same ID, so its changes are handled once.
    public var scanID: String = UUID().uuidString

    public init(folderID: String) {
        self.folderID = folderID
    }
}

/// Watched folders of assets downloaded by hand: Envato, Mixkit, Pixabay
/// SFX, Sonniss and anything else. Files stay where they are; the library
/// indexes them, normalises copies into its own folder on first use and
/// reads the folder's licence note.
public class ImportFolderProvider: AssetProvider, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let kinds: Set<AssetKind> = [.music, .sfx, .sticker, .overlay, .video, .image, .font, .icon, .logo, .lut]
    public let capabilities = ProviderCapabilities(search: false)
    public let rules: ProviderRules
    let catalog: AssetCatalog

    public convenience init(catalog: AssetCatalog) {
        self.init(catalog: catalog, id: "import", displayName: "Import folders", rules: ProviderRules(cacheTTL: 0, notes: ["Each folder's tandem-licence.json says what its files may be used for."]))
    }

    /// For providers built on the same folder indexing (the shared library).
    init(catalog: AssetCatalog, id: String, displayName: String, rules: ProviderRules) {
        self.catalog = catalog
        self.id = id
        self.displayName = displayName
        self.rules = rules
    }

    public func status() async -> ProviderStatus {
        let folders = (try? catalog.importFolders()) ?? []
        return folders.isEmpty ? ProviderStatus(.ready, "No import folders yet") : .ready
    }

    // MARK: - What differs between folder providers

    /// The folder a scan or a licence lookup is about, by its ID.
    func folderRecord(_ folderID: String) throws -> AssetCatalog.ImportFolderRecord? {
        try catalog.importFolders().first { $0.id == folderID }
    }

    /// Saves a scan's rows, unless the folder went away during the scan.
    func saveScan(_ assets: [Asset], folderID: String) throws -> Bool {
        try catalog.upsert(assets, ifImportFolderExists: folderID)
    }

    /// Notes that a folder was scanned.
    func scanned(_ folderID: String) throws {
        try catalog.recordImportFolderScan(id: folderID, at: Date())
    }

    /// The licence note for the files in `folder` (relative to the root,
    /// "" for the root itself): an import folder has one, at its root.
    func licenceNote(forFolder folder: String, root: URL) -> FolderLicence? {
        FolderLicence.read(in: root)
    }

    /// What a file is when the file alone can't say, from where it is.
    func kindHint(forPath relative: String) -> AssetKind? { nil }

    /// Folders and files the index leaves out.
    func skips(_ relative: String, isFolder: Bool) -> Bool { false }

    /// The provider ID for a file in a folder.
    func providerID(folderID: String, relative: String) -> String {
        "\(folderID)/\(relative)"
    }

    /// The folder of the file an asset stands for, relative to its root.
    static func folderPart(of asset: Asset) -> String {
        let relative = asset.remote["relativePath"] ?? ""
        return (relative as NSString).deletingLastPathComponent
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
        let record = try folderRecord(folderID)
        let note = record.flatMap { licenceNote(forFolder: Self.folderPart(of: asset), root: URL(fileURLWithPath: $0.path, isDirectory: true)) }
        guard let note else {
            return AssetLicence(
                name: "No licence note", licenceClass: .unknown,
                notes: "The \(id == "import" ? "import folder" : "file's folder") has no \(FolderLicence.fileName). Add one so this asset's terms are on record."
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
    /// them, kept and marked missing so their credits survive). A changed
    /// licence note relicenses every file. Scans of one folder never
    /// overlap: a scan asked for while one runs waits and runs once after
    /// it, however many asked.
    public func scan(_ record: AssetCatalog.ImportFolderRecord) async throws -> ImportScanReport {
        try await scans.run(record.id) { try await self.performScan(record.id) }
    }

    private let scans = ScanQueue()

    private func performScan(_ folderID: String) async throws -> ImportScanReport {
        // Read the record again: a watcher may outlive the folder's removal.
        guard let record = try folderRecord(folderID) else {
            throw AssetError.notFound("import folder \(folderID) is no longer registered")
        }
        let root = URL(fileURLWithPath: record.path, isDirectory: true).standardizedFileURL
        var report = ImportScanReport(folderID: record.id)
        // A folder that can't be listed (an unplugged drive, privacy
        // settings) must not look empty, or its whole index would go.
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            throw AssetError.notFound("can't read \(id == "import" ? "import folder" : "folder") \(record.path): \(error.localizedDescription)")
        }
        // Each folder's note, read once a scan.
        var notes: [String: (note: FolderLicence?, signature: String)] = [:]
        func note(forFolder folder: String) -> (note: FolderLicence?, signature: String) {
            if let known = notes[folder] { return known }
            let found = licenceNote(forFolder: folder, root: root)
            let entry = (found, FolderLicence.signature(found))
            notes[folder] = entry
            return entry
        }
        report.missingLicence = note(forFolder: "").note == nil

        let existing = try catalog.search(AssetQuery(providers: [id], limit: Int.max)).filter { $0.remote["folder"] == record.id }
        let before = Dictionary(existing.map { ($0.providerID, $0) }, uniquingKeysWith: { first, _ in first })
        var known = before
        let pinned = try catalog.pinnedIDs()

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let problems = ProblemList()
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) { url, error in
            problems.add("\(url.path): \(error.localizedDescription)")
            return true
        }
        var changes: [Asset] = []
        var relicensed: [(Asset, Date)] = []
        while let file = enumerator?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if let relative = Paths.relative(file, to: root), skips(relative, isFolder: true) { enumerator?.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard let relative = Paths.relative(file, to: root) else { continue }
            if file.lastPathComponent == FolderLicence.fileName || skips(relative, isFolder: false) { continue }
            let ext = file.pathExtension.lowercased()
            let format = FormatSniffer.fromExtension(ext)
            guard format != .unknown || ext == "json" else {
                report.skipped.append(relative)
                continue
            }
            let providerID = providerID(folderID: record.id, relative: relative)
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let signature = "\(size)-\(Int(modified))"
            let (fileNote, noteSignature) = note(forFolder: (relative as NSString).deletingLastPathComponent)
            // Checked before anything expensive (probing, parsing JSON). A
            // row for the same file somewhere else (the folder moved) is
            // described again, so it points at the file where it is now.
            if let old = known.removeValue(forKey: providerID), old.remote["signature"] == signature, old.remote["missing"] == nil,
               old.files.original == file.standardizedFileURL.path {
                if old.remote["note"] == noteSignature {
                    report.unchanged += 1
                } else {
                    relicensed.append((relicense(old, note: fileNote, signature: noteSignature), old.updatedAt))
                    report.relicensed += 1
                }
                continue
            }
            let isLottie = ext == "json" && FormatSniffer.isLottie(file)
            guard format != .unknown || isLottie else {
                report.skipped.append(relative)
                continue
            }
            var asset = await describe(file: file, relative: relative, format: isLottie ? .lottie : format, folderID: record.id, note: fileNote)
            asset.size = size
            asset.remote["signature"] = signature
            asset.remote["note"] = noteSignature
            if let old = before[providerID] {
                // A changed file starts over (it needs normalising again)
                // but keeps the date it first arrived.
                asset.addedAt = old.addedAt
                report.updated += 1
                report.updatedIDs.append(asset.id)
            } else {
                report.added += 1
            }
            changes.append(asset)
        }
        guard try saveScan(changes, folderID: record.id) else {
            throw AssetError.notFound("\(id == "import" ? "import folder" : "folder") \(record.name) was removed during the scan")
        }
        for (asset, stamp) in relicensed {
            // Skip rows changed meanwhile; the next scan catches them.
            guard try catalog.replace(asset, ifUpdatedAt: stamp) else { continue }
            // Assets already used or fetched get a new snapshot, so the
            // credits follow the corrected note (unless the terms match the
            // latest snapshot already).
            if let latest = try catalog.licence(for: asset.id) {
                let current = try await licence(for: asset)
                if !latest.hasSameTerms(as: current) { try catalog.addLicence(current, for: asset.id) }
            }
        }

        report.unreadable = problems.all
        if report.unreadable.isEmpty {
            // Whatever is left in `known` has gone from the folder.
            for (_, gone) in known {
                if pinned.contains(gone.id) {
                    var kept = gone
                    kept.state = .remote
                    kept.remote["missing"] = "1"
                    kept.updatedAt = Date()
                    try catalog.replace(kept, ifUpdatedAt: gone.updatedAt)
                } else {
                    try catalog.delete(id: gone.id)
                    report.removedIDs.append(gone.id)
                }
                report.removed += 1
            }
        }
        try scanned(record.id)
        return report
    }

    /// The asset with its folder's current licence note applied, if the
    /// note changed since the asset was last scanned. A fetch uses this so
    /// it never writes back licence details the scan has since corrected.
    public func applyingCurrentNote(to asset: Asset) throws -> Asset {
        guard let folderID = asset.remote["folder"], let record = try folderRecord(folderID) else { return asset }
        let note = licenceNote(forFolder: Self.folderPart(of: asset), root: URL(fileURLWithPath: record.path, isDirectory: true))
        let signature = FolderLicence.signature(note)
        return asset.remote["note"] == signature ? asset : relicense(asset, note: note, signature: signature)
    }

    /// An unchanged file under a changed licence note.
    func relicense(_ asset: Asset, note: FolderLicence?, signature: String) -> Asset {
        var updated = asset
        updated.licenceClass = note?.licenceClass ?? .unknown
        updated.creditLine = note?.credit
        updated.summary = note.map { "From \($0.source)" }
        if let kind = Self.noteKind(note?.kind ?? kindHint(forPath: asset.remote["relativePath"] ?? ""), forFileKind: asset.kind) { updated.kind = kind }
        updated.remote["note"] = signature
        updated.updatedAt = Date()
        return updated
    }

    /// The note's kind, when it suits a file of `kind`: an audio kind for
    /// audio, a picture kind for pictures. A Sonniss note saying "sfx"
    /// shouldn't turn a stray PNG into a sound effect.
    static func noteKind(_ note: FolderLicence?, forFileKind kind: AssetKind) -> AssetKind? {
        noteKind(note?.kind, forFileKind: kind)
    }

    /// `wanted`, when it suits a file of `kind`.
    static func noteKind(_ wanted: AssetKind?, forFileKind kind: AssetKind) -> AssetKind? {
        guard let wanted else { return nil }
        if wanted.isAudio && kind.isAudio { return wanted }
        if wanted.isVisual && kind.isVisual { return wanted }
        return nil
    }

    /// An asset for a file, with its kind guessed from the folder note, its
    /// path and its length.
    func describe(file: URL, relative: String, format: AssetFormat, folderID: String, note: FolderLicence?) async -> Asset {
        let name = ProviderFiles.title(file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".", with: " "))
        let folders = relative.split(separator: "/").dropLast().map(String.init)
        // What the note says the files are, or else where the file is.
        let wanted = note?.kind ?? kindHint(forPath: relative)
        var asset = Asset(
            provider: id,
            providerID: providerID(folderID: folderID, relative: relative),
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
            asset.kind = Self.noteKind(wanted, forFileKind: .sfx) ?? Self.audioKind(path: lowerPath, duration: asset.duration)
        } else if format == .mov || format == .mp4 {
            if let info = try? await MediaProbe.video(file) {
                asset.duration = info.duration
                asset.width = info.width
                asset.height = info.height
                asset.hasAlpha = info.hasAlpha
            }
            asset.kind = Self.noteKind(wanted, forFileKind: .video) ?? (asset.hasAlpha || lowerPath.contains("overlay") ? .overlay : .video)
        } else if format == .webm || format == .lottie {
            asset.kind = Self.noteKind(wanted, forFileKind: .sticker) ?? (lowerPath.contains("overlay") ? .overlay : .sticker)
            asset.hasAlpha = true
        } else if format == .svg {
            asset.kind = Self.noteKind(wanted, forFileKind: .icon) ?? (lowerPath.contains("logo") ? .logo : .icon)
            asset.hasAlpha = true
        } else if format.isFont {
            asset.kind = .font
        } else if format == .cube {
            asset.kind = .lut
        } else if format.isStillOrAnimatedImage {
            if let info = MediaProbe.image(file) {
                asset.width = info.width
                asset.height = info.height
                asset.hasAlpha = info.hasAlpha || format == .gif
                // Animated GIF, WebP and APNG are stickers.
                if info.frames > 1 { asset.kind = Self.noteKind(wanted, forFileKind: .sticker) ?? (lowerPath.contains("overlay") ? .overlay : .sticker) }
            }
            if asset.kind == .image {
                asset.kind = Self.noteKind(wanted, forFileKind: .image) ?? (lowerPath.contains("overlay") ? .overlay : .image)
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

/// Runs one scan per folder at a time. A scan asked for while one runs
/// waits for it and then runs once, shared by everyone who asked meanwhile.
actor ScanQueue {
    private var running: [String: Task<ImportScanReport, Error>] = [:]
    private var queued: [String: Task<ImportScanReport, Error>] = [:]

    func run(_ id: String, _ work: @escaping @Sendable () async throws -> ImportScanReport) async throws -> ImportScanReport {
        if let next = queued[id] { return try await next.value }
        if let current = running[id] {
            let next = Task<ImportScanReport, Error> {
                _ = await current.result
                return try await self.execute(id, work)
            }
            queued[id] = next
            return try await next.value
        }
        return try await execute(id, work)
    }

    private func execute(_ id: String, _ work: @escaping @Sendable () async throws -> ImportScanReport) async throws -> ImportScanReport {
        queued[id] = nil
        let task = Task { try await work() }
        running[id] = task
        let result = await task.result
        if running[id] == task { running[id] = nil }
        return try result.get()
    }
}

/// Errors collected from the file enumerator's callback.
final class ProblemList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ problem: String) {
        lock.lock()
        items.append(problem)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Watches import folders with FSEvents and calls back (debounced) with
/// the folders that changed.
public final class ImportFolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "tandem.assets.import-watcher")
    private static let queueKey = DispatchSpecificKey<Bool>()

    /// What the FSEvents callback reaches. The stream retains it, so a
    /// callback already running when the watcher goes away still has
    /// something valid to call; it never points back at the watcher.
    private final class Relay: @unchecked Sendable {
        /// Watched folders as given, keyed by their real path. FSEvents
        /// reports real paths (`/private/var/...` for `/var/...`).
        let roots: [(real: String, given: String)]
        let handler: @Sendable ([String]) -> Void

        init(roots: [(real: String, given: String)], handler: @escaping @Sendable ([String]) -> Void) {
            self.roots = roots
            self.handler = handler
        }

        func deliver(_ paths: [String]) {
            // The licence note changing matters too, so every file counts.
            let touched = roots.filter { root in paths.contains { $0 == root.real || $0.hasPrefix(root.real + "/") } }.map(\.given)
            guard !touched.isEmpty else { return }
            handler(touched)
        }
    }

    /// Starts watching `paths`. `handler` gets the watched folders (as
    /// passed in) that saw changes, at most every `latency` seconds.
    public init(paths: [String], latency: TimeInterval = 1, handler: @escaping @Sendable ([String]) -> Void) {
        queue.setSpecific(key: Self.queueKey, value: true)
        guard !paths.isEmpty else { return }
        let relay = Relay(roots: paths.map { (Self.realPath($0), $0) }, handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(relay).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Relay>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Relay>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let relay = Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            relay.deliver(Array(changed.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        let watched = relay.roots.map(\.real) as CFArray
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

    /// Stops watching. Also happens when the watcher is released. Runs on
    /// the watcher's queue, so no callback is part-way through when the
    /// stream lets go of what it calls.
    public func stop() {
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            stopOnQueue()
        } else {
            queue.sync { stopOnQueue() }
        }
    }

    private func stopOnQueue() {
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
