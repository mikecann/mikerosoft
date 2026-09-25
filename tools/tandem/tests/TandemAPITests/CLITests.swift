import XCTest
@testable import TandemAPI
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
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = Self.environment(env)
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        var errorData = Data()
        let reader = Thread { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
        reader.start()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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
        XCTAssertTrue(timeline.stdout.contains("t1-camera.mov [00:00.000-01:00.000]  linked #1  level -14 LUFS"), timeline.stdout)

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
        serve.waitUntilExit()
        XCTAssertEqual(serve.terminationStatus, 0)
        let printed = String(decoding: serveOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(printed.contains("Serving \"Decision Models\""), printed)
        XCTAssertEqual(try ProjectFile.load(from: url).project.markers.map(\.id), ["mk_hook", "mk_s2"], "saved on the way out")
        XCTAssertNil(ProjectSession.liveLock(for: url))
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
        try mcp.run()
        defer { if mcp.isRunning { mcp.terminate() } }
        var lines = LineReader.lines(output.fileHandleForReading).makeAsyncIterator()
        func send(_ text: String) { input.fileHandleForWriting.write(Data((text + "\n").utf8)) }
        func next() async throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: Data((await lines.next() ?? "").utf8))
        }

        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}"#)
        let initialize = try await next()
        XCTAssertEqual(initialize["result"]?["protocolVersion"], .string("2025-06-18"))
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"timeline","arguments":{"from":20,"to":25}}}"#)
        let timeline = try await next()
        let text = timeline["result"]?["content"]?[0]?["text"]?.string ?? ""
        XCTAssertTrue(text.contains("clip_brl1  00:20.000-00:25.000"), text)
        send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"apply","arguments":{"commands":[{"blade":{"at":22}}]}}}"#)
        let apply = try await next()
        XCTAssertTrue(apply["result"]?["content"]?[0]?["text"]?.string?.contains("by claude as revision 2") ?? false, "\(apply)")

        try input.fileHandleForWriting.close()
        mcp.waitUntilExit()
        XCTAssertEqual(mcp.terminationStatus, 0, "exits when stdin closes")
    }
}
