import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

@main
private enum LauncherConfigurationTests {
    static func main() throws {
        let configuration = WorkerLauncherConfiguration()
        try require(
            configuration.selectionError(for: URL(fileURLWithPath: "/Volumes/CannMedia/MeetingArchive")) == nil,
            "exact archive path was rejected"
        )
        for wrongPath in [
            "/Volumes/CannMedia",
            "/Volumes/CannMedia/MeetingArchive-copy",
            "/Volumes/cannmedia/MeetingArchive",
            "/Volumes/CannMedia/MeetingArchive/meetings",
        ] {
            try require(
                configuration.selectionError(for: URL(fileURLWithPath: wrongPath)) != nil,
                "unsafe selection was accepted: \(wrongPath)"
            )
        }
        try require(
            configuration.serviceScript(for: .worker).path ==
                "/Volumes/CannMedia/MeetingArchive/runtime/worker/run-service-bruce.sh",
            "worker script escaped the fixed archive root"
        )
        try require(
            configuration.serviceScript(for: .viewer).path ==
                "/Volumes/CannMedia/MeetingArchive/runtime/worker/run-viewer-bruce.sh",
            "viewer script escaped the fixed archive root"
        )
        try require(configuration.serviceExecutable.path == "/bin/bash", "unexpected service executable")
        try require(
            configuration.serviceArguments(for: .worker) == [configuration.serviceScript(for: .worker).path],
            "worker arguments changed"
        )
        try require(
            configuration.serviceArguments(for: .viewer) == [configuration.serviceScript(for: .viewer).path],
            "viewer arguments changed"
        )
        let finderMode = try configuration.requestedMode(arguments: [])
        let workerMode = try configuration.requestedMode(arguments: ["--worker"])
        let viewerMode = try configuration.requestedMode(arguments: ["--viewer"])
        try require(finderMode == nil, "Finder launch selected a service")
        try require(workerMode == .worker, "worker mode failed")
        try require(viewerMode == .viewer, "viewer mode failed")
        for unsafeArguments in [["--service"], ["/tmp/script"], ["--worker", "extra"]] {
            do {
                _ = try configuration.requestedMode(arguments: unsafeArguments)
                throw TestFailure(description: "unsafe arguments were accepted: \(unsafeArguments)")
            } catch is LauncherArgumentError {
                // Expected: there is no arbitrary command or path mode.
            }
        }
        try require(
            configuration.resolvedBookmarkError(
                for: URL(fileURLWithPath: "/Volumes/CannMedia/MeetingArchive")
            ) == nil,
            "exact saved archive bookmark was rejected"
        )
        try require(
            configuration.resolvedBookmarkError(
                for: URL(fileURLWithPath: "/Volumes/Other/MeetingArchive")
            ) != nil,
            "bookmark outside the fixed archive root was accepted"
        )
        try require(
            WorkerLauncherConfiguration.archiveBookmarkDefaultsKey == "archiveDirectoryBookmark",
            "bookmark key changed"
        )
        let bookmarkData = try ArchiveBookmarkData.make(
            for: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        )
        let bookmark = try ArchiveBookmarkData.resolve(bookmarkData)
        try require(bookmark.url.path == "/private/tmp", "bookmark path changed")
        try require(!bookmark.isStale, "new bookmark was stale")
        try require(
            WorkerLauncherConfiguration.bundleIdentifier == "com.mikerosoft.meeting-archive-worker",
            "bundle identity changed"
        )
        try require(
            WorkerLauncherConfiguration.expectedVolumeUUID == "5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46",
            "CannMedia identity changed"
        )
        try testRealPrivatePathIsNotRewritten()
        try testArchivePreflight()
        try testChildShutdown()
        print("Meeting Archive Worker launcher configuration tests passed")
    }

