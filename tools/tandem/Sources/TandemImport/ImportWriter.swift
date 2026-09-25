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
    @discardableResult
    public static func write(_ result: ImportResult, into folder: URL, name: String) throws -> URL {
        let projectFolder = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let url = projectFolder.appendingPathComponent("\(name).\(ProjectFile.fileExtension)")
        try ProjectFile.save(result.project, revision: 0, to: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(result.report).write(to: projectFolder.appendingPathComponent("\(name).import.json"), options: .atomic)
        try Data((result.report.text + "\n").utf8).write(to: projectFolder.appendingPathComponent("\(name).import.txt"), options: .atomic)
        return url
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

