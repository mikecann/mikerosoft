import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

final class HTTPTests: XCTestCase {
    /// A fixture project served over HTTP from this process.
    final class Served {
        let harness: ServiceHarness
        let server: TandemHTTPServer
        let port: Int

        init() async throws {
            harness = try ServiceHarness()
            server = TandemHTTPServer(service: harness.service)
            port = try await server.start()
        }

        func client(token: String? = nil, author: String? = "claude") -> TandemHTTPClient {
            TandemHTTPClient(port: port, token: token ?? server.token, author: author)
        }

        func stop() {
            server.stop()
            harness.close()
        }
    }

    func testRoundTripWithAuth() async throws {
        let served = try await Served()
        defer { served.stop() }
        XCTAssertGreaterThan(served.port, 0)
        let status = try await served.client().call(StatusRequest())
        XCTAssertEqual(status.name, "Decision Models")
        XCTAssertEqual(status.revision, 1)

        let applied = try await served.client().call(ApplyRequest(commands: [.blade(at: t(10))]))
        XCTAssertEqual(applied.author, "claude", "credited to the X-Tandem-Author header")
        XCTAssertEqual(served.harness.service.coordinator.revision, 2)

        do {
            _ = try await served.client(token: String(repeating: "0", count: 64)).call(StatusRequest())
            XCTFail("a wrong token must be refused")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "unauthorized")
        }
        let alive = await served.client(token: "nope").isAlive()
        XCTAssertTrue(alive, "health needs no token")
    }

    func testErrorsKeepTheirCodeAndWording() async throws {
        let served = try await Served()
        defer { served.stop() }
        do {
            _ = try await served.client().call(ApplyRequest(commands: [.removeClips(clipIDs: ["clip_nope"])]))
            XCTFail("expected an error")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "notFound")
            XCTAssertEqual(error.message, "Not found: clip clip_nope")
        }
        do {
            _ = try await served.client().post("explode", body: Data("{}".utf8))
            XCTFail("expected an error")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "notFound")
            XCTAssertTrue(error.message.contains("No operation \"explode\""), error.message)
        }
        do {
            _ = try await served.client().post("apply", body: Data(#"{"commands": [{"blade": {"at": "soon"}}]}"#.utf8))
            XCTFail("expected an error")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "badRequest")
        }
    }

    func testRawHTTPWithURLSession() async throws {
        let served = try await Served()
        defer { served.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(served.port)/v1/status")!)
        request.setValue("Bearer \(served.server.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "GET works for calls without parameters")
        XCTAssertEqual(try ServiceJSON.decoder().decode(StatusResult.self, from: data).revision, 1)

        var schema = URLRequest(url: URL(string: "http://127.0.0.1:\(served.port)/v1/schema")!)
        schema.setValue("Bearer \(served.server.token)", forHTTPHeaderField: "Authorization")
        let (schemaData, _) = try await URLSession.shared.data(for: schema)
        XCTAssertTrue(String(decoding: schemaData, as: UTF8.self).contains("rippleDeleteRange"))

        let unauthorised = URLRequest(url: URL(string: "http://127.0.0.1:\(served.port)/v1/status")!)
        let (_, refused) = try await URLSession.shared.data(for: unauthorised)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 401)
    }

    func testWatchStreamsEventsAndReplaysAfterReconnecting() async throws {
        let served = try await Served()
        defer { served.stop() }
        let events = served.client().events()
        var iterator = events.makeAsyncIterator()
        // Give the stream a moment to subscribe before editing.
        try await Task.sleep(nanoseconds: 100_000_000)
        try served.harness.apply(.blade(at: t(10)), label: "Cut")
        let first = try await iterator.next()
        XCTAssertEqual(first?.kind, .edit)
        XCTAssertEqual(first?.label, "Cut")
        XCTAssertEqual(first?.revision, 2)
        _ = try served.harness.service.undo(expectedRevision: nil)
        let second = try await iterator.next()
        XCTAssertEqual(second?.kind, .undo)

        // A new stream that says where it got to gets what it missed.
        var replay = served.client().events(after: first?.seq).makeAsyncIterator()
        let missed = try await replay.next()
        XCTAssertEqual(missed?.seq, second?.seq)
    }

    /// The app shows which agent is connected: every call reports its
    /// operation and author, and open watch streams are counted.
    func testCallsAndWatchersAreReported() async throws {
        let served = try await Served()
        defer { served.stop() }
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var seen: [String] = []
            func add(_ call: String) { lock.withLock { seen.append(call) } }
            var all: [String] { lock.withLock { seen } }
        }
        let calls = Calls()
        served.harness.service.onCall = { operation, author in calls.add("\(operation) by \(author)") }
        _ = try await served.client().call(StatusRequest())
        _ = try await served.client(author: nil).call(TimelineRequest(format: .json))
        XCTAssertEqual(calls.all, ["status by claude", "timeline by agent"])

        XCTAssertEqual(served.harness.service.events.subscriberCount, 0)
        let reader = Task { () -> Int in
            var count = 0
            do { for try await _ in served.client().events() { count += 1 } } catch {}
            return count
        }
        var waited = 0
        while served.harness.service.events.subscriberCount == 0 && waited < 50 {
            try await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        XCTAssertEqual(served.harness.service.events.subscriberCount, 1)
        XCTAssertEqual(calls.all.last, "watch by claude")
        reader.cancel()
        served.harness.service.events.finishAll()
        _ = await reader.value
        XCTAssertEqual(served.harness.service.events.subscriberCount, 0)
    }

    func testStoppingTheServerEndsEventStreams() async throws {
        let served = try await Served()
        let events = served.client().events()
        let reader = Task { () -> Int in
            var count = 0
            do { for try await _ in events { count += 1 } } catch {}
            return count
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        served.stop()
        let count = await reader.value
        XCTAssertEqual(count, 0)
    }

    func testHostAdvertisesInTheLock() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let host = try await TandemAPIHost.start(session: h.session, analysis: h.analysis, renderer: FakeRenderer())
        let lock = try XCTUnwrap(ProjectSession.readLock(for: h.url))
        XCTAssertEqual(lock.port, host.port)
        XCTAssertEqual(lock.token, host.token)
        XCTAssertEqual(lock.pid, getpid())
        XCTAssertTrue(LockHandle.isHeld(ProjectSession.lockURL(for: h.url)), "rewriting the lock keeps it held")
        let status = try await TandemHTTPClient(port: host.port, token: host.token).call(StatusRequest())
        XCTAssertEqual(status.openIn?.port, host.port)
        host.stop()
        XCTAssertNil(ProjectSession.readLock(for: h.url)?.port)
    }

    func testParallelRequests() async throws {
        let served = try await Served()
        defer { served.stop() }
        let client = served.client()
        let revisions = try await withThrowingTaskGroup(of: Int?.self) { group in
            for index in 0..<24 {
                group.addTask {
                    if index % 3 == 0 {
                        let marker = Marker(id: "mk_p\(index)", time: t(Double(index)), name: "P\(index)")
                        return try await client.call(ApplyRequest(commands: [.addMarker(marker: marker)])).revision
                    }
                    _ = try await client.call(TimelineRequest(from: t(0), to: t(10)))
                    return nil
                }
            }
            var found: [Int] = []
            for try await revision in group { if let revision { found.append(revision) } }
            return found
        }
        XCTAssertEqual(Set(revisions).count, 8, "every edit committed once")
        XCTAssertEqual(served.harness.service.coordinator.project.markers.count, 9)
    }

    func testTheAppDoesntGiveUpItsProject() async throws {
        let served = try await Served()
        defer { served.stop() }
        do {
            try await served.client().requestRelease()
            XCTFail("a server without a release handler refuses")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "unavailable")
        }
    }

    func testRequestParsing() {
        let raw = Data("POST /v1/apply?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nX-Tandem-Author: me\r\n\r\n{}".utf8)
        guard case .complete(let request) = HTTPRequest.parse(raw) else { return XCTFail("should parse") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/apply")
        XCTAssertEqual(request.query["x"], "1")
        XCTAssertEqual(request.headers["x-tandem-author"], "me")
        XCTAssertEqual(request.body, Data("{}".utf8))
        guard case .incomplete = HTTPRequest.parse(raw.dropLast()) else { return XCTFail("body not complete yet") }
        guard case .invalid(let status, _) = HTTPRequest.parse(Data("POST /v1/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) else { return XCTFail("chunked") }
        XCTAssertEqual(status, 411)
    }

    func testSSEParser() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed("id: 3"))
        XCTAssertNil(parser.feed("event: edit"))
        let message = parser.feed("data: {\"a\":1}")
        XCTAssertEqual(message?.event, "edit")
        XCTAssertEqual(message?.data, "{\"a\":1}")
        XCTAssertNil(parser.feed(": keep-alive"))
    }
}

