import Foundation

/// Pexels stock video and photos. Free key (Keychain service `pexels`);
/// on only when the key exists.
///
/// The Pexels licence needs no credit, but the API guidelines ask apps to
/// show that results come from Pexels and to credit creators when they can,
/// so every asset carries an optional credit line.
public final class PexelsProvider: AssetProvider, @unchecked Sendable {
    public let id = "pexels"
    public let displayName = "Pexels"
    public let kinds: Set<AssetKind> = [.video, .image]
    public let capabilities = ProviderCapabilities(search: true)
    public let rules = ProviderRules(
        requestsPerWindow: 200,
        window: 3600,
        cacheTTL: 24 * 3600,
        notes: [
            "Free to use, no credit needed; credit the creator when you can.",
            "Show that results come from Pexels.",
            "200 requests an hour and 20,000 a month by default."
        ]
    )
    public var website: URL? { URL(string: "https://www.pexels.com") }

    public static let keychainService = "pexels"
    static let licenceURL = URL(string: "https://www.pexels.com/license/")!
    let http: ProviderHTTP
    let secrets: SecretStore

    public init(environment: ProviderEnvironment) {
        http = ProviderHTTP(provider: id, rules: rules, environment: environment)
        secrets = environment.secrets
    }

    public func status() async -> ProviderStatus {
        secrets.secret(service: Self.keychainService) == nil
            ? ProviderStatus(.needsKey, "Add a free Pexels API key to the Keychain: security add-generic-password -s pexels -a pexels -w")
            : .ready
    }

    private func key() throws -> String {
        guard let key = secrets.secret(service: Self.keychainService) else {
            throw AssetError.providerUnavailable(provider: displayName, reason: "no API key in the Keychain (service pexels)")
        }
        return key
    }

    struct VideoSearch: Decodable {
        struct Video: Decodable {
            struct User: Decodable { var name: String?; var url: String? }
            struct File: Decodable {
                var quality: String?
                var file_type: String?
                var width: Int?
                var height: Int?
                var link: String
            }
            var id: Int
            var width: Int?
            var height: Int?
            var url: String?
            var image: String?
            var duration: Double?
            var user: User?
            var video_files: [File]?
        }
        var videos: [Video]
    }

    struct PhotoSearch: Decodable {
        struct Photo: Decodable {
            var id: Int
            var width: Int?
            var height: Int?
            var url: String?
            var photographer: String?
            var photographer_url: String?
            var alt: String?
            var src: [String: String]?
        }
        var photos: [Photo]
    }

    public func search(_ query: ProviderQuery) async throws -> [Asset] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        let key = try key()
        let items = [
            URLQueryItem(name: "query", value: text),
            URLQueryItem(name: "per_page", value: String(min(80, max(1, query.perPage)))),
            URLQueryItem(name: "page", value: String(max(1, query.page)))
        ]
        var results: [Asset] = []
        if query.wants(.video) {
            let url = URL(string: "https://api.pexels.com/videos/search")!.adding(items)
            let response = try await http.getJSON(VideoSearch.self, url, headers: ["Authorization": key])
            results += response.videos.compactMap(asset(for:))
        }
        if query.wants(.image) {
            let url = URL(string: "https://api.pexels.com/v1/search")!.adding(items)
            let response = try await http.getJSON(PhotoSearch.self, url, headers: ["Authorization": key])
            results += response.photos.compactMap(asset(for:))
        }
        return results
    }

    /// "Aerial view of a city" from `https://www.pexels.com/video/aerial-view-of-a-city-123/`.
    static func name(fromPage page: String?, fallback: String) -> String {
        guard let page, let url = URL(string: page) else { return fallback }
        let slug = url.lastPathComponent
        let words = slug.split(separator: "-").filter { Int($0) == nil }
        return words.isEmpty ? fallback : ProviderFiles.title(words.joined(separator: " "))
    }

    func asset(for video: VideoSearch.Video) -> Asset? {
        let files = (video.video_files ?? []).filter { $0.file_type == nil || $0.file_type == "video/mp4" }
        // The largest file up to 4K is the original; the smallest is the preview.
        let bySize = files.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        guard let original = bySize.last(where: { ($0.width ?? 0) <= 3840 }) ?? bySize.last else { return nil }
        let preview = bySize.first(where: { ($0.width ?? 0) >= 640 }) ?? bySize.first
        let name = Self.name(fromPage: video.url, fallback: "Pexels video \(video.id)")
        let creator = video.user?.name ?? "a Pexels creator"
        var remote = ["download": original.link, "creator": creator]
        if let url = video.user?.url { remote["creatorURL"] = url }
        return Asset(
            provider: id,
            providerID: "video-\(video.id)",
            kind: .video,
            name: name,
            tags: LocalMatcher.tokens(name),
            duration: video.duration,
            width: original.width ?? video.width,
            height: original.height ?? video.height,
            licenceClass: .noCredit,
            creditLine: "Video by \(creator) on Pexels",
            previewURL: preview.flatMap { URL(string: $0.link) },
            thumbnailURL: video.image.flatMap(URL.init(string:)),
            pageURL: video.url.flatMap(URL.init(string:)),
            remote: remote
        )
    }

    func asset(for photo: PhotoSearch.Photo) -> Asset? {
        guard let src = photo.src, let original = src["original"] ?? src["large2x"] else { return nil }
        let name = photo.alt.flatMap { $0.isEmpty ? nil : $0 } ?? Self.name(fromPage: photo.url, fallback: "Pexels photo \(photo.id)")
        let creator = photo.photographer ?? "a Pexels photographer"
        var remote = ["download": original, "creator": creator]
        if let url = photo.photographer_url { remote["creatorURL"] = url }
        return Asset(
            provider: id,
            providerID: "photo-\(photo.id)",
            kind: .image,
            name: name,
            tags: LocalMatcher.tokens(name),
            width: photo.width,
            height: photo.height,
            licenceClass: .noCredit,
            creditLine: "Photo by \(creator) on Pexels",
            previewURL: (src["medium"] ?? src["small"]).flatMap(URL.init(string:)),
            thumbnailURL: (src["small"] ?? src["tiny"]).flatMap(URL.init(string:)),
            pageURL: photo.url.flatMap(URL.init(string:)),
            remote: remote
        )
    }

    public func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal {
        guard let link = asset.remote["download"], let url = URL(string: link) else { throw AssetError.notFound("download link for \(asset.id)") }
        let file = ProviderFiles.original(in: folder, ext: ProviderFiles.ext(of: url, fallback: asset.kind == .video ? "mp4" : "jpg"))
        // Pexels file links don't need the key.
        try await http.download(url, to: file)
        return FetchedOriginal(asset: asset, file: file)
    }

    public func licence(for asset: Asset) async throws -> AssetLicence {
        AssetLicence(
            name: "Pexels License",
            licenceClass: .noCredit,
            url: Self.licenceURL,
            text: "All photos and videos on Pexels are free to use. Attribution is not required but appreciated. Don't sell unaltered copies, don't imply endorsement by people shown.",
            holder: asset.remote["creator"],
            creditLine: asset.creditLine,
            sourceURL: asset.pageURL
        )
    }
}
