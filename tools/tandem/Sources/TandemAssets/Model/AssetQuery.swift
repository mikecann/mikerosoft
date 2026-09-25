import Foundation

/// A search of the local catalogue. Every field is optional; an empty query
/// lists everything, most popular first.
///
/// JSON uses the same names, so the CLI and MCP can pass a query through
/// as it came: `{"text": "whoosh", "kinds": ["sfx"], "maxDuration": 2}`.
public struct AssetQuery: Codable, Equatable, Sendable {
    public enum Sort: String, Codable, Sendable, CaseIterable {
        /// Best text match first (the default when there is text).
        case relevance
        /// Provider popularity, then newest (the default without text).
        case popular
        case name
        case newest
        /// Most recently used in any project.
        case lastUsed
    }

    /// Words to match against name, tags, description and provider.
    /// Each word matches as a prefix, all words must match.
    public var text: String
    public var kinds: Set<AssetKind>
    public var providers: Set<String>
    public var licenceClasses: Set<LicenceClass>
    public var hasAlpha: Bool?
    /// Seconds.
    public var minDuration: Double?
    public var maxDuration: Double?
    public var minBPM: Double?
    public var maxBPM: Double?
    /// Only assets with at least this state, for example `.original` for
    /// "Downloaded".
    public var minState: AssetState?
    public var favouritesOnly: Bool
    /// Only assets used in some project.
    public var usedOnly: Bool
    /// Only assets used in this project (by project ID).
    public var projectID: String?
    public var sort: Sort?
    public var limit: Int
    public var offset: Int

    public init(
        text: String = "",
        kinds: Set<AssetKind> = [],
        providers: Set<String> = [],
        licenceClasses: Set<LicenceClass> = [],
        hasAlpha: Bool? = nil,
        minDuration: Double? = nil,
        maxDuration: Double? = nil,
        minBPM: Double? = nil,
        maxBPM: Double? = nil,
        minState: AssetState? = nil,
        favouritesOnly: Bool = false,
        usedOnly: Bool = false,
        projectID: String? = nil,
        sort: Sort? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.text = text
        self.kinds = kinds
        self.providers = providers
        self.licenceClasses = licenceClasses
        self.hasAlpha = hasAlpha
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.minBPM = minBPM
        self.maxBPM = maxBPM
        self.minState = minState
        self.favouritesOnly = favouritesOnly
        self.usedOnly = usedOnly
        self.projectID = projectID
        self.sort = sort
        self.limit = limit
        self.offset = offset
    }

    /// The browser's Favourites view for a kind.
    public static func favourites(_ kinds: Set<AssetKind> = []) -> AssetQuery {
        AssetQuery(kinds: kinds, favouritesOnly: true, sort: .name)
    }

    /// The browser's Recently used view.
    public static func recentlyUsed(_ kinds: Set<AssetKind> = [], limit: Int = 50) -> AssetQuery {
        AssetQuery(kinds: kinds, usedOnly: true, sort: .lastUsed, limit: limit)
    }

    /// The browser's In this project view.
    public static func inProject(_ projectID: String, kinds: Set<AssetKind> = []) -> AssetQuery {
        AssetQuery(kinds: kinds, projectID: projectID, sort: .lastUsed)
    }

    /// The browser's Downloaded view.
    public static func downloaded(_ kinds: Set<AssetKind> = []) -> AssetQuery {
        AssetQuery(kinds: kinds, minState: .original, sort: .newest)
    }
}

extension AssetQuery {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AssetQuery()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? d.text
        kinds = try c.decodeIfPresent(Set<AssetKind>.self, forKey: .kinds) ?? d.kinds
        providers = try c.decodeIfPresent(Set<String>.self, forKey: .providers) ?? d.providers
        licenceClasses = try c.decodeIfPresent(Set<LicenceClass>.self, forKey: .licenceClasses) ?? d.licenceClasses
        hasAlpha = try c.decodeIfPresent(Bool.self, forKey: .hasAlpha)
        minDuration = try c.decodeIfPresent(Double.self, forKey: .minDuration)
        maxDuration = try c.decodeIfPresent(Double.self, forKey: .maxDuration)
        minBPM = try c.decodeIfPresent(Double.self, forKey: .minBPM)
        maxBPM = try c.decodeIfPresent(Double.self, forKey: .maxBPM)
        minState = try c.decodeIfPresent(AssetState.self, forKey: .minState)
        favouritesOnly = try c.decodeIfPresent(Bool.self, forKey: .favouritesOnly) ?? d.favouritesOnly
        usedOnly = try c.decodeIfPresent(Bool.self, forKey: .usedOnly) ?? d.usedOnly
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        sort = try c.decodeIfPresent(Sort.self, forKey: .sort)
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? d.limit
        offset = try c.decodeIfPresent(Int.self, forKey: .offset) ?? d.offset
    }
}

/// One use of an asset in a project. Drives Recently used, In this project,
/// description credits, and proof of use for Content ID disputes.
public struct AssetUsage: Codable, Equatable, Sendable {
    public var assetID: String
    public var projectID: String
    /// The project file, so "which videos used this" can be answered later.
    public var projectPath: String?
    /// The media item the asset became, when it was added to the project.
    public var mediaID: String?
    /// Where the copy lives, relative to the project folder.
    public var mediaPath: String?
    public var usedAt: Date

    public init(assetID: String, projectID: String, projectPath: String? = nil, mediaID: String? = nil, mediaPath: String? = nil, usedAt: Date = Date()) {
        self.assetID = assetID
        self.projectID = projectID
        self.projectPath = projectPath
        self.mediaID = mediaID
        self.mediaPath = mediaPath
        self.usedAt = usedAt
    }
}
