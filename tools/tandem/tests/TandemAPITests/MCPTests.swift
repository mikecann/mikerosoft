import XCTest
@testable import TandemAPI
@testable import TandemCore

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var array: [JSONValue]? {
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
        XCTAssertEqual(response["id"], .number(Double(id)))
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
        XCTAssertEqual(initialize["result"]?["protocolVersion"], .string("2025-11-25"))
        XCTAssertEqual(initialize["result"]?["serverInfo"]?["name"], .string("tandem"))
        XCTAssertNotNil(initialize["result"]?["capabilities"]?["tools"])
        XCTAssertNil(initialize["result"]?["resultType"], "legacy results stay as they were")
        mcp.send(#"{"jsonrpc": "2.0", "method": "notifications/initialized"}"#)

        let list = try await mcp.call(2, "tools/list")
        let tools = try XCTUnwrap(list["result"]?["tools"]?.array)
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, MCPTools.all.map(\.name))
        let apply = try XCTUnwrap(tools.first { $0["name"] == .string("apply") })
        XCTAssertEqual(apply["inputSchema"]?["required"], .array([.string("commands")]))
        XCTAssertNotNil(apply["inputSchema"]?["properties"]?["commands"]?["items"]?["oneOf"])
        XCTAssertEqual(apply["annotations"]?["readOnlyHint"], .bool(false))

        let status = try await mcp.tool(3, "status")
        XCTAssertEqual(status["result"]?["isError"], .bool(false))
        let text = try XCTUnwrap(status["result"]?["content"]?[0]?["text"]?.string)
        XCTAssertTrue(text.hasPrefix("Decision Models (Decision Models.tandem)"), text)

        let edit = try await mcp.tool(4, "apply", #"{"commands": [{"blade": {"at": "00:10.000"}}], "expectedRevision": 1}"#)
        let editText = try XCTUnwrap(edit["result"]?["content"]?[0]?["text"]?.string)
        XCTAssertTrue(editText.hasPrefix("Applied \"Cut at 00:10.000\" by claude as revision 2."), "credited to the client: \(editText)")

        let history = try await mcp.tool(5, "history", #"{"json": true}"#)
        let historyJSON = try XCTUnwrap(history["result"]?["content"]?[0]?["text"]?.string)
        let decoded = try ServiceJSON.decoder().decode(HistoryResult.self, from: Data(historyJSON.utf8))
        XCTAssertEqual(decoded.undo.first?.label, "Cut at 00:10.000")
        await mcp.close()
    }

    func testModernStatelessRequests() async throws {
        let mcp = try MCPHarness()
        let discover = try await mcp.call(1, "server/discover", #"{"_meta": \#(Self.modernMeta)}"#)
        XCTAssertEqual(discover["result"]?["resultType"], .string("complete"))
        XCTAssertEqual(discover["result"]?["supportedVersions"]?[0], .string("2026-07-28"))
        XCTAssertEqual(discover["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"], .string("tandem"))

        let list = try await mcp.call(2, "tools/list", #"{"_meta": \#(Self.modernMeta)}"#)
        XCTAssertEqual(list["result"]?["cacheScope"], .string("public"))
        XCTAssertNotNil(list["result"]?["ttlMs"])

        let edit = try await mcp.tool(3, "apply", #"{"commands": [{"blade": {"at": 10}}]}"#, meta: Self.modernMeta)
        XCTAssertEqual(edit["result"]?["resultType"], .string("complete"))
        let text = try XCTUnwrap(edit["result"]?["content"]?[0]?["text"]?.string)
        XCTAssertTrue(text.contains("by codex"), "the client info in _meta names the author: \(text)")

        let unsupported = try await mcp.call(4, "tools/list", #"{"_meta": {"io.modelcontextprotocol/protocolVersion": "2031-01-01", "io.modelcontextprotocol/clientCapabilities": {}}}"#)
        XCTAssertEqual(unsupported["error"]?["code"], .number(-32022))
        XCTAssertEqual(unsupported["error"]?["data"]?["requested"], .string("2031-01-01"))
        let missing = try await mcp.call(5, "tools/list", #"{"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}}"#)
        XCTAssertEqual(missing["error"]?["code"], .number(-32602))
        await mcp.close()
    }

    func testErrorsComeBackTheRightWay() async throws {
        let mcp = try MCPHarness(author: "tester")
        mcp.send("this isn't json")
        let parse = try await mcp.receive()
        XCTAssertEqual(parse["error"]?["code"], .number(-32700))

        let method = try await mcp.call(1, "resources/list")
        XCTAssertEqual(method["error"]?["code"], .number(-32601))

        let unknown = try await mcp.tool(2, "explode")
        XCTAssertEqual(unknown["error"]?["code"], .number(-32602))

        // A failed edit is a tool result the model can read and fix.
        let failed = try await mcp.tool(3, "apply", #"{"commands": [{"trim": {"clipID": "clip_cam1", "edge": "end", "to": 5, "rippel": true}}]}"#)
        XCTAssertEqual(failed["result"]?["isError"], .bool(true))
        let message = try XCTUnwrap(failed["result"]?["content"]?[0]?["text"]?.string)
        XCTAssertTrue(message.contains("did you mean \"ripple\""), message)

        let stale = try await mcp.tool(4, "apply", #"{"commands": [{"blade": {"at": 10}}], "expectedRevision": 99}"#)
        XCTAssertEqual(stale["result"]?["isError"], .bool(true))
        XCTAssertTrue(stale["result"]?["content"]?[0]?["text"]?.string?.contains("expected revision 99") ?? false)

        let elsewhere = try await mcp.tool(5, "status", #"{"project": "/nowhere/at/all.tandem"}"#)
        XCTAssertEqual(elsewhere["result"]?["isError"], .bool(true))
        await mcp.close()
    }

    func testFrameComesBackAsAnImage() async throws {
        let mcp = try MCPHarness()
        let frame = try await mcp.tool(1, "frame", #"{"time": 12}"#)
        let content = try XCTUnwrap(frame["result"]?["content"]?.array)
        XCTAssertEqual(content.first?["type"], .string("image"))
        XCTAssertEqual(content.first?["mimeType"], .string("image/png"))
        XCTAssertEqual(content.first?["data"], .string(FakeRenderer.png.base64EncodedString()))
        XCTAssertEqual(content.last?["type"], .string("text"))

        let effects = try await mcp.tool(2, "effects", #"{"type": "dropShadow"}"#)
        XCTAssertTrue(effects["result"]?["content"]?[0]?["text"]?.string?.contains("dropShadow") ?? false)
        await mcp.close()
    }

    func testCancelledRequestsGetNoAnswer() async throws {
        let mcp = try MCPHarness()
        mcp.send(#"{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "watch", "arguments": {"timeout": 20}}}"#)
        try await Task.sleep(nanoseconds: 200_000_000)
        mcp.send(#"{"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 1, "reason": "user"}}"#)
        let ping = try await mcp.call(2, "ping")
        XCTAssertEqual(ping["result"], .object([:]), "the next message is the ping's answer, not the cancelled watch")
        await mcp.close()
    }

    func testBatchesGetOneArrayOfAnswers() async throws {
        let mcp = try MCPHarness()
        mcp.send(#"[{"jsonrpc": "2.0", "id": 1, "method": "ping"}, {"jsonrpc": "2.0", "method": "notifications/initialized"}, {"jsonrpc": "2.0", "id": "b", "method": "tools/list"}]"#)
        let answers = try await mcp.receive()
        let items = try XCTUnwrap(answers.array)
        XCTAssertEqual(items.map { $0["id"] }, [.number(1), .string("b")], "one answer per request, none for the notification")
        XCTAssertNotNil(items[1]["result"]?["tools"])
        await mcp.close()
    }

    func testAuthorNames() {
        XCTAssertEqual(MCPServer.author(fromClient: "claude-code"), "claude")
        XCTAssertEqual(MCPServer.author(fromClient: "Codex CLI"), "codex")
        XCTAssertEqual(MCPServer.author(fromClient: "my-bot"), "my-bot")
    }
}
