import Foundation
import TandemCore

/// `tandem mcp`: the service as MCP tools over stdio (newline-delimited
/// JSON-RPC 2.0).
///
/// It speaks both eras of MCP. Clients on 2025-11-25 and earlier open with
/// `initialize` and `notifications/initialized`; clients on 2026-07-28 send
/// the protocol version, capabilities and client info in each request's
/// `_meta` (and may probe with `server/discover`). Every tool call goes
/// through `ProjectClient`, so it reaches the app when the app has the
/// project open and opens the file directly otherwise.
public final class MCPServer: @unchecked Sendable {
    public static let modernVersions = ["2026-07-28"]
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var supportedVersions: [String] { modernVersions + legacyVersions }

    public struct Options: Sendable {
        /// `--project`: the project to use when a call doesn't name one.
        public var project: String?
        /// Where to look for a project when none is named.
        public var directory: URL
        /// `--author` or `$TANDEM_AUTHOR`. Otherwise edits are credited to
        /// the client's name (claude, codex...).
        public var author: String?
        public var environment: [String: String]

        public init(project: String? = nil, directory: URL, author: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
            self.project = project
            self.directory = directory
            self.author = author
            self.environment = environment
        }
    }

    public let options: Options
    /// Makes the client for a project; tests swap in fakes.
    var makeClient: (URL, String) -> ProjectClient = { ProjectClient(projectURL: $0, author: $1) }

    private let output: FileHandle
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var legacyClientName: String?
    private var assets: AssetService?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var cancelled: Set<String> = []

    public init(options: Options, output: FileHandle = .standardOutput) {
        self.options = options
        self.output = output
    }

