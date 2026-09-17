import Darwin
import Foundation

enum LauncherServiceMode: String, CaseIterable, Equatable {
    case worker
    case viewer

    var argument: String { "--\(rawValue)" }

    var scriptName: String {
        switch self {
        case .worker: "run-service-bruce.sh"
        case .viewer: "run-viewer-bruce.sh"
        }
    }

    var displayName: String { rawValue.capitalized }
}

struct LauncherArgumentError: LocalizedError, Equatable {
    let errorDescription: String?
}

struct LauncherPreflightError: LocalizedError, Equatable {
    let errorDescription: String?
}

struct ResolvedArchiveBookmark: Equatable {
    let url: URL
    let isStale: Bool
}

enum ArchiveBookmarkData {
    static func make(for url: URL) throws -> Data {
        // This app is deliberately not sandboxed. Removable Volumes consent is
        // attached to the signed app identity; this bookmark records which
        // exact folder the user selected without relying on sandbox scope.
        try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ data: Data) throws -> ResolvedArchiveBookmark {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return ResolvedArchiveBookmark(url: url, isStale: stale)
    }
}

struct WorkerLauncherConfiguration: Equatable {
    static let expectedArchivePath = "/Volumes/CannMedia/MeetingArchive"
    static let expectedVolumeUUID = "5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46"
    static let bundleIdentifier = "com.mikerosoft.meeting-archive-worker"
    static let archiveBookmarkDefaultsKey = "archiveDirectoryBookmark"

    let archiveDirectory: URL
    let expectedVolumeUUID: String

    init(
        archiveDirectory: URL = URL(fileURLWithPath: expectedArchivePath, isDirectory: true),
        expectedVolumeUUID: String = expectedVolumeUUID
    ) {
        self.archiveDirectory = archiveDirectory.standardizedFileURL
        self.expectedVolumeUUID = expectedVolumeUUID.uppercased()
    }

    var volumeDirectory: URL { archiveDirectory.deletingLastPathComponent() }

    func serviceScript(for mode: LauncherServiceMode) -> URL {
        archiveDirectory
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("worker", isDirectory: true)
            .appendingPathComponent(mode.scriptName, isDirectory: false)
    }

    var serviceExecutable: URL { URL(fileURLWithPath: "/bin/bash") }

    func serviceArguments(for mode: LauncherServiceMode) -> [String] {
        [serviceScript(for: mode).path]
    }

    func requestedMode(arguments: [String]) throws -> LauncherServiceMode? {
        guard !arguments.isEmpty else { return nil }
        guard arguments.count == 1,
              let mode = LauncherServiceMode.allCases.first(where: { $0.argument == arguments[0] }) else {
            throw LauncherArgumentError(
                errorDescription: "Use exactly --worker or --viewer. Arbitrary commands and paths are not accepted."
            )
        }
        return mode
    }

    func selectionError(for selectedDirectory: URL) -> String? {
        let selected = selectedDirectory.standardizedFileURL.path
        guard selected == archiveDirectory.path else {
            return "Choose exactly \(archiveDirectory.path). The worker will not accept a parent, sibling, or lookalike folder."
        }
        return nil
    }

    func resolvedBookmarkError(for bookmarkedDirectory: URL) -> String? {
        guard selectionError(for: bookmarkedDirectory) == nil else {
            return "The saved archive permission no longer points to \(archiveDirectory.path). Open the launcher and choose that exact folder again."
        }
        return nil
    }
}

enum ArchivePathPreflight {
    typealias VolumeUUIDProvider = (URL) throws -> String?

    static func verify(
        _ configuration: WorkerLauncherConfiguration,
        mode: LauncherServiceMode,
        volumeUUIDProvider: VolumeUUIDProvider = systemVolumeUUID
    ) throws {
        try verifyRealDirectoryChain(configuration.archiveDirectory)
        let actualUUID = try volumeUUIDProvider(configuration.volumeDirectory)?.uppercased()
        guard actualUUID == configuration.expectedVolumeUUID else {
            throw LauncherPreflightError(
                errorDescription: "CannMedia volume UUID mismatch. Expected \(configuration.expectedVolumeUUID), got \(actualUUID ?? "unavailable")."
            )
        }
        try verifyRealFileChain(configuration.serviceScript(for: mode))
    }

    static func systemVolumeUUID(_ volumeDirectory: URL) throws -> String? {
        try volumeDirectory.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    private static func verifyRealDirectoryChain(_ url: URL) throws {
        try walk(url, finalMustBeDirectory: true)
    }

    private static func verifyRealFileChain(_ url: URL) throws {
        try walk(url, finalMustBeDirectory: false)
    }

    private static func walk(_ url: URL, finalMustBeDirectory: Bool) throws {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else {
            throw LauncherPreflightError(errorDescription: "Expected an absolute path: \(path)")
        }
        let components = path.split(separator: "/").map(String.init)
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(path: "/") }
        defer { Darwin.close(descriptor) }

        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let mustBeDirectory = !isLast || finalMustBeDirectory
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (mustBeDirectory ? O_DIRECTORY : 0)
            let next = Darwin.openat(descriptor, component, flags)
            guard next >= 0 else {
                throw posixError(path: "/" + components[...index].joined(separator: "/"))
            }
            var metadata = stat()
            guard Darwin.fstat(next, &metadata) == 0 else {
                let error = posixError(path: "/" + components[...index].joined(separator: "/"))
                Darwin.close(next)
                throw error
            }
            let kind = metadata.st_mode & S_IFMT
            let expectedKind = mustBeDirectory ? S_IFDIR : S_IFREG
            guard kind == expectedKind else {
                Darwin.close(next)
                throw LauncherPreflightError(
                    errorDescription: "Unsafe archive path component: /\(components[...index].joined(separator: "/"))"
                )
            }
            Darwin.close(descriptor)
            descriptor = next
        }
    }

    private static func posixError(path: String) -> LauncherPreflightError {
        LauncherPreflightError(
            errorDescription: "Could not safely open \(path): \(String(cString: strerror(errno)))"
        )
    }
}

enum ChildProcessShutdown {
    static func stop(_ process: Process, timeout: TimeInterval = 5) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}