final class LockTests: XCTestCase {
    func testTheSameProcessCantOpenTwice() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let first = try ProjectSession.open(url, owner: .cli)
        defer { first.close() }
        XCTAssertThrowsError(try ProjectSession.open(url, owner: .cli)) { error in
            XCTAssertTrue("\(error)".contains("already open in this process"), "\(error)")
        }
        XCTAssertNil(ProjectSession.liveLock(for: url), "our own lock isn't someone else's")
    }

    func testAStaleLockFileDoesntBlock() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let lockURL = ProjectSession.lockURL(for: url)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Left behind by a crashed app whose pid now belongs to something else.
        try Data(#"{"owner":"app","pid":1,"port":9,"started":"2026-01-01T00:00:00Z","token":"x"}"#.utf8).write(to: lockURL)
        XCTAssertNil(ProjectSession.liveLock(for: url))
        XCTAssertEqual(ProjectClient(projectURL: url, author: "t").route, .headless)
        let session = try ProjectSession.open(url, owner: .cli)
        XCTAssertEqual(ProjectSession.readLock(for: url)?.pid, getpid())
        session.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path), "closing removes the lock")
    }

    func testClosingTwiceIsHarmless() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let session = try ProjectSession.open(url, owner: .cli)
        session.close()
        session.close()
        let again = try ProjectSession.open(url, owner: .cli)
        again.close()
    }
}