    /// Reads requests from `input` until it closes.
    public func run(input: FileHandle = .standardInput) async {
        for await line in LineReader.lines(input) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            receive(trimmed)
        }
        await drain()
    }

    /// Handles one message. Requests run concurrently; responses are
    /// written as each finishes.
    func receive(_ line: String) {
        guard let data = line.data(using: .utf8), let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            write(Self.error(id: .null, code: -32700, message: "Parse error: each line must be one JSON-RPC message."))
            return
        }
        if case .array(let messages) = message {
            batch(messages)
            return
        }
        guard case .object(let fields) = message else {
            write(Self.error(id: .null, code: -32600, message: "Invalid request: expected a JSON-RPC object."))
            return
        }
        guard case .string(let method)? = fields["method"] else {
            // A response or something else we never asked for.
            return
        }
        let params = fields["params"] ?? .object([:])
        guard let id = fields["id"], id != .null else {
            notification(method, params)
            return
        }
        let key = Self.key(id)
        // Registered under the lock so a quick call can't finish (and
        // unregister) before it's registered.
        stateLock.withLock {
            tasks[key] = Task { [weak self] in
                guard let self else { return }
                let response = await self.request(method, params: params, id: id)
                let dropped = self.stateLock.withLock { () -> Bool in
                    self.tasks.removeValue(forKey: key)
                    return self.cancelled.remove(key) != nil
                }
                if !dropped { self.write(response) }
            }
        }
    }

    /// A JSON-RPC batch (allowed by the 2025-03-26 revision): the requests
    /// run together and their responses go back as one array.
    private func batch(_ messages: [JSONValue]) {
        guard !messages.isEmpty else {
            write(Self.error(id: .null, code: -32600, message: "Invalid request: empty batch."))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let responses = await withTaskGroup(of: (Int, JSONValue?).self) { group in
                for (index, message) in messages.enumerated() {
                    group.addTask {
                        guard case .object(let fields) = message, case .string(let method)? = fields["method"] else {
                            return (index, Self.error(id: .null, code: -32600, message: "Invalid request."))
                        }
                        let params = fields["params"] ?? .object([:])
                        guard let id = fields["id"], id != .null else {
                            self.notification(method, params)
                            return (index, nil)
                        }
                        return (index, await self.request(method, params: params, id: id))
                    }
                }
                var collected: [(Int, JSONValue)] = []
                for await (index, response) in group {
                    if let response { collected.append((index, response)) }
                }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            if !responses.isEmpty { self.write(.array(responses)) }
        }
    }

    private func notification(_ method: String, _ params: JSONValue) {
        switch method {
        case "notifications/cancelled":
            guard case .object(let fields) = params, let id = fields["requestId"] else { return }
            let key = Self.key(id)
            stateLock.lock()
            let task = tasks[key]
            if task != nil { cancelled.insert(key) }
            stateLock.unlock()
            task?.cancel()
        default:
            // notifications/initialized and anything else need no answer.
            break
        }
    }

    /// Waits for running calls when input ends, cancelling slow ones.
    private func drain() async {
        let running = stateLock.withLock { Array(tasks.values) }
        let deadline = Date().addingTimeInterval(5)
        for task in running {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { task.cancel(); continue }
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                task.cancel()
            }
            await task.value
            timer.cancel()
        }
    }

    // MARK: - Requests

    func request(_ method: String, params: JSONValue, id: JSONValue) async -> JSONValue {
        let meta = Self.meta(params)
        var modern = false
        if case .string(let version)? = meta["io.modelcontextprotocol/protocolVersion"] {
            if Self.modernVersions.contains(version) {
                modern = true
                guard meta["io.modelcontextprotocol/clientCapabilities"] != nil else {
                    return Self.error(id: id, code: -32602, message: "Missing _meta[\"io.modelcontextprotocol/clientCapabilities\"].")
                }
            } else if !Self.legacyVersions.contains(version) {
                return Self.error(id: id, code: -32022, message: "Unsupported protocol version", data: .object([
                    "supported": .array(Self.supportedVersions.map(JSONValue.string)),
                    "requested": .string(version)
                ]))
            }
        }
        let clientName = Self.clientName(meta["io.modelcontextprotocol/clientInfo"]) ?? stateLocked { legacyClientName }

        var result: JSONValue
        switch method {
        case "initialize":
            return Self.response(id: id, result: initialize(params))
        case "ping":
            result = .object([:])
        case "server/discover":
            result = discover()
        case "tools/list":
            var fields: [String: JSONValue] = ["tools": .array(MCPTools.all.map(\.definition))]
            if modern {
                fields["ttlMs"] = .number(3_600_000)
                fields["cacheScope"] = .string("public")
            }
            result = .object(fields)
        case "tools/call":
            do {
                result = try await callTool(params, clientName: clientName)
            } catch let error as MCPProtocolError {
                return Self.error(id: id, code: error.code, message: error.message)
            } catch {
                return Self.error(id: id, code: -32603, message: error.localizedDescription)
            }
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
        if modern, case .object(var fields) = result {
            fields["resultType"] = .string("complete")
            var resultMeta: [String: JSONValue] = [:]
            if case .object(let existing)? = fields["_meta"] { resultMeta = existing }
            resultMeta["io.modelcontextprotocol/serverInfo"] = Self.serverInfo
            fields["_meta"] = .object(resultMeta)
            result = .object(fields)
        }
        return Self.response(id: id, result: result)
    }

    private func initialize(_ params: JSONValue) -> JSONValue {
        var requested: String?
        if case .object(let fields) = params {
            if case .string(let version)? = fields["protocolVersion"] { requested = version }
            if let name = Self.clientName(fields["clientInfo"]) {
                stateLocked { legacyClientName = name }
            }
        }
        let version = requested.flatMap { Self.legacyVersions.contains($0) ? $0 : nil } ?? Self.legacyVersions[0]
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": Self.serverInfo,
            "instructions": .string(Self.instructions)
        ])
    }

    private func discover() -> JSONValue {
        .object([
            "supportedVersions": .array(Self.supportedVersions.map(JSONValue.string)),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "instructions": .string(Self.instructions),
            "ttlMs": .number(3_600_000),
            "cacheScope": .string("public")
        ])
    }

    static let serverInfo: JSONValue = .object([
        "name": .string("tandem"),
        "title": .string("Tandem video editor"),
        "version": .string(TandemAPI.version)
    ])

    static let instructions = """
    Tandem is Mike's video editor. These tools read and edit a .tandem project: the app's copy when the app has it open, otherwise the file. \
    Start with `timeline` (add words: true to see what's said in each voice clip). Change things with `apply`, a batch of edit commands applied \
    atomically as one undo step credited to you; pass expectedRevision from your last read so you never edit a timeline that changed under you, \
    and try dryRun: true when unsure. `undo` reverts your last edit. `search` finds a phrase's timeline time, `pauses` lists silences and \
    `tighten` shortens them (a dry run unless apply: true). `frame` shows a moment, `clip` renders a review MP4. Mike's saved segments (his intro, \
    outro and calls to action) are in `segments_list` and go in with `segments_insert`. Times are seconds or mm:ss.mmm. \
    Pass `project` (a .tandem path) when the server wasn't started in the video's folder.
    """

    private func callTool(_ params: JSONValue, clientName: String?) async throws -> JSONValue {
        guard case .object(let fields) = params, case .string(let name)? = fields["name"] else {
            throw MCPProtocolError(code: -32602, message: "tools/call needs a tool name.")
        }
        guard let tool = MCPTools.named(name) else {
            throw MCPProtocolError(code: -32602, message: "Unknown tool: \(name)")
        }
        var arguments: [String: JSONValue] = [:]
        if case .object(let given)? = fields["arguments"] { arguments = given }
        let asJSON = arguments["json"] == .bool(true)
        var projectPath: String?
        if case .string(let path)? = arguments["project"] { projectPath = path }
        arguments.removeValue(forKey: "project")
        arguments.removeValue(forKey: "json")
        let author = options.author ?? options.environment["TANDEM_AUTHOR"] ?? clientName.map(Self.author(fromClient:)) ?? "agent"
        do {
            let body = try JSONEncoder().encode(JSONValue.object(tool.defaults.merging(arguments) { _, given in given }))
            let content: [JSONValue]
            if let asset = tool.asset {
                content = try await runAsset(asset, body: body, projectPath: projectPath, author: author, asJSON: asJSON)
            } else if let operation = tool.operation {
                content = try await run(operation, body: body, projectPath: projectPath, author: author, asJSON: asJSON)
            } else {
                throw MCPProtocolError(code: -32603, message: "Tool \(name) has nothing to run.")
            }
            return .object(["content": .array(content), "isError": .bool(false)])
        } catch let error as MCPProtocolError {
            throw error
        } catch {
            let message = ServiceError.wrap(error).message
            return .object(["content": .array([.object(["type": .string("text"), "text": .string(message)])]), "isError": .bool(true)])
        }
    }

    /// The asset library, opened on first use: the per-user one, or
    /// `$TANDEM_ASSETS_ROOT`. Tests set it.
    var assetService: AssetService? {
        get { stateLock.withLock { assets } }
        set { stateLock.withLock { assets = newValue } }
    }

    private func openAssets() throws -> AssetService {
        try stateLock.withLock {
            if let assets { return assets }
            let opened = try AssetService.standard(environment: options.environment)
            assets = opened
            return opened
        }
    }

    private func runAsset(_ operation: AssetOperation, body: Data, projectPath: String?, author: String, asJSON: Bool) async throws -> [JSONValue] {
        let assets = try openAssets()
        let result = try await assets.handle(operation, body: body) {
            let url = try ProjectLocator.find(projectPath ?? self.options.project, in: self.options.directory, environment: self.options.environment)
            return self.makeClient(url, author)
        }
        let text = asJSON ? String(decoding: try ServiceJSON.encoder(pretty: true).encode(result), as: UTF8.self) : result.readableText
        return [.object(["type": .string("text"), "text": .string(text)])]
    }

    private func run(_ operation: ServiceOperation, body: Data, projectPath: String?, author: String, asJSON: Bool) async throws -> [JSONValue] {
        try await run(operation.callType, body: body, projectPath: projectPath, author: author, asJSON: asJSON)
    }

    private func run<C: ServiceCall>(_ type: C.Type, body: Data, projectPath: String?, author: String, asJSON: Bool) async throws -> [JSONValue] {
        let call = try ServiceJSON.decodeRequest(C.self, from: body)
        let result: C.Result
        if let effects = call as? EffectsRequest {
            // The catalogue doesn't need a project.
            result = try EffectsResult.catalog(type: effects.type) as! C.Result
        } else {
            let url = try ProjectLocator.find(projectPath ?? options.project, in: options.directory, environment: options.environment)
            result = try await makeClient(url, author).call(call)
        }
        var content: [JSONValue] = []
        if let image = result as? ImageResult, let png = image.png {
            content.append(.object(["type": .string("image"), "data": .string(png), "mimeType": .string("image/png")]))
        }
        let text: String
        if asJSON, var image = result as? ImageResult, image.png != nil {
            // The picture is already the image content; don't send it twice.
            image.png = nil
            text = String(decoding: try ServiceJSON.encoder(pretty: true).encode(image), as: UTF8.self)
        } else if asJSON {
            text = String(decoding: try ServiceJSON.encoder(pretty: true).encode(result), as: UTF8.self)
        } else {
            text = result.readableText
        }
        content.append(.object(["type": .string("text"), "text": .string(text)]))
        return content
    }

    // MARK: - Helpers

    /// A short author name from the client's name: "claude-code" is
    /// credited as "claude".
    static func author(fromClient name: String) -> String {
        let lower = name.lowercased()
        for known in ["claude", "codex", "cursor", "gemini"] where lower.contains(known) { return known }
        return name
    }

    static func clientName(_ info: JSONValue?) -> String? {
        guard case .object(let fields)? = info, case .string(let name)? = fields["name"], !name.isEmpty else { return nil }
        return name
    }

    static func meta(_ params: JSONValue) -> [String: JSONValue] {
        guard case .object(let fields) = params, case .object(let meta)? = fields["_meta"] else { return [:] }
        return meta
    }

    static func key(_ id: JSONValue) -> String {
        switch id {
        case .string(let s): return "s:\(s)"
        case .number(let n): return "n:\(n)"
        default: return "other"
        }
    }

    static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    static func error(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var error: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { error["data"] = data }
        return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(error)])
    }

    private func stateLocked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    func write(_ message: JSONValue) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(message) else { return }
        data.append(0x0A)
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try output.write(contentsOf: data)
        } catch {
            log("couldn't write a response: \(error.localizedDescription)")
        }
    }

    private func log(_ text: String) {
        FileHandle.standardError.write(Data("tandem mcp: \(text)\n".utf8))
    }
}

