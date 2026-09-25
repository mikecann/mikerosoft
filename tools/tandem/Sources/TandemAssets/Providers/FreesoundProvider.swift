import Foundation

/// Freesound sound effects: search, similar sounds and high-quality MP3
/// previews with a token from the Keychain (service `freesound`). Only CC0
/// and CC BY sounds are offered.
///
/// Off by default: Freesound's API terms need written permission from its
/// operator (the Music Technology Group at UPF) for commercial use, and
/// Mike's channel is commercial. Turn it on in the asset settings once that
/// permission is in hand. Originals need OAuth2, so fetches keep the HQ
/// preview, which is fine for most effects.
public final class FreesoundProvider: AssetProvider, @unchecked Sendable {
    public let id = "freesound"
    public let displayName = "Freesound"
    public let kinds: Set<AssetKind> = [.sfx]
    public let capabilities = ProviderCapabilities(search: true, similar: true)
    public let rules = ProviderRules(
        requestsPerWindow: 60,
        window: 60,
        cacheTTL: 24 * 3600,
        notes: [
            "Only CC0 and CC BY sounds; CC BY needs a credit line.",
            "Commercial use of the API needs written permission from UPF's Music Technology Group.",
            "60 requests a minute and 2,000 a day.",
            "Originals need OAuth2; Tandem keeps the high-quality MP3 preview."
        ]
    )
    public var website: URL? { URL(string: "https://freesound.org") }

    public static let keychainService = "freesound"
    static let api = "https://freesound.org/apiv2"
    static let fields = "id,name,tags,description,duration,license,username,previews,images,url,num_downloads"
    static let licenceFilter = "license:(\"Creative Commons 0\" OR \"Attribution\")"

    public let enabled: Bool
    let http: ProviderHTTP
    let secrets: SecretStore

    public init(environment: ProviderEnvironment, enabled: Bool = false) {
        self.enabled = enabled
        http = ProviderHTTP(provider: id, rules: rules, environment: environment)
        secrets = environment.secrets
    }

    public func status() async -> ProviderStatus {
        guard enabled else {
            return ProviderStatus(.disabled, "Off until Freesound's operator (UPF) gives written permission for commercial API use. Then turn it on in the asset settings.")
        }
        return secrets.secret(service: Self.keychainService) == nil
            ? ProviderStatus(.needsKey, "Add a Freesound API token to the Keychain: security add-generic-password -s freesound -a freesound -w")
            : .ready
    }

    private func headers() throws -> [String: String] {
        guard enabled else {
            throw AssetError.providerUnavailable(provider: displayName, reason: "turned off until UPF gives written permission for commercial API use")
        }
        guard let token = secrets.secret(service: Self.keychainService) else {
            throw AssetError.providerUnavailable(provider: displayName, reason: "no API token in the Keychain (service freesound)")
        }
        return ["Authorization": "Token \(token)"]
    }

    struct SearchResponse: Decodable {
        var results: [Sound]
    }

    struct Sound: Decodable {
        var id: Int
        var name: String
        var tags: [String]?
        var description: String?
        var duration: Double?
        var license: String
        var username: String?
        var previews: [String: String]?
        var images: [String: String]?
        var url: String?
        var num_downloads: Double?
    }

    /// CC0 or CC BY (with its version), or nil for anything else.
    static func licence(_ value: String) -> (spdx: String, name: String, url: URL)? {
        let lower = value.lowercased()
        if lower.contains("publicdomain/zero") || lower == "creative commons 0" || lower == "cc0" {
            return ("CC0-1.0", "CC0 1.0", URL(string: "https://creativecommons.org/publicdomain/zero/1.0/")!)
        }
        let isBy = lower.contains("/licenses/by/") || lower == "attribution"
        guard isBy else { return nil }
        let version = lower.contains("/by/3.0") ? "3.0" : lower.contains("/by/4.0") ? "4.0" : lower.contains("/by/2.0") ? "2.0" : "4.0"
        return ("CC-BY-\(version)", "CC BY \(version)", URL(string: "https://creativecommons.org/licenses/by/\(version)/")!)
    }