    private static func testRealPrivatePathIsNotRewritten() throws {
        // /tmp is a symlink to the real directory /private/tmp. The preflight
        // must accept the real path as given and reject the symlinked alias.
        // It walks the archive directory before asking for the volume UUID,
        // so the provider only runs when that walk succeeded.
        let real = WorkerLauncherConfiguration(
            archiveDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        )
        try require(real.archiveDirectory.path == "/private/tmp", "real archive path was rewritten")
        var walkedRealPath = false
        _ = try? ArchivePathPreflight.verify(real, mode: .worker) { _ in
            walkedRealPath = true
            return nil
        }
        try require(walkedRealPath, "real /private/tmp directory chain failed preflight")

        let symlinked = WorkerLauncherConfiguration(
            archiveDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        var walkedSymlinkedPath = false
        _ = try? ArchivePathPreflight.verify(symlinked, mode: .worker) { _ in
            walkedSymlinkedPath = true
            return nil
        }
        try require(!walkedSymlinkedPath, "symlinked /tmp directory passed preflight")
    }

    private static func realDirectory(containing file: String) throws -> URL {
        let directory = URL(fileURLWithPath: file).deletingLastPathComponent().path
        guard let resolved = realpath(directory, nil) else {
            throw TestFailure(description: "could not resolve \(directory)")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func testArchivePreflight() throws {
        let fileManager = FileManager.default
        // The build directory may be reached through a symlink such as /tmp,
        // which preflight rightly rejects, so build the fixture on the real path.
        let root = try realDirectory(containing: CommandLine.arguments[0])
            .appendingPathComponent("meeting-archive-launcher-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let archive = root.appendingPathComponent("CannMedia/MeetingArchive", isDirectory: true)
        let worker = archive.appendingPathComponent("runtime/worker", isDirectory: true)
        try fileManager.createDirectory(at: worker, withIntermediateDirectories: true)
        for script in ["run-service-bruce.sh", "run-viewer-bruce.sh"] {
            try Data("#!/bin/bash\nexit 0\n".utf8).write(to: worker.appendingPathComponent(script))
        }
        let configuration = WorkerLauncherConfiguration(
            archiveDirectory: archive,
            expectedVolumeUUID: "EXPECTED-UUID"
        )
        try ArchivePathPreflight.verify(configuration, mode: .worker) { _ in "expected-uuid" }

        do {
            try ArchivePathPreflight.verify(configuration, mode: .worker) { _ in "wrong-uuid" }
            throw TestFailure(description: "wrong volume UUID passed preflight")
        } catch is LauncherPreflightError {
            // Expected: no external script can run from the wrong volume.
        }

        let redirectedRoot = root.appendingPathComponent("redirected", isDirectory: true)
        try fileManager.createDirectory(at: redirectedRoot, withIntermediateDirectories: true)
        try fileManager.removeItem(at: archive.appendingPathComponent("runtime"))
        try fileManager.createSymbolicLink(
            at: archive.appendingPathComponent("runtime"),
            withDestinationURL: redirectedRoot
        )
        do {
            try ArchivePathPreflight.verify(configuration, mode: .worker) { _ in "expected-uuid" }
            throw TestFailure(description: "intermediate archive symlink passed preflight")
        } catch is LauncherPreflightError {
            // Expected: every path component must be a real directory.
        }

        try fileManager.removeItem(at: archive.appendingPathComponent("runtime"))
        try fileManager.createDirectory(at: worker, withIntermediateDirectories: true)
        let externalScript = redirectedRoot.appendingPathComponent("external-worker.sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: externalScript)
        try fileManager.createSymbolicLink(
            at: worker.appendingPathComponent("run-service-bruce.sh"),
            withDestinationURL: externalScript
        )
        do {
            try ArchivePathPreflight.verify(configuration, mode: .worker) { _ in "expected-uuid" }
            throw TestFailure(description: "symlinked worker script passed preflight")
        } catch is LauncherPreflightError {
            // Expected: only the regular wrapper at the fixed path may run.
        }
        let externalBytes = try Data(contentsOf: externalScript)
        try require(externalBytes == Data("#!/bin/bash\nexit 0\n".utf8), "preflight modified the symlink target")
    }

    private static func testChildShutdown() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let started = Date()
        ChildProcessShutdown.stop(process, timeout: 1)
        try require(!process.isRunning, "child survived launcher shutdown")
        try require(Date().timeIntervalSince(started) < 2, "child shutdown exceeded its bound")
    }
}
