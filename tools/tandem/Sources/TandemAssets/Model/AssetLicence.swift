import Foundation

/// The terms an asset was downloaded under, snapshotted at download time.
///
/// Terms change and subscriptions lapse, so the catalogue keeps a snapshot
/// per download rather than one current value: it's the proof for a Content
/// ID dispute and what the credits builder reads.
public struct AssetLicence: Codable, Equatable, Sendable {
    /// Human name, for example "CC BY 4.0" or "Pexels License".
    public var name: String
    /// SPDX identifier when there is one, for example "CC-BY-4.0".
    public var spdx: String?
    public var licenceClass: LicenceClass
    /// Where the full terms live.
    public var url: URL?
    /// A copy of the terms (or the folder's licence note) when we have it.
    public var text: String?
    /// Who made or owns the asset, for credits.
    public var holder: String?
    /// The line to put in the video description, if the licence wants one.
    public var creditLine: String?
    /// A licence certificate or its ID (Envato and Epidemic issue these per
    /// download or project).
    public var certificate: String?
    /// Where the asset came from, for people.
    public var sourceURL: URL?
    public var notes: String?
    public var capturedAt: Date

    public init(
        name: String,
        spdx: String? = nil,
        licenceClass: LicenceClass,
        url: URL? = nil,
        text: String? = nil,
        holder: String? = nil,
        creditLine: String? = nil,
        certificate: String? = nil,
        sourceURL: URL? = nil,
        notes: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.name = name
        self.spdx = spdx
        self.licenceClass = licenceClass
        self.url = url
        self.text = text
        self.holder = holder
        self.creditLine = creditLine
        self.certificate = certificate
        self.sourceURL = sourceURL
        self.notes = notes
        self.capturedAt = capturedAt
    }
}

/// Classifying licences by their SPDX identifier.
public enum LicencePolicy {
    /// Licences that forbid commercial use or force share-alike on the video.
    /// Assets under them never enter the library.
    public static func isExcluded(spdx: String) -> Bool {
        let id = spdx.uppercased()
        if id.hasPrefix("GPL") || id.hasPrefix("AGPL") || id.hasPrefix("LGPL") { return true }
        if id.contains("-NC") || id.contains("NONCOMMERCIAL") { return true }
        if id.contains("-SA") || id.contains("SHAREALIKE") { return true }
        if id.contains("-ND") { return true }
        return false
    }

    /// Which licence class an SPDX identifier falls in. Permissive software
    /// licences (MIT, Apache, ISC, BSD) and font licences (OFL) don't ask
    /// for a credit in a video; CC BY does.
    public static func licenceClass(spdx: String) -> LicenceClass {
        let id = spdx.uppercased()
        if isExcluded(spdx: spdx) { return .unknown }
        if id.hasPrefix("CC0") || id == "UNLICENSE" || id == "PUBLIC DOMAIN" || id == "PDDL-1.0" { return .noCredit }
        if id.hasPrefix("CC-BY") { return .creditNeeded }
        if id.hasPrefix("MIT") || id.hasPrefix("APACHE") || id.hasPrefix("ISC") || id.hasPrefix("BSD")
            || id.hasPrefix("OFL") || id.hasPrefix("MPL") || id == "ZLIB" {
            return .noCredit
        }
        return .unknown
    }

    /// The deed URL for a Creative Commons SPDX identifier.
    public static func creativeCommonsURL(spdx: String) -> URL? {
        let id = spdx.uppercased()
        if id == "CC0-1.0" { return URL(string: "https://creativecommons.org/publicdomain/zero/1.0/") }
        guard id.hasPrefix("CC-BY") else { return nil }
        let parts = id.split(separator: "-")
        guard parts.count >= 3, let version = parts.last else { return nil }
        let flavour = parts.dropFirst().dropLast().joined(separator: "-").lowercased()
        return URL(string: "https://creativecommons.org/licenses/\(flavour)/\(version)/")
    }
}
