import Foundation

/// Library settings Mike might change, in `<root>/settings.json`.
public struct AssetSettings: Codable, Equatable, Sendable {
    /// Freesound stays off until its operator (UPF) gives written
    /// permission for commercial API use.
    public var freesoundEnabled: Bool
    /// The colour Iconify icons are fetched in, as a CSS colour.
    public var iconColour: String
    /// Size cap for cached previews, in bytes.
    public var previewCacheLimit: Int64
    /// Where the shared library folder is, when Mike moved it from the
    /// default (`~/Movies/Tandem Library`; see `SharedLibrary`).
    public var sharedLibrary: String?

    public init(freesoundEnabled: Bool = false, iconColour: String = "#FFFFFF", previewCacheLimit: Int64 = 2 * 1024 * 1024 * 1024, sharedLibrary: String? = nil) {
        self.freesoundEnabled = freesoundEnabled
        self.iconColour = iconColour
        self.previewCacheLimit = previewCacheLimit
        self.sharedLibrary = sharedLibrary
    }

    public static let fileName = "settings.json"

    /// The settings in `root`, or the defaults.
    public static func load(from root: URL) -> AssetSettings {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)) else { return AssetSettings() }
        return (try? JSONDecoder().decode(AssetSettings.self, from: data)) ?? AssetSettings()
    }

    /// Writes the settings into `root`.
    public func save(to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder.sorted.encode(self).write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

extension AssetSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AssetSettings()
        freesoundEnabled = try c.decodeIfPresent(Bool.self, forKey: .freesoundEnabled) ?? d.freesoundEnabled
        iconColour = try c.decodeIfPresent(String.self, forKey: .iconColour) ?? d.iconColour
        previewCacheLimit = try c.decodeIfPresent(Int64.self, forKey: .previewCacheLimit) ?? d.previewCacheLimit
        sharedLibrary = try c.decodeIfPresent(String.self, forKey: .sharedLibrary).flatMap { $0.isEmpty ? nil : $0 }
    }
}
