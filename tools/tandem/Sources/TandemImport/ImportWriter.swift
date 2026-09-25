import Foundation
import TandemCore

/// Writes an import where Tandem can open it:
///
///     <folder>/<name>/<name>.tandem        the project
///     <folder>/<name>/<name>.import.json   the report, for agents
///     <folder>/<name>/<name>.import.txt    the report, for people
///
/// Media paths stay absolute (a `ProjectFolder` accepts them), so the
/// project can live anywhere. Links made for files with misleading
/// extensions go in `linkFolder(in:name:)`, next to the project.
public enum ImportWriter {
    /// Writes the import, replacing an earlier import of the same name
    /// only while it's untouched (see `checkReplaceable`).
    @discardableResult
    public static func write(_ result: ImportResult, into folder: URL, name: String) throws -> URL {
        let projectFolder = folder.appendingPathComponent(name, isDirectory: true)
        let url = projectFolder.appendingPathComponent("\(name).\(ProjectFile.fileExtension)")
        try checkReplaceable(url)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        ProjectFile.forgetHistory(of: url)
        try ProjectFile.save(result.project, revision: 0, to: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(result.report).write(to: projectFolder.appendingPathComponent("\(name).import.json"), options: .atomic)
        try Data((result.report.text + "\n").utf8).write(to: projectFolder.appendingPathComponent("\(name).import.txt"), options: .atomic)
        return url
    }

    /// Throws if `url` holds work an import mustn't replace. Imports are
    /// written at revision 0, so a project with a higher revision, or with
    /// edits in its journal that a crash kept from being saved, has been
    /// edited since: it's Mike's now, not the importer's.
    static func checkReplaceable(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let advice = "Import it under another name with --name, or move \(url.lastPathComponent) away first."
        struct Header: Decodable { var revision: Int }
        guard let data = try? Data(contentsOf: url), let header = try? JSONDecoder().decode(Header.self, from: data) else {
            throw ImportError.invalid("\(url.path) already exists and isn't a Tandem project this import can replace. \(advice)")
        }
        if header.revision > 0 {
            throw ImportError.invalid("\(url.path) has been edited since it was imported (revision \(header.revision)). \(advice)")
        }
        if !ProjectJournal.forProject(at: url).entries(after: header.revision).isEmpty {
            throw ImportError.invalid("\(url.path) has edits that weren't saved when Tandem last closed; open it in Tandem to recover them. \(advice)")
        }
    }

    /// Where an import named `name` in `folder` keeps its media links.
    public static func linkFolder(in folder: URL, name: String) -> URL {
        folder.appendingPathComponent(name, isDirectory: true).appendingPathComponent("linked-media", isDirectory: true)
    }
}

/// One import from start to finish, the way `tandem import` runs it:
/// import, then write the project and its report into `output`.
public struct ImportRequest: Sendable {
    public enum Source: Sendable {
        /// A Filmora `.wfp`, or an unzipped project folder.
        case filmora(URL)
        /// A segment EDL (nil for the recipe's own) and its recipe.
        case edl(URL?, recipe: EDLRecipe)
    }

    public var source: Source
    /// The folder the project folder goes in.
    public var output: URL
    /// The project folder and file name. Defaults to the source project's
    /// name.
    public var name: String?
    /// Extra folders to look for moved media in. A Filmora project's own
    /// folder is always searched.
    public var searchFolders: [URL]
    public var pathRewrites: [MediaLocating.PathRewrite]
    public var prober: any MediaProbing

    public init(
        source: Source,
        output: URL,
        name: String? = nil,
        searchFolders: [URL] = [],
        pathRewrites: [MediaLocating.PathRewrite] = [MediaLocating.tinkerDeskHome],
        prober: any MediaProbing = AVFoundationProbe()
    ) {
        self.source = source
        self.output = output
        self.name = name
        self.searchFolders = searchFolders
        self.pathRewrites = pathRewrites
        self.prober = prober
    }

    /// Runs the import and writes it. Returns where the project went.
    public func perform() async throws -> (url: URL, result: ImportResult) {
        switch source {
        case .filmora(let url):
            let name = Self.fileName(self.name ?? (try? WfpProject.load(from: url).name) ?? url.deletingPathExtension().lastPathComponent)
            let locating = MediaLocating(
                prober: prober,
                pathRewrites: pathRewrites,
                searchFolders: [url.deletingLastPathComponent()] + searchFolders,
                aliasFolder: ImportWriter.linkFolder(in: output, name: name)
            )
            let result = try await FilmoraImporter(locating: locating).importProject(at: url)
            return (try ImportWriter.write(result, into: output, name: name), result)
        case .edl(let url, let recipe):
            let name = Self.fileName(self.name ?? recipe.name)
            let locating = MediaLocating(
                prober: prober,
                pathRewrites: pathRewrites,
                searchFolders: searchFolders,
                aliasFolder: ImportWriter.linkFolder(in: output, name: name)
            )
            let result = try await EDLImporter(recipe: recipe, locating: locating).importEDL(at: url)
            return (try ImportWriter.write(result, into: output, name: name), result)
        }
    }

    /// A project name made safe for a file name.
    static func fileName(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Imported" : result
    }
}

