import XCTest
import TandemCore
import TandemMedia
@testable import TandemAssets

/// A transport that serves the Noto index and a tiny sticker for any emoji.
func notoTransport() throws -> FixtureTransport {
    let transport = FixtureTransport()
    try transport.on("noto-emoji-animation/data/api.json", fixture: "noto_api.json")
    let folder = makeTempFolder("noto-fixture")
    let lottie = folder.appendingPathComponent("lottie.json")
    try Generated.lottie(at: lottie)
    let gif = folder.appendingPathComponent("sticker.gif")
    try Generated.animatedGIF(at: gif, frames: 6)
    let lottieData = try Data(contentsOf: lottie)
    let gifData = try Data(contentsOf: gif)
    transport.on("/lottie.json", data: lottieData)
    // Served as the "WebP": the sniffer reads the bytes, not the name.
    transport.on("/512.webp", data: gifData)
    return transport
}

final class LibraryTests: XCTestCase {
    func testDefaultProvidersAndTheirStatus() async throws {
        let library = try makeLibrary(secrets: ["elevenlabs": "k"])
        let info = await library.providerInfo()
        XCTAssertEqual(info.map(\.id), ["import", "elevenlabs", "noto", "iconify", "svgl", "fontsource", "pexels", "pixabay", "freesound", "epidemic", "lordicon"])
        func state(_ id: String) -> ProviderStatus.State? { info.first { $0.id == id }?.status.state }
        XCTAssertEqual(state("noto"), .ready)
        XCTAssertEqual(state("elevenlabs"), .ready)
        XCTAssertEqual(state("pexels"), .needsKey)
        XCTAssertEqual(state("pixabay"), .needsKey)
        XCTAssertEqual(state("freesound"), .disabled)
        XCTAssertEqual(state("epidemic"), .stub)
        XCTAssertEqual(state("lordicon"), .stub)
        XCTAssertEqual(info.first { $0.id == "pixabay" }?.rules.cacheTTL, 24 * 3600)
    }

    func testFreesoundTurnsOnFromSettings() async throws {
        let library = try makeLibrary(secrets: ["freesound": "t"], settings: AssetSettings(freesoundEnabled: true))
        let status = await library.provider("freesound")!.status()
        XCTAssertEqual(status, .ready)
    }

    func testSettingsRoundTrip() throws {
        let folder = tempFolder("settings")
        XCTAssertEqual(AssetSettings.load(from: folder), AssetSettings())
        let custom = AssetSettings(freesoundEnabled: true, iconColour: "#FF0000", previewCacheLimit: 10)
        try custom.save(to: folder)
        XCTAssertEqual(AssetSettings.load(from: folder), custom)
    }

    func testSearchingProvidersRecordsResultsAndReportsWhyOthersCant() async throws {
        let transport = try notoTransport()
        try transport.on("api.svgl.app", fixture: "svgl.json")
        let library = try makeLibrary(transport)

        let results = await library.searchProviders(ProviderQuery(text: "rocket"), providerIDs: ["noto", "svgl", "pexels"])

        XCTAssertEqual(results.map(\.provider), ["noto", "svgl", "pexels"])
        XCTAssertEqual(results[0].assets.map(\.id), ["noto:1f680"])
        XCTAssertNil(results[0].error)
        XCTAssertTrue(results[1].assets.isEmpty)
        XCTAssertNotNil(results[2].error)
        // Recorded for a later fetch, even from another process.
        XCTAssertEqual(try library.asset("noto:1f680")?.state, .remote)
        XCTAssertEqual(try library.search(AssetQuery(text: "rocket")).map(\.id), ["noto:1f680"])
    }

    func testKindsNarrowWhichProvidersAreAsked() async throws {
        let transport = try notoTransport()
        let library = try makeLibrary(transport)
        let results = await library.searchProviders(ProviderQuery(text: "rocket", kinds: [.sticker]))
        XCTAssertEqual(results.map(\.provider), ["noto"])
    }

