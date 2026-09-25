import XCTest
@testable import TandemAPI
@testable import TandemCore

// Test-only helpers for digging into JSON, with labels so they can't clash
// with anything TandemCore adds to JSONValue.
extension JSONValue {
    subscript(json key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    subscript(json index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    var testString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var testArray: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }
}

/// An MCP server in this process, talking over pipes.
final class MCPHarness {
    let folder = TempFolder()
    let projectURL: URL
    let input = Pipe()
    let output = Pipe()
    let server: MCPServer
    private var lines: AsyncStream<String>.AsyncIterator
    private var runTask: Task<Void, Never>!

    init(author: String? = nil) throws {
        projectURL = try APIFixture.write(to: folder.url)
        server = MCPServer(
            options: MCPServer.Options(directory: folder.url, author: author, environment: [:]),
            output: output.fileHandleForWriting
        )
        server.makeClient = { url, author in
            let client = ProjectClient(projectURL: url, author: author)
            client.analysis = FakeAnalysis()
            client.renderer = FakeRenderer()
            return client
        }
        lines = LineReader.lines(output.fileHandleForReading).makeAsyncIterator()
        let server = self.server
        let reader = input.fileHandleForReading
        runTask = Task { await server.run(input: reader) }
    }

    func send(_ message: String) {
        input.fileHandleForWriting.write(Data((message + "\n").utf8))
    }

