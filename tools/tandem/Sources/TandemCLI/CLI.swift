import Foundation
import TandemAPI
import TandemCore

/// The `tandem` command. Each subcommand builds a service request, sends
/// it through `ProjectClient` (to the app when it has the project open,
/// otherwise straight to the file) and prints the result as text, or as
/// JSON with `--json`.
struct CLI {
    let arguments: [String]
    let directory: URL
    let environment: [String: String]

    init(arguments: [String], directory: URL, environment: [String: String]) {
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
    }

    func run() async -> Int32 {
        let parsed: Arguments
        do {
            parsed = try Arguments.parse(arguments)
        } catch let error as UsageError {
            return usage(error.message, command: nil)
        } catch {
            return usage(error.localizedDescription, command: nil)
        }
        if parsed.has("version") && parsed.command == nil {
            print("tandem \(TandemAPI.version)")
            return 0
        }
        guard let name = parsed.command else {
            print(Help.overview)
            return parsed.has("help") ? 0 : 2
        }
        if name == "help" {
            if let topic = parsed.positionals.first {
                guard let command = Help.command(topic) else { return usage("There's no `\(topic)` command.", command: nil) }
                print(Help.detail(command))
            } else {
                print(Help.overview)
            }
            return 0
        }
        guard let command = Help.command(name) else {
            let hint = Arguments.closest(name, in: Help.commands.map(\.name)).map { " Did you mean `tandem \($0)`?" } ?? ""
            return usage("There's no `\(name)` command.\(hint)", command: nil)
        }
        if parsed.has("help") {
            print(Help.detail(command))
            return 0
        }
        do {
            try parsed.check(allowed: command.options, command: name)
            return try await execute(name, parsed)
        } catch let error as UsageError {
            return usage(error.message, command: command)
        } catch {
            return fail(ServiceError.wrap(error), json: parsed.has("json"))
        }
    }

    // MARK: - Commands