    func testFetchNormalisesSnapshotsTheLicenceAndWritesMeta() async throws {
        let transport = try notoTransport()
        let library = try makeLibrary(transport)
        _ = await library.searchProviders(ProviderQuery(text: "rocket"), providerIDs: ["noto"])

        let asset = try await library.fetch("noto:1f680")

        XCTAssertEqual(asset.state, .normalised)
        XCTAssertEqual(asset.files.folder, "noto/1f680")
        XCTAssertEqual(asset.files.normalised, "normalised.mov")
        XCTAssertEqual(asset.files.thumbnail, "thumbnail.png")
        XCTAssertTrue(asset.hasAlpha)
        XCTAssertNotNil(asset.sha256)
        XCTAssertGreaterThan(asset.size ?? 0, 0)
        XCTAssertEqual(try XCTUnwrap(asset.duration), 0.5, accuracy: 0.05)
        let expectedOriginal = AssetNormaliser.canRenderLottie ? "original.json" : "original-512.webp"
        XCTAssertEqual(asset.files.original, expectedOriginal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(library.playableURL(for: asset)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(library.url(for: asset, .thumbnail)).path))

        let licence = try XCTUnwrap(library.licence(for: "noto:1f680"))
        XCTAssertEqual(licence.spdx, "CC-BY-4.0")
        XCTAssertEqual(licence.creditLine, NotoEmojiProvider.creditLine)

        let metaURL = try XCTUnwrap(library.url(for: asset, .meta))
        let meta = try JSONDecoder.iso.decode(AssetLibrary.AssetMeta.self, from: Data(contentsOf: metaURL))
        XCTAssertEqual(meta.asset.id, "noto:1f680")
        XCTAssertEqual(meta.licence?.spdx, "CC-BY-4.0")

        // Fetching again is free: nothing new is downloaded.
        let before = transport.requests.count
        _ = try await library.fetch("noto:1f680")
        XCTAssertEqual(transport.requests.count, before)
    }

    func testFetchingTwiceAtOnceDownloadsOnce() async throws {
        let transport = try notoTransport()
        let library = try makeLibrary(transport)
        _ = await library.searchProviders(ProviderQuery(text: "fire"), providerIDs: ["noto"])
        async let first = library.fetch("noto:1f525")
        async let second = library.fetch("noto:1f525")
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.state, .normalised)
        XCTAssertEqual(b.files, a.files)
        XCTAssertEqual(transport.requests(matching: "1f525/512.webp").count, 1)
    }

    func testFetchRefusesUnknownAssetsAndUnusableProviders() async throws {
        let library = try makeLibrary()
        do {
            _ = try await library.fetch("noto:nope")
            XCTFail("expected an error")
        } catch let error as AssetError {
            XCTAssertEqual(error, .notFound("asset noto:nope"))
        }
        try library.catalog.upsert(sampleAsset(provider: "pexels", id: "video-1", kind: .video, name: "Clip", state: .remote))
        do {
            _ = try await library.fetch("pexels:video-1")
            XCTFail("expected an error")
        } catch let error as AssetError {
            guard case .providerUnavailable = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testFolderNamesAreSafeAndDistinct() {
        XCTAssertEqual(AssetLibrary.folderName(for: "1f680"), "1f680")
        let icon = AssetLibrary.folderName(for: "mdi:rocket")
        XCTAssertTrue(icon.hasPrefix("mdi_rocket-"))
        XCTAssertNotEqual(AssetLibrary.folderName(for: "a/b"), AssetLibrary.folderName(for: "a_b"))
        XCTAssertFalse(AssetLibrary.folderName(for: "../../etc").contains("/"))
        XCTAssertLessThanOrEqual(AssetLibrary.folderName(for: String(repeating: "x", count: 300)).count, 70)
    }

    func testPreviewsAreCachedAndTrimmed() async throws {
        let transport = FixtureTransport()
        transport.on("example.com/a", data: Data(count: 600))
        transport.on("example.com/b", data: Data(count: 600))
        let cache = PreviewCache(folder: tempFolder("previews"), limit: 1_000, transport: transport)
        let a = try await cache.fetch(URL(string: "https://example.com/a.mp3")!)
        XCTAssertEqual(a.pathExtension, "mp3")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: a.path)
        _ = try await cache.fetch(URL(string: "https://example.com/b.mp3")!)
        // Over the limit: the older file went.
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertLessThanOrEqual(cache.totalSize, 1_000)
        _ = try await cache.fetch(URL(string: "https://example.com/b.mp3")!)
        XCTAssertEqual(transport.requests(matching: "example.com/b").count, 1)
    }

    func testPreviewFileMarksTheAsset() async throws {
        let transport = try notoTransport()
        let library = try makeLibrary(transport)
        _ = await library.searchProviders(ProviderQuery(text: "eyes"), providerIDs: ["noto"])
        let file = try await library.previewFile(for: "noto:1f440")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try library.asset("noto:1f440")?.state, .preview)
    }

    func testFavourites() throws {
        let library = try makeLibrary()
        try library.catalog.upsert(sampleAsset(id: "a", name: "A"))
        try library.setFavourite("import:a", true)
        XCTAssertEqual(try library.search(.favourites()).map(\.id), ["import:a"])
        XCTAssertThrowsError(try library.setFavourite("import:missing", true))
    }
}