    func asset(for sound: Sound) -> Asset? {
        guard let licence = Self.licence(sound.license) else { return nil }
        let licenceClass: LicenceClass = licence.spdx == "CC0-1.0" ? .noCredit : .creditNeeded
        let author = sound.username ?? "a Freesound user"
        let page = sound.url ?? "https://freesound.org/s/\(sound.id)/"
        let credit = "\"\(sound.name)\" by \(author) (https://freesound.org/s/\(sound.id)/), \(licence.name)"
        var remote = ["creator": author, "spdx": licence.spdx, "licenceName": licence.name, "licenceURL": licence.url.absoluteString]
        if let hq = sound.previews?["preview-hq-mp3"] { remote["download"] = hq }
        let description = sound.description.map { String($0.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression).prefix(300)) }
        return Asset(
            provider: id,
            providerID: String(sound.id),
            kind: .sfx,
            name: sound.name,
            tags: sound.tags ?? [],
            summary: description,
            duration: sound.duration,
            licenceClass: licenceClass,
            creditLine: credit,
            previewURL: (sound.previews?["preview-lq-mp3"] ?? sound.previews?["preview-hq-mp3"]).flatMap(URL.init(string:)),
            thumbnailURL: sound.images?["waveform_m"].flatMap(URL.init(string:)),
            pageURL: URL(string: page),
            remote: remote,
            popularity: sound.num_downloads
        )
    }

    private func query(_ extra: [URLQueryItem], filter: String = FreesoundProvider.licenceFilter, perPage: Int, page: Int) -> [URLQueryItem] {
        extra + [
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "fields", value: Self.fields),
            URLQueryItem(name: "page_size", value: String(min(150, max(1, perPage)))),
            URLQueryItem(name: "page", value: String(max(1, page)))
        ]
    }

    public func search(_ query: ProviderQuery) async throws -> [Asset] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        guard query.wants(.sfx), !text.isEmpty else { return [] }
        let headers = try headers()
        // One filter parameter holds every condition, space separated.
        var filter = Self.licenceFilter
        if query.minDuration != nil || query.maxDuration != nil {
            let low = query.minDuration.map { String($0) } ?? "*"
            let high = query.maxDuration.map { String($0) } ?? "*"
            filter += " duration:[\(low) TO \(high)]"
        }
        let items = self.query([URLQueryItem(name: "query", value: text)], filter: filter, perPage: query.perPage, page: query.page)
        let url = URL(string: "\(Self.api)/search/")!.adding(items)
        let response = try await http.getJSON(SearchResponse.self, url, headers: headers)
        return response.results.compactMap(asset(for:))
    }

    public func similar(to asset: Asset, limit: Int) async throws -> [Asset] {
        let headers = try headers()
        let url = URL(string: "\(Self.api)/sounds/\(asset.providerID)/similar/")!.adding(query([], perPage: limit, page: 1))
        let response = try await http.getJSON(SearchResponse.self, url, headers: headers)
        return response.results.compactMap(self.asset(for:)).filter { $0.providerID != asset.providerID }
    }

    public func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal {
        _ = try headers()
        guard let link = asset.remote["download"] ?? asset.previewURL?.absoluteString, let url = URL(string: link) else {
            throw AssetError.notFound("preview link for \(asset.id)")
        }
        let file = ProviderFiles.original(in: folder, ext: "mp3")
        // Previews are public CDN files; no token needed.
        try await http.download(url, to: file)
        var updated = asset
        updated.remote["quality"] = "hq-preview"
        return FetchedOriginal(asset: updated, file: file)
    }

    public func licence(for asset: Asset) async throws -> AssetLicence {
        let spdx = asset.remote["spdx"] ?? "CC0-1.0"
        let licenceClass: LicenceClass = spdx == "CC0-1.0" ? .noCredit : .creditNeeded
        return AssetLicence(
            name: asset.remote["licenceName"] ?? spdx,
            spdx: spdx,
            licenceClass: licenceClass,
            url: asset.remote["licenceURL"].flatMap(URL.init(string:)),
            holder: asset.remote["creator"],
            creditLine: licenceClass == .creditNeeded ? asset.creditLine : nil,
            sourceURL: asset.pageURL,
            notes: "Freesound high-quality MP3 preview. Commercial API use needs UPF's written permission."
        )
    }
}
