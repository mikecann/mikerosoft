import Foundation
import XCTest
@testable import TandemAPI
import TandemAssets
@testable import TandemCore
import TandemMedia

// MARK: - Support

enum AssetFixtures {
    /// A 16-bit PCM WAV of a quiet sine.
    static func wav(at url: URL, seconds: Double = 0.5, sampleRate: Int = 48_000) throws {
        let frames = Int(seconds * Double(sampleRate))
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(36 + frames * 2)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(frames * 2))
        for index in 0..<frames {
            append(Int16(3000 * sin(Double(index) * 2 * .pi * 440 / Double(sampleRate))))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Half a second of bare 48 kHz mono PCM, what ElevenLabs sends.
    static var pcm: Data {
        var data = Data()
        for index in 0..<24_000 {
            var sample = Int16(1000 * sin(Double(index) * 2 * .pi * 440 / 48_000)).littleEndian
            data.append(Data(bytes: &sample, count: 2))
        }
        return data
    }

    static let missingPermission = Data(#"{"detail":{"status":"missing_permissions","message":"The API key you used is missing the permission sound_generation to execute this operation."}}"#.utf8)
}

/// Canned HTTP responses by URL substring. Anything else fails as offline.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [(match: String, status: Int, body: Data)] = []

    func on(_ match: String, status: Int = 200, body: Data) {
        lock.withLock { routes.insert((match, status, body), at: 0) }
    }

    private func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString ?? ""
        guard let route = lock.withLock({ routes.first { url.contains($0.match) } }) else { throw URLError(.notConnectedToInternet) }
        return (route.body, HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try respond(request)
    }

    func download(for request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        let (data, response) = try respond(request)
        try data.write(to: destination)
        return response
    }
}

/// A stock sound library that asks for a credit, standing in for Freesound
/// or Pexels without their APIs.
final class StockProvider: AssetProvider, @unchecked Sendable {
    let id = "stock"
    let displayName = "Test stock"
    let kinds: Set<AssetKind> = [.sfx]
    let rules = ProviderRules()
    let capabilities = ProviderCapabilities(search: true)
    static let credit = "Whoosh Deep by Test Sounds (CC BY 4.0)"

    func status() async -> ProviderStatus { .ready }

    func search(_ query: ProviderQuery) async throws -> [Asset] {
        [Asset(provider: id, providerID: "whoosh-deep", kind: .sfx, name: "Whoosh Deep", tags: ["whoosh", "transition"], duration: 0.5, licenceClass: .creditNeeded, creditLine: Self.credit)]
    }

    func fetchOriginal(_ asset: Asset, into folder: URL) async throws -> FetchedOriginal {
        let file = folder.appendingPathComponent("original.wav")
        try AssetFixtures.wav(at: file)
        return FetchedOriginal(asset: asset, file: file)
    }

    func licence(for asset: Asset) async throws -> AssetLicence {
        AssetLicence(name: "CC BY 4.0", spdx: "CC-BY-4.0", licenceClass: .creditNeeded, creditLine: Self.credit)
    }
}

/// A library in a temp folder: every built-in provider on a stub transport,
/// plus the stock provider and an import folder holding one whoosh.
final class AssetHarness {
    let folder = TempFolder("tandem-assets")
    let transport = StubTransport()
    let service: AssetService

    init(secrets: [String: String] = [:]) async throws {
        let library = try AssetLibrary(
            root: folder.url.appendingPathComponent("library", isDirectory: true),
            previewFolder: folder.url.appendingPathComponent("previews", isDirectory: true),
            transport: transport,
            secrets: StaticSecretStore(secrets)
        )
        library.register(StockProvider())
        let imports = folder.url.appendingPathComponent("imports", isDirectory: true)
        try AssetFixtures.wav(at: imports.appendingPathComponent("sfx/Whoosh_01.wav"))
        try await library.addImportFolder(imports, licence: FolderLicence.presets["mixkit"])
        service = AssetService(library: library)
    }

    var library: AssetLibrary { service.library }