final class GenerationTests: XCTestCase {
    func testGeneratedSoundGoesIntoTheCatalogueWithItsPrompt() async throws {
        let transport = FixtureTransport()
        // Half a second of a quiet sine as bare 16-bit mono PCM.
        var pcm = Data()
        for index in 0..<24_000 {
            var sample = Int16(1000 * sin(Double(index) * 2 * .pi * 440 / 48_000)).littleEndian
            pcm.append(Data(bytes: &sample, count: 2))
        }
        transport.on("api.elevenlabs.io/v1/sound-generation", data: pcm)
        let library = try makeLibrary(transport, secrets: ["elevenlabs": "k"])

        let made = try await library.generate(GenerationRequest(kind: .sfx, prompt: "Short soft click", duration: 0.5))

        XCTAssertEqual(made.count, 1)
        let asset = made[0]
        XCTAssertEqual(asset.state, .normalised)
        XCTAssertEqual(asset.kind, .sfx)
        XCTAssertEqual(asset.summary, "Short soft click")
        XCTAssertEqual(asset.licenceClass, .aiGenerated)
        // ElevenLabs sends 48 kHz PCM, so the WAV is used as it is.
        XCTAssertNil(asset.files.normalised)
        XCTAssertEqual(library.playableURL(for: asset)?.lastPathComponent, "original.wav")
        XCTAssertEqual(asset.files.peaks, "peaks.bin")
        XCTAssertNotNil(asset.loudness)
        XCTAssertEqual(try XCTUnwrap(asset.duration), 0.5, accuracy: 0.01)
        XCTAssertEqual(try library.licence(for: asset.id)?.licenceClass, .aiGenerated)
        XCTAssertEqual(try library.search(AssetQuery(text: "soft click")).map(\.id), [asset.id])
        XCTAssertNotNil(library.waveform(for: asset))
        // The staging folder is cleaned up.
        let staging = library.root.appendingPathComponent("staging")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: staging.path))?.count ?? 0, 0)
    }

    func testGenerationNeedsAGeneratingProvider() async throws {
        let library = try makeLibrary()
        do {
            _ = try await library.generate(GenerationRequest(kind: .sfx, prompt: "x"), provider: "noto")
            XCTFail("expected an error")
        } catch let error as AssetError {
            guard case .unsupported = error else { return XCTFail("wrong error \(error)") }
        }
        do {
            _ = try await library.generate(GenerationRequest(kind: .sfx, prompt: "x"))
            XCTFail("expected an error without a key")
        } catch let error as AssetError {
            guard case .providerUnavailable = error else { return XCTFail("wrong error \(error)") }
        }
    }
}

final class StarterContentTests: XCTestCase {
    func testStarterSetIsAboutFortyEmojiThirtyIconsAndTheLogos() throws {
        let assets = StarterContent.assets()
        let byKind = Dictionary(grouping: assets, by: \.kind)
        XCTAssertEqual(byKind[.sticker]?.count, 43)
        XCTAssertEqual(byKind[.icon]?.count, 32)
        XCTAssertEqual(byKind[.logo]?.count, 15)
        XCTAssertEqual(Set(assets.map(\.id)).count, assets.count, "IDs must be unique")
        XCTAssertTrue(assets.allSatisfy { $0.tags.contains(StarterContent.tag) && $0.state == .remote })
        let logos = Set(byKind[.logo]!.compactMap { $0.remote["title"] })
        XCTAssertEqual(logos, ["Convex", "React", "Next.js", "TypeScript", "OpenAI", "Anthropic", "Vercel", "GitHub"])
        XCTAssertTrue(byKind[.icon]!.allSatisfy { $0.licenceClass == .noCredit && $0.remote["spdx"] == "Apache-2.0" })
    }

    func testInstallIsIdempotentAndSearchable() throws {
        let library = try makeLibrary()
        let installed = try library.installStarterContent()
        XCTAssertEqual(installed.count, 90)
        try library.setFavourite("noto:1f680", true)
        try library.installStarterContent()
        XCTAssertEqual(try library.count(AssetQuery()), 90)
        XCTAssertEqual(try library.asset("noto:1f680")?.isFavourite, true)
        let rockets = try library.search(AssetQuery(text: "rocket"))
        XCTAssertEqual(Set(rockets.map(\.id)), ["noto:1f680", "iconify:mdi:rocket-launch"])
        XCTAssertEqual(try library.search(AssetQuery(text: "convex", kinds: [.logo])).count, 3)
        XCTAssertEqual(try library.search(AssetQuery(text: "starter", kinds: [.sticker], limit: 500)).count, 43)
    }

