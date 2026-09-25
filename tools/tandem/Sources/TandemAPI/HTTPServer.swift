import Foundation
import Network
import TandemCore

/// The local API: HTTP/1.1 on 127.0.0.1 with a random port and a bearer
/// token, both written to the project's lock file by `advertise`.
///
///     POST /v1/<operation>   JSON request body, JSON result
///     GET  /v1/<operation>   the same with no parameters (status, history...)
///     GET  /v1/watch         server-sent events: change, jobs and export events
///     GET  /v1/schema        the EditBatch JSON schema
///     GET  /v1/health        no token needed; says a Tandem API is here
///     POST /v1/release       asks `tandem serve` to save and let go of the project
///
/// Errors come back as `{"error": {"code", "message"}}` with a matching
/// status code. Edits are credited to the `X-Tandem-Author` header when a
/// request doesn't name its own author.
public final class TandemHTTPServer: @unchecked Sendable {
    public let service: TandemService
    public let token: String
    public private(set) var port: Int = 0

    private let queue = DispatchQueue(label: "com.mikerosoft.tandem.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private let lock = NSLock()
    /// How often an idle event stream sends a comment to keep proxies and
    /// clients from timing out.
    var keepAliveInterval: TimeInterval = 15
    /// Called for `POST /v1/release`, when another process (the app) wants
    /// the project. `tandem serve` sets it to save and quit; the app leaves
    /// it nil, so the request is refused.
    public var onRelease: (@Sendable () -> Void)?

    public init(service: TandemService, token: String = TandemHTTPServer.makeToken()) {
        self.service = service
        self.token = token
    }

    /// A random 256-bit token as hex.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    /// Starts listening on 127.0.0.1 and returns the port. Pass 0 for a
    /// free port.
    @discardableResult
    public func start(port requested: UInt16 = 0) async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let port = requested == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requested) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let started: Int = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .failed(let error):
                    once.run { continuation.resume(throwing: ServiceError(.unavailable, "The API server couldn't start: \(error.localizedDescription)")) }
                case .cancelled:
                    once.run { continuation.resume(throwing: ServiceError(.unavailable, "The API server stopped before it started.")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.port = started
        return started
    }

    /// Stops listening and closes every connection, including event streams.
    public func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for connection in open { connection.close() }
    }

    private func accept(_ nw: NWConnection) {
        let connection = HTTPConnection(connection: nw, server: self)
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.start(on: queue)
    }

    fileprivate func finished(_ connection: HTTPConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    fileprivate func authorised(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        let presented = Array(header.dropFirst("Bearer ".count).utf8)
        let expected = Array(token.utf8)
        guard presented.count == expected.count else { return false }
        // Compare every byte so the time taken doesn't leak the token.
        var difference: UInt8 = 0
        for (a, b) in zip(presented, expected) { difference |= a ^ b }
        return difference == 0
    }

    /// Answers one request.
    fileprivate func respond(to request: HTTPRequest, on connection: HTTPConnection) async {
        let path = request.path
        if path == "/v1/health" {
            connection.send(json: .object(["ok": .bool(true), "service": .string("tandem"), "apiVersion": .string(TandemAPI.version)]))
            return
        }
        guard authorised(request) else {
            connection.send(error: ServiceError(.unauthorized, "Missing or wrong API token. The token is in the project's .tandem/<name>.lock file."))
            return
        }
        guard path.hasPrefix("/v1/") else {
            connection.send(error: ServiceError(.notFound, "No such endpoint \(path). Try POST /v1/status."))
            return
        }
        let name = String(path.dropFirst("/v1/".count))
        if name == "schema" && request.method == "GET" {
            connection.send(json: CommandSchema.document)
            return
        }
        if name == "release" && request.method == "POST" {
            guard let onRelease else {
                connection.send(error: ServiceError(.unavailable, "This Tandem keeps the project open; close it there instead."))
                return
            }
            connection.send(json: .object(["ok": .bool(true)]))
            onRelease()
            return
        }
        if name == "watch" && request.method == "GET" {
            let after = request.headers["last-event-id"].flatMap(Int.init) ?? request.query["after"].flatMap(Int.init)
            await connection.stream(events: service.events, replayAfter: after, revision: service.coordinator.revision, keepAlive: keepAliveInterval)
            return
        }
        guard let operation = ServiceOperation(rawValue: name) else {
            let known = ServiceOperation.allCases.map(\.rawValue).joined(separator: ", ")
            connection.send(error: ServiceError(.notFound, "No operation \"\(name)\". Operations: \(known)."))
            return
        }
        guard request.method == "POST" || (request.method == "GET" && request.body.isEmpty) else {
            connection.send(error: ServiceError(.badRequest, "Use POST /v1/\(name) with a JSON body."), status: 405)
            return
        }
        let author = request.headers["x-tandem-author"].flatMap { $0.isEmpty ? nil : $0 } ?? "agent"
        do {
            let body = try await service.handle(operation, body: request.body, context: CallContext(author: author))
            connection.send(status: 200, contentType: "application/json; charset=utf-8", body: body)
        } catch {
            connection.send(error: ServiceError.wrap(error))
        }
    }
}

/// Runs a closure at most once, for continuations resumed from callbacks.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    /// Header names are lower-cased.
    var headers: [String: String]
    var body: Data

