import Foundation

/// SVGL: SVG logos of tech brands (Convex, React, Next.js, Vercel...), no
/// key. The whole list is one response.
///
/// Logos are trademarks of their owners, not licensed artwork: fine for
/// referring to the product in a video, not for implying endorsement.
/// Where a brand has light and dark versions each becomes its own asset.
public final class SVGLProvider: AssetProvider, @unchecked Sendable {
    public let id = "svgl"
    public let displayName = "SVGL logos"
    public let kinds: Set<AssetKind> = [.logo]
    public let capabilities = ProviderCapabilities(search: true)
    public let rules = ProviderRules(
        cacheTTL: 24 * 3600,
        notes: ["Logos are trademarks of their owners: use them to refer to the product, never to suggest endorsement. Check the brand guidelines when there are any."]
    )
    public var website: URL? { URL(string: "https://svgl.app") }

    static let listURL = URL(string: "https://api.svgl.app")!
    let http: ProviderHTTP

    public init(environment: ProviderEnvironment) {
        http = ProviderHTTP(provider: id, rules: rules, environment: environment)
    }

    public func status() async -> ProviderStatus { .ready }

    /// A route is a single URL or a light and a dark one.
    enum Route: Decodable {
        case single(String)
        case themed(light: String, dark: String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let url = try? container.decode(String.self) {
                self = .single(url)
                return
            }
            let pair = try container.decode([String: String].self)
            self = .themed(light: pair["light"] ?? "", dark: pair["dark"] ?? "")
        }
    }

    /// A category is a string or a list of strings.
    struct Categories: Decodable {
        var values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let one = try? container.decode(String.self) {
                values = [one]
            } else {
                values = try container.decode([String].self)
            }
        }
    }

    struct Logo: Decodable {
        var id: Int?
        var title: String
        var category: Categories?
        var route: Route
        var wordmark: Route?
        var url: String?
        var brandUrl: String?
    }

    /// Every logo variant, in SVGL's order. A file listed twice (some
    /// brands use one logo for both themes) appears once.
    public func all() async throws -> [Asset] {
        let logos = try await http.getJSON([Logo].self, Self.listURL)
        var seen = Set<String>()
        return logos.flatMap(assets(for:)).filter { seen.insert($0.providerID).inserted }
    }

    func assets(for logo: Logo) -> [Asset] {
        var result: [Asset] = []
        func add(_ url: String, variant: String?, wordmark: Bool) {
            guard let file = URL(string: url), !url.isEmpty else { return }
            let stem = file.deletingPathExtension().lastPathComponent
            var name = logo.title + (wordmark ? " wordmark" : "")
            if let variant { name += " (for \(variant) backgrounds)" }
            var remote = ["svg": url, "title": logo.title]
            if let brand = logo.brandUrl { remote["brandURL"] = brand }
            result.append(Asset(
                provider: id,
                providerID: stem,
                kind: .logo,
                name: name,
                tags: [logo.title, "logo"] + (logo.category?.values ?? []) + (wordmark ? ["wordmark"] : []) + (variant.map { [$0] } ?? []),
                summary: "\(logo.title) logo, a trademark of its owner",
                hasAlpha: true,
                licenceClass: .noCredit,
                previewURL: file,
                thumbnailURL: file,
                pageURL: logo.url.flatMap(URL.init(string:)),
                remote: remote
            ))
        }
        switch logo.route {
        case .single(let url): add(url, variant: nil, wordmark: false)
        case .themed(let light, let dark):
            add(light, variant: "light", wordmark: false)
            add(dark, variant: "dark", wordmark: false)
        }
        switch logo.wordmark {
        case .single(let url): add(url, variant: nil, wordmark: true)
        case .themed(let light, let dark):
            add(light, variant: "light", wordmark: true)
            add(dark, variant: "dark", wordmark: true)
        case nil: break
        }
        return result
    }

    public func search(_ query: ProviderQuery) async throws -> [Asset] {
        guard query.wants(.logo) else { return [] }
        let everything = try await all()
        let matcher = LocalMatcher(query.text)
        let ranked = matcher.isEmpty ? everything : matcher.rank(everything)
        return LocalMatcher.page(ranked, page: query.page, perPage: query.perPage)
    }

    public func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal {
        let url = asset.remote["svg"].flatMap(URL.init(string:)) ?? URL(string: "https://svgl.app/library/\(asset.providerID).svg")!
        let file = ProviderFiles.original(in: folder, ext: "svg")
        try await http.download(url, to: file)
        return FetchedOriginal(asset: asset, file: file)
    }

    public func licence(for asset: Asset) async throws -> AssetLicence {
        let title = asset.remote["title"] ?? asset.name
        return AssetLicence(
            name: "Trademark of \(title)'s owner",
            licenceClass: .noCredit,
            url: asset.remote["brandURL"].flatMap(URL.init(string:)),
            holder: title,
            sourceURL: URL(string: "https://svgl.app"),
            notes: "Logo from svgl.app. Use it to refer to \(title) only; follow the brand guidelines where there are any."
        )
    }
}
