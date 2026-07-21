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
            "---\nnotion_page_id: b55c9c91-384d-452b-81db-d1ef79372b75\n---\n\n# Video script\n\nOpening line.\n"
        )
        XCTAssertFalse(result.wasTruncated)
    }

    func testScriptDocumentReadsNotionSourceWithoutExposingFrontMatter() {
        let document = NotionScriptDocument(contents: """
        ---
        notion_page_id: b55c9c91-384d-452b-81db-d1ef79372b75
        ---

        # Video script

        Opening line.
        """)

        XCTAssertEqual(document.notionPageID, "b55c9c91-384d-452b-81db-d1ef79372b75")
        XCTAssertEqual(document.markdown, "# Video script\n\nOpening line.")
    }

    func testScriptDocumentLeavesLocalMarkdownUntouched() {
        let document = NotionScriptDocument(contents: "# Local script\n\nOpening line.")

        XCTAssertNil(document.notionPageID)
        XCTAssertEqual(document.markdown, "# Local script\n\nOpening line.")
    }
}