    func testStarterIconFetchesAsAPNG() async throws {
        let transport = FixtureTransport()
        transport.on("api.iconify.design/mdi/check-bold.svg", data: Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\"><path fill=\"#fff\" d=\"M2 12l7 7L22 5\"/></svg>".utf8))
        let library = try makeLibrary(transport)
        try library.installStarterContent()
        let icon = try await library.fetch("iconify:mdi:check-bold")
        XCTAssertEqual(icon.files.normalised, "normalised.png")
        XCTAssertEqual(icon.width, 2048)
        XCTAssertEqual(try library.licence(for: icon.id)?.spdx, "Apache-2.0")
    }
}

final class HousekeepingTests: XCTestCase {
    func testEvictionFreesUnpinnedFilesOnly() async throws {
        let transport = try notoTransport()
        let library = try makeLibrary(transport)
        _ = await library.searchProviders(ProviderQuery(text: "fire"), providerIDs: ["noto"])
        _ = await library.searchProviders(ProviderQuery(text: "eyes"), providerIDs: ["noto"])
        _ = await library.searchProviders(ProviderQuery(text: "rocket"), providerIDs: ["noto"])
        let imports = tempFolder("imports")
        try Generated.sineWAV(at: imports.appendingPathComponent("click.wav"), seconds: 0.2)
        try await library.addImportFolder(imports)
        let click = try XCTUnwrap(library.search(AssetQuery(text: "click")).first)
        for id in ["noto:1f525", "noto:1f440", "noto:1f680", click.id] { _ = try await library.fetch(id) }
        try library.setFavourite("noto:1f440", true)
        try library.catalog.recordUsage(AssetUsage(assetID: "noto:1f680", projectID: "prj"))
        // Age every row.
        for var asset in try library.search(AssetQuery(limit: 1000)) {
            asset.updatedAt = Date(timeIntervalSinceNow: -200 * 24 * 3600)
            try library.catalog.upsert(asset)
        }
        let fireFolder = library.folder(for: try XCTUnwrap(library.asset("noto:1f525")))

        let evicted = try library.evictUnpinnedFiles(olderThan: 90 * 24 * 3600)

        XCTAssertEqual(Set(evicted), ["noto:1f525", click.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fireFolder.path))
        XCTAssertEqual(try library.asset("noto:1f525")?.state, .remote)
        XCTAssertEqual(try library.asset("noto:1f440")?.state, .normalised)
        XCTAssertEqual(try library.asset("noto:1f680")?.state, .normalised)
        // The import file itself is untouched and can be normalised again.
        let clickAfter = try XCTUnwrap(library.asset(click.id))
        XCTAssertEqual(clickAfter.state, .original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imports.appendingPathComponent("click.wav").path))
        let again = try await library.fetch(click.id)
        XCTAssertEqual(again.state, .normalised)
        // And the evicted sticker comes back on demand.
        let fire = try await library.fetch("noto:1f525")
        XCTAssertEqual(fire.state, .normalised)
    }

    func testCatalogueRebuildsFromMetaFiles() async throws {
        let transport = try notoTransport()
        let library = try makeLibrary(transport)
        _ = await library.searchProviders(ProviderQuery(text: "rocket"), providerIDs: ["noto"])
        let fetched = try await library.fetch("noto:1f680")
        try library.catalog.delete(id: "noto:1f680")
        XCTAssertNil(try library.asset("noto:1f680"))

        XCTAssertEqual(try library.rebuildCatalogFromDisk(), 1)

        let restored = try XCTUnwrap(library.asset("noto:1f680"))
        XCTAssertEqual(restored.state, .normalised)
        XCTAssertEqual(restored.files, fetched.files)
        XCTAssertEqual(try library.licence(for: "noto:1f680")?.spdx, "CC-BY-4.0")
        XCTAssertEqual(try library.rebuildCatalogFromDisk(), 0)
    }

    func testPlacementEditCommands() async throws {
        let transport = try notoTransport()
        let library = try makeLibrary(transport)
        _ = await library.searchProviders(ProviderQuery(text: "rocket"), providerIDs: ["noto"])
        var project = Project.standard(name: "Commands")
        let placement = try await library.use("noto:1f680", in: ProjectFolder(root: tempFolder("project")), projectID: project.id)
        let item = try XCTUnwrap(placement.mediaItem)

        let first = placement.editCommands(at: Time(seconds: 2), in: project)
        XCTAssertEqual(first, [.addMedia(item: item), .placeMedia(mediaIDs: [item.id], at: Time(seconds: 2))])
        project.media.append(item)
        XCTAssertEqual(placement.editCommands(at: .zero, in: project), [.placeMedia(mediaIDs: [item.id], at: .zero)])
        var font = placement
        font.mediaItem = nil
        XCTAssertTrue(font.editCommands(at: .zero, in: project).isEmpty)
    }
}
