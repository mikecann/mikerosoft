import AVFoundation
import XCTest
@testable import TandemAPI
import TandemAssets
import TandemMedia
import ImageIO
@testable import TandemCore

/// Runs the built `tandem` binary, the way Mike and agents do.
final class CLITests: XCTestCase {
    static var binary: URL {
        Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("tandem")
    }

    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TANDEM_PROJECT")
        environment.removeValue(forKey: "TANDEM_AUTHOR")
        environment.merge(extra) { $1 }
        return environment
    }

    @discardableResult
    func tandem(_ arguments: String..., in folder: URL, stdin: String? = nil, env: [String: String] = [:]) throws -> Output {
        try tandem(arguments, in: folder, stdin: stdin, env: env)
    }

    func tandem(_ arguments: [String], in folder: URL, stdin: String? = nil, env: [String: String] = [:]) throws -> Output {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = Self.environment(env)
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        let exited = ExitSignal(process)
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        var errorData = Data()
        let reader = Thread { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
        reader.start()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        while !reader.isFinished { Thread.sleep(forTimeInterval: 0.005) }
        return Output(status: process.terminationStatus, stdout: String(decoding: outputData, as: UTF8.self), stderr: String(decoding: errorData, as: UTF8.self))
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.binary.path), "tandem isn't built at \(Self.binary.path)")
    }

    func testHelpVersionAndUsageErrors() throws {
        let folder = TempFolder()
        let version = try tandem("--version", in: folder.url)
        XCTAssertEqual(version.status, 0)
        XCTAssertEqual(version.stdout, "tandem \(TandemAPI.version)\n")

        let bare = try tandem(in: folder.url)
        XCTAssertEqual(bare.status, 2)
        XCTAssertTrue(bare.stdout.contains("Commands:"), bare.stdout)

        let help = try tandem("help", "tighten", in: folder.url)
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: tandem tighten"), help.stdout)

        let typo = try tandem("statsu", in: folder.url)
        XCTAssertEqual(typo.status, 2)
        XCTAssertTrue(typo.stderr.contains("Did you mean `tandem status`?"), typo.stderr)

        let option = try tandem("pauses", "--mni", "1", in: folder.url)
        XCTAssertEqual(option.status, 2)
        XCTAssertTrue(option.stderr.contains("Unknown option --mni. Did you mean --min?"), option.stderr)

        let wrong = try tandem("timeline", "--min", "3", in: folder.url)
        XCTAssertEqual(wrong.status, 2)
        XCTAssertTrue(wrong.stderr.contains("`tandem timeline` doesn't take --min"), wrong.stderr)

        let noProject = try tandem("status", in: folder.url)
        XCTAssertEqual(noProject.status, 1)
        XCTAssertTrue(noProject.stderr.contains("No .tandem project"), noProject.stderr)

        let badTime = try tandem("frame", "soon", in: folder.url)
        XCTAssertEqual(badTime.status, 2)
        XCTAssertTrue(badTime.stderr.contains("isn't a time"), badTime.stderr)
    }

    func testHeadlessEditLoop() throws {
        let folder = TempFolder()
        let created = try tandem("new", "Loop.tandem", in: folder.url)
        XCTAssertEqual(created.status, 0, created.stderr)
        XCTAssertTrue(created.stdout.contains("with 8 tracks"), created.stdout)

        let batch = #"""
        {"label": "Place the take", "commands": [
          {"addMedia": {"item": {"id": "med_cam", "path": "source/t1-camera.mov", "kind": "video", "role": "camera", "takeID": "t1", "takeOffset": 0.5, "duration": 60, "hasVideo": true, "hasAudio": true}}},
          {"addMedia": {"item": {"id": "med_scr", "path": "source/t1-screen.mov", "kind": "video", "role": "screen", "takeID": "t1", "duration": 61, "hasVideo": true, "hasAudio": true}}},
          {"placeMedia": {"mediaIDs": ["med_cam", "med_scr"], "at": 0}}
        ]}
        """#
        try batch.write(to: folder.file("batch.json"), atomically: true, encoding: .utf8)
        let applied = try tandem("apply", "batch.json", in: folder.url)
        XCTAssertEqual(applied.status, 0, applied.stderr)
        XCTAssertTrue(applied.stdout.hasPrefix("Applied \"Place the take\" by cli as revision 1."), applied.stdout)

        let timeline = try tandem("timeline", in: folder.url)
        XCTAssertEqual(timeline.status, 0)
        XCTAssertTrue(timeline.stdout.contains("t1-camera.mov [00:00.000-01:00.000]  linked #1  level -20 LUFS"), timeline.stdout)

        let cut = try tandem("apply", "-", "--author", "claude", in: folder.url, stdin: #"{"blade": {"at": "0:10"}}"#)
        XCTAssertEqual(cut.status, 0, cut.stderr)
        XCTAssertTrue(cut.stdout.hasPrefix("Applied \"Cut at 00:10.000\" by claude as revision 2."), cut.stdout)

        let dry = try tandem("apply", "-", "--dry-run", in: folder.url, stdin: #"[{"rippleDeleteRange": {"range": {"start": 20, "end": 22}}}]"#)
        XCTAssertEqual(dry.status, 0, dry.stderr)
        XCTAssertTrue(dry.stdout.contains("it would work"), dry.stdout)

        let history = try tandem("history", in: folder.url)
        XCTAssertTrue(history.stdout.contains("Cut at 00:10.000  (claude)\n  Place the take  (cli)"), history.stdout)

        let undo = try tandem("undo", "--expect", "2", in: folder.url)
        XCTAssertEqual(undo.status, 0, undo.stderr)
        XCTAssertEqual(undo.stdout, "Undid \"Cut at 00:10.000\" (by claude). Now at revision 3.\n")

        let status = try tandem("status", "--json", in: folder.url)
        let decoded = try ServiceJSON.decoder().decode(StatusResult.self, from: Data(status.stdout.utf8))
        XCTAssertEqual(decoded.revision, 3)
        XCTAssertEqual(decoded.redo, "Cut at 00:10.000")
        XCTAssertTrue(decoded.headless)

        let invalid = try tandem("validate", in: folder.url)
        XCTAssertEqual(invalid.status, 1, "the media files don't exist")
        XCTAssertTrue(invalid.stdout.contains("source/t1-camera.mov is missing"), invalid.stdout)

        let bad = try tandem("apply", "-", "--json", in: folder.url, stdin: #"{"trim": {"clipID": "x", "edge": "end", "to": 5, "rippel": true}}"#)
        XCTAssertEqual(bad.status, 1)
        let envelope = try ServiceJSON.decoder().decode(ErrorEnvelope.self, from: Data(bad.stdout.utf8))
        XCTAssertEqual(envelope.error.code, "badRequest")
        XCTAssertTrue(envelope.error.message.contains("did you mean \"ripple\""), envelope.error.message)

        // Without transcripts the tools say so instead of inventing pauses.
        let pauses = try tandem("pauses", in: folder.url)
        XCTAssertEqual(pauses.status, 0)
        XCTAssertTrue(pauses.stdout.contains("No transcript yet for med_cam"), pauses.stdout)

        let project = try ProjectFile.load(from: folder.file("Loop.tandem"))
        XCTAssertEqual(project.revision, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectSession.lockURL(for: folder.file("Loop.tandem")).path))
    }

    func testServeTakesCommandsOverHTTP() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let serve = Process()
        serve.executableURL = Self.binary
        serve.arguments = ["serve"]
        serve.currentDirectoryURL = folder.url
        serve.environment = Self.environment()
        let serveOutput = Pipe()
        serve.standardOutput = serveOutput
        serve.standardError = Pipe()
        let exited = ExitSignal(serve)
        try serve.run()
        defer { if serve.isRunning { serve.terminate() } }

        let deadline = Date().addingTimeInterval(10)
        while ProjectSession.liveLock(for: url)?.port == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let lock = try XCTUnwrap(ProjectSession.liveLock(for: url), "serve should advertise its port")
        XCTAssertEqual(lock.pid, serve.processIdentifier)

        let status = try tandem("status", "--json", in: folder.url)
        let decoded = try ServiceJSON.decoder().decode(StatusResult.self, from: Data(status.stdout.utf8))
        XCTAssertFalse(decoded.headless, "went through serve's API")
        XCTAssertEqual(decoded.openIn?.pid, serve.processIdentifier)

        let applied = try tandem("apply", "-", "--author", "codex", in: folder.url, stdin: #"{"addMarker": {"marker": {"id": "mk_hook", "time": 3, "name": "Hook"}}}"#)
        XCTAssertEqual(applied.status, 0, applied.stderr)
        XCTAssertTrue(applied.stdout.contains("by codex as revision 2"), applied.stdout)

        serve.interrupt()
        XCTAssertTrue(exited.wait(timeout: 20), "serve should stop on Ctrl-C")
        XCTAssertEqual(serve.terminationStatus, 0)
        let printed = String(decoding: serveOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(printed.contains("Serving \"Decision Models\""), printed)
        XCTAssertEqual(try ProjectFile.load(from: url).project.markers.map(\.id), ["mk_hook", "mk_s2"], "saved on the way out")
        XCTAssertNil(ProjectSession.liveLock(for: url))
    }

    func testServeLetsGoWhenTheAppAsks() async throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let serve = Process()
        serve.executableURL = Self.binary
        serve.arguments = ["serve"]
        serve.currentDirectoryURL = folder.url
        serve.environment = Self.environment()
        serve.standardOutput = Pipe()
        serve.standardError = Pipe()
        let exited = ExitSignal(serve)
        try serve.run()
        defer { if serve.isRunning { serve.terminate() } }
        let deadline = Date().addingTimeInterval(10)
        while ProjectSession.liveLock(for: url)?.port == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertThrowsError(try ProjectSession.open(url, owner: .app), "serve has it")

        // What the app does: ask serve to let go, then open.
        let session = try await ProjectSession.open(url, owner: .app, waitingUpTo: 10)
        let stopped = await exited.value(timeout: 20)
        XCTAssertTrue(stopped, "serve should quit once it has let go")
        XCTAssertEqual(serve.terminationStatus, 0)
        XCTAssertEqual(ProjectSession.readLock(for: url)?.owner, .app)
        session.close()
    }

    func testMCPOverStdio() async throws {
        let folder = TempFolder()
        _ = try APIFixture.write(to: folder.url)
        let mcp = Process()
        mcp.executableURL = Self.binary
        mcp.arguments = ["mcp"]
        mcp.currentDirectoryURL = folder.url
        mcp.environment = Self.environment()
        let input = Pipe(), output = Pipe()
        mcp.standardInput = input
        mcp.standardOutput = output
        mcp.standardError = Pipe()
        let exited = ExitSignal(mcp)
        try mcp.run()
        defer { if mcp.isRunning { mcp.terminate() } }
        var lines = LineReader.lines(output.fileHandleForReading).makeAsyncIterator()
        func send(_ text: String) { input.fileHandleForWriting.write(Data((text + "\n").utf8)) }
        func next() async throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: Data((await lines.next() ?? "").utf8))
        }

        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}"#)
        let initialize = try await next()
        XCTAssertEqual(initialize[json: "result"]?[json: "protocolVersion"], .string("2025-06-18"))
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"timeline","arguments":{"from":20,"to":25}}}"#)
        let timeline = try await next()
        let text = timeline[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString ?? ""
        XCTAssertTrue(text.contains("clip_brl1  00:20.000-00:25.000"), text)
        send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"apply","arguments":{"commands":[{"blade":{"at":22}}]}}}"#)
        let apply = try await next()
        XCTAssertTrue(apply[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString?.contains("by claude as revision 2") ?? false, "\(apply)")

        try input.fileHandleForWriting.close()
        let stopped = await exited.value(timeout: 20)
        XCTAssertTrue(stopped, "exits when stdin closes")
        XCTAssertEqual(mcp.terminationStatus, 0)
    }
}

/// `tandem import`, wired in at integration.
final class ImportCLITests: XCTestCase {
    let cli = CLITests()

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
    }

    func testImportUsageErrors() throws {
        let folder = TempFolder()
        let bare = try cli.tandem("import", in: folder.url)
        XCTAssertEqual(bare.status, 2)
        XCTAssertTrue(bare.stderr.contains("needs filmora, edl or compare"), bare.stderr)
        let typo = try cli.tandem("import", "filmroa", "x.wfp", in: folder.url)
        XCTAssertEqual(typo.status, 2)
        XCTAssertTrue(typo.stderr.contains("Did you mean `tandem import filmora`?"), typo.stderr)
        let noRecipe = try cli.tandem("import", "edl", in: folder.url)
        XCTAssertEqual(noRecipe.status, 2)
        XCTAssertTrue(noRecipe.stderr.contains("needs --recipe"), noRecipe.stderr)
        let missing = try cli.tandem("import", "filmora", "nope.wfp", in: folder.url)
        XCTAssertEqual(missing.status, 1)
    }

    func testCompareTwoCuts() throws {
        let folder = TempFolder()
        let coordinator = ProjectCoordinator(project: APIFixture.project())
        let a = folder.url.appendingPathComponent("a.tandem")
        let b = folder.url.appendingPathComponent("b.tandem")
        try ProjectFile.save(coordinator.project, revision: 1, to: a)
        try coordinator.apply(EditBatch(label: "Tighten", commands: [.rippleDeleteRange(range: TimeRange(start: Time(seconds: 10), end: Time(seconds: 11)))]))
        try ProjectFile.save(coordinator.project, revision: 2, to: b)
        let result = try cli.tandem("import", "compare", "a.tandem", "b.tandem", "--json", in: folder.url)
        XCTAssertEqual(result.status, 0, result.stderr)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
        guard case .object(let fields) = json else { return XCTFail("not an object: \(result.stdout)") }
        XCTAssertNotNil(fields["matchedVoice"])
    }
}

/// Knows when a process has exited. `Process.waitUntilExit()` spins the run
/// loop of the thread that launched the process, so in an async test that
/// resumes on another thread it can wait forever; the termination handler
/// runs on a queue of its own.
final class ExitSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var exited = false

    /// Call before `run()`.
    init(_ process: Process) {
        process.terminationHandler = { [self] _ in
            lock.withLock { exited = true }
            semaphore.signal()
        }
    }

    /// Blocks until the process exits, or `timeout` passes. True if it exited.
    @discardableResult
    func wait(timeout: TimeInterval = 120) -> Bool {
        if lock.withLock({ exited }) { return true }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    /// The same without blocking a concurrency thread.
    func value(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ exited }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return lock.withLock { exited }
    }
}

/// `tandem assets`, against a library in a temp folder with the network
/// and the Keychain switched off.
final class AssetsCLITests: XCTestCase {
    let cli = CLITests()

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
    }

    func testAssetsEndToEnd() async throws {
        let folder = TempFolder("tandem-assets-cli")
        let root = folder.url.appendingPathComponent("library", isDirectory: true)
        do {
            // An import folder whose licence asks for a credit.
            let library = try AssetLibrary(root: root, previewFolder: root.appendingPathComponent("previews"), transport: OfflineTransport(), secrets: StaticSecretStore())
            let imports = folder.url.appendingPathComponent("imports", isDirectory: true)
            try AssetFixtures.wav(at: imports.appendingPathComponent("sfx/Swoosh_Air.wav"))
            try await library.addImportFolder(imports, licence: FolderLicence(source: "Test Sounds", licence: "CC BY 4.0", licenceClass: .creditNeeded, credit: "Swoosh Air by Test Sounds (CC BY 4.0)"))
        }
        let env = ["TANDEM_ASSETS_ROOT": root.path, "TANDEM_ASSETS_OFFLINE": "1"]
        let video = folder.url.appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        let projectURL = try APIFixture.write(to: video)

        let providers = try cli.tandem("assets", "providers", in: video, env: env)
        XCTAssertEqual(providers.status, 0, providers.stderr)
        XCTAssertTrue(providers.stdout.contains("elevenlabs  ElevenLabs"), providers.stdout)
        XCTAssertTrue(providers.stdout.contains("needs a key"), providers.stdout)

        let search = try cli.tandem("assets", "search", "swoosh", "--kind", "sfx", "--json", in: video, env: env)
        XCTAssertEqual(search.status, 0, search.stderr)
        let found = try ServiceJSON.decoder().decode(AssetSearchResult.self, from: Data(search.stdout.utf8))
        let id = try XCTUnwrap(found.local.first?.id)

        let use = try cli.tandem("assets", "use", id, "--at", "0:02", "--author", "claude", in: video, env: env)
        XCTAssertEqual(use.status, 0, use.stderr)
        XCTAssertTrue(use.stdout.hasPrefix("Placed Swoosh Air (sfx) at 00:02.000 on SFX at -15 dB as revision 2."), use.stdout)
        XCTAssertTrue(use.stdout.contains("needs a credit"), use.stdout)
        let project = try ProjectFile.load(from: projectURL).project
        XCTAssertEqual(project.track(named: "SFX")?.clips.first?.start, t(2))
        let history = try cli.tandem("history", in: video)
        XCTAssertTrue(history.stdout.contains("Add Swoosh Air at 00:02.000  (claude)"), history.stdout)

        let credits = try cli.tandem("assets", "credits", in: video, env: env)
        XCTAssertEqual(credits.status, 0, credits.stderr)
        XCTAssertTrue(credits.stdout.contains("Credits\nSwoosh Air by Test Sounds (CC BY 4.0)"), credits.stdout)

        let online = try cli.tandem("assets", "search", "rocket", "--online", "--provider", "noto", in: video, env: env)
        XCTAssertEqual(online.status, 0, online.stderr)
        XCTAssertTrue(online.stdout.contains("noto: couldn't search."), online.stdout)

        let generate = try cli.tandem("assets", "generate", "sfx", "soft whoosh", in: video, env: env)
        XCTAssertEqual(generate.status, 1)
        XCTAssertTrue(generate.stderr.contains("ElevenLabs is unavailable"), generate.stderr)

        let starter = try cli.tandem("assets", "install-starter", in: video, env: env)
        XCTAssertTrue(starter.stdout.hasPrefix("The starter set is in the library:"), starter.stdout)

        let noID = try cli.tandem("assets", "use", in: video, env: env)
        XCTAssertEqual(noID.status, 2)
        XCTAssertTrue(noID.stderr.contains("needs an asset ID"), noID.stderr)
        let wrongOption = try cli.tandem("assets", "search", "x", "--at", "3", in: video, env: env)
        XCTAssertEqual(wrongOption.status, 2)
        XCTAssertTrue(wrongOption.stderr.contains("`tandem assets search` doesn't take --at"), wrongOption.stderr)
    }
}

/// `tandem screenshot` needs the app, so headless it explains that.
final class ScreenshotCLITests: XCTestCase {
    func testScreenshotWithoutTheAppExplainsWhy() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        let folder = TempFolder()
        _ = try APIFixture.write(to: folder.url)
        let result = try CLITests().tandem("screenshot", "-o", "shot.png", in: folder.url)
        XCTAssertEqual(result.status, 1)
        XCTAssertFalse(result.stderr.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.file("shot.png").path))
    }
}

final class NewProjectCLITests: XCTestCase {
    func testPortraitProject() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        let folder = TempFolder()
        let result = try CLITests().tandem("new", "Short.tandem", "--portrait", in: folder.url)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("1080x1920"), result.stdout)
        let project = try ProjectFile.load(from: folder.file("Short.tandem")).project
        XCTAssertEqual(project.settings.width, 1080)
        XCTAssertEqual(project.settings.height, 1920)
        let bad = try CLITests().tandem("new", "Odd.tandem", "--size", "big", in: folder.url)
        XCTAssertEqual(bad.status, 2)
    }

    /// A project made portrait is its own short: the short preset and the
    /// default both render its 1080x1920 canvas at the 1080p rate, and say
    /// what they used. (It used to fail with "No output format".)
    func testPortraitProjectExports() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        let cli = CLITests()
        let folder = TempFolder()
        try FileManager.default.createDirectory(at: folder.file("source"), withIntermediateDirectories: true)
        try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", "color=c=0x2040c0:s=1080x1920:d=2:r=30",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-shortest", folder.file("source/take1-camera.mp4").path])
        let created = try cli.tandem("new", "Short.tandem", "--portrait", in: folder.url)
        XCTAssertEqual(created.status, 0, created.stderr)
        let project = try ProjectFile.load(from: folder.file("Short.tandem")).project
        let media = try XCTUnwrap(project.media.first { $0.path == "source/take1-camera.mp4" })
        let placed = try cli.tandem("apply", "-", in: folder.url, stdin: #"{"placeMedia": {"mediaIDs": ["\#(media.id)"], "at": 0}}"#)
        XCTAssertEqual(placed.status, 0, placed.stderr)

        // Into exports/, as the snapshot beside each export is a .tandem too.
        let short = try cli.tandem("export", "--preset", "short", "-o", "exports/short.mp4", in: folder.url)
        XCTAssertEqual(short.status, 0, short.stderr)
        XCTAssertTrue(short.stdout.contains("(Short 9:16: 1080x1920 H.264 at 20 Mbps, 00:02.000 long)"), short.stdout)
        let standard = try cli.tandem("export", "-o", "exports/default.mp4", "--json", in: folder.url)
        XCTAssertEqual(standard.status, 0, standard.stderr)
        let outcome = try ServiceJSON.decoder().decode(ExportOutcome.self, from: Data(standard.stdout.utf8))
        XCTAssertEqual(outcome.preset, "YouTube 1080p")
        XCTAssertEqual([outcome.width, outcome.height], [1080, 1920])
        XCTAssertEqual(outcome.videoBitrate, 20_000_000)
        for name in ["exports/short.mp4", "exports/default.mp4"] {
            let asset = AVURLAsset(url: folder.file(name))
            let size = try await asset.loadTracks(withMediaType: .video)[0].load(.naturalSize)
            XCTAssertEqual(size, CGSize(width: 1080, height: 1920), name)
        }
        // Laying a short over a project that's already one is refused.
        let layout = try cli.tandem("short", in: folder.url)
        XCTAssertEqual(layout.status, 1)
        XCTAssertTrue(layout.stderr.contains("already 9:16"), layout.stderr)

        let help = try cli.tandem("help", "export", in: folder.url)
        XCTAssertTrue(help.stdout.contains("1080x1920 for a 9:16 one"), help.stdout)
        XCTAssertTrue(help.stdout.contains("`tandem new --portrait`"), help.stdout)
    }
}

/// Stock alpha stickers come as QuickTime Animation or PNG in a MOV, which
/// AVFoundation can't decode. Rendering a project that uses them used to
/// fail with "Cannot Decode"; now the render converts them first.
final class UndecodableStickerCLITests: XCTestCase {
    func testQuickTimeAnimationAndPNGStickersRender() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        let cli = CLITests()
        let folder = TempFolder()
        try FileManager.default.createDirectory(at: folder.file("stickers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.file("source"), withIntermediateDirectories: true)
        // A red disc on a clear square, in both codecs, and a screen take.
        let disc = "color=c=red:s=256x256:d=2:r=30,format=rgba,geq=r='255':g='0':b='0':a='if(lt(hypot(X-128,Y-128),100),255,0)'"
        try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", disc, "-c:v", "qtrle", "-pix_fmt", "argb", folder.file("stickers/disc-qtrle.mov").path])
        try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", disc, "-c:v", "png", "-pix_fmt", "rgba", folder.file("stickers/disc-png.mov").path])
        try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", "color=c=0x2040c0:s=1280x720:d=4:r=30", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        folder.file("source/take1-screen.mp4").path])

        let created = try cli.tandem("new", "Alpha.tandem", "--size", "1280x720", in: folder.url)
        XCTAssertEqual(created.status, 0, created.stderr)
        let listed = try cli.tandem("media", "--refresh", "--json", in: folder.url)
        XCTAssertEqual(listed.status, 0, listed.stderr)
        let media = try ServiceJSON.decoder().decode(MediaResult.self, from: Data(listed.stdout.utf8))
        func id(_ path: String) throws -> String { try XCTUnwrap(media.items.first { $0.path == path }?.id, path) }
        XCTAssertEqual(media.items.first { $0.path == "stickers/disc-qtrle.mov" }?.undecodableCodec, "rle ")
        XCTAssertEqual(media.items.first { $0.path == "stickers/disc-png.mov" }?.undecodableCodec, "png ")
        XCTAssertNil(media.items.first { $0.path == "source/take1-screen.mp4" }?.undecodableCodec)

        let project = try ProjectFile.load(from: folder.file("Alpha.tandem")).project
        let graphics = try XCTUnwrap(project.track(named: "Graphics")).id
        let batch = """
        {"commands": [
          {"placeMedia": {"mediaIDs": ["\(try id("source/take1-screen.mp4"))"], "at": 0}},
          {"placeMedia": {"mediaIDs": ["\(try id("stickers/disc-qtrle.mov"))"], "at": 0, "videoTrackID": "\(graphics)"}},
          {"placeMedia": {"mediaIDs": ["\(try id("stickers/disc-png.mov"))"], "at": 2, "videoTrackID": "\(graphics)"}}
        ]}
        """
        let applied = try cli.tandem("apply", "-", in: folder.url, stdin: batch)
        XCTAssertEqual(applied.status, 0, applied.stderr)

        for (time, name) in [("1", "qtrle"), ("3", "png")] {
            let frame = try cli.tandem("frame", time, "-o", "frame-\(name).png", in: folder.url)
            XCTAssertEqual(frame.status, 0, "\(name): \(frame.stderr)")
            XCTAssertFalse(frame.stdout.contains("decode"), frame.stdout)
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(folder.file("frame-\(name).png") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let centre = pixel(image, x: image.width / 2, y: image.height / 2)
            let corner = pixel(image, x: 20, y: 20)
            XCTAssertGreaterThan(centre[0], 220, "\(name): the disc is at the centre, \(centre)")
            XCTAssertLessThan(centre[2], 40, "\(name): \(centre)")
            XCTAssertGreaterThan(corner[2], 150, "\(name): the take shows around it, \(corner)")
        }
        let clip = try cli.tandem("clip", "0", "4", "-o", "exports/review.mp4", in: folder.url)
        XCTAssertEqual(clip.status, 0, clip.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.file("exports/review.mp4").path))

        let after = try cli.tandem("media", in: folder.url)
        XCTAssertEqual(after.status, 0, after.stderr)
        XCTAssertTrue(after.stdout.contains("stickers/disc-qtrle.mov  sticker"), after.stdout)
        XCTAssertTrue(after.stdout.contains("QuickTime Animation"), after.stdout)
        XCTAssertTrue(after.stdout.contains("converted ready"), after.stdout)
    }

    /// RGBA at (x, y), y down.
    func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return data.map(Int.init)
    }
}