    func whoosh() throws -> Asset {
        try XCTUnwrap(library.search(AssetQuery(text: "whoosh", providers: ["import"])).first)
    }

    /// The fixture project in its own folder, reached the way the CLI reaches it.
    func project() throws -> (ProjectClient, URL) {
        let videoFolder = folder.url.appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: videoFolder, withIntermediateDirectories: true)
        let url = try APIFixture.write(to: videoFolder)
        return (ProjectClient(projectURL: url, author: "claude"), url)
    }
}

// MARK: - Tests

final class AssetServiceTests: XCTestCase {
    func testProvidersSayWhatToFix() async throws {
        let h = try await AssetHarness(secrets: ["elevenlabs": "k"])
        h.transport.on("api.elevenlabs.io/v1/sound-generation", status: 401, body: AssetFixtures.missingPermission)
        do {
            _ = try await h.service.generate(AssetGenerateRequest(kind: .sfx, prompt: "soft whoosh"))
            XCTFail("the key can't make sound effects")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "unavailable")
            XCTAssertTrue(error.message.contains("sound_generation"), error.message)
        }
        let result = await h.service.providers()
        let elevenlabs = try XCTUnwrap(result.providers.first { $0.id == "elevenlabs" })
        XCTAssertEqual(elevenlabs.status.state, .limited)
        XCTAssertTrue(elevenlabs.status.message?.contains("Turn on the sound_generation permission") == true, elevenlabs.status.message ?? "")
        XCTAssertEqual(result.providers.first { $0.id == "pexels" }?.status.state, .needsKey)
        let text = result.readableText
        XCTAssertTrue(text.contains("elevenlabs  ElevenLabs"), text)
        XCTAssertTrue(text.contains("partly working"), text)
        XCTAssertTrue(text.contains("Sound effects are off"), text)
    }

    func testSearchesTheLibraryAndTheProviders() async throws {
        let h = try await AssetHarness()
        let local = try await h.service.search(AssetSearchRequest(text: "whoosh", kinds: [.sfx]))
        XCTAssertEqual(local.local.map(\.provider), ["import"])
        XCTAssertNil(local.online)

        let online = try await h.service.search(AssetSearchRequest(text: "whoosh", providers: ["stock", "noto"], online: true))
        let answers = Dictionary(uniqueKeysWithValues: (online.online ?? []).map { ($0.provider, $0) })
        XCTAssertEqual(Set(answers.keys), ["stock", "noto"])
        XCTAssertEqual(answers["stock"]?.assets.map(\.id), ["stock:whoosh-deep"])
        XCTAssertNotNil(answers["noto"]?.error, "noto is offline here")
        XCTAssertEqual(online.local.map(\.id), ["stock:whoosh-deep"], "found online, now in the catalogue")
        XCTAssertTrue(online.readableText.contains("stock: 1 found"), online.readableText)
        XCTAssertTrue(online.readableText.contains("noto: couldn't search."), online.readableText)

        let everything = try await h.service.search(AssetSearchRequest(text: "whoosh"))
        XCTAssertEqual(Set(everything.local.map(\.provider)), ["import", "stock"])
        do {
            _ = try await h.service.search(AssetSearchRequest(providers: ["nope"]))
            XCTFail("unknown provider")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "notFound")
        }
    }

    func testRequestsReadFriendlyForms() throws {
        let search = try ServiceJSON.decodeRequest(AssetSearchRequest.self, from: Data(#"{"text": "boom", "kind": "sounds,music", "provider": "stock", "maxDuration": "0:02"}"#.utf8))
        XCTAssertEqual(search.kinds, [.sfx, .music])
        XCTAssertEqual(search.providers, ["stock"])
        XCTAssertEqual(search.maxDuration, 2)
        let use = try ServiceJSON.decodeRequest(AssetUseRequest.self, from: Data(#"{"id": "stock:whoosh-deep", "at": "1:02.5", "duration": 0.4}"#.utf8))
        XCTAssertEqual(use.at, t(62.5))
        XCTAssertEqual(use.duration, t(0.4))
        XCTAssertThrowsError(try ServiceJSON.decodeRequest(AssetSearchRequest.self, from: Data(#"{"kind": "podcast"}"#.utf8)))
        XCTAssertThrowsError(try ServiceJSON.decodeRequest(AssetGenerateRequest.self, from: Data(#"{"kind": "sticker", "prompt": "x"}"#.utf8)))
    }

    func testUsePlacesTheAssetOnItsTrack() async throws {
        let h = try await AssetHarness()
        let (client, url) = try h.project()
        let whoosh = try h.whoosh()

        let placed = try await h.service.use(AssetUseRequest(id: whoosh.id, at: t(12)), project: client)

        XCTAssertEqual(placed.applied?.revision, 2)
        XCTAssertEqual(placed.applied?.author, "claude")
        XCTAssertEqual(placed.trackName, "SFX")
        XCTAssertEqual(placed.mediaID, AssetLibrary.mediaID(for: whoosh.id))
        let project = try ProjectFile.load(from: url).project
        let clip = try XCTUnwrap(project.track(named: "SFX")?.clips.first)
        XCTAssertEqual(clip.start, t(12))
        XCTAssertEqual(clip.mediaID, placed.mediaID)
        XCTAssertEqual(clip.audio?.gainDB, -15)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectFolder(projectFile: url).url(forPath: placed.files[0]).path))
        XCTAssertTrue(placed.readableText.hasPrefix("Placed Whoosh 01 (sfx) at 00:12.000 on SFX at -15 dB as revision 2."), placed.readableText)
        XCTAssertEqual(try h.library.search(.inProject(project.id)).map(\.id), [whoosh.id])

        // Using it again without a time changes nothing: it's in the media.
        let again = try await h.service.use(AssetUseRequest(id: whoosh.id), project: client)
        XCTAssertNil(again.applied)
        XCTAssertTrue(again.readableText.contains("already in the project"), again.readableText)
        XCTAssertEqual(try ProjectFile.load(from: url).revision, 2)
    }

    func testUseWithoutATimeOnlyAddsTheMedia() async throws {
        let h = try await AssetHarness()
        let (client, url) = try h.project()
        _ = try await h.service.search(AssetSearchRequest(text: "whoosh", providers: ["stock"], online: true))

        let added = try await h.service.use(AssetUseRequest(id: "stock:whoosh-deep"), project: client)

        let project = try ProjectFile.load(from: url).project
        XCTAssertNotNil(project.media(added.mediaID ?? ""))
        XCTAssertEqual(project.allTracks.flatMap(\.clips).count, APIFixture.project().allTracks.flatMap(\.clips).count, "nothing placed")
        XCTAssertTrue(added.readableText.hasPrefix("Added Whoosh Deep to the project's media as med_"), added.readableText)
        XCTAssertTrue(added.readableText.contains("needs a credit"), added.readableText)
    }

    func testUseReusesTheMediaAWatchingSessionAlreadyAdded() async throws {
        let h = try await AssetHarness()
        let (client, url) = try h.project()
        let whoosh = try h.whoosh()
        // The app's folder watcher noticed the copied file first and gave it
        // an ID of its own.
        let copy = try await h.library.use(whoosh.id, in: ProjectFolder(projectFile: url), projectID: "prj_fixture")
        let path = try XCTUnwrap(copy.mediaItem?.path)
        _ = try await client.call(ApplyRequest(label: "Found new media", commands: [
            .addMedia(item: MediaItem(id: "med_scanned", path: path, kind: .audio, role: .sfx, duration: t(0.5), hasAudio: true))
        ]))

        let placed = try await h.service.use(AssetUseRequest(id: whoosh.id, at: t(3)), project: client)

        XCTAssertEqual(placed.mediaID, "med_scanned")
        let project = try ProjectFile.load(from: url).project
        XCTAssertEqual(project.media.filter { $0.path == path }.count, 1, "the file is in the project once")
        XCTAssertEqual(project.track(named: "SFX")?.clips.first?.mediaID, "med_scanned")
    }

    func testCreditsForTheProject() async throws {
        let h = try await AssetHarness()
        let (client, _) = try h.project()
        let empty = try await h.service.credits(AssetCreditsRequest(), project: client)
        XCTAssertEqual(empty.text, "")
        XCTAssertTrue(empty.readableText.hasPrefix("Nothing in this project needs a credit."), empty.readableText)

        _ = try await h.service.search(AssetSearchRequest(text: "whoosh", providers: ["stock"], online: true))
        _ = try await h.service.use(AssetUseRequest(id: "stock:whoosh-deep", at: t(20)), project: client)
        _ = try await h.service.use(AssetUseRequest(id: try h.whoosh().id, at: t(40)), project: client)

        let credits = try await h.service.credits(AssetCreditsRequest(), project: client)
        XCTAssertEqual(credits.text, "Credits\n\(StockProvider.credit)")
        XCTAssertEqual(Set(credits.credits.assets.map(\.name)), ["Whoosh Deep", "Whoosh 01"])
        let text = credits.readableText
        XCTAssertTrue(text.hasPrefix("Paste into the description:\n\nCredits\n\(StockProvider.credit)"), text)
        XCTAssertTrue(text.contains("Assets used (2):"), text)
    }

    func testGenerateThenUse() async throws {
        let h = try await AssetHarness(secrets: ["elevenlabs": "k"])
        h.transport.on("api.elevenlabs.io/v1/sound-generation", body: AssetFixtures.pcm)
        let made = try await h.service.generate(AssetGenerateRequest(kind: .sfx, prompt: "Short soft click", duration: 0.5))
        let asset = try XCTUnwrap(made.assets.first)
        XCTAssertEqual(asset.provider, "elevenlabs")
        XCTAssertEqual(asset.licenceClass, .aiGenerated)
        XCTAssertTrue(made.readableText.hasPrefix("Made 1 sound effect:"), made.readableText)

        let (client, url) = try h.project()
        _ = try await h.service.use(AssetUseRequest(id: asset.id, at: t(1)), project: client)
        XCTAssertEqual(try ProjectFile.load(from: url).project.track(named: "SFX")?.clips.count, 1)
    }

    func testFetchExplainsAnUnknownID() async throws {
        let h = try await AssetHarness()
        do {
            _ = try await h.service.fetch(AssetFetchRequest(id: "noto:zzzz"))
            XCTFail("unknown asset")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "notFound")
            XCTAssertTrue(error.message.contains("Search for it first"), error.message)
        }
        let fetched = try await h.service.fetch(AssetFetchRequest(id: try h.whoosh().id))
        XCTAssertEqual(fetched.asset.state, .normalised)
        XCTAssertTrue(fetched.readableText.contains("is ready:"), fetched.readableText)
        XCTAssertTrue(fetched.readableText.contains("Licence: Mixkit Free License (no credit)"), fetched.readableText)
    }

    func testStarterSet() async throws {
        let h = try await AssetHarness()
        let result = try h.service.installStarter()
        XCTAssertEqual(result.total, StarterContent.assets().count)
        XCTAssertGreaterThan(result.counts["sticker"] ?? 0, 30)
        XCTAssertTrue(result.readableText.hasPrefix("The starter set is in the library:"), result.readableText)
        let logos = try await h.service.search(AssetSearchRequest(text: "convex", kinds: [.logo]))
        XCTAssertFalse(logos.local.isEmpty)
    }

    func testOfflineLibraryUsesTheOverriddenRoot() async throws {
        let folder = TempFolder("tandem-assets-root")
        let root = folder.url.appendingPathComponent("lib")
        let service = try AssetService.standard(environment: ["TANDEM_ASSETS_ROOT": root.path, "TANDEM_ASSETS_OFFLINE": "1"])
        XCTAssertEqual(service.library.root.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)
        let providers = await service.providers()
        XCTAssertEqual(providers.providers.first { $0.id == "elevenlabs" }?.status.state, .needsKey, "offline reads no keys")
    }
}
