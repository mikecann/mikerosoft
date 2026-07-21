import Foundation
import XCTest
@testable import VideoHQApp

private struct NewProjectMarkdownProvider: NotionPageMarkdownProviding {
    let markdown: String

    func retrieveMarkdown(pageID: String) async throws -> NotionPageMarkdown {
        NotionPageMarkdown(markdown: markdown, truncated: false, unknownBlockIDs: [])
    }
}

final class NewVideoProjectTests: XCTestCase {
    func testFolderSuggestionUsesExistingKebabCaseConvention() {
        XCTAssertEqual(NewVideoProject.folderSuggestion(for: "Convex + AI Quick Tips"), "convex-ai-quick-tips")
        XCTAssertEqual(NewVideoProject.folderSuggestion(for: "  Full-text Search!  "), "full-text-search")
    }

    func testCreateBlankProjectUsesChosenFolderName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await NewVideoProject.create(
            rootURL: root,
            folderName: "my-new-video",
            notionPageID: nil,
            markdownProvider: nil
        )

        XCTAssertEqual(result, root.appendingPathComponent("my-new-video", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.appendingPathComponent("script.md").path))
    }

    func testCreateNotionProjectDownloadsScriptIntoNewFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await NewVideoProject.create(
            rootURL: root,
            folderName: "ai-quick-tips",
            notionPageID: "page-id",
            markdownProvider: NewProjectMarkdownProvider(markdown: "# Script\n\nHello")
        )

        XCTAssertEqual(
            try String(contentsOf: result.appendingPathComponent("script.md"), encoding: .utf8),
            "# Script\n\nHello\n"
        )
    }

    func testRejectsUnsafeOrExistingFolderNames() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("existing"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for folderName in ["", "../outside", "nested/folder", "existing"] {
            do {
                _ = try await NewVideoProject.create(
                    rootURL: root,
                    folderName: folderName,
                    notionPageID: nil,
                    markdownProvider: nil
                )
                XCTFail("Expected \(folderName) to be rejected")
            } catch {
                // Expected.
            }
        }
    }
}
