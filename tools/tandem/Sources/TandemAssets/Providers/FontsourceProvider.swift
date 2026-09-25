import Foundation

/// Fonts from Fontsource, which mirrors every Google Font (and a few more)
/// with a free, keyless API. Licences are OFL or Apache, so no credit is
/// needed.
///
/// Fetching a family downloads the Latin subset of every weight and style
/// as TTF; the regular weight is the original and the rest ride along.
public final class FontsourceProvider: AssetProvider, @unchecked Sendable {
    public let id = "fontsource"
    public let displayName = "Google Fonts (Fontsource)"
    public let kinds: Set<AssetKind> = [.font]
    public let capabilities = ProviderCapabilities(search: true)
    public let rules = ProviderRules(cacheTTL: 7 * 24 * 3600, notes: ["Open font licences (OFL, Apache): free to use in videos, no credit needed."])
    public var website: URL? { URL(string: "https://fontsource.org") }

    static let api = "https://api.fontsource.org/v1/fonts"
    let http: ProviderHTTP

    public init(environment: ProviderEnvironment) {
        http = ProviderHTTP(provider: id, rules: rules, environment: environment)
    }

    public func status() async -> ProviderStatus { .ready }

    struct Family: Decodable {
        var id: String
        var family: String
        var subsets: [String]?
        var weights: [Int]?
        var styles: [String]?
        var variable: Bool?
        var category: String?
        var license: String?
        var type: String?
    }

    struct Detail: Decodable {
        struct Files: Decodable {
            var url: [String: String]
        }
        var id: String
        var family: String
        var license: String?
        /// weight -> style -> subset -> file URLs by format.
        var variants: [String: [String: [String: Files]]]
    }

    func asset(for family: Family) -> Asset {
        let spdx = family.license ?? "OFL-1.1"
        return Asset(
            provider: id,
            providerID: family.id,
            kind: .font,
            name: family.family,
            tags: [family.category, family.type == "google" ? "google" : nil, family.variable == true ? "variable" : nil].compactMap { $0 } + (family.subsets ?? []),
            summary: "\(family.category ?? "font"), \((family.weights ?? []).count) weights, \(spdx)",
            licenceClass: LicencePolicy.licenceClass(spdx: spdx) == .unknown ? .noCredit : LicencePolicy.licenceClass(spdx: spdx),
            pageURL: URL(string: "https://fontsource.org/fonts/\(family.id)"),
            remote: [
                "spdx": spdx,
                "weights": (family.weights ?? []).map(String.init).joined(separator: ","),
                "styles": (family.styles ?? []).joined(separator: ",")
            ]
        )
    }

    public func search(_ query: ProviderQuery) async throws -> [Asset] {
        guard query.wants(.font) else { return [] }
        let families = try await http.getJSON([Family].self, URL(string: Self.api)!)
        let assets = families.map(asset(for:))
        let matcher = LocalMatcher(query.text)
        let ranked = matcher.isEmpty ? assets : matcher.rank(assets)
        return LocalMatcher.page(ranked, page: query.page, perPage: query.perPage)
    }

    public func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal {
        let detail = try await http.getJSON(Detail.self, URL(string: "\(Self.api)/\(asset.providerID)")!)
        var files: [(weight: Int, style: String, url: URL)] = []
        for (weight, styles) in detail.variants {
            for (style, subsets) in styles {
                guard let latin = subsets["latin"] ?? subsets.values.first,
                      let link = latin.url["ttf"] ?? latin.url["woff2"],
                      let url = URL(string: link) else { continue }
                files.append((Int(weight) ?? 400, style, url))
            }
        }
        guard !files.isEmpty else { throw AssetError.notFound("font files for \(asset.name)") }
        files.sort { ($0.style == "normal" ? 0 : 1, abs($0.weight - 400), $0.weight) < ($1.style == "normal" ? 0 : 1, abs($1.weight - 400), $1.weight) }
        // A family is up to 18 small files; fetch four at a time.
        let targets = files.map { file in
            (file.url, folder.appendingPathComponent("\(detail.id)-\(file.weight)-\(file.style).\(ProviderFiles.ext(of: file.url, fallback: "ttf"))"))
        }
        var start = 0
        while start < targets.count {
            let batch = targets[start..<min(start + 4, targets.count)]
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (url, target) in batch {
                    group.addTask { try await self.http.download(url, to: target) }
                }
                try await group.waitForAll()
            }
            start += 4
        }
        let downloaded = targets.map(\.1)
        return FetchedOriginal(asset: asset, file: downloaded[0], extras: Array(downloaded.dropFirst()))
    }

    public func licence(for asset: Asset) async throws -> AssetLicence {
        let spdx = asset.remote["spdx"] ?? "OFL-1.1"
        let url = spdx.hasPrefix("OFL") ? URL(string: "https://openfontlicense.org") : spdx.hasPrefix("Apache") ? URL(string: "https://www.apache.org/licenses/LICENSE-2.0") : nil
        return AssetLicence(
            name: spdx,
            spdx: spdx,
            licenceClass: .noCredit,
            url: url,
            holder: asset.name,
            sourceURL: asset.pageURL,
            notes: "Font from Fontsource (Google Fonts)."
        )
    }
}
