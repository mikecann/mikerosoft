import Foundation
import CryptoKit

/// Sends HTTP requests. The real one uses URLSession; tests replay recorded
/// responses.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Streams the body to `destination` (replacing it) and returns the response.
    func download(for request: URLRequest, to destination: URL) async throws -> HTTPURLResponse
}

/// The transport used outside tests.
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            // Long enough for a 4K stock clip on a slow connection.
            configuration.timeoutIntervalForResource = 60 * 60
            configuration.httpAdditionalHeaders = ["User-Agent": "Tandem/\(TandemAssets.version) (macOS video editor)"]
            // Tandem keeps its own caches with each provider's rules.
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func download(for request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporary, to: destination)
        return http
    }
}

/// Response bodies kept on disk per provider, keyed by the request with any
/// secrets left out, and reused while younger than the provider's TTL.
final class ResponseCache: @unchecked Sendable {
    let folder: URL
    private let now: @Sendable () -> Date

    init(folder: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.now = now
    }

    private func file(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(digest).body")
    }

    func get(_ key: String, maxAge: TimeInterval) -> Data? {
        let url = file(for: key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              now().timeIntervalSince(modified) < maxAge else { return nil }
        return try? Data(contentsOf: url)
    }

    func put(_ key: String, _ data: Data) {
        let url = file(for: key)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: file(for: key))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Keeps a provider under its request limit. Waits briefly when the window
/// is full; throws `rateLimited` rather than stall a search for minutes.
actor RateLimiter {
    let provider: String
    let limit: Int
    let window: TimeInterval
    let maxWait: TimeInterval
    private var stamps: [Date] = []
    private var blockedUntil: Date?

    init(provider: String, limit: Int, window: TimeInterval, maxWait: TimeInterval = 5) {
        self.provider = provider
        self.limit = limit
        self.window = window
        self.maxWait = maxWait
    }

    func acquire() async throws {
        while true {
            let now = Date()
            if let until = blockedUntil, until > now {
                try await pause(until.timeIntervalSince(now))
                continue
            }
            stamps.removeAll { now.timeIntervalSince($0) >= window }
            if stamps.count < limit {
                stamps.append(now)
                return
            }
            let wait = window - now.timeIntervalSince(stamps[0])
            try await pause(wait)
        }
    }

    /// Stops requests until `date`, after a 429 or an exhausted quota header.
    func block(until date: Date) {
        blockedUntil = max(blockedUntil ?? date, date)
    }

    private func pause(_ seconds: TimeInterval) async throws {
        guard seconds <= maxWait else { throw AssetError.rateLimited(provider: provider, retryAfter: seconds) }
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// At most `limit` tasks at once.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) {
        available = limit
    }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// A provider's view of HTTP: caching by its TTL, its rate limit and
/// concurrency cap, and errors turned into `AssetError` with readable
/// messages and no secrets.
final class ProviderHTTP: @unchecked Sendable {
    let provider: String
    let transport: HTTPTransport
    let cache: ResponseCache
    let rules: ProviderRules
    private let limiter: RateLimiter?
    private let concurrency: AsyncSemaphore?

    init(provider: String, rules: ProviderRules, environment: ProviderEnvironment) {
        self.provider = provider
        self.rules = rules
        transport = environment.transport
        cache = ResponseCache(folder: environment.cacheFolder.appendingPathComponent(provider, isDirectory: true), now: environment.now)
        limiter = rules.requestsPerWindow.map { RateLimiter(provider: provider, limit: $0, window: rules.window) }
        concurrency = rules.maxConcurrentRequests.map { AsyncSemaphore($0) }
    }

    /// GET, served from the cache when a fresh copy exists. `cacheKey`
    /// defaults to the URL; pass one without secrets when the URL has a key
    /// in it.
    func get(_ url: URL, headers: [String: String] = [:], cacheKey: String? = nil, useCache: Bool = true) async throws -> Data {
        let key = cacheKey ?? url.absoluteString
        if useCache, let cached = cache.get(key, maxAge: rules.cacheTTL) { return cached }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, _) = try await send(request)
        if useCache { cache.put(key, data) }
        return data
    }

    func getJSON<T: Decodable>(_ type: T.Type, _ url: URL, headers: [String: String] = [:], cacheKey: String? = nil) async throws -> T {
        let data = try await get(url, headers: headers, cacheKey: cacheKey)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // A bad body shouldn't stay cached for a day.
            cache.remove(cacheKey ?? url.absoluteString)
            throw AssetError.http(provider: provider, status: 200, message: "unexpected response: \(error)")
        }
    }

    /// POST a JSON body, never cached.
    func postJSON(_ url: URL, body: Data, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = 300
        return try await send(request)
    }

    /// Downloads a file to `destination`.
    func download(_ url: URL, to destination: URL, headers: [String: String] = [:]) async throws {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let response = try await withSlot { try await self.transport.download(for: request, to: destination) }
        await noteQuota(response)
        guard (200..<300).contains(response.statusCode) else {
            let body = (try? Data(contentsOf: destination)) ?? Data()
            try? FileManager.default.removeItem(at: destination)
            throw failure(status: response.statusCode, body: body, response: response)
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await withSlot { try await self.transport.data(for: request) }
        await noteQuota(response)
        guard (200..<300).contains(response.statusCode) else {
            throw failure(status: response.statusCode, body: data, response: response)
        }
        return (data, response)
    }

    /// Runs one request inside the rate limit and concurrency cap, turning
    /// transport errors into `AssetError.network` without any secrets.
    private func withSlot<T>(_ body: () async throws -> T) async throws -> T {
        try await limiter?.acquire()
        await concurrency?.wait()
        let result: Result<T, Error>
        do {
            result = .success(try await body())
        } catch {
            result = .failure(error)
        }
        await concurrency?.signal()
        switch result {
        case .success(let value): return value
        case .failure(let error as AssetError): throw error
        case .failure(let error): throw AssetError.network(provider: provider, message: Self.redact(error.localizedDescription))
        }
    }

    /// Pauses when the provider says the quota is spent (Pexels and
    /// Pixabay send X-RateLimit headers).
    private func noteQuota(_ response: HTTPURLResponse) async {
        guard let limiter else { return }
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
        if remaining == 0, let reset {
            // Pixabay sends seconds to go; Pexels sends a Unix time.
            let until = reset > 1_000_000_000 ? Date(timeIntervalSince1970: reset) : Date().addingTimeInterval(reset)
            await limiter.block(until: until)
        }
    }

    private func failure(status: Int, body: Data, response: HTTPURLResponse) -> AssetError {
        let message = Self.message(from: body)
        if status == 429 {
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                ?? response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
                ?? rules.window
            return .rateLimited(provider: provider, retryAfter: retry)
        }
        if status == 401 || status == 403 {
            return .permission(provider: provider, message: message.isEmpty ? "HTTP \(status)" : message)
        }
        return .http(provider: provider, status: status, message: message)
    }

    /// A short readable message from an error body: JSON `detail`,
    /// `message` or `error` fields, or the text itself.
    static func message(from body: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) {
            if let text = describe(json) { return redact(String(text.prefix(400))) }
        }
        let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return redact(String(text.prefix(400)))
    }

    private static func describe(_ json: Any) -> String? {
        if let text = json as? String { return text }
        if let dictionary = json as? [String: Any] {
            // ElevenLabs: {"detail": {"status": "missing_permissions", "message": "..."}}
            if let detail = dictionary["detail"] {
                if let inner = detail as? [String: Any] {
                    let status = inner["status"] as? String
                    let message = inner["message"] as? String
                    return [status, message].compactMap { $0 }.joined(separator: ": ")
                }
                if let list = detail as? [[String: Any]] {
                    return list.compactMap { $0["msg"] as? String }.joined(separator: "; ")
                }
                return describe(detail)
            }
            for key in ["message", "error", "error_description", "errors"] {
                if let value = dictionary[key], let text = describe(value) { return text }
            }
        }
        if let list = json as? [Any] { return list.compactMap(describe).joined(separator: "; ") }
        return nil
    }

    /// Takes API keys out of anything that might reach a log or the UI.
    static func redact(_ text: String) -> String {
        var result = text
        for pattern in ["key=[^&\\s\"]+", "token=[^&\\s\"]+"] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return result
    }
}

extension URL {
    /// Appends query items to a URL.
    func adding(_ items: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.queryItems = (components.queryItems ?? []) + items
        // "+" is legal in a query but many servers read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? self
    }
}
