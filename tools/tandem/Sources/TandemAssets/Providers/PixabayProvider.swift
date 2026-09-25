import Foundation

/// Pixabay stock video and images. Free key (Keychain service `pixabay`);
/// on only when the key exists.
///
/// Pixabay's API rules: cache every response for 24 hours, download before
/// use (no hotlinking), no automated mass downloads, and show where results
/// come from.
public final class PixabayProvider: AssetProvider, @unchecked Sendable {
    public let id = "pixabay"
    public let displayName = "Pixabay"
    public let kinds: Set<AssetKind> = [.video, .image]
    public let capabilities = ProviderCapabilities(search: true)
    public let rules = ProviderRules(
        requestsPerWindow: 100,
        window: 60,
        cacheTTL: 24 * 3600,
        notes: [
            "Responses are cached for 24 hours, as Pixabay requires.",
            "Download before use; Pixabay links aren't for permanent use.",
            "Show that results come from Pixabay. No credit needed in videos."
        ]
    )
    public var website: URL? { URL(string: "https://pixabay.com") }

    public static let keychainService = "pixabay"
    static let licenceURL = URL(string: "https://pixabay.com/service/license-summary/")!
    let http: ProviderHTTP
    let secrets: SecretStore

    public init(environment: ProviderEnvironment) {
        http = ProviderHTTP(provider: id, rules: rules, environment: environment)
        secrets = environment.secrets
    }

    public func status() async -> ProviderStatus {
        secrets.secret(service: Self.keychainService) == nil
            ? ProviderStatus(.needsKey, "Add a free Pixabay API key to the Keychain: security add-generic-password -s pixabay -a pixabay -w")
            : .ready
    }

    struct VideoSearch: Decodable {
        struct Hit: Decodable {
            struct Rendition: Decodable {
                var url: String
                var width: Int?
                var height: Int?
                var size: Int64?
                var thumbnail: String?
            }
            var id: Int
            var pageURL: String?
            var tags: String?
            var duration: Double?
            var videos: [String: Rendition]
            var user: String?
            var user_id: Int?
        }
        var hits: [Hit]
    }

    struct ImageSearch: Decodable {
        struct Hit: Decodable {
            var id: Int
            var pageURL: String?
            var tags: String?
            var previewURL: String?
            var webformatURL: String?
            var largeImageURL: String?
            var fullHDURL: String?
            var imageURL: String?
            var imageWidth: Int?
            var imageHeight: Int?
            var imageSize: Int64?
            var user: String?
        }
        var hits: [Hit]
    }

