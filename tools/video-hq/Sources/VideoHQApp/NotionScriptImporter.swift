import Foundation

protocol NotionPageMarkdownProviding {
    func retrieveMarkdown(pageID: String) async throws -> NotionPageMarkdown
}

extension NotionClient: NotionPageMarkdownProviding {}

struct NotionScriptImportResult: Equatable {
    let scriptURL: URL
    let wasTruncated: Bool
}

struct NotionScriptDocument: Equatable {
    private static let pageIDKey = "notion_page_id"

    let markdown: String
    let notionPageID: String?

    init(contents: String) {
        guard contents.hasPrefix("---\n"),
              let closingDelimiter = contents.range(
                of: "\n---\n",
                range: contents.index(contents.startIndex, offsetBy: 4)..<contents.endIndex
              ) else {
            markdown = contents
            notionPageID = nil
            return
        }

        let metadataStart = contents.index(contents.startIndex, offsetBy: 4)
        let metadata = contents[metadataStart..<closingDelimiter.lowerBound]
        let pageID = metadata
            .split(separator: "\n")
            .compactMap(Self.pageID(fromMetadataLine:))
            .first

        // Only consume front matter containing VideoHQ's source key. A local
        // script may have unrelated YAML metadata that belongs in the document.
        guard let pageID else {
            markdown = contents
            notionPageID = nil
            return
        }

        var bodyStart = closingDelimiter.upperBound
        if contents[bodyStart...].hasPrefix("\n") {
            // Also accept the common blank line between YAML front matter and Markdown.
            bodyStart = contents.index(after: bodyStart)
        }
        markdown = String(contents[bodyStart...])
        notionPageID = pageID
    }

    static func fileContents(markdown: String, notionPageID: String) -> String {
        let body = markdown.hasSuffix("\n") ? markdown : markdown + "\n"
        return "---\n\(pageIDKey): \(notionPageID)\n---\n\n\(body)"
    }

    private static func pageID(fromMetadataLine line: Substring) -> String? {
        let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2,
              pieces[0].trimmingCharacters(in: .whitespaces) == pageIDKey else {
            return nil
        }
        let value = pieces[1].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

struct NotionScriptImporter {
    let provider: any NotionPageMarkdownProviding

    func importScript(pageID: String, into projectDirectoryURL: URL) async throws -> NotionScriptImportResult {
        let page = try await provider.retrieveMarkdown(pageID: pageID)
        let scriptURL = projectDirectoryURL.appendingPathComponent("script.md")
        let contents = NotionScriptDocument.fileContents(
            markdown: page.markdown,
            notionPageID: pageID
        )
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        return NotionScriptImportResult(scriptURL: scriptURL, wasTruncated: page.truncated)
    }
}
