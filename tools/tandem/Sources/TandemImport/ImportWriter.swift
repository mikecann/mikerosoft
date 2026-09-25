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
