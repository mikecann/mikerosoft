import Foundation
import TandemCore
import TandemMedia

/// Recently opened projects, newest first, kept in user defaults.
struct RecentProjects: Equatable {
    static let limit = 12
    static let defaultsKey = "recentProjects"

    private(set) var paths: [String]

    init(paths: [String] = []) {
        self.paths = Array(paths.prefix(Self.limit))
    }

    /// Moves `path` to the front.
    mutating func add(_ path: String) {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        paths.removeAll { $0 == standard }
        paths.insert(standard, at: 0)
        if paths.count > Self.limit { paths.removeLast(paths.count - Self.limit) }
    }

    mutating func remove(_ path: String) {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        paths.removeAll { $0 == standard }
    }

    /// The ones still on disk.
    func existing(_ exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [URL] {
        paths.filter(exists).map { URL(fileURLWithPath: $0) }
    }

    static func load(_ defaults: UserDefaults = AppDefaults.store) -> RecentProjects {
        RecentProjects(paths: defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    func save(_ defaults: UserDefaults = AppDefaults.store) {
        defaults.set(paths, forKey: Self.defaultsKey)
    }
}

/// Names for Save As versions: `Video.tandem` becomes `Video v2.tandem`,
/// `Video v2.tandem` becomes `Video v3.tandem`, skipping names in use.
enum VersionNaming {
    static func nextName(after fileName: String, existing: Set<String>) -> String {
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension.isEmpty ? "tandem" : url.pathExtension
        var base = url.deletingPathExtension().lastPathComponent
        var version = 1
        if let match = base.range(of: #" v(\d+)$"#, options: .regularExpression) {
            version = Int(base[match].dropFirst(2)) ?? 1
            base.removeSubrange(match)
        }
        let taken = Set(existing.map { $0.lowercased() })
        var candidate = version + 1
        while taken.contains("\(base) v\(candidate).\(ext)".lowercased()) { candidate += 1 }
        return "\(base) v\(candidate).\(ext)"
    }

    /// The project to write when a version is saved in another folder.
    /// Media paths are relative to the project's folder, so each one is
    /// rewritten to reach the same file from the new folder: relative when
    /// the file is inside it, absolute otherwise.
    static func relocated(_ project: Project, from oldFolder: URL, to newFolder: URL) -> Project {
        let old = ProjectFolder(root: oldFolder)
        let new = ProjectFolder(root: newFolder)
        guard old != new else { return project }
        var copy = project
        for index in copy.media.indices {
            copy.media[index].path = new.path(for: old.url(for: copy.media[index]))
        }
        return copy
    }

    /// The next free export file name: `Video v3 (YouTube 4K).mp4`, then
    /// `Video v3 (YouTube 4K) 2.mp4` if that's taken.
    static func exportName(projectFile: String, preset: String, existing: Set<String>) -> String {
        let base = URL(fileURLWithPath: projectFile).deletingPathExtension().lastPathComponent
        let suffix = preset.isEmpty ? "" : " (\(preset))"
        let taken = Set(existing.map { $0.lowercased() })
        var name = "\(base)\(suffix).mp4"
        var counter = 2
        while taken.contains(name.lowercased()) {
            name = "\(base)\(suffix) \(counter).mp4"
            counter += 1
        }
        return name
    }
}
