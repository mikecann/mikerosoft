import Foundation

struct VideoProject: Identifiable, Equatable {
    let directoryURL: URL
    let scriptURL: URL?
    let renderedVideoURLs: [URL]

    var id: URL { directoryURL }
    var name: String { directoryURL.lastPathComponent }
    var canonicalScriptURL: URL { directoryURL.appendingPathComponent("script.md") }
}

struct VideoProjectCatalog {
    let rootURL: URL
    var fileManager = FileManager.default

    func discover() throws -> [VideoProject] {
        let directories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
            return values?.isDirectory == true && values?.isHidden != true
        }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        return try directories.map(project(at:))
    }

    private func project(at directoryURL: URL) throws -> VideoProject {
        let files = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }

        let renderedVideos = files
            .filter { $0.pathExtension.caseInsensitiveCompare("mp4") == .orderedSame }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        let script = scriptURL(in: files)

        return VideoProject(
            directoryURL: directoryURL,
            scriptURL: script,
            renderedVideoURLs: renderedVideos
        )
    }

    private func scriptURL(in files: [URL]) -> URL? {
        if let canonical = files.first(where: {
            $0.lastPathComponent.caseInsensitiveCompare("script.md") == .orderedSame
        }) {
            return canonical
        }

        return files
            .filter {
                let supportedExtension = ["md", "txt"].contains($0.pathExtension.lowercased())
                return supportedExtension && $0.deletingPathExtension().lastPathComponent
                    .localizedCaseInsensitiveContains("script")
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .first
    }
}