    private func execute(_ name: String, _ args: Arguments) async throws -> Int32 {
        let json = args.has("json")
        switch name {
        case "new":
            return try await newProject(args)
        case "effects":
            try args.expectPositionals(atMost: 1, command: name)
            return show(try EffectsResult.catalog(type: args.positionals.first), json: json)
        case "schema":
            let data = try ServiceJSON.encoder(pretty: true).encode(CommandSchema.document)
            print(String(decoding: data, as: UTF8.self))
            return 0
        case "serve":
            return try await serve(args)
        case "mcp":
            return await mcp(args)
        case "import":
            return try await ImportCommand(directory: directory).run(args)
        case "assets":
            return try await AssetsCommand(directory: directory, environment: environment).run(args, author: author(args)) { try project(args) }
        case "archive":
            try args.expectPositionals(atMost: 1, command: name)
            if args.has("with-cache"), args.options["to"] == nil {
                throw UsageError(message: "--with-cache keeps proxies and mattes in a copy made with --to <folder>; without --to the cache stays where it is.")
            }
            let request = ArchiveRequest(
                to: args.options["to"].map(absolute), withCache: args.has("with-cache") ? true : nil,
                dryRun: args.has("dry-run") ? true : nil, label: args.options["label"]
            )
            // The project can be named straight after the command.
            let url = try ProjectLocator.find(args.positionals.first ?? args.options["project"], in: directory, environment: environment)
            return show(try await ProjectClient(projectURL: url, author: author(args)).call(request), json: json)
        default:
            break
        }

        // Arguments are checked before the project is looked up, so a typo
        // gets a usage error even outside a project folder.
        let client = { ProjectClient(projectURL: try project(args), author: author(args)) }
        switch name {
        case "status":
            try args.expectPositionals(atMost: 0, command: name)
            return show(try await client().call(StatusRequest()), json: json)
        case "media":
            try args.expectPositionals(atMost: 0, command: name)
            return show(try await client().call(MediaRequest(refresh: args.has("refresh"))), json: json)
        case "timeline":
            try args.expectPositionals(atMost: 0, command: name)
            let request = TimelineRequest(
                from: try time(args, "from"), to: try time(args, "to"), format: json ? .json : .text,
                words: args.has("words"), summary: args.has("summary")
            )
            return show(try await client().call(request), json: json)
        case "apply":
            try args.expectPositionals(atMost: 1, command: name)
            let request = try applyRequest(args)
            return show(try await client().call(request), json: json)
        case "undo":
            try args.expectPositionals(atMost: 0, command: name)
            return show(try await client().call(UndoRequest(expectedRevision: try args.integer("expect"))), json: json)
        case "redo":
            try args.expectPositionals(atMost: 0, command: name)
            return show(try await client().call(RedoRequest(expectedRevision: try args.integer("expect"))), json: json)
        case "history":
            try args.expectPositionals(atMost: 0, command: name)
            return show(try await client().call(HistoryRequest(limit: try args.integer("limit"))), json: json)
        case "validate":
            try args.expectPositionals(atMost: 0, command: name)
            let result = try await client().call(ValidateRequest())
            _ = show(result, json: json)
            return result.ok ? 0 : 1
        case "transcript":
            try args.expectPositionals(atMost: 1, command: name)
            let request = TranscriptRequest(id: args.positionals.first, from: try time(args, "from"), to: try time(args, "to"))
            return show(try await client().call(request), json: json)
        case "search":
            let phrase = args.positionals.joined(separator: " ")
            guard !phrase.isEmpty else { throw UsageError(message: "`tandem search` needs a phrase, like tandem search \"decision models\".") }
            return show(try await client().call(SearchRequest(phrase: phrase, limit: try args.integer("limit"))), json: json)
        case "pauses":
            try args.expectPositionals(atMost: 0, command: name)
            let request = PausesRequest(min: try seconds(args, "min"), from: try time(args, "from"), to: try time(args, "to"))
            return show(try await client().call(request), json: json)
        case "tighten":
            try args.expectPositionals(atMost: 0, command: name)
            let request = TightenRequest(
                min: try seconds(args, "min"), keep: try seconds(args, "keep"), apply: args.has("apply"),
                from: try time(args, "from"), to: try time(args, "to"),
                label: args.options["label"], expectedRevision: try args.integer("expect")
            )
            return show(try await client().call(request), json: json)
        case "short":
            try args.expectPositionals(atMost: 0, command: name)
            let request = ShortRequest(apply: args.has("apply"), label: args.options["label"], expectedRevision: try args.integer("expect"))
            return show(try await client().call(request), json: json)
        case "captions":
            try args.expectPositionals(atMost: 0, command: name)
            let request = CaptionsRequest(
                from: try time(args, "from"), to: try time(args, "to"), words: try args.integer("max-words"),
                y: try args.number("y"), track: args.options["track"], apply: args.has("apply"),
                label: args.options["label"], expectedRevision: try args.integer("expect")
            )
            return show(try await client().call(request), json: json)
        case "frame":
            try args.expectPositionals(atMost: 1, command: name)
            let at = try parseTime(try args.positional(0, "a time, like tandem frame 01:23.500", command: name))
            let output = absolute(args.options["output"] ?? "frame-\(TimeText.fileSafe(at)).png")
            let request = FrameRequest(time: at, maxWidth: try args.integer("width"), maxHeight: try args.integer("height"), output: output, format: args.options["format"])
            return show(try await client().call(request), json: json)
        case "screenshot":
            try args.expectPositionals(atMost: 0, command: name)
            let output = absolute(args.options["output"] ?? "tandem-window.png")
            return show(try await client().call(ScreenshotRequest(output: output)), json: json)
        case "clip":
            try args.expectPositionals(atMost: 2, command: name)
            let start = try parseTime(try args.positional(0, "a start and an end, like tandem clip 1:00 1:20", command: name))
            let end = try parseTime(try args.positional(1, "an end time too, like tandem clip 1:00 1:20", command: name))
            let request = ClipRequest(start: start, end: end, output: args.options["output"].map(absolute), preset: args.options["preset"])
            return show(try await client().call(request), json: json)
        case "export":
            try args.expectPositionals(atMost: 0, command: name)
            let request = ExportRequest(
                preset: args.options["preset"], output: args.options["output"].map(absolute),
                from: try time(args, "from"), to: try time(args, "to"), format: args.options["format"]
            )
            return show(try await client().call(request), json: json)
        case "loudness":
            try args.expectPositionals(atMost: 1, command: name)
            return show(try await client().call(LoudnessRequest(mediaID: args.positionals.first)), json: json)
        case "relink":
            try args.expectPositionals(atMost: 0, command: name)
            let search = args.values("search").map(absolute)
            let request = RelinkRequest(search: search.isEmpty ? nil : search, dryRun: args.has("dry-run") ? true : nil, label: args.options["label"])
            return show(try await client().call(request), json: json)
        case "watch":
            try args.expectPositionals(atMost: 0, command: name)
            if args.has("once") {
                let result = try await client().call(WatchRequest(timeout: try args.number("timeout")))
                return show(result, json: json)
            }
            return try await follow(try client(), json: json)
        default:
            throw UsageError(message: "There's no `\(name)` command.")
        }
    }

