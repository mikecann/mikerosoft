import Foundation

/// Iconify: over 200,000 open icons from about 240 sets, no key. Each set
/// has its own licence (SPDX); sets under GPL, share-alike or
/// non-commercial terms are left out.
///
/// Icons are fetched as SVG in `colour` (sets with their own palette keep
/// it) and rasterised to PNG at import.
public final class IconifyProvider: AssetProvider, @unchecked Sendable {
    public let id = "iconify"
    public let displayName = "Iconify"
    public let kinds: Set<AssetKind> = [.icon]
    public let capabilities = ProviderCapabilities(search: true)
    public let rules = ProviderRules(
        cacheTTL: 24 * 3600,
        notes: [
            "Each icon set has its own licence; GPL, share-alike and non-commercial sets are left out.",
            "CC BY sets need a credit line in the description."
        ]
    )
    public var website: URL? { URL(string: "https://icon-sets.iconify.design/") }

    static let api = "https://api.iconify.design"
    /// Colour icons are fetched in, as a CSS colour. White suits overlays on
    /// dark screen recordings.
    public let colour: String
    let http: ProviderHTTP

    public init(environment: ProviderEnvironment, colour: String = "#FFFFFF") {
        self.colour = colour
        http = ProviderHTTP(provider: id, rules: rules, environment: environment)
    }

    public func status() async -> ProviderStatus { .ready }

    /// What Iconify says about a set.
    public struct IconSet: Codable, Equatable, Sendable {
        public struct Person: Codable, Equatable, Sendable {
            public var name: String?
            public var url: String?
        }
        public struct Licence: Codable, Equatable, Sendable {
            public var title: String?
            public var spdx: String?
            public var url: String?
        }
        public var name: String
        public var author: Person?
        public var license: Licence?
        public var category: String?
        public var palette: Bool?
        public var tags: [String]?

        public init(name: String, author: Person? = nil, license: Licence? = nil, category: String? = nil, palette: Bool? = nil, tags: [String]? = nil) {
            self.name = name
            self.author = author
            self.license = license
            self.category = category
            self.palette = palette
            self.tags = tags
        }

        /// False for GPL, share-alike and non-commercial sets, and sets with
        /// no licence given.
        public var isAllowed: Bool {
            guard let spdx = license?.spdx, !spdx.isEmpty else { return false }
            return !LicencePolicy.isExcluded(spdx: spdx)
        }
    }

    struct SearchResponse: Decodable {
        var icons: [String]
        var total: Int?
        var collections: [String: IconSet]?
    }

    public func search(_ query: ProviderQuery) async throws -> [Asset] {
        guard query.wants(.icon), !query.text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        // Each page is one window of Iconify's results (it won't send fewer
        // than 32), and every allowed icon in it comes back, so pages never
        // overlap or skip. Excluded sets can make a page shorter.
        let limit = min(999, max(32, query.perPage))
        let url = URL(string: "\(Self.api)/search")!.adding([
            URLQueryItem(name: "query", value: query.text),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "start", value: String(max(0, query.page - 1) * limit))
        ])
        let response = try await http.getJSON(SearchResponse.self, url)
        let sets = response.collections ?? [:]
        let assets = response.icons.compactMap { name -> Asset? in
            let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let set = sets[parts[0]], set.isAllowed else { return nil }
            return asset(prefix: parts[0], icon: parts[1], set: set)
        }
        return assets
    }

    /// An icon as an asset in this provider's colour.
    public func asset(prefix: String, icon: String, set: IconSet) -> Asset {
        Self.asset(prefix: prefix, icon: icon, set: set, colour: colour)
    }

    /// An icon as an asset. `set` supplies the licence and credit.
    public static func asset(prefix: String, icon: String, set: IconSet, colour: String) -> Asset {
        let spdx = set.license?.spdx ?? ""
        let licenceClass = LicencePolicy.licenceClass(spdx: spdx)
        let author = set.author?.name ?? set.name
        let licenceTitle = set.license?.title ?? spdx
        let svg = svgURL(prefix: prefix, icon: icon, colour: colour)
        var remote = [
            "set": prefix,
            "setName": set.name,
            "author": author,
            "spdx": spdx,
            "licenceTitle": licenceTitle,
            "svg": svg.absoluteString,
            "colour": colour,
            "palette": set.palette == true ? "1" : "0"
        ]
        if let url = set.license?.url { remote["licenceURL"] = url }
        if let url = set.author?.url { remote["authorURL"] = url }
        return Asset(
            provider: "iconify",
            providerID: "\(prefix):\(icon)",
            kind: .icon,
            name: ProviderFiles.title(icon),
            tags: [set.name, set.category].compactMap { $0 } + LocalMatcher.tokens(icon) + (set.tags ?? []),
            summary: "\(set.name) by \(author), \(licenceTitle)",
            hasAlpha: true,
            licenceClass: licenceClass,
            creditLine: licenceClass == .creditNeeded ? "\(set.name) icons by \(author), \(licenceTitle)" : nil,
            previewURL: svg,
            thumbnailURL: svg,
            pageURL: URL(string: "https://icon-sets.iconify.design/\(prefix)/\(icon)/"),
            remote: remote
        )
    }

    static func svgURL(prefix: String, icon: String, colour: String) -> URL {
        URL(string: "\(api)/\(prefix)/\(icon).svg")!.adding([URLQueryItem(name: "color", value: colour)])
    }

    public func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal {
        let parts = asset.providerID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw AssetError.invalid("Iconify IDs look like set:icon, not \(asset.providerID)") }
        let url = asset.remote["svg"].flatMap(URL.init(string:)) ?? Self.svgURL(prefix: parts[0], icon: parts[1], colour: colour)
        let file = ProviderFiles.original(in: folder, ext: "svg")
        try await http.download(url, to: file)
        return FetchedOriginal(asset: asset, file: file)
    }

    public func licence(for asset: Asset) async throws -> AssetLicence {
        let spdx = asset.remote["spdx"]
        let setName = asset.remote["setName"] ?? asset.remote["set"] ?? "Iconify"
        let title = asset.remote["licenceTitle"] ?? spdx ?? "unknown licence"
        let licenceClass = spdx.map(LicencePolicy.licenceClass(spdx:)) ?? .unknown
        return AssetLicence(
            name: title,
            spdx: spdx,
            licenceClass: licenceClass,
            url: asset.remote["licenceURL"].flatMap(URL.init(string:)),
            holder: asset.remote["author"],
            creditLine: licenceClass == .creditNeeded ? asset.creditLine : nil,
            sourceURL: asset.pageURL,
            notes: "Icon from the \(setName) set on Iconify."
        )
    }
}