    func receive() async throws -> JSONValue {
        guard let line = await lines.next() else { throw ServiceError(.unavailable, "the server closed its output") }
        XCTAssertFalse(line.contains("\n"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    /// Sends a request and waits for its response.
    func call(_ id: Int, _ method: String, _ params: String = "{}") async throws -> JSONValue {
        send(#"{"jsonrpc": "2.0", "id": \#(id), "method": "\#(method)", "params": \#(params)}"#)
        let response = try await receive()
        XCTAssertEqual(response[json: "id"], .number(Double(id)))
        return response
    }

    func tool(_ id: Int, _ name: String, _ arguments: String = "{}", meta: String? = nil) async throws -> JSONValue {
        let metaField = meta.map { #", "_meta": \#($0)"# } ?? ""
        return try await call(id, "tools/call", #"{"name": "\#(name)", "arguments": \#(arguments)\#(metaField)}"#)
    }

    func close() async {
        try? input.fileHandleForWriting.close()
        await runTask.value
    }
}

final class MCPTests: XCTestCase {
    static let modernMeta = #"{"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}, "io.modelcontextprotocol/clientInfo": {"name": "codex-cli", "version": "1"}}"#

    func testLegacyHandshakeListAndCall() async throws {
        let mcp = try MCPHarness()
        let initialize = try await mcp.call(1, "initialize", #"{"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "claude-code", "version": "2.1"}}"#)
        XCTAssertEqual(initialize[json: "result"]?[json: "protocolVersion"], .string("2025-11-25"))
        XCTAssertEqual(initialize[json: "result"]?[json: "serverInfo"]?[json: "name"], .string("tandem"))
        XCTAssertNotNil(initialize[json: "result"]?[json: "capabilities"]?[json: "tools"])
        XCTAssertNil(initialize[json: "result"]?[json: "resultType"], "legacy results stay as they were")
        mcp.send(#"{"jsonrpc": "2.0", "method": "notifications/initialized"}"#)

        let list = try await mcp.call(2, "tools/list")
        let tools = try XCTUnwrap(list[json: "result"]?[json: "tools"]?.testArray)
        XCTAssertEqual(tools.compactMap { $0[json: "name"]?.testString }, MCPTools.all.map(\.name))
        let apply = try XCTUnwrap(tools.first { $0[json: "name"] == .string("apply") })
        XCTAssertEqual(apply[json: "inputSchema"]?[json: "required"], .array([.string("commands")]))
        XCTAssertNotNil(apply[json: "inputSchema"]?[json: "properties"]?[json: "commands"]?[json: "items"]?[json: "oneOf"])
        XCTAssertEqual(apply[json: "annotations"]?[json: "readOnlyHint"], .bool(false))

        let status = try await mcp.tool(3, "status")
        XCTAssertEqual(status[json: "result"]?[json: "isError"], .bool(false))
        let text = try XCTUnwrap(status[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString)
        XCTAssertTrue(text.hasPrefix("Decision Models (Decision Models.tandem)"), text)

        let edit = try await mcp.tool(4, "apply", #"{"commands": [{"blade": {"at": "00:10.000"}}], "expectedRevision": 1}"#)
        let editText = try XCTUnwrap(edit[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString)
        XCTAssertTrue(editText.hasPrefix("Applied \"Cut at 00:10.000\" by claude as revision 2."), "credited to the client: \(editText)")

        let history = try await mcp.tool(5, "history", #"{"json": true}"#)
        let historyJSON = try XCTUnwrap(history[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString)
        let decoded = try ServiceJSON.decoder().decode(HistoryResult.self, from: Data(historyJSON.utf8))
        XCTAssertEqual(decoded.undo.first?.label, "Cut at 00:10.000")
        await mcp.close()
    }

    func testModernStatelessRequests() async throws {
        let mcp = try MCPHarness()
        let discover = try await mcp.call(1, "server/discover", #"{"_meta": \#(Self.modernMeta)}"#)
        XCTAssertEqual(discover[json: "result"]?[json: "resultType"], .string("complete"))
        XCTAssertEqual(discover[json: "result"]?[json: "supportedVersions"]?[json: 0], .string("2026-07-28"))
        XCTAssertEqual(discover[json: "result"]?[json: "_meta"]?[json: "io.modelcontextprotocol/serverInfo"]?[json: "name"], .string("tandem"))

        let list = try await mcp.call(2, "tools/list", #"{"_meta": \#(Self.modernMeta)}"#)
        XCTAssertEqual(list[json: "result"]?[json: "cacheScope"], .string("public"))
        XCTAssertNotNil(list[json: "result"]?[json: "ttlMs"])

        let edit = try await mcp.tool(3, "apply", #"{"commands": [{"blade": {"at": 10}}]}"#, meta: Self.modernMeta)
        XCTAssertEqual(edit[json: "result"]?[json: "resultType"], .string("complete"))
        let text = try XCTUnwrap(edit[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString)
        XCTAssertTrue(text.contains("by codex"), "the client info in _meta names the author: \(text)")

        let unsupported = try await mcp.call(4, "tools/list", #"{"_meta": {"io.modelcontextprotocol/protocolVersion": "2031-01-01", "io.modelcontextprotocol/clientCapabilities": {}}}"#)
        XCTAssertEqual(unsupported[json: "error"]?[json: "code"], .number(-32022))
        XCTAssertEqual(unsupported[json: "error"]?[json: "data"]?[json: "requested"], .string("2031-01-01"))
        let missing = try await mcp.call(5, "tools/list", #"{"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}}"#)
        XCTAssertEqual(missing[json: "error"]?[json: "code"], .number(-32602))
        await mcp.close()
    }

    func testErrorsComeBackTheRightWay() async throws {
        let mcp = try MCPHarness(author: "tester")
        mcp.send("this isn't json")
        let parse = try await mcp.receive()
        XCTAssertEqual(parse[json: "error"]?[json: "code"], .number(-32700))

        let method = try await mcp.call(1, "resources/list")
        XCTAssertEqual(method[json: "error"]?[json: "code"], .number(-32601))

        let unknown = try await mcp.tool(2, "explode")
        XCTAssertEqual(unknown[json: "error"]?[json: "code"], .number(-32602))

        // A failed edit is a tool result the model can read and fix.
        let failed = try await mcp.tool(3, "apply", #"{"commands": [{"trim": {"clipID": "clip_cam1", "edge": "end", "to": 5, "rippel": true}}]}"#)
        XCTAssertEqual(failed[json: "result"]?[json: "isError"], .bool(true))
        let message = try XCTUnwrap(failed[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString)
        XCTAssertTrue(message.contains("did you mean \"ripple\""), message)

        let stale = try await mcp.tool(4, "apply", #"{"commands": [{"blade": {"at": 10}}], "expectedRevision": 99}"#)
        XCTAssertEqual(stale[json: "result"]?[json: "isError"], .bool(true))
        XCTAssertTrue(stale[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString?.contains("expected revision 99") ?? false)

        let elsewhere = try await mcp.tool(5, "status", #"{"project": "/nowhere/at/all.tandem"}"#)
        XCTAssertEqual(elsewhere[json: "result"]?[json: "isError"], .bool(true))
        await mcp.close()
    }

    func testFrameComesBackAsAnImage() async throws {
        let mcp = try MCPHarness()
        let frame = try await mcp.tool(1, "frame", #"{"time": 12}"#)
        let content = try XCTUnwrap(frame[json: "result"]?[json: "content"]?.testArray)
        XCTAssertEqual(content.first?[json: "type"], .string("image"))
        XCTAssertEqual(content.first?[json: "mimeType"], .string("image/png"))
        XCTAssertEqual(content.first?[json: "data"], .string(FakeRenderer.png.base64EncodedString()))
        XCTAssertEqual(content.last?[json: "type"], .string("text"))

        let effects = try await mcp.tool(2, "effects", #"{"type": "dropShadow"}"#)
        XCTAssertTrue(effects[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString?.contains("dropShadow") ?? false)
        await mcp.close()
    }

    func testCancelledRequestsGetNoAnswer() async throws {
        let mcp = try MCPHarness()
        mcp.send(#"{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "watch", "arguments": {"timeout": 20}}}"#)
        try await Task.sleep(nanoseconds: 200_000_000)
        mcp.send(#"{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 1, "reason": "user"}}"#)
        let ping = try await mcp.call(2, "ping")
        XCTAssertEqual(ping[json: "result"], .object([:]), "the next message is the ping's answer, not the cancelled watch")
        await mcp.close()
    }

    func testBatchesGetOneArrayOfAnswers() async throws {
        let mcp = try MCPHarness()
        mcp.send(#"[{"jsonrpc": "2.0", "id": 1, "method": "ping"}, {"jsonrpc": "2.0", "method": "notifications/initialized"}, {"jsonrpc": "2.0", "id": "b", "method": "tools/list"}]"#)
        let answers = try await mcp.receive()
        let items = try XCTUnwrap(answers.testArray)
        XCTAssertEqual(items.map { $0[json: "id"] }, [.number(1), .string("b")], "one answer per request, none for the notification")
        XCTAssertNotNil(items[1][json: "result"]?[json: "tools"])
        await mcp.close()
    }

    func testAssetTools() async throws {
        let mcp = try MCPHarness()
        let assets = try await AssetHarness()
        mcp.server.assetService = assets.service
        let whoosh = try assets.whoosh()

        let list = try await mcp.call(1, "tools/list")
        let tools = try XCTUnwrap(list[json: "result"]?[json: "tools"]?.testArray)
        func tool(_ name: String) -> JSONValue? { tools.first { $0[json: "name"] == .string(name) } }
        for name in ["assets_search", "assets_use", "assets_credits", "assets_generate", "assets_providers"] {
            XCTAssertNotNil(tool(name), name)
        }
        XCTAssertNil(tool("assets_search")?[json: "inputSchema"]?[json: "properties"]?[json: "project"], "searching needs no project")
        XCTAssertNotNil(tool("assets_use")?[json: "inputSchema"]?[json: "properties"]?[json: "project"])
        XCTAssertEqual(tool("assets_generate")?[json: "annotations"]?[json: "openWorldHint"], .bool(true))

        let found = try await mcp.tool(2, "assets_search", #"{"text": "whoosh", "kind": "sfx"}"#)
        XCTAssertTrue(found[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString?.contains(whoosh.id) ?? false, "\(found)")

        let used = try await mcp.tool(3, "assets_use", #"{"id": "\#(whoosh.id)", "at": "0:02"}"#)
        let usedText = try XCTUnwrap(used[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString)
        XCTAssertTrue(usedText.hasPrefix("Placed Whoosh 01 (sfx) at 00:02.000 on SFX at -15 dB as revision 2."), usedText)
        XCTAssertEqual(try ProjectFile.load(from: mcp.projectURL).project.track(named: "SFX")?.clips.count, 1)

        let credits = try await mcp.tool(4, "assets_credits")
        XCTAssertTrue(credits[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString?.hasPrefix("Nothing in this project needs a credit.") ?? false, "\(credits)")

        let generate = try await mcp.tool(5, "assets_generate", #"{"kind": "sfx", "prompt": "soft whoosh"}"#)
        XCTAssertEqual(generate[json: "result"]?[json: "isError"], .bool(true), "no ElevenLabs key here")
        XCTAssertTrue(generate[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString?.contains("ElevenLabs is unavailable") ?? false, "\(generate)")
        await mcp.close()
    }

    func testAuthorNames() {
        XCTAssertEqual(MCPServer.author(fromClient: "claude-code"), "claude")
        XCTAssertEqual(MCPServer.author(fromClient: "Codex CLI"), "codex")
        XCTAssertEqual(MCPServer.author(fromClient: "my-bot"), "my-bot")
    }
}
