import CryptoKit
import Foundation
import TandemCore
import TandemMedia

/// The asset library as the app, the CLI and MCP see it: search the local
/// catalogue or the providers, fetch and normalise, generate, use an asset
/// in a project, and build the description credits.
///
/// Disk layout under `root` (default
/// `~/Library/Application Support/Tandem/Assets/`):
///
///     catalog.sqlite           the index
///     settings.json            AssetSettings
///     <provider>/<id>/         meta.json thumbnail.jpg|png original.<ext>
///                              normalised.<ext> peaks.bin loudness.json
///     cache/http/<provider>/   provider responses, kept per provider rules
///     providers/               small provider state (refused permissions)
///
/// Previews live in `~/Library/Caches/Tandem/AssetPreviews/`, size capped.
public final class AssetLibrary: @unchecked Sendable {
    public let root: URL
    public let catalog: AssetCatalog
    public let normaliser: AssetNormaliser
    public let settings: AssetSettings
    public let previews: PreviewCache
    public let environment: ProviderEnvironment
    private var registry: [String: AssetProvider] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    private let fetches = FetchQueue()

    /// `~/Library/Application Support/Tandem/Assets/`.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tandem", isDirectory: true)
            .appendingPathComponent("Assets", isDirectory: true)
    }

    /// `~/Library/Caches/Tandem/AssetPreviews/`.
    public static var defaultPreviewFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tandem", isDirectory: true)
            .appendingPathComponent("AssetPreviews", isDirectory: true)
    }

    /// Opens the library at `root`, creating it if needed. With no
    /// `providers`, every built-in provider is registered (see
    /// `defaultProviders`); tests pass their own transport and secrets.
    public init(
        root: URL = AssetLibrary.defaultRoot,
        previewFolder: URL? = nil,
        transport: HTTPTransport = URLSessionTransport(),
        secrets: SecretStore = KeychainSecretStore(),
        normaliser: AssetNormaliser = AssetNormaliser(),
        settings: AssetSettings? = nil,
        providers: [AssetProvider]? = nil
    ) throws {
        // Create the folder before standardising: standardizedFileURL only
        // drops a leading /private from paths that exist.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.standardizedFileURL
        catalog = try AssetCatalog(url: self.root.appendingPathComponent("catalog.sqlite"))
        self.normaliser = normaliser
        let settings = settings ?? AssetSettings.load(from: self.root)
        self.settings = settings
        environment = ProviderEnvironment(
            transport: transport,
            secrets: secrets,
            cacheFolder: self.root.appendingPathComponent("cache/http", isDirectory: true),
            stateFolder: self.root.appendingPathComponent("providers", isDirectory: true)
        )
        previews = PreviewCache(folder: previewFolder ?? Self.defaultPreviewFolder, limit: settings.previewCacheLimit, transport: transport)
        for provider in providers ?? Self.defaultProviders(catalog: catalog, environment: environment, settings: settings) {
            register(provider)
        }
    }

    /// Every built-in provider, in the order the browser shows them.
    public static func defaultProviders(catalog: AssetCatalog, environment: ProviderEnvironment, settings: AssetSettings) -> [AssetProvider] {
        [
            ImportFolderProvider(catalog: catalog),
            ElevenLabsProvider(environment: environment),
            NotoEmojiProvider(environment: environment),
            IconifyProvider(environment: environment, colour: settings.iconColour),
            SVGLProvider(environment: environment),
            FontsourceProvider(environment: environment),
            PexelsProvider(environment: environment),
            PixabayProvider(environment: environment),
            FreesoundProvider(environment: environment, enabled: settings.freesoundEnabled),
            EpidemicSoundProvider(),
            LordiconProvider()
        ]
    }

    // MARK: - Providers

    /// Adds or replaces a provider.
    public func register(_ provider: AssetProvider) {
        lock.lock()
        defer { lock.unlock() }
        if registry[provider.id] == nil { order.append(provider.id) }
        registry[provider.id] = provider
    }

    /// The provider with this ID (`noto`, `elevenlabs`...), if registered.
    public func provider(_ id: String) -> AssetProvider? {
        lock.lock()
        defer { lock.unlock() }
        return registry[id]
    }

    /// Every registered provider, in registration order.
    public var providers: [AssetProvider] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { registry[$0] }
    }

    /// Every provider with its status, rules and capabilities.
    public func providerInfo() async -> [ProviderInfo] {
        var result: [ProviderInfo] = []
        for provider in providers { result.append(await provider.info()) }
        return result
    }

    // MARK: - Files

    /// Folder names are the provider ID made safe for a file system, with a
    /// short hash when anything had to change so two IDs never share one.
    static func folderName(for providerID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        var safe = String(providerID.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "_" })
        let changed = safe != providerID || safe.count > 60 || safe.hasPrefix(".")
        if safe.count > 60 { safe = String(safe.prefix(60)) }
        guard changed else { return safe }
        let digest = SHA256.hash(data: Data(providerID.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(safe.trimmingCharacters(in: CharacterSet(charactersIn: "._")))-\(digest)"
    }

    /// `<root>/<provider>/<id>/`.
    public func folder(for asset: Asset) -> URL {
        root.appendingPathComponent(asset.provider, isDirectory: true)
            .appendingPathComponent(Self.folderName(for: asset.providerID), isDirectory: true)
    }

    /// An asset folder's path relative to the root, as stored in the catalogue.
    func relativeFolder(_ folder: URL) throws -> String {
        guard let relative = Paths.relative(folder, to: root) else {
            throw AssetError.invalid("\(folder.path) isn't inside the library at \(root.path)")
        }
        return relative
    }

    /// The files the library keeps for an asset.
    public enum AssetFile: String, Sendable {
        case original, normalised, thumbnail, peaks, meta, loudness
    }

    /// Where one of an asset's files is, or nil if the library has none.
    public func url(for asset: Asset, _ file: AssetFile) -> URL? {
        let folder = asset.files.folder.map { root.appendingPathComponent($0, isDirectory: true) } ?? self.folder(for: asset)
        func local(_ name: String?) -> URL? {
            guard let name else { return nil }
            return name.hasPrefix("/") ? URL(fileURLWithPath: name) : folder.appendingPathComponent(name)
        }
        switch file {
        case .original: return local(asset.files.original)
        case .normalised: return local(asset.files.normalised)
        case .thumbnail: return local(asset.files.thumbnail)
        case .peaks: return local(asset.files.peaks)
        case .meta: return folder.appendingPathComponent("meta.json")
        case .loudness: return asset.loudness == nil ? nil : folder.appendingPathComponent("loudness.json")
        }
    }

    /// The file the editor plays: the normalised copy, or the original when
    /// it's used as it is.
    public func playableURL(for asset: Asset) -> URL? {
        url(for: asset, .normalised) ?? url(for: asset, .original)
    }

    /// Waveform peaks for an audio asset.
    public func waveform(for asset: Asset) -> Waveform? {
        guard let url = url(for: asset, .peaks) else { return nil }
        return try? AudioNormaliser.readPeaks(from: url)
    }

    // MARK: - Searching

    /// Searches the local catalogue: everything downloaded, imported,
    /// generated, starter content and recent provider results.
    public func search(_ query: AssetQuery) throws -> [Asset] {
        try catalog.search(query)
    }

    /// How many catalogue assets match, ignoring limit and offset.
    public func count(_ query: AssetQuery) throws -> Int {
        try catalog.count(query)
    }

    /// One asset from the catalogue.
    public func asset(_ id: String) throws -> Asset? {
        try catalog.asset(id: id)
    }

    /// One provider's answer to a search.
    public struct ProviderResults: Codable, Sendable {
        public var provider: String
        public var assets: [Asset]
        /// Why the provider couldn't answer, if it couldn't.
        public var error: String?
    }

    /// Searches providers at once and records what they return in the
    /// catalogue (as `remote`), so a later `fetch` or `use` can find the
    /// asset by ID, even from another process. `providerIDs` names the
    /// providers to ask, and each gets an entry, with the reason when it
    /// can't answer. Without it, every usable provider that offers the
    /// requested kinds is asked.
    public func searchProviders(_ query: ProviderQuery, providerIDs: [String]? = nil) async -> [ProviderResults] {
        var candidates: [AssetProvider] = []
        for provider in providers where provider.capabilities.search {
            if let providerIDs, !providerIDs.contains(provider.id) { continue }
            if !query.kinds.isEmpty && query.kinds.isDisjoint(with: provider.kinds) { continue }
            if providerIDs == nil, await !provider.status().isUsable { continue }
            candidates.append(provider)
        }
        return await withTaskGroup(of: (Int, ProviderResults).self) { group in
            for (index, provider) in candidates.enumerated() {
                group.addTask {
                    let status = await provider.status()
                    guard status.isUsable else {
                        return (index, ProviderResults(provider: provider.id, assets: [], error: status.message ?? status.state.rawValue))
                    }
                    do {
                        let found = try await provider.search(query)
                        let stored = (try? self.catalog.mergeRemote(found)) ?? found
                        return (index, ProviderResults(provider: provider.id, assets: stored, error: nil))
                    } catch {
                        return (index, ProviderResults(provider: provider.id, assets: [], error: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
                    }
                }
            }
            var results: [(Int, ProviderResults)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Assets like this one, from providers that can tell (Freesound).
    public func similar(to id: String, limit: Int = 20) async throws -> [Asset] {
        guard let asset = try catalog.asset(id: id) else { throw AssetError.notFound("asset \(id)") }
        guard let provider = provider(asset.provider), provider.capabilities.similar else {
            throw AssetError.unsupported("\(asset.provider) can't find similar assets")
        }
        return try catalog.mergeRemote(try await provider.similar(to: asset, limit: limit))
    }

    // MARK: - Favourites and licences

    /// Marks or unmarks a favourite. Favourites keep their files on disk.
    public func setFavourite(_ id: String, _ favourite: Bool) throws {
        guard try catalog.asset(id: id) != nil else { throw AssetError.notFound("asset \(id)") }
        try catalog.setFavourite(id, favourite)
    }

    /// The licence snapshot taken when the asset was downloaded.
    public func licence(for id: String) throws -> AssetLicence? {
        try catalog.licence(for: id)
    }

    // MARK: - Fetching

    /// Downloads an asset's original (if it isn't already on disk),
    /// snapshots its licence, normalises it and makes a thumbnail. Safe to
    /// call twice at once for the same asset: the second call waits for the
    /// first.
    @discardableResult
    public func fetch(_ id: String) async throws -> Asset {
        try await fetches.run(id) { try await self.performFetch(id) }
    }

    private func performFetch(_ id: String) async throws -> Asset {
        guard let stored = try catalog.asset(id: id) else { throw AssetError.notFound("asset \(id)") }
        if stored.state == .normalised, let playable = playableURL(for: stored), FileManager.default.fileExists(atPath: playable.path) {
            return stored
        }
        guard let provider = provider(stored.provider) else {
            throw AssetError.providerUnavailable(provider: stored.provider, reason: "no provider with that name is registered")
        }
        let folder = self.folder(for: stored)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var fetched: FetchedOriginal
        if stored.state >= .original, let original = url(for: stored, .original), FileManager.default.fileExists(atPath: original.path) {
            let extras = (stored.remote["extraFiles"] ?? "").split(separator: "\n").map { folder.appendingPathComponent(String($0)) }
            fetched = FetchedOriginal(asset: stored, file: original, extras: extras)
        } else {
            let status = await provider.status()
            guard status.isUsable else {
                throw AssetError.providerUnavailable(provider: provider.displayName, reason: status.message ?? status.state.rawValue)
            }
            fetched = try await provider.fetchOriginal(stored, into: folder)
        }
        if try catalog.licence(for: id) == nil {
            try catalog.addLicence(try await provider.licence(for: fetched.asset), for: id)
        }
        return try await finish(fetched, id: id, provider: provider, folder: folder)
    }

    /// Normalises a fetched original and records the result.
    private func finish(_ fetched: FetchedOriginal, id: String, provider: AssetProvider, folder: URL) async throws -> Asset {
        var asset = fetched.asset
        asset.id = id
        let original = fetched.file
        let inFolder = Paths.relative(original, to: folder) == original.lastPathComponent
        asset.files.folder = try relativeFolder(folder)
        asset.files.original = inFolder ? original.lastPathComponent : original.standardizedFileURL.path
        let extras = fetched.extras.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !extras.isEmpty { asset.remote["extraFiles"] = extras.map(\.lastPathComponent).joined(separator: "\n") }
        if asset.sha256 == nil || asset.state < .original {
            let (digest, size) = try await AssetNormaliser.offload { try Self.sha256(of: original) }
            asset.sha256 = digest
            asset.size = size
        }

        let result = try await normaliser.normalise(original, into: folder, fallbacks: extras)
        if !result.fonts.isEmpty, normaliser.registersFonts, !extras.isEmpty {
            await FontInstaller.register(extras)
        }
        asset.files.normalised = result.file
        asset.files.thumbnail = result.thumbnail
        asset.files.peaks = result.peaks
        asset.loudness = result.loudness
        asset.duration = result.duration ?? asset.duration
        asset.width = result.width ?? asset.width
        asset.height = result.height ?? asset.height
        asset.hasAlpha = result.mediaKind == nil ? asset.hasAlpha : result.hasAlpha
        if let frameRate = result.frameRate { asset.remote["frameRate"] = String(frameRate) }
        asset.remote["format"] = result.format.rawValue
        asset.remote["mediaKind"] = result.mediaKind?.rawValue
        asset.remote["hasAudio"] = result.hasAudio ? "1" : "0"
        asset.remote["hasVideo"] = result.hasVideo ? "1" : "0"
        if !result.fonts.isEmpty { asset.remote["fonts"] = result.fonts.map(\.postScriptName).joined(separator: "\n") }
        if let licence = try catalog.licence(for: id) {
            asset.licenceClass = licence.licenceClass
            asset.creditLine = licence.creditLine ?? asset.creditLine
        }
        asset.state = .normalised
        asset.updatedAt = Date()
        try catalog.upsert(asset)
        try writeMeta(asset, normalised: result)
        return try catalog.asset(id: id) ?? asset
    }

    /// What `meta.json` holds: enough to rebuild the catalogue row.
    public struct AssetMeta: Codable, Sendable {
        public var asset: Asset
        public var licence: AssetLicence?
        public var normalised: NormalisedAsset?
    }

    private func writeMeta(_ asset: Asset, normalised: NormalisedAsset?) throws {
        guard let url = url(for: asset, .meta) else { return }
        let meta = AssetMeta(asset: asset, licence: try catalog.licence(for: asset.id), normalised: normalised)
        try JSONEncoder.sorted.encode(meta).write(to: url, options: .atomic)
    }

    static func sha256(of url: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    /// The cached preview for an asset, downloaded if needed, for hover
    /// playback in the browser.
    public func previewFile(for id: String) async throws -> URL {
        guard let asset = try catalog.asset(id: id) else { throw AssetError.notFound("asset \(id)") }
        if let local = url(for: asset, .normalised) ?? url(for: asset, .original), FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        guard let remote = provider(asset.provider)?.previewURL(for: asset) ?? asset.previewURL else {
            throw AssetError.notFound("preview for \(asset.name)")
        }
        let file = try await previews.fetch(remote)
        if asset.state < .preview {
            var updated = asset
            updated.state = .preview
            try catalog.upsert(updated)
        }
        return file
    }

    // MARK: - Generating

    /// Makes new assets with a generating provider (ElevenLabs), normalises
    /// them and adds them to the catalogue with their prompt, so a kept
    /// result can be found again and remade.
    public func generate(_ request: GenerationRequest, provider providerID: String = "elevenlabs") async throws -> [Asset] {
        guard let provider = provider(providerID) else { throw AssetError.notFound("provider \(providerID)") }
        guard provider.capabilities.generate else { throw AssetError.unsupported("\(provider.displayName) can't generate assets") }
        let status = await provider.status()
        guard status.isUsable else {
            throw AssetError.providerUnavailable(provider: provider.displayName, reason: status.message ?? status.state.rawValue)
        }
        let staging = root.appendingPathComponent("staging/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let takes = try await provider.generate(request, into: staging)
        var made: [Asset] = []
        for take in takes {
            var asset = take.asset
            let folder = self.folder(for: asset)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let original = folder.appendingPathComponent("original.\(take.file.pathExtension)")
            try? FileManager.default.removeItem(at: original)
            try FileManager.default.moveItem(at: take.file, to: original)
            asset.state = .original
            asset.files.folder = try relativeFolder(folder)
            asset.files.original = original.lastPathComponent
            try catalog.upsert(asset)
            try catalog.addLicence(try await provider.licence(for: asset), for: asset.id)
            made.append(try await finish(FetchedOriginal(asset: asset, file: original), id: asset.id, provider: provider, folder: folder))
        }
        return made
    }

    // MARK: - Import folders

    /// The watched import folders.
    public func importFolders() throws -> [AssetCatalog.ImportFolderRecord] {
        try catalog.importFolders()
    }

    /// Adds a folder of hand-downloaded assets and indexes it. Pass a
    /// licence note (or one of `FolderLicence.presets`) to write it into the
    /// folder; an existing note is kept otherwise.
    @discardableResult
    public func addImportFolder(_ url: URL, name: String? = nil, licence: FolderLicence? = nil) async throws -> ImportScanReport {
        let folder = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AssetError.notFound("folder \(folder.path)")
        }
        if let licence { try licence.write(in: folder) }
        let record = AssetCatalog.ImportFolderRecord(id: ImportFolderProvider.folderID(for: folder), path: folder.path, name: name ?? folder.lastPathComponent)
        try catalog.saveImportFolder(record)
        return try await importProvider().scan(record)
    }

    /// Stops watching a folder and forgets its assets, except any used in a
    /// project or favourited (their licence history stays either way).
    public func removeImportFolder(_ id: String) throws {
        let pinned = try catalog.pinnedIDs()
        for asset in try catalog.search(AssetQuery(providers: ["import"], limit: Int.max)) where asset.remote["folder"] == id {
            if !pinned.contains(asset.id) { try catalog.delete(id: asset.id) }
        }
        try catalog.removeImportFolder(id: id)
    }

    /// Rescans every import folder.
    public func rescanImportFolders() async throws -> [ImportScanReport] {
        let provider = try importProvider()
        var reports: [ImportScanReport] = []
        for record in try catalog.importFolders() {
            reports.append(try await provider.scan(record))
        }
        return reports
    }

    /// Watches the import folders and rescans the ones that change. Keep
    /// the returned watcher; dropping it stops watching. It covers the
    /// folders registered now, so make a new one after adding a folder.
    public func watchImportFolders(onChange: @escaping @Sendable ([ImportScanReport]) -> Void) throws -> ImportFolderWatcher {
        let records = try catalog.importFolders()
        let provider = try importProvider()
        return ImportFolderWatcher(paths: records.map(\.path)) { roots in
            Task {
                var reports: [ImportScanReport] = []
                for record in records where roots.contains(record.path) {
                    if let report = try? await provider.scan(record) { reports.append(report) }
                }
                if !reports.isEmpty { onChange(reports) }
            }
        }
    }

    private func importProvider() throws -> ImportFolderProvider {
        guard let provider = provider("import") as? ImportFolderProvider else {
            throw AssetError.providerUnavailable(provider: "Import folders", reason: "not registered")
        }
        return provider
    }

    // MARK: - Fonts

    /// Registers every downloaded font with Core Text for this process. The
    /// app calls this at launch so titles can use library fonts.
    @discardableResult
    public func registerFonts() async throws -> [URL: String] {
        var files: [URL] = []
        for asset in try catalog.search(AssetQuery(kinds: [.font], minState: .original, limit: Int.max)) {
            if let original = url(for: asset, .original) { files.append(original) }
            let folder = self.folder(for: asset)
            files += (asset.remote["extraFiles"] ?? "").split(separator: "\n").map { folder.appendingPathComponent(String($0)) }
        }
        return await FontInstaller.register(files.filter { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// Registers the fonts a project carries in `assets/font/`, so a project
    /// opened on another Mac renders its titles the same.
    @discardableResult
    public static func registerFonts(in project: ProjectFolder) async -> [URL: String] {
        let folder = project.assetsFolder.appendingPathComponent(AssetKind.font.rawValue, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return await FontInstaller.register(files.filter { FormatSniffer.fromExtension($0.pathExtension).isFont })
    }

    // MARK: - Housekeeping

    /// Forgets provider results nobody used, favourited or downloaded in
    /// `age` seconds, and trims the preview cache. Returns rows removed.
    @discardableResult
    public func prune(olderThan age: TimeInterval = 30 * 24 * 3600) throws -> Int {
        previews.trim()
        return try catalog.pruneRemote(notUpdatedSince: Date().addingTimeInterval(-age))
    }
}

/// Runs at most one fetch per asset at a time; later callers wait for the
/// running one.
actor FetchQueue {
    private var running: [String: Task<Asset, Error>] = [:]

    func run(_ id: String, _ work: @escaping @Sendable () async throws -> Asset) async throws -> Asset {
        if let task = running[id] { return try await task.value }
        let task = Task { try await work() }
        running[id] = task
        defer { running[id] = nil }
        return try await task.value
    }
}

extension AssetLibrary {
    // MARK: - Disk space

    /// Frees disk by deleting the files of downloaded assets that aren't
    /// favourites, aren't used in any project and haven't changed in `age`
    /// seconds. Their catalogue rows go back to `remote`, so they can be
    /// fetched again. Generated assets are never touched (they can't be
    /// downloaded again), and files in import folders stay where they are;
    /// only the library's normalised copies of them go. Returns the IDs of
    /// the assets whose files were deleted.
    @discardableResult
    public func evictUnpinnedFiles(olderThan age: TimeInterval = 90 * 24 * 3600) throws -> [String] {
        let pinned = try catalog.pinnedIDs()
        let cutoff = Date().addingTimeInterval(-age)
        var evicted: [String] = []
        for asset in try catalog.search(AssetQuery(minState: .original, limit: Int.max)) {
            guard !pinned.contains(asset.id), asset.updatedAt < cutoff else { continue }
            guard let provider = provider(asset.provider), !provider.capabilities.generate else { continue }
            let folder = self.folder(for: asset)
            var updated = asset
            if asset.provider == "import" {
                // The original is Mike's file in his folder; keep it.
                updated.state = .original
                let original = asset.files.original
                updated.files = AssetFiles(original: original)
            } else {
                updated.state = .remote
                updated.files = AssetFiles()
                updated.sha256 = nil
            }
            updated.loudness = nil
            try? FileManager.default.removeItem(at: folder)
            try catalog.upsert(updated)
            evicted.append(asset.id)
        }
        return evicted
    }

    /// Rebuilds catalogue rows from the `meta.json` files on disk, for when
    /// `catalog.sqlite` has been lost. Favourites and usage live only in
    /// the database and can't come back this way. Returns how many assets
    /// were restored.
    @discardableResult
    public func rebuildCatalogFromDisk() throws -> Int {
        let fileManager = FileManager.default
        var restored = 0
        for provider in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            guard (try? provider.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            for folder in (try? fileManager.contentsOfDirectory(at: provider, includingPropertiesForKeys: nil)) ?? [] {
                let metaURL = folder.appendingPathComponent("meta.json")
                guard let data = try? Data(contentsOf: metaURL),
                      let meta = try? JSONDecoder.iso.decode(AssetMeta.self, from: data) else { continue }
                if try catalog.asset(id: meta.asset.id) == nil {
                    try catalog.upsert(meta.asset)
                    restored += 1
                }
                if let licence = meta.licence, try catalog.licence(for: meta.asset.id) == nil {
                    try catalog.addLicence(licence, for: meta.asset.id)
                }
            }
        }
        return restored
    }
}

extension AssetLibrary {
    /// Removes an asset and its files from the library, for example the
    /// generated takes that weren't kept. Refuses assets used in a project
    /// (their record is the proof of use) and import folder files (delete
    /// those from the folder instead; the next scan notices).
    public func remove(_ id: String) throws {
        guard let asset = try catalog.asset(id: id) else { throw AssetError.notFound("asset \(id)") }
        guard asset.provider != "import" else {
            throw AssetError.invalid("\(asset.name) lives in an import folder; delete the file there and the library will notice")
        }
        guard try catalog.usage(forAsset: id).isEmpty else {
            throw AssetError.invalid("\(asset.name) is used in a project, so its record stays for the credits")
        }
        try? FileManager.default.removeItem(at: folder(for: asset))
        try catalog.delete(id: id)
    }
}