    private func newProject(_ args: Arguments) async throws -> Int32 {
        try args.expectPositionals(atMost: 1, command: "new")
        var url = URL(fileURLWithPath: absolute(try args.positional(0, "a path, like tandem new \"Decision Models.tandem\"", command: "new")))
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            url = url.appendingPathComponent(url.lastPathComponent).appendingPathExtension(ProjectFile.fileExtension)
        } else if url.pathExtension != ProjectFile.fileExtension {
            url = url.appendingPathExtension(ProjectFile.fileExtension)
        }
        var settings = ProjectSettings()
        if args.has("portrait") {
            settings.width = 1080
            settings.height = 1920
        }
        if let size = args.options["size"] {
            let parts = size.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
                throw UsageError(message: "--size takes width x height in pixels, like 1080x1920 or 3840x2160.")
            }
            settings.width = parts[0]
            settings.height = parts[1]
        }
        let session = try ProjectSession.create(at: url, name: args.options["name"], settings: settings, owner: .cli)
        defer { session.close() }
        let refresh = try await session.refreshMediaReport()
        let project = session.coordinator.project
        if args.has("json") {
            let service = TandemService(session: session, mode: .headless)
            defer { service.shutdown() }
            return show(service.status(), json: true)
        }
        print("Created \(url.path), \(project.settings.width)x\(project.settings.height), with \(project.allTracks.count) tracks (\(project.allTracks.map(\.name).joined(separator: ", "))).")
        let added = refresh.added
        print(added.isEmpty ? "No media found in the folder yet. Add files and run `tandem media --refresh`." : "Added \(added.count) media file\(added.count == 1 ? "" : "s") from the folder.")
        for line in Self.newMediaLines(refresh, in: project) { print(line) }
        return 0
    }

    /// What `tandem new` says about the media it found: the Live Photos, and
    /// which file it treated as the camera take, why, and how to change it.
    static func newMediaLines(_ refresh: MediaRefresh, in project: Project) -> [String] {
        let added = refresh.added.compactMap { project.media($0) }
        var lines: [String] = []
        let livePhotos = added.filter { $0.livePhotoVideo != nil }.count
        if livePhotos > 0 {
            lines.append("\(livePhotos) \(livePhotos == 1 ? "is a Live Photo" : "are Live Photos"): the still is the media item, with its motion clip kept on it (livePhotoVideo) rather than added on its own.")
        }
        func command(_ id: String, role: MediaRole) -> String {
            #"tandem apply '{"updateMedia": {"mediaID": "\#(id)", "patch": {"role": "\#(role.rawValue)"}}}'"#
        }
        let takes = refresh.cameraTakes
        if !takes.isEmpty {
            let shown = 5
            for take in takes.prefix(shown) { lines.append("Camera take: \(take.path) (\(take.mediaID)), \(take.reason).") }
            if takes.count > shown { lines.append("And \(takes.count - shown) more camera takes; `tandem media` lists them.") }
            lines.append("Not the camera? \(command(takes.count == 1 ? takes[0].mediaID : "<id>", role: .other))")
        } else if added.contains(where: { $0.kind == .video }) {
            // The likeliest take is the longest video with sound that nothing
            // else claimed.
            let likely = added.filter { $0.kind == .video && $0.role == .other && $0.hasAudio }.max { ($0.duration ?? .zero) < ($1.duration ?? .zero) }
            var line = "No camera take: no video is named like one, or is a recording (from a phone or camera, or in source/) with speech and a face in it. To make one the camera: \(command(likely?.id ?? "<id>", role: .camera))"
            if let likely { line += " (\(likely.id) is \((likely.path as NSString).lastPathComponent), the longest video with sound)." }
            lines.append(line)
        }
        return lines
    }

    private func serve(_ args: Arguments) async throws -> Int32 {
        try args.expectPositionals(atMost: 0, command: "serve")
        let url = try project(args)
        let port = try args.integer("port") ?? 0
        guard (0...65535).contains(port) else { throw UsageError(message: "--port must be between 0 and 65535.") }
        let session = try ProjectSession.open(url, owner: .cli)
        let host: TandemAPIHost
        do {
            host = try await TandemAPIHost.start(session: session, port: UInt16(port))
        } catch {
            session.close()
            throw error
        }
        let project = session.coordinator.project
        print("Serving \"\(project.name)\" on http://127.0.0.1:\(host.port) (pid \(getpid())). The token is in \(ProjectSession.lockURL(for: url).path). Stop with Ctrl-C.")
        fflush(stdout)
        let log = Task {
            for await event in host.service.events.subscribe() where event.isChange {
                let line = "r\(event.revision ?? 0) \(event.kind.rawValue) \"\(event.label ?? "")\" by \(event.author ?? "?")\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
        // Stop on Ctrl-C or kill, or when the app asks for the project.
        let release = Signals.Trigger()
        host.server.onRelease = { release.fire() }
        await Signals.wait(for: [SIGINT, SIGTERM], or: release)
        log.cancel()
        host.stop()
        session.close()
        print("Stopped. Saved revision \(session.savedRevision).")
        return 0
    }

    private func mcp(_ args: Arguments) async -> Int32 {
        // A client that goes away mid-write shouldn't kill the process.
        signal(SIGPIPE, SIG_IGN)
        let options = MCPServer.Options(project: args.options["project"], directory: directory, author: args.options["author"], environment: environment)
        await MCPServer(options: options).run()
        return 0
    }

    private func follow(_ client: ProjectClient, json: Bool) async throws -> Int32 {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        if !json {
            FileHandle.standardError.write(Data("Watching \(client.projectURL.lastPathComponent). Stop with Ctrl-C.\n".utf8))
        }
        for try await event in client.events() {
            if json {
                print(String(decoding: try ServiceJSON.encoder().encode(event), as: UTF8.self))
            } else {
                var line = "\(formatter.string(from: event.date))  "
                switch event.kind {
                case .jobs:
                    let active = (event.jobs ?? []).filter { $0.state == .running || $0.state == .queued }
                    line += "jobs: " + (active.isEmpty ? "idle" : active.map { "\($0.kind.rawValue) \($0.mediaID) \($0.state.rawValue)" }.joined(separator: ", "))
                case .export:
                    if let job = event.export {
                        line += "export \((job.output as NSString).lastPathComponent) \(job.state.rawValue) \(Int(job.progress * 100))%"
                    }
                default:
                    line += "r\(event.revision ?? 0)  \(event.kind.rawValue)  \(event.label ?? "")  (\(event.author ?? "?"))"
                }
                print(line)
            }
            fflush(stdout)
        }
        return 0
    }

    // MARK: - Helpers

    private func project(_ args: Arguments) throws -> URL {
        try ProjectLocator.find(args.options["project"], in: directory, environment: environment)
    }

    private func author(_ args: Arguments) -> String {
        args.options["author"] ?? environment["TANDEM_AUTHOR"] ?? "cli"
    }

    private func absolute(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return directory.appendingPathComponent(expanded).standardizedFileURL.path
    }

    private func parseTime(_ text: String) throws -> Time {
        guard let time = TimeText.parse(text), time >= .zero else {
            throw UsageError(message: "\"\(text)\" isn't a time. Use seconds (83.5) or mm:ss.mmm (01:23.500).")
        }
        return time
    }

    private func time(_ args: Arguments, _ name: String) throws -> Time? {
        guard let text = args.options[name] else { return nil }
        return try parseTime(text)
    }

    private func seconds(_ args: Arguments, _ name: String) throws -> Double? {
        try time(args, name)?.seconds
    }

    /// Reads the batch for `apply` from a file or stdin. Accepts a batch
    /// object, a list of commands, or a single command.
    private func applyRequest(_ args: Arguments) throws -> ApplyRequest {
        let source = try args.positional(0, "a JSON file, or - to read standard input", command: "apply")
        let data: Data
        if source == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            let url = URL(fileURLWithPath: absolute(source))
            guard let contents = try? Data(contentsOf: url) else { throw UsageError(message: "Couldn't read \(url.path).") }
            data = contents
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ServiceError(.badRequest, "That isn't valid JSON: \(error.localizedDescription)")
        }
        var request: ApplyRequest
        switch value {
        case .object(let fields) where fields["commands"] != nil:
            request = try ServiceJSON.decodeRequest(ApplyRequest.self, from: data)
        case .array(let items):
            request = ApplyRequest(commands: try items.enumerated().map { try CommandJSON.decode($1, path: "[\($0)]") })
        case .object:
            request = ApplyRequest(commands: [try CommandJSON.decode(value)])
        default:
            throw ServiceError(.badRequest, "Expected a batch object, a list of commands or one command.")
        }
        if let label = args.options["label"] { request.label = label }
        if let author = args.options["author"] { request.author = author }
        if let expected = try args.integer("expect") { request.expectedRevision = expected }
        if let key = args.options["key"] { request.idempotencyKey = key }
        if args.has("dry-run") { request.dryRun = true }
        return request
    }

    private func show<R: Encodable & ReadableResult>(_ result: R, json: Bool) -> Int32 {
        if json {
            guard let data = try? ServiceJSON.encoder(pretty: true).encode(result) else { return 1 }
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(result.readableText)
        }
        return 0
    }

    private func fail(_ error: ServiceError, json: Bool) -> Int32 {
        if json, let data = try? ServiceJSON.encoder(pretty: true).encode(ErrorEnvelope(error: error)) {
            print(String(decoding: data, as: UTF8.self))
        } else {
            FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
        }
        return 1
    }

    private func usage(_ message: String, command: CommandHelp?) -> Int32 {
        var text = "error: \(message)\n"
        if let command { text += "Usage: \(command.usage)\n" } else { text += "Run `tandem help` for the commands.\n" }
        FileHandle.standardError.write(Data(text.utf8))
        return 2
    }
}

