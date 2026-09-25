import Foundation
import TandemAssets
import TandemCore
import TandemMedia

// Requests and results for the asset library, shared by `tandem assets` and
// the `assets_*` MCP tools. Like the project operations they're Codable and
// read well as text; unlike them they work on Mike's per-user library, so
// only `use` and `credits` need a project.

/// The asset operations agents have.
public enum AssetOperation: String, CaseIterable, Codable, Sendable {
    case providers
    case search
    case fetch
    case use
    case credits
    case generate
    case installStarter = "install-starter"

    /// The request type that carries this operation's parameters.
    public var callType: any AssetCall.Type {
        switch self {
        case .providers: return AssetProvidersRequest.self
        case .search: return AssetSearchRequest.self
        case .fetch: return AssetFetchRequest.self
        case .use: return AssetUseRequest.self
        case .credits: return AssetCreditsRequest.self
        case .generate: return AssetGenerateRequest.self
        case .installStarter: return AssetInstallStarterRequest.self
        }
    }
}

/// A request to the asset library. `project` is the project to work on,
/// for the calls that need one.
public protocol AssetCall: Codable, Sendable {
    associatedtype Result: Codable & Sendable & ReadableResult
    static var operation: AssetOperation { get }
    /// True for calls that work on a project (`use`, `credits`).
    static var needsProject: Bool { get }
    func run(on assets: AssetService, project: ProjectClient?) async throws -> Result
}

extension AssetCall {
    public static var needsProject: Bool { false }
}

// MARK: - Lenient lists

