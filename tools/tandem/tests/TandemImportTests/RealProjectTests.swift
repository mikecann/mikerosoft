import Foundation
import XCTest
@testable import TandemCore
@testable import TandemImport

/// Imports Mike's real projects. Opt-in, since they need his media:
///
///     TANDEM_REAL_MEDIA=1 swift test --package-path tools/tandem --filter RealProjectTests
///
/// Each import must validate with no errors and no failed steps, and is
/// written to /private/tmp/claude-501/tandem-importer/<name>/<name>.tandem
/// with its report beside it. The source folders are only ever read.
final class RealProjectTests: XCTestCase {
    static let output = URL(fileURLWithPath: "/private/tmp/claude-501/tandem-importer")
    static let videos = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("dev/convex/convex-videos")

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TANDEM_REAL_MEDIA"] == "1",
            "Set TANDEM_REAL_MEDIA=1 to import Mike's real projects."
        )
    }

    /// Validates, writes and reloads an import.
    @discardableResult
    func check(_ result: ImportResult, name: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        assertValid(result.project, file: file, line: line)
        XCTAssertEqual(result.report.count(.failed), 0, result.report.text, file: file, line: line)
        let url = try ImportWriter.write(result, into: Self.output, name: name)
        let loaded = try ProjectFile.load(from: url)
        XCTAssertEqual(loaded.project, result.project, "the project should survive a save and load", file: file, line: line)
        print("\n=== \(name): \(url.path)\n\(result.report.text)\n")
        return url
    }

    func testDecisionModelsEDL() async throws {
        let recipe = try EDLRecipe.decisionModels
        let result = try await EDLImporter(recipe: recipe).importEDL()
        try check(result, name: "decision-models-edl")
        XCTAssertEqual(result.report.count(.missingMedia), 0, result.report.text)
        XCTAssertEqual(result.project.markers.filter { $0.kind == .section }.count, 10)
    }

    /// Imports a Filmora project, linking library files with misleading
    /// extensions into the output folder.
    @discardableResult
    func importFilmora(_ relative: String, name: String) async throws -> ImportResult {
        let url = Self.videos.appendingPathComponent(relative)
        let locating = MediaLocating(
            pathRewrites: [MediaLocating.tinkerDeskHome],
            searchFolders: [url.deletingLastPathComponent()],
            aliasFolder: ImportWriter.linkFolder(in: Self.output, name: name)
        )
        let result = try await FilmoraImporter(locating: locating).importProject(at: url)
        try check(result, name: name)
        return result
    }

    func testDecisionModelsV14() async throws {
        let result = try await importFilmora("decision-models/Decision Models v14.wfp", name: "decision-models-v14")
        let p = result.project
        XCTAssertEqual(p.settings.frameRate, .fps25)
        XCTAssertEqual(p.duration.seconds, 667.31, accuracy: 0.05)
        XCTAssertEqual(result.report.count(.missingMedia), 0, result.report.text)
    }

    func testAIGateway() async throws {
        let result = try await importFilmora("ai-gateway/AI Gateway.wfp", name: "ai-gateway")
        XCTAssertEqual(result.project.duration.seconds, 339.36, accuracy: 0.05)
    }

    func testRelease1_46() async throws {
        let result = try await importFilmora("v1.46.0/1.46.0.wfp", name: "v1.46.0")
        XCTAssertTrue(result.project.allTracks.flatMap(\.clips).contains { clip in
            if case .text(let text) = clip.content { return text.text == "v1.46.0" }
            return false
        })
    }

    func testRelease1_46Portrait() async throws {
        let result = try await importFilmora("v1.46.0/1.46.0 - portrait.wfp", name: "v1.46.0-portrait")
        XCTAssertEqual(result.project.settings.width, 1080)
        XCTAssertEqual(result.project.settings.height, 1920)
    }

    func testNoGuidelinesAndWeb() async throws {
        try await importFilmora("no guidelines and web/no guidelines and web.wfp", name: "no-guidelines-and-web")
    }

    func testMagicJevBall() async throws {
        try await importFilmora("decision-models/Magic Jev Ball.wfp", name: "magic-jev-ball")
    }
}
