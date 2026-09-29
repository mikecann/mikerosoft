import Foundation
import TandemCore

/// Talks to a running Tandem (the app or `tandem serve`) over its local API.
public final class TandemHTTPClient: @unchecked Sendable {
    public let baseURL: URL
    public let token: String
    public let author: String?
    private let session: URLSession

    public init(port: Int, token: String, author: String? = nil) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.token = token
        self.author = author
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 24 * 3600
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Runs a service call on the server.
    public func call<C: ServiceCall>(_ call: C) async throws -> C.Result {
        let body = try ServiceJSON.encoder().encode(call)
        let data = try await post(C.operation.rawValue, body: body, timeout: Self.timeout(for: C.operation, call: call))
        do {
            return try ServiceJSON.decoder().decode(C.Result.self, from: data)
        } catch {
            throw ServiceError(.internalError, "The server's reply to \(C.operation.rawValue) couldn't be read: \(error.localizedDescription)")
        }
    }

    /// Sends a raw JSON body and returns the raw JSON reply.
    public func post(_ operation: String, body: Data, timeout: TimeInterval = 600) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/\(operation)"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let author { request.setValue(author, forHTTPHeaderField: "X-Tandem-Author") }
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if let envelope = try? ServiceJSON.decoder().decode(ErrorEnvelope.self, from: data) {
                throw envelope.error
            }
            throw ServiceError(.internalError, "The Tandem API answered \(status).")
        }
        return data
    }

    /// Asks the owner to save and let go of the project (`tandem serve`
    /// agrees; the app doesn't).
    public func requestRelease() async throws {
        _ = try await post("release", body: Data("{}".utf8), timeout: 10)
    }

    /// True when a Tandem API answers on this port.
    public func isAlive() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/health"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Server-sent events from `GET /v1/watch`, until the server stops or
    /// the consumer stops iterating.
    public func events(after seq: Int? = nil) -> AsyncThrowingStream<ServiceEvent, Error> {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/watch"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // So the app can show who's watching.
        if let author { request.setValue(author, forHTTPHeaderField: "X-Tandem-Author") }
        if let seq { request.setValue(String(seq), forHTTPHeaderField: "Last-Event-ID") }
        request.timeoutInterval = 24 * 3600
        return AsyncThrowingStream { continuation in
            // The task keeps the client (and its URL session) alive for as
            // long as the stream runs.
            let task = Task { [self] in
                do {
                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw ServiceError(.unauthorized, "The Tandem API refused the event stream.")
                    }
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        if let message = parser.feed(line), message.event != "hello",
                           let event = try? ServiceJSON.decoder().decode(ServiceEvent.self, from: Data(message.data.utf8)) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.wrap(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw Self.wrap(error)
        }
    }

    static func wrap(_ error: Error) -> Error {
        if let error = error as? ServiceError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .cannotConnectToHost, .notConnectedToInternet:
                return ServiceError(.unavailable, "Couldn't reach the Tandem API: \(error.localizedDescription)")
            case .networkConnectionLost, .timedOut, .badServerResponse, .cannotParseResponse, .zeroByteResource:
                return ServiceError(.interrupted, "The Tandem API stopped answering before it replied (\(error.localizedDescription)). If this was an edit, it may have been applied: check `tandem history` before sending it again.")
            case .cancelled:
                return CancellationError()
            default:
                break
            }
        }
        return ServiceError.wrap(error)
    }

    /// Renders, archives and waits can take a while; everything else should
    /// be quick.
    static func timeout<C: ServiceCall>(for operation: ServiceOperation, call: C) -> TimeInterval {
        switch operation {
        case .export, .clip, .archive: return 24 * 3600
        case .watch: return ((call as? WatchRequest)?.timeout ?? 30) + 30
        case .media, .relink: return 1800
        default: return 600
        }
    }
}

/// Reads server-sent events line by line. `bytes.lines` drops blank lines,
/// so a message ends at the next `id:` or `event:` field, or at a `data:`
/// line when that's the last field we expect.
struct SSEParser {
    struct Message {
        var event: String
        var data: String
    }

    private var event = "message"

    /// Tandem sends `id`, `event` then one `data` line per message, so a data
    /// line completes a message.
    mutating func feed(_ line: String) -> Message? {
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            event = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            let data = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            let message = Message(event: event, data: data)
            event = "message"
            return message
        }
        return nil
    }
}
