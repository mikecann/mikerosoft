import Foundation

enum NewProjectSource: String, CaseIterable, Identifiable {
    case notion
    case folder

    var id: Self { self }
}

enum NewVideoProjectError: LocalizedError {
    case invalidFolderName
    case folderAlreadyExists(URL)
    case missingNotionProvider

    var errorDescription: String? {
        switch self {
        case .invalidFolderName:
            return "Use a single folder name without slashes or parent-directory references."
        case .folderAlreadyExists(let url):
            return "A project folder already exists at \(url.path)."
        case .missingNotionProvider:
            return "Video HQ could not connect to Notion for this project."
        }
    }
}

enum NewVideoProject {
    static func folderSuggestion(for projectName: String) -> String {
        let folded = projectName
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        let pieces = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return pieces.joined(separator: "-")
    }

    static func create(
        rootURL: URL,
        folderName: String,
        notionPageID: String?,
        markdownProvider: (any NotionPageMarkdownProviding)?,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\") else {
            throw NewVideoProjectError.invalidFolderName
        }

        let projectURL = rootURL.appendingPathComponent(trimmed, isDirectory: true)
        guard !fileManager.fileExists(atPath: projectURL.path) else {
            throw NewVideoProjectError.folderAlreadyExists(projectURL)
        }

        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        do {
            if let notionPageID {
                guard let markdownProvider else {
                    throw NewVideoProjectError.missingNotionProvider
                }
                _ = try await NotionScriptImporter(provider: markdownProvider).importScript(
                    pageID: notionPageID,
                    into: projectURL
                )
            }
            return projectURL
        } catch {
            // A failed Notion download should not leave a half-created project behind.
            try? fileManager.removeItem(at: projectURL)
            throw error
        }
    }
}
