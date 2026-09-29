import Foundation
import TandemAssets
import TandemCore
import TandemMedia

/// The asset library for agents: what `tandem assets` and the `assets_*`
/// MCP tools do. The library is Mike's, one per user, at
/// `~/Library/Application Support/Tandem/Assets/`, shared with the app's
/// browser; its SQLite catalogue copes with several processes at once.
///
/// Searching, fetching and generating don't touch a project. `use` copies
/// the asset into the project folder, records the use (for credits) and
/// sends the edit that adds and places it through `ProjectClient`, so it
/// lands in the app when the app has the project open. `credits` reads the
/// project the same way.
public final class AssetService: @unchecked Sendable {
    public let library: AssetLibrary

    public init(library: AssetLibrary) {
        self.library = library
    }

    /// The per-user library. `$TANDEM_ASSETS_ROOT` moves it (for tests),
    /// and `$TANDEM_ASSETS_OFFLINE=1` keeps it off the network and out of
    /// the Keychain: providers fail as if offline and have no keys. The
    /// shared library is where `SharedLibrary.locate` says
    /// (`$TANDEM_LIBRARY`, the settings, or `~/Movies/Tandem Library`).
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> AssetService {
        let offline = environment["TANDEM_ASSETS_OFFLINE"] == "1"
        let transport: HTTPTransport = offline ? OfflineTransport() : URLSessionTransport()
        let secrets: SecretStore = offline ? StaticSecretStore() : KeychainSecretStore()
        let shared = SharedLibrary.locate(environment: environment).root
        let library: AssetLibrary
        do {
            if let root = environment["TANDEM_ASSETS_ROOT"], !root.isEmpty {
                let url = URL(fileURLWithPath: NSString(string: root).expandingTildeInPath, isDirectory: true)
                library = try AssetLibrary(root: url, previewFolder: url.appendingPathComponent("previews", isDirectory: true), transport: transport, secrets: secrets, sharedLibrary: shared)
            } else {
                library = try AssetLibrary(transport: transport, secrets: secrets, sharedLibrary: shared)
            }
        } catch {
            throw ServiceError.wrap(error)
        }
        return AssetService(library: library)
    }

    /// Runs any asset call with JSON in and out, for MCP.
    public func handle(_ operation: AssetOperation, body: Data, project: () throws -> ProjectClient) async throws -> any ReadableResult & Encodable {
        try await handle(operation.callType, body: body, project: project)
    }

    private func handle<C: AssetCall>(_ type: C.Type, body: Data, project: () throws -> ProjectClient) async throws -> any ReadableResult & Encodable {
        let call = try ServiceJSON.decodeRequest(C.self, from: body)
        let client = C.needsProject ? try project() : nil
        return try await call.run(on: self, project: client)
    }

    // MARK: - providers

    public func providers() async -> AssetProvidersResult {
        AssetProvidersResult(providers: await library.providerInfo())
    }

    // MARK: - search

    public func search(_ request: AssetSearchRequest) async throws -> AssetSearchResult {
        let limit = max(1, min(request.limit ?? 20, 200))
        let known = Set(library.providers.map(\.id))
        if let unknown = request.providers.first(where: { !known.contains($0) }) {
            throw ServiceError(.notFound, "No provider called \"\(unknown)\". Providers: \(library.providers.map(\.id).joined(separator: ", ")).")
        }
        let query = AssetQuery(
            text: request.text,
            kinds: Set(request.kinds),
            providers: Set(request.providers),
            maxDuration: request.maxDuration,
            limit: limit
        )
        var online: [AssetLibrary.ProviderResults]?
        if request.online {
            // Ask first, so what the providers found is in the catalogue and
            // can be fetched or used by ID straight away.
            let providerQuery = ProviderQuery(text: request.text, kinds: Set(request.kinds), perPage: limit, maxDuration: request.maxDuration)
            online = await library.searchProviders(providerQuery, providerIDs: request.providers.isEmpty ? nil : request.providers)
        }
        do {
            let local = try library.search(query)
            let total = try library.count(query)
            return AssetSearchResult(text: request.text, local: local, total: total, online: online)
        } catch {
            throw ServiceError.wrap(error)
        }
    }

    // MARK: - fetch

    public func fetch(_ request: AssetFetchRequest) async throws -> AssetFetchResult {
        let asset = try await fetched(request.id)
        return AssetFetchResult(asset: asset, file: library.playableURL(for: asset)?.path, licence: try? library.licence(for: asset.id))
    }

    /// Fetches an asset, explaining an unknown ID.
    func fetched(_ id: String) async throws -> Asset {
        do {
            return try await library.fetch(id)
        } catch let error as AssetError {
            if case .notFound = error, (try? library.asset(id)) == nil {
                throw ServiceError(.notFound, "No asset \(id) in the library. Search for it first (tandem assets search \"...\" --online), then use the ID the search gives.")
            }
            throw ServiceError.wrap(error)
        }
    }

