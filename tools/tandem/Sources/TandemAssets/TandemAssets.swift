import Foundation

/// The asset library: music, sound effects, stickers, overlays, B-roll,
/// fonts, icons and logos from several sources, with the licence of every
/// asset recorded.
///
/// The pieces:
/// - `AssetCatalog` is the local index (SQLite with FTS5): assets, licence
///   snapshots, usage by project and favourites.
/// - `AssetProvider` is one source (an import folder, ElevenLabs, Noto
///   emoji, Iconify...), each with its own rules for keys, rate limits and
///   caching.
/// - `AssetNormaliser` turns whatever a source hands over into something
///   the editor plays directly: 48 kHz audio with loudness and peaks, HEVC
///   with alpha for animated stickers, PNG for SVG, registered fonts.
/// - `AssetLibrary` ties them together and is what the app, the CLI and MCP
///   call: search, fetch, generate, use in a project, credits.
public enum TandemAssets {
    public static let version = "0.1.0"
}
