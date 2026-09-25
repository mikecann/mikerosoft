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
}
