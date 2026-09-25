import Foundation
import TandemCore
import TandemMedia

/// What an asset is. Drives the browser's left rail, the default role when
/// it's used in a project and how it's normalised.
public enum AssetKind: String, Codable, Sendable, CaseIterable {
    case music, sfx, sticker, overlay, video, image, font, icon, logo, lut, title, transition

    /// True for kinds that are sound.
    public var isAudio: Bool { self == .music || self == .sfx }

    /// True for kinds that become a picture on a video track.
    public var isVisual: Bool {
        switch self {
        case .sticker, .overlay, .video, .image, .icon, .logo: return true
        case .music, .sfx, .font, .lut, .title, .transition: return false
        }
    }
}

/// How far an asset has come towards being usable. Ordered: a normalised
/// asset also has its original.
public enum AssetState: String, Codable, Sendable, CaseIterable, Comparable {
    /// Known from a provider's index or search, nothing on disk yet.
    case remote
    /// A preview is cached, the original isn't downloaded.
    case preview
    /// The original file is on disk.
    case original
    /// The original has been turned into the file the editor uses.
    case normalised

    private var order: Int {
        switch self {
        case .remote: return 0
        case .preview: return 1
        case .original: return 2
        case .normalised: return 3
        }
    }

    public static func < (a: AssetState, b: AssetState) -> Bool { a.order < b.order }
}

/// The licence filter in the browser, and what the credits builder needs to
/// know about an asset.
public enum LicenceClass: String, Codable, Sendable, CaseIterable {
    /// Free to use without a credit (CC0, Pexels, Pixabay, OFL fonts, MIT icons).
    case noCredit
    /// The licence asks for a credit line (CC BY).
    case creditNeeded
    /// Covered while a subscription is active (Envato, Epidemic, Lordicon PRO).
    case subscription
    /// Made by a generator (ElevenLabs); commercial use depends on the plan.
    case aiGenerated
    /// Nobody recorded the terms. Credits flag these so nothing slips through.
    case unknown

    public var label: String {
        switch self {
        case .noCredit: return "No credit"
        case .creditNeeded: return "Credit needed"
        case .subscription: return "Subscription"
        case .aiGenerated: return "AI generated"
        case .unknown: return "Unknown licence"
        }
    }
}

/// Files the library keeps for an asset. Names are relative to `folder`,
/// which is relative to the library root, except `original` for import
/// folder assets, which is the absolute path of the file in its folder.
public struct AssetFiles: Codable, Equatable, Sendable {
    /// `<provider>/<id>` under the library root.
    public var folder: String?
    public var original: String?
    public var normalised: String?
    public var thumbnail: String?
    /// Waveform peaks: little-endian Float32 values, `peaksPerSecond` a second.
    public var peaks: String?

    public init(folder: String? = nil, original: String? = nil, normalised: String? = nil, thumbnail: String? = nil, peaks: String? = nil) {
        self.folder = folder
        self.original = original
        self.normalised = normalised
        self.thumbnail = thumbnail
        self.peaks = peaks
    }
}

