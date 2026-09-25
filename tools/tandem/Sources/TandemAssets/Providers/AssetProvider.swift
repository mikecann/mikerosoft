import Foundation

/// One source of assets: an import folder, ElevenLabs, Noto emoji, Iconify
/// and so on. Each provider carries its own rules (keys, rate limits, how
/// long responses may be cached) so the library can treat them alike.
///
/// Providers return `Asset` values with `state == .remote`; the library
/// records them in the catalogue, downloads originals into the asset's
/// folder and normalises them.
public protocol AssetProvider: AnyObject, Sendable {
    /// Short stable name used in asset IDs, for example "noto".
    var id: String { get }
    var displayName: String { get }
    /// What it offers, for the source chips in the browser.
    var kinds: Set<AssetKind> { get }
    var rules: ProviderRules { get }
    var capabilities: ProviderCapabilities { get }
    /// The provider's site, for people.
    var website: URL? { get }

    /// Whether it can be used right now, and if not, what to do about it.
    func status() async -> ProviderStatus

    /// Searches the provider. Providers that only generate (ElevenLabs)
    /// return nothing.
    func search(_ query: ProviderQuery) async throws -> [Asset]

    /// A remote preview for the browser: audio, video or an animated image.
    func previewURL(for asset: Asset) -> URL?

    /// Downloads (or locates) the original into `folder`. For import
    /// folders the original stays where it is and its URL is returned.
    func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal

    /// The terms as they stand now, snapshotted by the library at download.
    func licence(for asset: Asset) async throws -> AssetLicence

    /// Assets that sound or look like this one (Freesound, Epidemic).
    func similar(to asset: Asset, limit: Int) async throws -> [Asset]

    /// Makes new assets (ElevenLabs). Each result is already on disk in
    /// `folder`, one subfolder per variation.
    func generate(_ request: GenerationRequest, into folder: URL) async throws -> [FetchedOriginal]
}

extension AssetProvider {
    public var website: URL? { nil }

    public func previewURL(for asset: Asset) -> URL? { asset.previewURL }

    public func similar(to asset: Asset, limit: Int) async throws -> [Asset] {
        throw AssetError.unsupported("\(displayName) can't find similar assets")
    }

    public func generate(_ request: GenerationRequest, into folder: URL) async throws -> [FetchedOriginal] {
        throw AssetError.unsupported("\(displayName) can't generate assets")
    }

    /// A description of the provider for the app and the CLI.
    public func info() async -> ProviderInfo {
        ProviderInfo(
            id: id,
            displayName: displayName,
            kinds: kinds.map(\.rawValue).sorted(),
            status: await status(),
            rules: rules,
            capabilities: capabilities,
            website: website
        )
    }
}

/// What a provider can do beyond fetching.
public struct ProviderCapabilities: Codable, Equatable, Sendable {
    public var search: Bool
    public var similar: Bool
    public var generate: Bool

    public init(search: Bool = true, similar: Bool = false, generate: Bool = false) {
        self.search = search
        self.similar = similar
        self.generate = generate
    }
}

/// A provider's house rules, from its API terms.
public struct ProviderRules: Codable, Equatable, Sendable {
    /// Requests allowed per `window` seconds, when the provider sets a limit.
    public var requestsPerWindow: Int?
    public var window: TimeInterval
    /// Requests allowed at once (ElevenLabs plans cap concurrency).
    public var maxConcurrentRequests: Int?
    /// How long search and index responses are kept and reused, in seconds.
    /// For Pixabay this is a requirement (24 h), not just a courtesy.
    public var cacheTTL: TimeInterval
    /// Terms worth knowing, in plain English, for the app's source panel.
    public var notes: [String]

    public init(requestsPerWindow: Int? = nil, window: TimeInterval = 60, maxConcurrentRequests: Int? = nil, cacheTTL: TimeInterval = 24 * 3600, notes: [String] = []) {
        self.requestsPerWindow = requestsPerWindow
        self.window = window
        self.maxConcurrentRequests = maxConcurrentRequests
        self.cacheTTL = cacheTTL
        self.notes = notes
    }
}

/// Whether a provider can be used, and why not.
public struct ProviderStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Works.
        case ready
        /// Needs an API key in the Keychain.
        case needsKey
        /// Turned off on purpose, for example Freesound until its operator
        /// agrees to commercial API use.
        case disabled
        /// Not built yet because Mike hasn't subscribed.
        case stub
        /// Works, but part of it doesn't (an ElevenLabs key without the
        /// sound effects permission can still make music).
        case limited
    }

    public var state: State
    public var message: String?

    public init(_ state: State, _ message: String? = nil) {
        self.state = state
        self.message = message
    }

    public var isUsable: Bool { state == .ready || state == .limited }

    public static let ready = ProviderStatus(.ready)
}

/// A provider as the app and CLI see it.
public struct ProviderInfo: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var kinds: [String]
    public var status: ProviderStatus
    public var rules: ProviderRules
    public var capabilities: ProviderCapabilities
    public var website: URL?
}