    // MARK: - use

    public func use(_ request: AssetUseRequest, project client: ProjectClient) async throws -> AssetUseResult {
        let folder = ProjectFolder(projectFile: client.projectURL)
        var (project, revision) = try await read(client)
        let placement: AssetPlacement
        do {
            _ = try await fetched(request.id)
            placement = try await library.use(request.id, in: folder, projectID: project.id, projectFile: client.projectURL)
        } catch {
            throw ServiceError.wrap(error)
        }
        let asset = placement.asset
        var result = AssetUseResult(
            asset: asset, mediaID: nil, files: placement.files, referencedInPlace: placement.referencedInPlace ? true : nil,
            role: placement.role, trackName: placement.trackName,
            gainDB: placement.gainDB, at: request.at, applied: nil,
            fonts: (asset.remote["fonts"] ?? "").split(separator: "\n").map(String.init),
            licence: try? library.licence(for: asset.id)
        )
        // The project can change between reading it and editing it (the
        // app's folder watcher may add the copied file itself), so a stale
        // revision means read again and rebuild the edit.
        for attempt in 1...3 {
            let (commands, mediaID) = Self.commands(for: placement, at: request.at, duration: request.duration, mode: request.mode, in: project)
            result.mediaID = mediaID
            guard !commands.isEmpty else { return result }
            let label = request.label ?? (request.at.map { "Add \(asset.name) at \($0)" } ?? "Add \(asset.name) to media")
            do {
                result.applied = try await client.call(ApplyRequest(label: label, author: request.author, commands: commands, expectedRevision: revision))
                return result
            } catch let error as ServiceError where error.knownCode == .staleRevision && attempt < 3 {
                (project, revision) = try await read(client)
            }
        }
        return result
    }

    /// The edit that adds (and with `at`, places) an asset: the placement's
    /// own commands, reusing a media item that already has the copied file
    /// so it's never in the project twice.
    static func commands(for placement: AssetPlacement, at time: Time?, duration: Time?, mode: InsertMode?, in project: Project) -> (commands: [EditCommand], mediaID: String?) {
        guard var item = placement.mediaItem else { return ([], nil) }
        var placement = placement
        if project.media(item.id) == nil, let existing = project.media.first(where: { $0.path == item.path }) {
            item.id = existing.id
            placement.mediaItem = item
        }
        if let time {
            return (placement.editCommands(at: time, in: project, duration: duration, mode: mode), item.id)
        }
        return (project.media(item.id) == nil ? [.addMedia(item: item)] : [], item.id)
    }

    /// The project as it is now, wherever it's open.
    func read(_ client: ProjectClient) async throws -> (Project, Int) {
        let result = try await client.call(TimelineRequest(format: .json))
        guard let project = result.project else { throw ServiceError(.internalError, "The project didn't come back.") }
        return (project, result.revision)
    }

    // MARK: - credits

    public func credits(_ request: AssetCreditsRequest, project client: ProjectClient) async throws -> AssetCreditsResult {
        let (project, _) = try await read(client)
        do {
            let credits = try library.credits(for: project, in: ProjectFolder(projectFile: client.projectURL))
            let optional = request.includeOptional ?? false
            return AssetCreditsResult(text: credits.text(includeOptional: optional), credits: credits, includeOptional: optional)
        } catch {
            throw ServiceError.wrap(error)
        }
    }

    // MARK: - generate

    public func generate(_ request: AssetGenerateRequest) async throws -> AssetGenerateResult {
        let generation = GenerationRequest(
            kind: request.kind, prompt: request.prompt, duration: request.duration,
            loop: request.loop ?? false, instrumental: !(request.vocals ?? false),
            variations: request.variations ?? 1
        )
        do {
            let made = try await library.generate(generation)
            return AssetGenerateResult(assets: made.assets, failures: made.failures)
        } catch {
            throw ServiceError.wrap(error)
        }
    }

    // MARK: - install-starter

    public func installStarter() throws -> AssetInstallStarterResult {
        do {
            let assets = try library.installStarterContent()
            var counts: [String: Int] = [:]
            for asset in assets { counts[asset.kind.rawValue, default: 0] += 1 }
            return AssetInstallStarterResult(counts: counts, total: assets.count)
        } catch {
            throw ServiceError.wrap(error)
        }
    }
}

/// A transport for `TANDEM_ASSETS_OFFLINE=1`: every request fails as if
/// the Mac were offline.
public struct OfflineTransport: HTTPTransport {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }

    public func download(for request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        throw URLError(.notConnectedToInternet)
    }
}
