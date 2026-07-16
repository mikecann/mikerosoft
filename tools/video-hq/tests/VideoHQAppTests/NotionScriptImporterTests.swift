import Foundation
import XCTest
@testable import VideoHQApp

private struct StubMarkdownProvider: NotionPageMarkdownProviding {
    let result: NotionPageMarkdown

    func retrieveMarkdown(pageID: String) async throws -> NotionPageMarkdown {
        result
    }
}

final class NotionScriptImporterTests: XCTestCase {
    func testImportWritesCanonicalScriptFileThatCanBeReloaded() async throws {
        let projectDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDirectory) }
        let provider = StubMarkdownProvider(
            result: NotionPageMarkdown(
                markdown: "# Video script\n\nOpening line.",
                truncated: false,
                unknownBlockIDs: []
            )
        )

        let result = try await NotionScriptImporter(provider: provider).importScript(
            pageID: "b55c9c91-384d-452b-81db-d1ef79372b75",
            into: projectDirectory
        )

        XCTAssertEqual(result.scriptURL, projectDirectory.appendingPathComponent("script.md"))
        XCTAssertEqual(
            try String(contentsOf: result.scriptURL, encoding: .utf8),
            "# Video script\n\nOpening line.\n"
        )
        XCTAssertFalse(result.wasTruncated)
    }
}