/// A search sent to providers.
public struct ProviderQuery: Codable, Equatable, Sendable {
    public var text: String
    /// Only these kinds; empty means whatever the provider has.
    public var kinds: Set<AssetKind>
    /// 1-based.
    public var page: Int
    public var perPage: Int
    /// Seconds, for providers that can filter by length.
    public var minDuration: Double?
    public var maxDuration: Double?

    public init(text: String, kinds: Set<AssetKind> = [], page: Int = 1, perPage: Int = 30, minDuration: Double? = nil, maxDuration: Double? = nil) {
        self.text = text
        self.kinds = kinds
        self.page = page
        self.perPage = perPage
        self.minDuration = minDuration
        self.maxDuration = maxDuration
    }

    /// True when the provider should answer for `kind`.
    public func wants(_ kind: AssetKind) -> Bool { kinds.isEmpty || kinds.contains(kind) }
}

extension ProviderQuery {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        kinds = try c.decodeIfPresent(Set<AssetKind>.self, forKey: .kinds) ?? []
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 1
        perPage = try c.decodeIfPresent(Int.self, forKey: .perPage) ?? 30
        minDuration = try c.decodeIfPresent(Double.self, forKey: .minDuration)
        maxDuration = try c.decodeIfPresent(Double.self, forKey: .maxDuration)
    }
}

/// A request to make new assets (ElevenLabs sound effects or music).
public struct GenerationRequest: Codable, Equatable, Sendable {
    /// `.sfx` or `.music`.
    public var kind: AssetKind
    public var prompt: String
    /// Seconds. Sound effects take 0.5 to 30; music 3 to 600.
    public var duration: Double?
    /// Sound effects only: make it loop seamlessly.
    public var loop: Bool
    /// Sound effects only, 0 to 1: higher follows the prompt more literally.
    public var promptInfluence: Double?
    /// Music only: no vocals.
    public var instrumental: Bool
    /// How many takes to make. Each one is a separate paid request.
    public var variations: Int
    /// Overrides the provider's default model.
    public var model: String?

    public init(kind: AssetKind, prompt: String, duration: Double? = nil, loop: Bool = false, promptInfluence: Double? = nil, instrumental: Bool = true, variations: Int = 1, model: String? = nil) {
        self.kind = kind
        self.prompt = prompt
        self.duration = duration
        self.loop = loop
        self.promptInfluence = promptInfluence
        self.instrumental = instrumental
        self.variations = variations
        self.model = model
    }
}

extension GenerationRequest {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(AssetKind.self, forKey: .kind) ?? .sfx
        prompt = try c.decode(String.self, forKey: .prompt)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false
        promptInfluence = try c.decodeIfPresent(Double.self, forKey: .promptInfluence)
        instrumental = try c.decodeIfPresent(Bool.self, forKey: .instrumental) ?? true
        variations = try c.decodeIfPresent(Int.self, forKey: .variations) ?? 1
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }
}

/// An original on disk, with whatever the provider learned while fetching
/// it (size, dimensions, a better name).
public struct FetchedOriginal: Sendable {
    public var asset: Asset
    public var file: URL
    /// Other useful files fetched alongside, for example the animated WebP
    /// next to a Lottie original.
    public var extras: [URL]

    public init(asset: Asset, file: URL, extras: [URL] = []) {
        self.asset = asset
        self.file = file
        self.extras = extras
    }
}

/// Everything a provider needs from the outside world, injectable so tests
/// run against recorded responses.
public struct ProviderEnvironment: Sendable {
    public var transport: HTTPTransport
    public var secrets: SecretStore
    /// Where response caches live, one subfolder per provider. Safe to delete.
    public var cacheFolder: URL
    /// Where providers keep small state worth keeping, for example which
    /// permissions a key was refused.
    public var stateFolder: URL
    public var now: @Sendable () -> Date

    public init(transport: HTTPTransport = URLSessionTransport(), secrets: SecretStore = KeychainSecretStore(), cacheFolder: URL, stateFolder: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.secrets = secrets
        self.cacheFolder = cacheFolder
        self.stateFolder = stateFolder
        self.now = now
    }
}

/// Paths inside a folder, compared carefully: `standardizedFileURL` drops
/// a leading `/private` only once a path exists, so two URLs for the same
/// place can disagree depending on when they were made.
enum Paths {
    /// `file`'s path relative to `root`, or nil when it isn't inside it.
    static func relative(_ file: URL, to root: URL) -> String? {
        let candidates = [
            (file.path, root.path),
            (file.standardizedFileURL.path, root.standardizedFileURL.path),
            (file.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        ]
        for (path, base) in candidates {
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return nil
    }
}

/// File name helpers shared by providers.
enum ProviderFiles {
    /// `original.<ext>` in `folder`.
    static func original(in folder: URL, ext: String) -> URL {
        folder.appendingPathComponent("original.\(ext.lowercased())")
    }

    /// The extension of a URL's last path component, or `fallback`.
    static func ext(of url: URL, fallback: String) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || ext.count > 5 ? fallback : ext
    }

    /// "Rocket ship" from ":rocket-ship:" or "rocket_ship".
    static func title(_ raw: String) -> String {
        let words = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
        guard let first = words.first else { return raw }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst().map(String.init)).joined(separator: " ")
    }
}
