import Foundation
import XCTest
@testable import TandemAssets

/// A fresh folder under the system temp directory, removed at the end of
/// the test.
func makeTempFolder(_ name: String = "assets", file: StaticString = #filePath, line: UInt = #line) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tandem-assets-tests", isDirectory: true)
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

extension XCTestCase {
    /// A temp folder that's deleted when the test ends.
    func tempFolder(_ name: String = "assets") -> URL {
        let url = makeTempFolder(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func makeCatalog() throws -> AssetCatalog {
        try AssetCatalog(url: tempFolder("catalog").appendingPathComponent("catalog.sqlite"))
    }
}

/// A sample asset with sensible defaults for tests.
func sampleAsset(
    provider: String = "import",
    id: String,
    kind: AssetKind = .sfx,
    name: String,
    tags: [String] = [],
    summary: String? = nil,
    duration: Double? = nil,
    bpm: Double? = nil,
    hasAlpha: Bool = false,
    state: AssetState = .original,
    licence: LicenceClass = .noCredit,
    credit: String? = nil,
    popularity: Double? = nil
) -> Asset {
    Asset(
        provider: provider,
        providerID: id,
        kind: kind,
        name: name,
        tags: tags,
        summary: summary,
        duration: duration,
        bpm: bpm,
        hasAlpha: hasAlpha,
        state: state,
        licenceClass: licence,
        creditLine: credit,
        popularity: popularity
    )
}

/// Loads a recorded fixture committed next to the tests.
func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw AssetError.notFound("fixture \(name)")
    }
    return try Data(contentsOf: url)
}

/// Replays canned responses by URL substring and records every request.
/// Anything unmatched fails as if offline, so tests never touch the network.
final class FixtureTransport: HTTPTransport, @unchecked Sendable {
    struct Route {
        var match: String
        var method: String?
        var status: Int
        var headers: [String: String]
        var body: @Sendable (URLRequest) throws -> Data
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var recorded: [URLRequest] = []

    /// Responds to requests whose URL contains `match`. Later routes win.
    func on(_ match: String, method: String? = nil, status: Int = 200, headers: [String: String] = [:], body: @escaping @Sendable (URLRequest) throws -> Data) {
        lock.lock()
        routes.insert(Route(match: match, method: method, status: status, headers: headers, body: body), at: 0)
        lock.unlock()
    }

    func on(_ match: String, method: String? = nil, status: Int = 200, headers: [String: String] = [:], data: Data) {
        on(match, method: method, status: status, headers: headers) { _ in data }
    }

    func on(_ match: String, fixture name: String, status: Int = 200) throws {
        let data = try fixture(name)
        on(match, status: status, data: data)
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requests(matching text: String) -> [URLRequest] {
        requests.filter { $0.url?.absoluteString.contains(text) == true }
    }

    private func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        lock.lock()
        recorded.append(request)
        let url = request.url?.absoluteString ?? ""
        let route = routes.first { url.contains($0.match) && ($0.method == nil || $0.method == request.httpMethod) }
        lock.unlock()
        guard let route else { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: route.headers)!
        return (try route.body(request), response)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try respond(request)
    }

    func download(for request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        let (data, response) = try respond(request)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
        return response
    }
}

extension XCTestCase {
    /// A provider environment with a fixture transport and fixed secrets.
    func makeEnvironment(_ transport: FixtureTransport, secrets: [String: String] = [:], now: @escaping @Sendable () -> Date = { Date() }) -> ProviderEnvironment {
        let root = tempFolder("env")
        return ProviderEnvironment(
            transport: transport,
            secrets: StaticSecretStore(secrets),
            cacheFolder: root.appendingPathComponent("cache", isDirectory: true),
            stateFolder: root.appendingPathComponent("state", isDirectory: true),
            now: now
        )
    }

    /// A library in a temp folder with a fixture transport and fixed secrets.
    func makeLibrary(_ transport: FixtureTransport = FixtureTransport(), secrets: [String: String] = [:], settings: AssetSettings = AssetSettings(), normaliser: AssetNormaliser = AssetNormaliser()) throws -> AssetLibrary {
        let root = tempFolder("library")
        return try AssetLibrary(
            root: root.appendingPathComponent("Assets", isDirectory: true),
            previewFolder: root.appendingPathComponent("Previews", isDirectory: true),
            transport: transport,
            secrets: StaticSecretStore(secrets),
            normaliser: normaliser,
            settings: settings
        )
    }
}

/// A mutable clock for cache expiry tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}
