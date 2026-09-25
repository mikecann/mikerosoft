import Foundation
import TandemCore

/// The folder a project lives in. Media paths in the project are relative to
/// it, and Tandem keeps its own files in `.tandem/` inside it:
///
///     <video folder>/
///       <name>.tandem          the project
///       source/                record-it takes (<base>-camera.mov, <base>-screen.mov)
///       broll/ music/ sfx/ graphics/ assets/ ...
///       exports/               renders, each with a project snapshot beside it
///       .tandem/
///         backups/             previous saves
///         <name>.journal.jsonl edits since the last save
///         cache/               analysis results, keyed by content hash
///         <name>.lock          who has the project open, and its API port
public struct ProjectFolder: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// The folder holding a `.tandem` file.
    public init(projectFile: URL) {
        self.init(root: projectFile.deletingLastPathComponent())
    }

    public var supportFolder: URL { root.appendingPathComponent(".tandem", isDirectory: true) }
    public var cacheFolder: URL { supportFolder.appendingPathComponent("cache", isDirectory: true) }
    public var exportsFolder: URL { root.appendingPathComponent("exports", isDirectory: true) }
    public var assetsFolder: URL { root.appendingPathComponent("assets", isDirectory: true) }

    /// The file behind a media item.
    public func url(for item: MediaItem) -> URL {
        url(forPath: item.path)
    }

    public func url(forPath path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~/") { return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath) }
        return root.appendingPathComponent(path)
    }

    /// The path to store for a file: relative when it's inside the folder.
    public func path(for url: URL) -> String {
        let file = url.standardizedFileURL.path
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.hasPrefix(base) ? String(file.dropFirst(base.count)) : file
    }
}