/// One asset in the catalogue or in a provider's search results.
///
/// IDs are `<provider>:<provider ID>`, for example `noto:1f680`,
/// `iconify:mdi:rocket` or `svgl:convex`, so an agent can pass the ID it got
/// from a search straight to `fetch` or `use`.
public struct Asset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: String
    public var providerID: String
    public var kind: AssetKind
    public var name: String
    public var tags: [String]
    /// A description, or the prompt a generated asset was made from.
    public var summary: String?
    /// Seconds, for audio and video.
    public var duration: Double?
    public var bpm: Double?
    /// Musical key, for example "F minor".
    public var musicalKey: String?
    public var hasAlpha: Bool
    public var width: Int?
    public var height: Int?
    /// Bytes of the original, when known.
    public var size: Int64?
    /// SHA-256 of the original, set once it's on disk.
    public var sha256: String?
    public var state: AssetState
    public var licenceClass: LicenceClass
    /// What to put in the video description, if anything.
    public var creditLine: String?
    /// A remote preview (audio, video or animated image) for the browser.
    public var previewURL: URL?
    /// A remote still for the browser tile.
    public var thumbnailURL: URL?
    /// The asset's page on the provider's site, for people.
    public var pageURL: URL?
    /// Provider-specific details needed to fetch the original later, for
    /// example download URLs or a variant name.
    public var remote: [String: String]
    public var files: AssetFiles
    /// Loudness of the normalised audio.
    public var loudness: Loudness?
    /// A provider's popularity hint, higher first when browsing without text.
    public var popularity: Double?
    public var addedAt: Date
    public var updatedAt: Date
    /// Read from the favourites table; setting it here does nothing.
    public var isFavourite: Bool
    /// Read from the usage table; setting it here does nothing.
    public var lastUsed: Date?

    public init(
        provider: String,
        providerID: String,
        kind: AssetKind,
        name: String,
        tags: [String] = [],
        summary: String? = nil,
        duration: Double? = nil,
        bpm: Double? = nil,
        musicalKey: String? = nil,
        hasAlpha: Bool = false,
        width: Int? = nil,
        height: Int? = nil,
        size: Int64? = nil,
        sha256: String? = nil,
        state: AssetState = .remote,
        licenceClass: LicenceClass = .unknown,
        creditLine: String? = nil,
        previewURL: URL? = nil,
        thumbnailURL: URL? = nil,
        pageURL: URL? = nil,
        remote: [String: String] = [:],
        files: AssetFiles = AssetFiles(),
        loudness: Loudness? = nil,
        popularity: Double? = nil,
        addedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = Asset.makeID(provider: provider, providerID: providerID)
        self.provider = provider
        self.providerID = providerID
        self.kind = kind
        self.name = name
        self.tags = tags
        self.summary = summary
        self.duration = duration
        self.bpm = bpm
        self.musicalKey = musicalKey
        self.hasAlpha = hasAlpha
        self.width = width
        self.height = height
        self.size = size
        self.sha256 = sha256
        self.state = state
        self.licenceClass = licenceClass
        self.creditLine = creditLine
        self.previewURL = previewURL
        self.thumbnailURL = thumbnailURL
        self.pageURL = pageURL
        self.remote = remote
        self.files = files
        self.loudness = loudness
        self.popularity = popularity
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.isFavourite = false
        self.lastUsed = nil
    }

    public static func makeID(provider: String, providerID: String) -> String {
        "\(provider):\(providerID)"
    }

    /// Splits an asset ID into provider and provider ID at the first colon.
    public static func parseID(_ id: String) -> (provider: String, providerID: String)? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let provider = String(id[..<colon])
        let rest = String(id[id.index(after: colon)...])
        guard !provider.isEmpty, !rest.isEmpty else { return nil }
        return (provider, rest)
    }
}

extension Asset {
    /// Lenient decoding, like the project model: agents can send only the
    /// fields they mean.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        providerID = try c.decode(String.self, forKey: .providerID)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Asset.makeID(provider: provider, providerID: providerID)
        kind = try c.decode(AssetKind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? providerID
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm)
        musicalKey = try c.decodeIfPresent(String.self, forKey: .musicalKey)
        hasAlpha = try c.decodeIfPresent(Bool.self, forKey: .hasAlpha) ?? false
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        state = try c.decodeIfPresent(AssetState.self, forKey: .state) ?? .remote
        licenceClass = try c.decodeIfPresent(LicenceClass.self, forKey: .licenceClass) ?? .unknown
        creditLine = try c.decodeIfPresent(String.self, forKey: .creditLine)
        previewURL = try c.decodeIfPresent(URL.self, forKey: .previewURL)
        thumbnailURL = try c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        pageURL = try c.decodeIfPresent(URL.self, forKey: .pageURL)
        remote = try c.decodeIfPresent([String: String].self, forKey: .remote) ?? [:]
        files = try c.decodeIfPresent(AssetFiles.self, forKey: .files) ?? AssetFiles()
        loudness = try c.decodeIfPresent(Loudness.self, forKey: .loudness)
        popularity = try c.decodeIfPresent(Double.self, forKey: .popularity)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? addedAt
        isFavourite = try c.decodeIfPresent(Bool.self, forKey: .isFavourite) ?? false
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed)
    }
}
