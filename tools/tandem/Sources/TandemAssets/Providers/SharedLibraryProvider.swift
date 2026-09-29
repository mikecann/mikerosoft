import Foundation

/// The shared library (`SharedLibrary`, `~/Movies/Tandem Library` by
/// default) as an asset source: its files indexed like an import folder's,
/// with the `Shared library` chip. What sets it apart:
///
/// - a file's folder says what it is (a sound in Music is music), so
///   `Stickers/`, `Graphics/`, `Sound effects/`, `Music/`, `Looks/` and
///   `Fonts/` fill the right tabs;
/// - `Segments/` isn't indexed (segments are listed by `SegmentStore`), nor
///   are the READMEs;
/// - licence notes (`tandem-licence.json`) can sit in any folder, and the
///   nearest one above a file covers it;
/// - asset IDs are the path inside the library (`shared:Stickers/wave.mov`),
///   so they survive the library moving;
/// - using one references the file where it is rather than copying it
///   into the project (`AssetLibrary.use`).
public final class SharedLibraryProvider: ImportFolderProvider, @unchecked Sendable {
    public static let providerID = "shared"
    /// The folder ID its rows carry (`remote["folder"]`).
    static let folderID = "library"

    private let lock = NSLock()
    private var current: SharedLibrary

    public init(catalog: AssetCatalog, library: SharedLibrary) {
        current = library
        super.init(
            catalog: catalog, id: Self.providerID, displayName: "Shared library",
            rules: ProviderRules(cacheTTL: 0, notes: [
                "Files in your Tandem Library folder, used where they are: projects refer to them, and archiving copies them in.",
                "A tandem-licence.json in a file's folder, or any folder above it, says what it may be used for."
            ])
        )
    }

    /// The library it indexes.
    public var library: SharedLibrary {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Points it at another folder. The next scan describes every file
    /// again where it is now; files only the old folder had go.
    public func move(to library: SharedLibrary) {
        lock.lock()
        current = library
        lock.unlock()
    }

    public override func status() async -> ProviderStatus {
        let library = self.library
        return library.exists ? .ready : ProviderStatus(.ready, "\(library.root.path) isn't there yet; Tandem makes it when it opens")
    }

    /// Scans the library, if it's there.
    public func scanLibrary() async throws -> ImportScanReport {
        let library = self.library
        guard library.exists else {
            throw AssetError.notFound("the shared library at \(library.root.path)")
        }
        return try await scan(record(for: library))
    }

    private func record(for library: SharedLibrary) -> AssetCatalog.ImportFolderRecord {
        AssetCatalog.ImportFolderRecord(id: Self.folderID, path: library.root.path, name: library.root.lastPathComponent)
    }

    // MARK: - Folder indexing

    override func folderRecord(_ folderID: String) throws -> AssetCatalog.ImportFolderRecord? {
        folderID == Self.folderID ? record(for: library) : nil
    }

    override func saveScan(_ assets: [Asset], folderID: String) throws -> Bool {
        try catalog.upsert(assets)
        return true
    }

    override func scanned(_ folderID: String) throws {}

    /// The nearest note at or above `folder`, up to the library's root.
    override func licenceNote(forFolder folder: String, root: URL) -> FolderLicence? {
        var parts = folder.split(separator: "/").map(String.init)
        while true {
            let url = parts.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            if let note = FolderLicence.read(in: url) { return note }
            if parts.isEmpty { return nil }
            parts.removeLast()
        }
    }

    override func kindHint(forPath relative: String) -> AssetKind? {
        guard let folder = SharedLibrary.Folder.of(relative) else { return nil }
        if folder == .graphics {
            // SVGs are icons or logos by their name; other pictures are
            // overlays unless they say they're a logo.
            if relative.lowercased().hasSuffix(".svg") { return nil }
            return relative.lowercased().contains("logo") ? .logo : .overlay
        }
        return folder.kind
    }

    override func skips(_ relative: String, isFolder: Bool) -> Bool {
        if isFolder { return SharedLibrary.Folder.of(relative) == .segments && !relative.contains("/") }
        return SharedLibrary.isReadme((relative as NSString).lastPathComponent)
    }

    override func providerID(folderID: String, relative: String) -> String {
        relative
    }
}