extension KeyedDecodingContainer {
    /// A list given as an array, one string, or a comma-separated string:
    /// `["sfx", "music"]`, `"sfx"` or `"sfx,music"`.
    func decodeList(_ key: Key) throws -> [String]? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let many = try? decode([String].self, forKey: key) { return many }
        let one = try decode(String.self, forKey: key)
        return one.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Reading asset kinds and provider lists the way people type them.
public enum AssetNames {
    /// A comma-separated list, trimmed, without empty items.
    public static func split(_ text: String?) -> [String] {
        (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Asset kinds from a comma-separated list like `sfx,music`.
    public static func parse(kinds text: String?) throws -> [AssetKind] {
        try kinds(split(text))
    }

    /// Asset kinds from names, with a list of the valid ones on a mistake.
    public static func kinds(_ names: [String]) throws -> [AssetKind] {
        try names.map { name in
            let lower = name.lowercased()
            if let kind = AssetKind(rawValue: lower) { return kind }
            // Plurals and the browser's words: "stickers", "logos", "sounds".
            let aliases: [String: AssetKind] = ["sound": .sfx, "sounds": .sfx, "effects": .sfx, "songs": .music, "emoji": .sticker, "broll": .video, "b-roll": .video]
            if let kind = aliases[lower] ?? AssetKind(rawValue: String(lower.dropLast())) { return kind }
            let known = AssetKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw ServiceError(.badRequest, "\"\(name)\" isn't an asset kind. Kinds: \(known).")
        }
    }
}

// MARK: - providers

public struct AssetProvidersRequest: AssetCall {
    public static let operation = AssetOperation.providers
    public init() {}

    public func run(on assets: AssetService, project: ProjectClient?) async throws -> AssetProvidersResult {
        await assets.providers()
    }
}

public struct AssetProvidersResult: Codable, Sendable {
    public var providers: [ProviderInfo]
}

// MARK: - search

public struct AssetSearchRequest: AssetCall {
    public static let operation = AssetOperation.search
    public var text: String
    public var kinds: [AssetKind]
    /// Provider IDs, like `noto` or `import`.
    public var providers: [String]
    /// Ask the providers too, not just the library's catalogue.
    public var online: Bool
    public var limit: Int?
    /// Seconds, for sounds and clips.
    public var maxDuration: Double?

    public init(text: String = "", kinds: [AssetKind] = [], providers: [String] = [], online: Bool = false, limit: Int? = nil, maxDuration: Double? = nil) {
        self.text = text
        self.kinds = kinds
        self.providers = providers
        self.online = online
        self.limit = limit
        self.maxDuration = maxDuration
    }

    enum CodingKeys: String, CodingKey {
        case text, kinds, kind, providers, provider, online, limit, maxDuration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        kinds = try AssetNames.kinds((try c.decodeList(.kinds) ?? []) + (try c.decodeList(.kind) ?? []))
        providers = (try c.decodeList(.providers) ?? []) + (try c.decodeList(.provider) ?? [])
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        maxDuration = try c.decodeSeconds(.maxDuration)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(kinds, forKey: .kinds)
        try c.encode(providers, forKey: .providers)
        try c.encode(online, forKey: .online)
        try c.encodeIfPresent(limit, forKey: .limit)
        try c.encodeIfPresent(maxDuration, forKey: .maxDuration)
    }

    public func run(on assets: AssetService, project: ProjectClient?) async throws -> AssetSearchResult {
        try await assets.search(self)
    }
}

public struct AssetSearchResult: Codable, Sendable {
    public var text: String
    /// Matches in the library's catalogue: downloaded, imported, generated,
    /// starter and recent provider results.
    public var local: [Asset]
    /// How many catalogue assets match, ignoring the limit.
    public var total: Int
    /// Each provider's answer, when searching online.
    public var online: [AssetLibrary.ProviderResults]?
}

// MARK: - fetch

public struct AssetFetchRequest: AssetCall {
    public static let operation = AssetOperation.fetch
    public var id: String

    public init(id: String) {
        self.id = id
    }

    public func run(on assets: AssetService, project: ProjectClient?) async throws -> AssetFetchResult {
        try await assets.fetch(self)
    }
}

public struct AssetFetchResult: Codable, Sendable {
    public var asset: Asset
    /// The file the editor plays, in the library.
    public var file: String?
    public var licence: AssetLicence?
}

// MARK: - use

public struct AssetUseRequest: AssetCall {
    public static let operation = AssetOperation.use
    public static var needsProject: Bool { true }
    public var id: String
    /// Where to place it on the timeline. Without it the asset is only added
    /// to the project's media.
    public var at: Time?
    /// How long the clip lasts. Default: all of it (5 s for a still).
    public var duration: Time?
    /// `place` (default) fails if the track is taken there, `overwrite`
    /// replaces what's there, `insert` pushes later clips right.
    public var mode: InsertMode?
    public var label: String?
    public var author: String?

    public init(id: String, at: Time? = nil, duration: Time? = nil, mode: InsertMode? = nil, label: String? = nil, author: String? = nil) {
        self.id = id
        self.at = at
        self.duration = duration
        self.mode = mode
        self.label = label
        self.author = author
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decodeTime(.at)
        duration = try c.decodeTime(.duration)
        mode = try c.decodeIfPresent(InsertMode.self, forKey: .mode)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        author = try c.decodeIfPresent(String.self, forKey: .author)
    }

    public func run(on assets: AssetService, project: ProjectClient?) async throws -> AssetUseResult {
        guard let project else { throw ServiceError(.badRequest, "Using an asset needs a project.") }
        return try await assets.use(self, project: project)
    }
}

public struct AssetUseResult: Codable, Sendable {
    public var asset: Asset
    /// The media item it is in the project. Nil for fonts and LUTs.
    public var mediaID: String?
    /// Files copied into the project, relative to its folder.
    public var files: [String]
    public var role: MediaRole
    /// The track it lands on in Mike's layout.
    public var trackName: String?
    public var gainDB: Double?
    /// Where it was placed, when it was.
    public var at: Time?
    /// The edit, when one was needed.
    public var applied: ApplyResult?
    /// For fonts: the PostScript names a title's style can use.
    public var fonts: [String]
    public var licence: AssetLicence?
}

// MARK: - credits

public struct AssetCreditsRequest: AssetCall {
    public static let operation = AssetOperation.credits
    public static var needsProject: Bool { true }
    /// Also list courtesy credits nobody requires (Pexels creators).
    public var includeOptional: Bool?

    public init(includeOptional: Bool? = nil) {
        self.includeOptional = includeOptional
    }

    public func run(on assets: AssetService, project: ProjectClient?) async throws -> AssetCreditsResult {
        guard let project else { throw ServiceError(.badRequest, "Credits are for a project.") }
        return try await assets.credits(self, project: project)
    }
}

public struct AssetCreditsResult: Codable, Sendable {
    /// The block to paste into the YouTube description. Empty when nothing
    /// needs a credit.
    public var text: String
    public var credits: ProjectCredits
    public var includeOptional: Bool
}

// MARK: - generate

public struct AssetGenerateRequest: AssetCall {
    public static let operation = AssetOperation.generate
    /// `sfx` or `music`.
    public var kind: AssetKind
    public var prompt: String
    /// Seconds: 0.5 to 30 for sound effects, 3 to 600 for music.
    public var duration: Double?
    /// How many takes, each a paid request. Default 1.
    public var variations: Int?
    /// Sound effects: loop seamlessly.
    public var loop: Bool?
    /// Music: allow vocals (instrumental by default).
    public var vocals: Bool?

    public init(kind: AssetKind, prompt: String, duration: Double? = nil, variations: Int? = nil, loop: Bool? = nil, vocals: Bool? = nil) {
        self.kind = kind
        self.prompt = prompt
        self.duration = duration
        self.variations = variations
        self.loop = loop
        self.vocals = vocals
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kindName = try c.decode(String.self, forKey: .kind)
        guard let kind = try AssetNames.kinds([kindName]).first, kind == .sfx || kind == .music else {
            throw ServiceError(.badRequest, "Generate makes sfx or music, not \(kindName).")
        }
        self.kind = kind
        prompt = try c.decode(String.self, forKey: .prompt)
        duration = try c.decodeSeconds(.duration)
        variations = try c.decodeIfPresent(Int.self, forKey: .variations)
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop)
        vocals = try c.decodeIfPresent(Bool.self, forKey: .vocals)
    }

    public func run(on assets: AssetService, project: ProjectClient?) async throws -> AssetGenerateResult {
        try await assets.generate(self)
    }
}

public struct AssetGenerateResult: Codable, Sendable {
    public var assets: [Asset]
    /// Takes that failed, or were saved but couldn't be normalised.
    public var failures: [String]
}

// MARK: - install-starter

public struct AssetInstallStarterRequest: AssetCall {
    public static let operation = AssetOperation.installStarter
    public init() {}

    public func run(on assets: AssetService, project: ProjectClient?) async throws -> AssetInstallStarterResult {
        try assets.installStarter()
    }
}

public struct AssetInstallStarterResult: Codable, Sendable {
    /// Starter assets by kind.
    public var counts: [String: Int]
    public var total: Int
}