struct MCPProtocolError: Error {
    var code: Int
    var message: String
}

/// The MCP tool list: one tool per service operation.
enum MCPTools {
    struct Tool {
        var name: String
        var title: String
        var description: String
        /// A project operation, run through `ProjectClient`...
        var operation: ServiceOperation?
        /// ...or an asset library operation.
        var asset: AssetOperation? = nil
        var properties: [String: JSONValue]
        var required: [String] = []
        var readOnly: Bool
        var idempotent = false
        /// Reaches outside the Mac (asset providers).
        var openWorld = false
        /// Arguments filled in when the caller leaves them out.
        var defaults: [String: JSONValue] = [:]

        /// Asset tools other than use and credits don't touch a project.
        var usesProject: Bool {
            asset.map { $0.callType.needsProject } ?? true
        }

        var definition: JSONValue {
            var properties = self.properties
            if usesProject {
                properties["project"] = S.string("Path to the .tandem file (or its folder). Defaults to the one the server was started with, or the one in its folder.")
            }
            properties["json"] = S.boolean("Return the raw JSON result instead of readable text.")
            var schema: [String: JSONValue] = [
                "type": .string("object"),
                "properties": .object(properties),
                "additionalProperties": .bool(false)
            ]
            if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
            // The edit command schemas share model definitions by reference.
            if operation == .apply { schema["$defs"] = .object(CommandSchema.definitions) }
            return .object([
                "name": .string(name),
                "title": .string(title),
                "description": .string(description),
                "inputSchema": .object(schema),
                "annotations": .object([
                    "title": .string(title),
                    "readOnlyHint": .bool(readOnly),
                    "destructiveHint": .bool(false),
                    "idempotentHint": .bool(idempotent),
                    "openWorldHint": .bool(openWorld)
                ])
            ])
        }
    }

