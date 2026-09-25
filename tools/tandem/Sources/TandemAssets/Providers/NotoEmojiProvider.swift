import Foundation

/// Google's animated Noto emoji: about 900 animated stickers, no key, CC BY
/// 4.0. The index is one JSON file; each emoji comes as Lottie (1024
/// square, 60 fps) and as 512 px WebP and GIF.
///
/// Originals are the Lottie files, rendered to HEVC with alpha at import;
/// the WebP comes along as a fallback.
public final class NotoEmojiProvider: AssetProvider, @unchecked Sendable {
    public let id = "noto"
    public let displayName = "Noto animated emoji"
    public let kinds: Set<AssetKind> = [.sticker]
    public let capabilities = ProviderCapabilities(search: true)
    public let rules = ProviderRules(
        cacheTTL: 7 * 24 * 3600,
        notes: ["CC BY 4.0: put \(NotoEmojiProvider.creditLine) in the video description."]
    )
    public var website: URL? { URL(string: "https://googlefonts.github.io/noto-emoji-animation/") }

    static let indexURL = URL(string: "https://googlefonts.github.io/noto-emoji-animation/data/api.json")!
    static let assetBase = "https://fonts.gstatic.com/s/e/notoemoji/latest/"
    static let licenceURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    public static let creditLine = "Animated Noto Emoji by Google, CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)"

    let http: ProviderHTTP

    public init(environment: ProviderEnvironment) {
        http = ProviderHTTP(provider: id, rules: rules, environment: environment)
    }

    public func status() async -> ProviderStatus { .ready }

    struct Index: Decodable {
        struct Icon: Decodable {
            var codepoint: String
            var tags: [String]?
            var categories: [String]?
            var popularity: Double?
        }
        var icons: [Icon]
    }

    /// Every animated emoji, most popular first.
    public func index() async throws -> [Asset] {
        let index = try await http.getJSON(Index.self, Self.indexURL)
        return index.icons.map(asset(for:)).sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
    }

    public func search(_ query: ProviderQuery) async throws -> [Asset] {
        guard query.wants(.sticker) else { return [] }
        let all = try await index()
        let matcher = LocalMatcher(query.text)
        let ranked = matcher.isEmpty ? all : matcher.rank(all)
        return LocalMatcher.page(ranked, page: query.page, perPage: query.perPage)
    }

    func asset(for icon: Index.Icon) -> Asset {
        Self.asset(codepoint: icon.codepoint, tags: icon.tags ?? [], categories: icon.categories ?? [], popularity: icon.popularity)
    }

    /// An emoji as an asset, from its code point (`1f680`, or `26a0_fe0f`
    /// for sequences) and the index's tags.
    public static func asset(codepoint: String, tags: [String], categories: [String], popularity: Double? = nil) -> Asset {
        let cleanTags = tags.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ":")).replacingOccurrences(of: "-", with: " ") }
        let name = cleanTags.first.map(ProviderFiles.title) ?? codepoint
        let character = emoji(codepoint)
        let base = assetBase + codepoint + "/"
        var asset = Asset(
            provider: "noto",
            providerID: codepoint,
            kind: .sticker,
            name: name,
            tags: cleanTags + categories + (character.isEmpty ? [] : [character]),
            summary: [character, categories.first].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "),
            hasAlpha: true,
            width: 1024,
            height: 1024,
            licenceClass: .creditNeeded,
            creditLine: creditLine,
            previewURL: URL(string: base + "512.webp"),
            thumbnailURL: URL(string: base + "emoji.svg"),
            pageURL: URL(string: "https://googlefonts.github.io/noto-emoji-animation/"),
            remote: ["lottie": base + "lottie.json", "webp": base + "512.webp", "gif": base + "512.gif"],
            popularity: popularity
        )
        asset.summary = asset.summary?.isEmpty == true ? nil : asset.summary
        return asset
    }

    /// The emoji characters for a code point string like `1f44b_1f3fb`.
    static func emoji(_ codepoint: String) -> String {
        let scalars = codepoint.split(separator: "_").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
        return String(String.UnicodeScalarView(scalars))
    }

    public func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal {
        let base = Self.assetBase + asset.providerID + "/"
        let lottie = URL(string: asset.remote["lottie"] ?? base + "lottie.json")!
        let webp = URL(string: asset.remote["webp"] ?? base + "512.webp")!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let webpFile = folder.appendingPathComponent("original-512.webp")
        try await http.download(webp, to: webpFile)
        guard AssetNormaliser.canRenderLottie else {
            return FetchedOriginal(asset: asset, file: webpFile)
        }
        let lottieFile = ProviderFiles.original(in: folder, ext: "json")
        try await http.download(lottie, to: lottieFile)
        return FetchedOriginal(asset: asset, file: lottieFile, extras: [webpFile])
    }

    public func licence(for asset: Asset) async throws -> AssetLicence {
        AssetLicence(
            name: "CC BY 4.0",
            spdx: "CC-BY-4.0",
            licenceClass: .creditNeeded,
            url: Self.licenceURL,
            text: "Animated Noto Emoji is licensed under CC BY 4.0. Credit Google and link the licence.",
            holder: "Google",
            creditLine: Self.creditLine,
            sourceURL: website
        )
    }
}
