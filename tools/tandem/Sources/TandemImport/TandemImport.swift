import Foundation
import TandemCore

/// Importers that turn projects made elsewhere into Tandem projects.
///
/// - `FilmoraImporter` reads Filmora `.wfp` projects, zipped or unzipped.
/// - `EDLImporter` rebuilds a video from the JSON EDL agents cut it from,
///   plus an `EDLRecipe` describing the rest of that video's pipeline
///   (intro, transitions, graphics, music and sound effects).
///
/// Both build through `ProjectCoordinator` with ordinary edit commands, so
/// the result always passes `ProjectValidator`. Anything an importer can't
/// carry over is listed in the `ImportReport` instead of being dropped
/// quietly.
public enum TandemImport {
    public static let version = "0.1.0"
}

/// A finished import: the project and what happened on the way.
public struct ImportResult: Sendable {
    public var project: Project
    public var report: ImportReport

    public init(project: Project, report: ImportReport) {
        self.project = project
        self.report = report
    }
}

/// Errors that stop an import before it starts. Problems with single clips
/// never throw; they go in the report.
public enum ImportError: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    case unreadable(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .unreadable(let what): return "Couldn't read \(what)"
        case .invalid(let what): return "Can't import: \(what)"
        }
    }

    public var errorDescription: String? { description }
}