final class ProjectClientTests: XCTestCase {
    func testHeadlessCallsOpenAndCloseTheProject() async throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let client = ProjectClient(projectURL: url, author: "claude")
        client.analysis = FakeAnalysis()
        client.renderer = FakeRenderer()
        XCTAssertEqual(client.route, .headless)
        let status = try await client.call(StatusRequest())
        XCTAssertTrue(status.headless)
        let applied = try await client.call(ApplyRequest(commands: [.blade(at: t(10))]))
        XCTAssertEqual(applied.author, "claude")
        XCTAssertEqual(try ProjectFile.load(from: url).revision, applied.revision, "saved when the call finished")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectSession.lockURL(for: url).path))
        let pauses = try await client.call(PausesRequest())
        XCTAssertEqual(pauses.pauses.count, 4)
        let frame = try await client.call(FrameRequest(time: t(1)))
        XCTAssertEqual(frame.bytes, FakeRenderer.png.count)
    }

    func testConcurrentHeadlessCallsShareOneSession() async throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let client = ProjectClient(projectURL: url, author: "claude")
        client.analysis = FakeAnalysis()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let marker = Marker(id: "mk_\(index)", time: t(Double(index)), name: "M\(index)")
                    return try await client.call(ApplyRequest(commands: [.addMarker(marker: marker)])).revision
                }
            }
            var revisions: [Int] = []
            for try await revision in group { revisions.append(revision) }
            return revisions
        }
        XCTAssertEqual(Set(results).count, 8, "every edit got its own revision")
        XCTAssertEqual(try ProjectFile.load(from: url).project.markers.count, 9)
    }

    func testHeadlessWatchSeesTheFileChange() async throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let client = ProjectClient(projectURL: url, author: "claude")
        let waiter = Task { try await client.call(WatchRequest(revision: 1, timeout: 5)) }
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await client.call(ApplyRequest(commands: [.blade(at: t(10))]))
        let result = try await waiter.value
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.revision, 2)
        let quiet = try await client.call(WatchRequest(timeout: 0.3))
        XCTAssertFalse(quiet.changed)
    }

    func testLocatorFindsTheProject() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let nested = folder.url.appendingPathComponent("source/deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertEqual(try ProjectLocator.find(nil, in: nested, environment: [:]), url.standardizedFileURL)
        XCTAssertEqual(try ProjectLocator.find(folder.url.path, in: URL(fileURLWithPath: "/"), environment: [:]), url.standardizedFileURL)
        XCTAssertEqual(try ProjectLocator.find(nil, in: URL(fileURLWithPath: "/"), environment: ["TANDEM_PROJECT": url.path]), url.standardizedFileURL)
        _ = try APIFixture.write(to: folder.url, name: "Decision Models v2")
        XCTAssertThrowsError(try ProjectLocator.find(nil, in: nested, environment: [:])) { error in
            XCTAssertTrue("\(error)".contains("has 2 projects"), "\(error)")
        }
        XCTAssertThrowsError(try ProjectLocator.find("missing.tandem", in: folder.url, environment: [:]))
    }
}
