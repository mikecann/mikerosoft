import Foundation

protocol NotionPageMarkdownProviding {
    func retrieveMarkdown(pageID: String) async throws -> NotionPageMarkdown
}

extension NotionClient: NotionPageMarkdownProviding {}

struct NotionScriptImportResult: Equatable {
    let scriptURL: URL
    let wasTruncated: Bool
}

struct NotionScriptImporter {
    let provider: any NotionPageMarkdownProviding

    func importScript(pageID: String, into projectDirectoryURL: URL) async throws -> NotionScriptImportResult {
        let page = try await provider.retrieveMarkdown(pageID: pageID)
        let scriptURL = projectDirectoryURL.appendingPathComponent("script.md")
        let contents = page.markdown.hasSuffix("\n") ? page.markdown : page.markdown + "\n"
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        return NotionScriptImportResult(scriptURL: scriptURL, wasTruncated: page.truncated)
    }
}