    enum ParseResult {
        case complete(HTTPRequest)
        case incomplete
        case invalid(status: Int, message: String)
    }

    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 64 * 1024 * 1024

    static func parse(_ buffer: Data) -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes ? .invalid(status: 431, message: "The request headers are too large.") : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, message: "The request headers aren't UTF-8.")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return .invalid(status: 400, message: "Malformed request line.") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .invalid(status: 411, message: "Send a Content-Length instead of a chunked body.")
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(status: 400, message: "Bad Content-Length.") }
        guard length <= maxBodyBytes else { return .invalid(status: 413, message: "The request body is too large.") }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
        let body = buffer[bodyStart..<(bodyStart + length)]
        let target = String(requestLine[1])
        var path = target
        var query: [String: String] = [:]
        if let components = URLComponents(string: target) {
            path = components.path
            for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers, body: Data(body)))
    }
}

/// One client connection: reads a request, answers it and closes, or holds
/// the connection open for an event stream.
final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private weak var server: TandemHTTPServer?
    private var buffer = Data()
    /// Set once a whole request has arrived.
    private var request: HTTPRequest?
    private let lock = NSLock()
    private var streamTask: Task<Void, Never>?
    private var isClosed = false

    init(connection: NWConnection, server: TandemHTTPServer) {
        self.connection = connection
        self.server = server
    }

    /// How long a client gets to send a whole request.
    static let requestTimeout: TimeInterval = 30

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
        // A client that connects and never finishes a request is dropped.
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            guard let self else { return }
            let waiting = self.lock.withLock { !self.isClosed && self.request == nil }
            if waiting { self.close() }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            switch HTTPRequest.parse(self.buffer) {
            case .complete(let request):
                self.lock.withLock { self.request = request }
                Task { [weak self] in
                    guard let self, let server = self.server else { return }
                    await server.respond(to: request, on: self)
                }
            case .invalid(let status, let message):
                self.send(error: ServiceError(.badRequest, message), status: status)
            case .incomplete:
                if isComplete || error != nil {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }
    }

    func send(json value: JSONValue, status: Int = 200) {
        let body = (try? ServiceJSON.encoder().encode(value)) ?? Data("{}".utf8)
        send(status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    func send(error: ServiceError, status: Int? = nil) {
        let body = (try? ServiceJSON.encoder().encode(ErrorEnvelope(error: error))) ?? Data()
        send(status: status ?? error.httpStatus, contentType: "application/json; charset=utf-8", body: body)
    }

    func send(status: Int, contentType: String, body: Data) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    /// Streams events as server-sent events until the client goes away or
    /// the server stops. Starts with a `hello` event carrying the revision.
    func stream(events: EventHub, replayAfter: Int?, revision: Int, keepAlive: TimeInterval) async {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        let hello = "retry: 2000\nevent: hello\ndata: {\"revision\":\(revision),\"seq\":\(events.lastSeq)}\n\n"
        write(head + hello)
        let stream = events.subscribe(replayAfter: replayAfter)
        let task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in stream {
                        guard let self, let data = try? ServiceJSON.encoder().encode(event) else { return }
                        self.write("id: \(event.seq)\nevent: \(event.kind.rawValue)\ndata: \(String(decoding: data, as: UTF8.self))\n\n")
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: UInt64(keepAlive * 1_000_000_000))
                        guard !Task.isCancelled, let self else { return }
                        self.write(": keep-alive\n\n")
                    }
                }
                // Either child ending (the stream finished, or we were
                // closed) ends the whole stream.
                await group.next()
                group.cancelAll()
            }
            self?.close()
        }
        let closed = lock.withLock { () -> Bool in
            if !isClosed { streamTask = task }
            return isClosed
        }
        if closed { task.cancel() }
        // Notice the client hanging up: a read that completes ends the stream.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { self?.close() }
        }
    }

    private func write(_ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    func close() {
        lock.lock()
        let already = isClosed
        isClosed = true
        let task = streamTask
        streamTask = nil
        lock.unlock()
        guard !already else { return }
        task?.cancel()
        connection.cancel()
        server?.finished(self)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
