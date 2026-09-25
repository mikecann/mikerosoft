import Foundation

/// Epidemic Sound music and SFX: a stub until Mike subscribes.
///
/// When he does: Epidemic's personal-key MCP endpoint serves search,
/// similar tracks, stems and downloads. The plan tier decides what's
/// allowed: Personal and Creator plans exclude company or client work, so a
/// Convex channel needs Pro (freelance) or Business (employee). Downloads
/// come with a licence per track and the channel has to be registered to
/// clear Content ID claims. Until then, tracks downloaded by hand can go in
/// an import folder with the `epidemic` licence preset.
public final class EpidemicSoundProvider: AssetProvider, @unchecked Sendable {
    public let id = "epidemic"
    public let displayName = "Epidemic Sound"
    public let kinds: Set<AssetKind> = [.music, .sfx]
    public let capabilities = ProviderCapabilities(search: true, similar: true)
    public let rules = ProviderRules(notes: [
        "Covered only while the subscription is active; the plan tier decides whether company videos are allowed.",
        "Register the channel with Epidemic so Content ID claims clear."
    ])
    public var website: URL? { URL(string: "https://www.epidemicsound.com") }

    public init() {}

    public func status() async -> ProviderStatus {
        ProviderStatus(.stub, "Not set up: Mike hasn't subscribed. Pro (freelance) or Business (Convex employee) is needed for company videos.")
    }

    public func search(_ query: ProviderQuery) async throws -> [Asset] {
        throw AssetError.providerUnavailable(provider: displayName, reason: "not set up until Mike subscribes")
    }

    public func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal {
        throw AssetError.providerUnavailable(provider: displayName, reason: "not set up until Mike subscribes")
    }

    public func licence(for asset: Asset) async throws -> AssetLicence {
        AssetLicence(name: "Epidemic Sound subscription", licenceClass: .subscription, url: URL(string: "https://www.epidemicsound.com/licensing/"))
    }
}

/// Lordicon animated icons: a stub until Mike subscribes.
///
/// When he does: the PRO plan ($8 a month) gives a bearer-token API with
/// Lottie JSON downloads and no credit requirement (the free plan needs a
/// credit). Lottie files render to HEVC with alpha like Noto emoji.
public final class LordiconProvider: AssetProvider, @unchecked Sendable {
    public let id = "lordicon"
    public let displayName = "Lordicon"
    public let kinds: Set<AssetKind> = [.icon, .sticker]
    public let capabilities = ProviderCapabilities(search: true)
    public let rules = ProviderRules(notes: [
        "PRO plan: no credit needed while subscribed. Free icons need a credit line.",
        "Lottie downloads render to HEVC with alpha at import."
    ])
    public var website: URL? { URL(string: "https://lordicon.com") }

    public init() {}

    public func status() async -> ProviderStatus {
        ProviderStatus(.stub, "Not set up: Mike hasn't subscribed to Lordicon PRO.")
    }

    public func search(_ query: ProviderQuery) async throws -> [Asset] {
        throw AssetError.providerUnavailable(provider: displayName, reason: "not set up until Mike subscribes")
    }

    public func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal {
        throw AssetError.providerUnavailable(provider: displayName, reason: "not set up until Mike subscribes")
    }

    public func licence(for asset: Asset) async throws -> AssetLicence {
        AssetLicence(name: "Lordicon PRO licence", licenceClass: .subscription, url: URL(string: "https://lordicon.com/licenses"))
    }
}