/// Waits for a signal instead of dying on it, so `serve` can save and let
/// go of the project.
enum Signals {
    /// A way to end the wait from code, like a signal would.
    final class Trigger: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (() -> Void)?
        private var fired = false

        func fire() {
            let run = lock.withLock { () -> (() -> Void)? in
                fired = true
                return handler
            }
            run?()
        }

        func onFire(_ body: @escaping () -> Void) {
            let already = lock.withLock { () -> Bool in
                handler = body
                return fired
            }
            if already { body() }
        }
    }

    static func wait(for signals: [Int32], or trigger: Trigger? = nil) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.mikerosoft.tandem.signals")
            let once = SignalOnce()
            // Ignore the default handling so the sources below see the signal.
            let sources = signals.map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                return DispatchSource.makeSignalSource(signal: number, queue: queue)
            }
            let finish = {
                once.run {
                    for source in sources { source.cancel() }
                    continuation.resume()
                }
            }
            for source in sources {
                source.setEventHandler { finish() }
                source.resume()
            }
            // Keep the sources alive until a signal arrives.
            once.keep(sources)
            trigger?.onFire { queue.async { finish() } }
        }
    }
}

final class SignalOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var retained: [DispatchSourceSignal] = []

    func keep(_ sources: [DispatchSourceSignal]) {
        lock.withLock { retained = sources }
    }

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