    static func named(_ name: String) -> Tool? {
        all.first { $0.name == name }
    }

    static func time(_ description: String) -> JSONValue {
        .object(["type": .array([.string("number"), .string("string")]), "description": .string(description + " Seconds or mm:ss.mmm.")])
    }

    static var applyProperties: [String: JSONValue] {
        CommandSchema.batchProperties
    }

    static let all: [Tool] = [
        Tool(
            name: "status", title: "Project status",
            description: "The project's name, revision, length, unsaved changes, who has it open, undo and redo, and background jobs.",
            operation: .status, properties: [:], readOnly: true, idempotent: true
        ),
        Tool(
            name: "timeline", title: "Read the timeline",
            description: "The edit as compact text: tracks top to bottom as the app shows them, one line per clip with its ID, timeline range, media and source range, link group and settings, plus transitions, gaps and markers. On a long project start with summary: true (one line per track), then read a part with from/to. words: true shows what's said in each voice clip; format: json gives the project JSON.",
            operation: .timeline,
            properties: [
                "from": time("Only clips overlapping from this time."),
                "to": time("Only clips overlapping up to this time."),
                "words": S.boolean("Show the words each voice clip plays."),
                "summary": S.boolean("Just one line per track and the markers."),
                "format": S.enumeration(["text", "json"], "text (default) or json.")
            ],
            readOnly: true, idempotent: true
        ),
        Tool(
            name: "media", title: "List media",
            description: "Media files in the project with their role, length, how many clips use them and analysis status (transcript, loudness, proxy, cutout matte). refresh: true scans the project folder for new files first.",
            operation: .media, properties: ["refresh": S.boolean("Scan the folder for new files first.")], readOnly: false
        ),
        Tool(
            name: "transcript", title: "Read a transcript",
            description: "Word timings. With a clip ID the words that clip plays in timeline time; with a media ID the whole file in file time; with no ID everything said on the timeline.",
            operation: .transcript,
            properties: ["id": S.string("A clip ID or media ID. Leave out for the whole timeline."), "from": time("Start of the range."), "to": time("End of the range.")],
            readOnly: true, idempotent: true
        ),
        Tool(
            name: "search", title: "Find a phrase",
            description: "Finds where a phrase is said, as timeline ranges with the clips that play it (ignoring case and punctuation). Also lists matches in material that isn't on the timeline.",
            operation: .search,
            properties: ["phrase": S.string("Words to find."), "limit": S.integer("At most this many hits.")],
            required: ["phrase"], readOnly: true, idempotent: true
        ),
        Tool(
            name: "pauses", title: "List pauses",
            description: "Silences between words on the voice tracks, in timeline time, with the words either side.",
            operation: .pauses,
            properties: ["min": time("Shortest pause to list. Default 0.6 s."), "from": time("Start of the range."), "to": time("End of the range.")],
            readOnly: true, idempotent: true
        ),
        Tool(
            name: "tighten", title: "Tighten pauses",
            description: "Shortens every pause longer than min down to keep, with frame-aligned ripple deletes that cut the whole take and let B-roll, music and titles follow. A dry run that returns the plan and the commands unless apply: true.",
            operation: .tighten,
            properties: [
                "min": time("Pauses at least this long get shortened. Default 0.6 s."),
                "keep": time("How much of each pause to keep. Default 0.15 s."),
                "apply": S.boolean("Make the cut. Without it nothing changes."),
                "from": time("Only pauses after this time."), "to": time("Only pauses before this time."),
                "label": S.string("Undo label."), "author": S.string("Who made the edit."),
                "expectedRevision": S.integer("Refuse unless the project is at this revision.")
            ],
            readOnly: false
        ),
        Tool(
            name: "captions", title: "Add word captions",
            description: "Adds word-by-word captions from the transcripts (a few words at a time, the spoken word highlighted, Mike's shorts style) on a Captions track. A dry run that returns the plan and the commands unless apply: true.",
            operation: .captions,
            properties: [
                "from": time("Only speech after this time."), "to": time("Only speech before this time."),
                "words": S.integer("Most words on screen at once. Default 3."),
                "y": S.number("Height on screen, 0 top to 1 bottom. Default 0.42, between screen and camera in a short."),
                "track": S.string("Video track to use, made if missing. Default Captions."),
                "apply": S.boolean("Add them. Without it nothing changes."),
                "label": S.string("Undo label."), "author": S.string("Who made the edit."),
                "expectedRevision": S.integer("Refuse unless the project is at this revision.")
            ],
            readOnly: false
        ),
        Tool(
            name: "short", title: "Lay out a 9:16 short",
            description: "Adds the portrait output format and places every video clip in it the way Mike's shorts look: screen, B-roll and graphics in the top half, the camera in the bottom half with its background, full-frame camera moments filling the frame. The landscape edit is untouched. A dry run unless apply: true. Then export with the short preset.",
            operation: .short,
            properties: [
                "apply": S.boolean("Lay it out. Without it nothing changes."),
                "label": S.string("Undo label."), "author": S.string("Who made the edit."),
                "expectedRevision": S.integer("Refuse unless the project is at this revision.")
            ],
            readOnly: false
        ),
        Tool(
            name: "cards", title: "Add section cards",
            description: "Puts a numbered section card at every section marker after the start (or at markers): Convex's bands wipe in, the card holds the number, the marker's name as the title, its note as the subtitle and progress bars for the count, and the bands wipe out, with a whoosh on each sweep from the asset library. A card already at a marker is renumbered and keeps its words. A dry run that returns the plan and the commands unless apply: true.",
            operation: .cards,
            properties: [
                "markers": S.ids("Marker IDs to put cards at. Default: every section marker after 0:00."),
                "kicker": S.string("Words beside the number, like Section or Tip, shown as SECTION 1 OF 3."),
                "duration": time("Card length. Default 3.2 s; the wipes keep their length."),
                "track": S.string("Video track ID for the cards. Default Graphics."),
                "insert": S.boolean("Make room at each marker so the card is a pause and its wipes show the shots either side (the whole take moves)."),
                "sounds": S.boolean("A whoosh on each sweep, from the asset library. Default true."),
                "apply": S.boolean("Add them. Without it nothing changes."),
                "label": S.string("Undo label."), "author": S.string("Who made the edit."),
                "expectedRevision": S.integer("Refuse unless the project is at this revision.")
            ],
            readOnly: false
        ),
        Tool(
            name: "apply", title: "Edit the project",
            description: "Applies a batch of edit commands atomically as one undo step. If any command fails nothing changes and the error says which one and why. Returns the new revision, created IDs and warnings. See the command list in the schema; times are seconds.",
            operation: .apply, properties: applyProperties, required: ["commands"], readOnly: false
        ),
        Tool(
            name: "undo", title: "Undo",
            description: "Undoes the last edit. Pass expectedRevision so you only undo your own edit if nothing changed since.",
            operation: .undo, properties: ["expectedRevision": S.integer("Refuse unless the project is at this revision.")], readOnly: false
        ),
        Tool(
            name: "redo", title: "Redo",
            description: "Redoes the last undone edit.",
            operation: .redo, properties: ["expectedRevision": S.integer("Refuse unless the project is at this revision.")], readOnly: false
        ),
        Tool(
            name: "history", title: "Edit history",
            description: "What undo would undo (newest first, with who made each edit) and recent changes.",
            operation: .history, properties: ["limit": S.integer("How many entries. Default 20.")], readOnly: true, idempotent: true
        ),
        Tool(
            name: "validate", title: "Check the project",
            description: "Checks the project for problems: overlaps, clips past the end of their media, missing files, broken transitions.",
            operation: .validate, properties: [:], readOnly: true, idempotent: true
        ),
        Tool(
            name: "frame", title: "Look at a frame",
            description: "Renders the timeline at a time and returns the picture. Default 1280 px wide; pass output to save a PNG instead.",
            operation: .frame,
            properties: [
                "time": time("Timeline time."),
                "maxWidth": S.integer("Largest width in pixels. Default 1280."),
                "maxHeight": S.integer("Largest height in pixels."),
                "output": S.string("Save the PNG here instead of returning it (absolute, or relative to the project folder)."),
                "format": S.string("An alternate output format ID, like portrait.")
            ],
            required: ["time"], readOnly: true, idempotent: true, defaults: ["maxWidth": .number(1280)]
        ),
        Tool(
            name: "screenshot", title: "Screenshot the app",
            description: "Captures the Tandem app's window, to see what Mike sees. Needs the app open.",
            operation: .screenshot, properties: ["output": S.string("Save the PNG here instead of returning it.")], readOnly: true
        ),
        Tool(
            name: "clip", title: "Render a review clip",
            description: "Renders part of the timeline to an MP4 (720p review preset by default) so the edit can be watched. Returns the file path.",
            operation: .clip,
            properties: [
                "start": time("Timeline start."), "end": time("Timeline end."),
                "output": S.string("Where to write the MP4. Default: exports/review <start>-<end>.mp4."),
                "preset": S.string("Export preset: review (default), youtube1080, youtube4k, short.")
            ],
            required: ["start", "end"], readOnly: false
        ),
        Tool(
            name: "export", title: "Export the video",
            description: "Renders the timeline (or a range) with an export preset, loudness-matched to the project target. A preset sets the quality (codec, bitrate, resolution class) and the frame keeps the canvas's shape, so youtube1080 of a 1080x1920 project is 1080x1920. Returns the file path, the size, codec and bitrate used, and the measured loudness.",
            operation: .export,
            properties: [
                "preset": S.string("youtube4k, youtube1080, review or short. Default: the one that fits the canvas, youtube1080 up to 1080 pixels on the short side (1920x1080, 1080x1920), youtube4k above. short renders the portrait format, or the canvas when it's 9:16."),
                "output": S.string("Where to write the file. Default: exports/<name> r<revision>.mp4."),
                "from": time("Start of the range."), "to": time("End of the range."),
                "format": S.string("An alternate output format ID, like portrait.")
            ],
            readOnly: false
        ),
        Tool(
            name: "archive", title: "Archive the project",
            description: "Makes the project standalone so it opens on another Mac. Without `to`, the media, LUTs and fonts it uses from outside its folder are copied into it (media/<folder they were in>/, assets/lut/, assets/font/) and the project is pointed at the copies as one undo step. With `to`, a standalone copy of the whole project folder is written inside that folder (proxies and mattes left out unless withCache), and the original is left alone. Copies are checked, never replace a different file, and are recorded in archive.json; missing files are listed and left as they are. dryRun: true lists what would be copied and the sizes first.",
            operation: .archive,
            properties: [
                "to": S.string("Folder to write a standalone copy into (absolute, or relative to the project folder). Leave out to make the project's own folder standalone."),
                "withCache": S.boolean("With to: also copy proxies, mattes, thumbnails and isolated voice. Transcripts, waveforms and loudness always go."),
                "dryRun": S.boolean("List what would be copied, and the sizes, without changing anything."),
                "label": S.string("Undo label."), "author": S.string("Who made the edit.")
            ],
            readOnly: false, idempotent: true
        ),
        Tool(
            name: "relink", title: "Relink missing media",
            description: "Finds media files that aren't where the project says (moved, or the project opened on another Mac) by name in the project folder and any search folders, checking their content against what the project knew, and points the project at them as one undo step. dryRun: true only reports.",
            operation: .relink,
            properties: [
                "search": S.array(S.string(), "Folders to look in as well as the project's own, subfolders included."),
                "dryRun": S.boolean("Say what would be relinked without changing anything."),
                "label": S.string("Undo label."), "author": S.string("Who made the edit.")
            ],
            readOnly: false, idempotent: true
        ),
        Tool(
            name: "loudness", title: "Loudness",
            description: "Measured loudness of each file with sound, the project's speech level (-20 LUFS unless changed) and master target (-14 LUFS), the gain each levelled clip gets, and how many speech clips aren't at the speech level (apply normalizeSpeech to level them).",
            operation: .loudness, properties: ["mediaID": S.string("Just this file.")], readOnly: true, idempotent: true
        ),
        Tool(
            name: "watch", title: "Wait for a change",
            description: "Waits until the project moves past a revision (default: now), for example to react when Mike edits in the app. Returns the changes, or changed: false after the timeout.",
            operation: .watch,
            properties: ["revision": S.integer("Wait for a revision after this one."), "timeout": S.number("Seconds to wait. Default 30, at most 600.")],
            readOnly: true, idempotent: true
        ),
        Tool(
            name: "assets_search", title: "Find assets",
            description: "Searches Mike's asset library (music, sound effects, stickers, icons, logos, fonts, stock) by words, kind and source. online: true asks the providers too (Noto emoji, Iconify, SVGL, Fontsource, Pexels, Pixabay); what they find joins the library, so its ID works with assets_use right away.",
            asset: .search,
            properties: [
                "text": S.string("Words to match, like whoosh or rocket."),
                "kind": S.string("Kinds, comma separated: music, sfx, sticker, overlay, video, image, font, icon, logo, lut, title, transition."),
                "provider": S.string("Only these sources, comma separated, like noto or import."),
                "online": S.boolean("Ask the providers too, not just the library."),
                "limit": S.integer("At most this many results. Default 20."),
                "maxDuration": time("Only sounds and clips up to this long.")
            ],
            readOnly: true, openWorld: true
        ),
        Tool(
            name: "assets_use", title: "Use an asset",
            description: "Downloads and normalises an asset if needed, copies it into the project's assets folder (a shared library asset, shared:..., is used where it is instead, and archiving copies it in), records the use for the credits and adds it to the project's media. With at it's also placed on the track for its kind (sound effects on SFX at -15 dB, music on Music at -31 dB with a fade out, stickers and logos on Graphics). One undo step, credited to you.",
            asset: .use,
            properties: [
                "id": S.string("An asset ID from assets_search, like noto:1f680 or import:..."),
                "at": time("Place it here on the timeline. Leave out to only add it to the media."),
                "duration": time("How long the clip lasts. Default: all of it (5 s for a still)."),
                "mode": S.enumeration(["place", "overwrite", "insert"], "place (default) fails if its track is taken there."),
                "label": S.string("Undo label.")
            ],
            required: ["id"], readOnly: false, openWorld: true
        ),
        Tool(
            name: "assets_credits", title: "Description credits",
            description: "The credits block for the video description, built from the assets the project uses and their recorded licences, plus anything to sort out before publishing (unknown licences, subscriptions to keep).",
            asset: .credits,
            properties: ["includeOptional": S.boolean("Also list courtesy credits nobody requires.")],
            readOnly: true, idempotent: true
        ),
        Tool(
            name: "assets_generate", title: "Generate a sound or music",
            description: "Makes a sound effect (0.5 to 30 s) or a music cue (3 to 600 s, instrumental) with ElevenLabs and adds it to the library. Each take is a paid request, so make one unless asked for more. Check assets_providers first if it fails.",
            asset: .generate,
            properties: [
                "kind": S.enumeration(["sfx", "music"]),
                "prompt": S.string("What it should sound like, like \"short airy whoosh, left to right\"."),
                "duration": time("Length."),
                "variations": S.integer("Takes to make, each paid. Default 1, at most 4."),
                "loop": S.boolean("Sound effects: loop seamlessly."),
                "vocals": S.boolean("Music: allow vocals (instrumental by default).")
            ],
            required: ["kind", "prompt"], readOnly: false, openWorld: true
        ),
        Tool(
            name: "segments_list", title: "List saved segments",
            description: "Mike's saved segments (an intro, an outro, like and subscribe, comment below) in the shared library's Segments folder: each one's name, length, clips, the tracks it goes on and the fields it asks for.",
            asset: .segments, properties: [:], readOnly: true, idempotent: true
        ),
        Tool(
            name: "segments_save", title: "Save clips as a segment",
            description: "Saves clips from the timeline as a reusable segment in the shared library (Segments/<name>/), with copies of the files they play beside it so it stands on its own. Name the clips exactly (clipIDs, linked partners aren't added) or give a range (from and to: every clip wholly inside). fields turns titles into words asked for on insert, each {\"clipID\": ..., \"label\": ...}. Doesn't change the project.",
            asset: .saveSegment,
            properties: [
                "name": S.string("What it's called in the library, like Intro."),
                "clipIDs": S.array(S.string(), "The clips to save."),
                "from": time("Or: every clip wholly after this time..."),
                "to": time("...and before this one."),
                "fields": S.array(S.object(["clipID": S.string(), "key": S.string(), "label": S.string()], required: ["clipID"]), "Titles whose words are asked for on insert; the words now are the default."),
                "replace": S.boolean("Replace a segment already called that. Files only the old one had stay (projects play them); the rest goes to the Trash.")
            ],
            required: ["name"], readOnly: false
        ),
        Tool(
            name: "segments_insert", title: "Insert a segment",
            description: "Puts a saved segment on the timeline at a time: its clips go on tracks of the same names (made if missing), linked, as one undo step credited to you. Its files are used where they are in the library, added to the project's media as needed; archiving the project copies them in. values fills its fields.",
            asset: .insertSegment,
            properties: [
                "name": S.string("The segment's name, from segments_list."),
                "at": time("Where it starts."),
                "values": S.map(S.string(), "Words for its fields, by key."),
                "mode": S.enumeration(["place", "overwrite", "insert"], "place (default) fails where a track is taken; overwrite replaces what's there; insert pushes later clips right."),
                "label": S.string("Undo label.")
            ],
            required: ["name", "at"], readOnly: false
        ),
        Tool(
            name: "assets_providers", title: "Asset sources",
            description: "Every asset source and whether it works now, with what to fix: a missing key, an ElevenLabs key without the sound_generation permission, a source that's off until its licence is agreed.",
            asset: .providers, properties: [:], readOnly: true, idempotent: true
        ),
        Tool(
            name: "effects", title: "Effects and layouts",
            description: "The effects addEffect accepts with their parameters and defaults, the transition types, the layout presets and the parameters setKeyframes can animate.",
            operation: .effects, properties: ["type": S.string("Just this effect type.")], readOnly: true, idempotent: true
        )
    ]
}

/// Lines from a file handle, read on a thread of their own so a blocking
/// read never ties up a thread of Swift's concurrency pool.
public enum LineReader {
    public static func lines(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        var line = buffer[buffer.startIndex..<newline]
                        if line.last == 0x0D { line = line.dropLast() }
                        continuation.yield(String(decoding: line, as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...newline)
                    }
                }
                if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                continuation.finish()
            }
            thread.name = "tandem line reader"
            thread.start()
        }
    }
}