    public func search(_ query: ProviderQuery) async throws -> [Asset] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        guard let key = secrets.secret(service: Self.keychainService) else {
            throw AssetError.providerUnavailable(provider: displayName, reason: "no API key in the Keychain (service pixabay)")
        }
        let common = [
            URLQueryItem(name: "q", value: String(text.prefix(100))),
            URLQueryItem(name: "per_page", value: String(min(200, max(3, query.perPage)))),
            URLQueryItem(name: "page", value: String(max(1, query.page))),
            URLQueryItem(name: "safesearch", value: "true")
        ]
        var results: [Asset] = []
        if query.wants(.video) {
            let base = URL(string: "https://pixabay.com/api/videos/")!
            // The key is in the URL, so the cache key leaves it out.
            let response = try await http.getJSON(VideoSearch.self, base.adding([URLQueryItem(name: "key", value: key)] + common), cacheKey: base.adding(common).absoluteString)
            results += response.hits.compactMap(asset(for:))
        }
        if query.wants(.image) {
            let base = URL(string: "https://pixabay.com/api/")!
            let items = common + [URLQueryItem(name: "image_type", value: "photo")]
            let response = try await http.getJSON(ImageSearch.self, base.adding([URLQueryItem(name: "key", value: key)] + items), cacheKey: base.adding(items).absoluteString)
            results += response.hits.compactMap(asset(for:))
        }
        return results
    }

    static func name(fromTags tags: String?, fallback: String) -> ([String], String) {
        let list = (tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let name = list.prefix(3).joined(separator: ", ")
        return (list, name.isEmpty ? fallback : ProviderFiles.title(name))
    }

    func asset(for hit: VideoSearch.Hit) -> Asset? {
        // "large" is usually 4K and sometimes missing (an empty URL).
        let original = ["large", "medium", "small", "tiny"].compactMap { hit.videos[$0] }.first { !$0.url.isEmpty }
        guard let original else { return nil }
        let preview = ["tiny", "small"].compactMap { hit.videos[$0] }.first { !$0.url.isEmpty }
        let (tags, name) = Self.name(fromTags: hit.tags, fallback: "Pixabay video \(hit.id)")
        let creator = hit.user ?? "a Pixabay creator"
        return Asset(
            provider: id,
            providerID: "video-\(hit.id)",
            kind: .video,
            name: name,
            tags: tags,
            duration: hit.duration,
            width: original.width,
            height: original.height,
            size: original.size,
            licenceClass: .noCredit,
            creditLine: "Video by \(creator) from Pixabay",
            previewURL: preview.flatMap { URL(string: $0.url) },
            thumbnailURL: (hit.videos["medium"]?.thumbnail ?? original.thumbnail).flatMap(URL.init(string:)),
            pageURL: hit.pageURL.flatMap(URL.init(string:)),
            remote: ["download": original.url, "creator": creator]
        )
    }

    func asset(for hit: ImageSearch.Hit) -> Asset? {
        guard let download = hit.imageURL ?? hit.fullHDURL ?? hit.largeImageURL else { return nil }
        let (tags, name) = Self.name(fromTags: hit.tags, fallback: "Pixabay image \(hit.id)")
        let creator = hit.user ?? "a Pixabay creator"
        return Asset(
            provider: id,
            providerID: "image-\(hit.id)",
            kind: .image,
            name: name,
            tags: tags,
            width: hit.imageWidth,
            height: hit.imageHeight,
            size: hit.imageSize,
            licenceClass: .noCredit,
            creditLine: "Image by \(creator) from Pixabay",
            // webformat links last 24 hours: fine for the browser, never stored as the original.
            previewURL: hit.webformatURL.flatMap(URL.init(string:)),
            thumbnailURL: hit.previewURL.flatMap(URL.init(string:)),
            pageURL: hit.pageURL.flatMap(URL.init(string:)),
            remote: ["download": download, "creator": creator]
        )
    }

    public func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal {
        var current = asset
        // Pixabay's links stop working after a day; look the item up again
        // by ID for a fresh one.
        if Date().timeIntervalSince(asset.updatedAt) > 23 * 3600, let fresh = try await lookUp(asset) {
            current.remote.merge(fresh.remote) { _, new in new }
            current.previewURL = fresh.previewURL ?? current.previewURL
        }
        guard let link = current.remote["download"], let url = URL(string: link) else { throw AssetError.notFound("download link for \(asset.id)") }
        let file = ProviderFiles.original(in: folder, ext: ProviderFiles.ext(of: url, fallback: asset.kind == .video ? "mp4" : "jpg"))
        try await http.download(url, to: file)
        return FetchedOriginal(asset: current, file: file)
    }

    /// The asset as Pixabay describes it now, found by its ID.
    func lookUp(_ asset: Asset) async throws -> Asset? {
        guard let key = secrets.secret(service: Self.keychainService) else {
            throw AssetError.providerUnavailable(provider: displayName, reason: "no API key in the Keychain (service pixabay)")
        }
        let parts = asset.providerID.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let isVideo = parts[0] == "video"
        let base = URL(string: isVideo ? "https://pixabay.com/api/videos/" : "https://pixabay.com/api/")!
        let items = [URLQueryItem(name: "id", value: parts[1])]
        let url = base.adding([URLQueryItem(name: "key", value: key)] + items)
        let cacheKey = base.adding(items).absoluteString
        if isVideo {
            return try await http.getJSON(VideoSearch.self, url, cacheKey: cacheKey).hits.first.flatMap(asset(for:))
        }
        return try await http.getJSON(ImageSearch.self, url, cacheKey: cacheKey).hits.first.flatMap(asset(for:))
    }

    public func licence(for asset: Asset) async throws -> AssetLicence {
        AssetLicence(
            name: "Pixabay Content License",
            licenceClass: .noCredit,
            url: Self.licenceURL,
            text: "Free to use without attribution. Don't sell or distribute unaltered copies, don't imply endorsement, don't use identifiable people or brands in a misleading way.",
            holder: asset.remote["creator"],
            creditLine: asset.creditLine,
            sourceURL: asset.pageURL
        )
    }
}
