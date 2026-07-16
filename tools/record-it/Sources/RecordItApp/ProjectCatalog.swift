import Foundation

struct ProjectDestination: Identifiable, Hashable {
    let id: String
    let displayName: String
    let outputDirectory: URL
    let projectDate: Date?

    static func project(directory: URL, date: Date?) -> ProjectDestination {
        ProjectDestination(
            id: directory.path,
            displayName: directory.lastPathComponent,
            outputDirectory: directory.appendingPathComponent("source", isDirectory: true),
            projectDate: date
        )
    }

    static func noProject(outputDirectory: URL) -> ProjectDestination {
        ProjectDestination(
            id: "no-project",
            displayName: "No Project",
            outputDirectory: outputDirectory,
            projectDate: nil
        )
    }
}

struct ProjectCatalog {
    let projectsRoot: URL
    let fallbackOutputRoot: URL

    func destinations() throws -> [ProjectDestination] {
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else {
            return [.noProject(outputDirectory: fallbackOutputRoot)]
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey]
        let directories = try FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        let projects = try directories.compactMap { directory -> ProjectDestination? in
            let values = try directory.resourceValues(forKeys: keys)
            guard values.isDirectory == true else { return nil }
            return .project(directory: directory, date: values.creationDate)
        }

        return projects.sorted {
            ($0.projectDate ?? .distantPast) > ($1.projectDate ?? .distantPast)
        } + [.noProject(outputDirectory: fallbackOutputRoot)]
    }

    func initialDestination() throws -> ProjectDestination {
        try destinations().first ?? .noProject(outputDirectory: fallbackOutputRoot)
    }
}

@discardableResult
func prepareOutputDirectory(
    for destination: ProjectDestination,
    fileManager: FileManager = .default
) throws -> URL {
    try fileManager.createDirectory(
        at: destination.outputDirectory,
        withIntermediateDirectories: true
    )
    return destination.outputDirectory
}
