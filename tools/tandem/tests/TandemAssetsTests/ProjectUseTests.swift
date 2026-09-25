import XCTest
import TandemCore
import TandemMedia
@testable import TandemAssets

final class ProjectUseTests: XCTestCase {
    /// An import folder with a sound effect, a music bed and a font.
    func makeImportFolder() throws -> URL {
        let folder = tempFolder("imports")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sfx"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("music"), withIntermediateDirectories: true)
        try Generated.sineWAV(at: folder.appendingPathComponent("sfx/Whoosh_01.wav"), seconds: 0.5)
        try Generated.sineWAV(at: folder.appendingPathComponent("music/Lounge Bed.wav"), seconds: 0.6)
        return folder
    }

    func testUsingASoundEffectCopiesItAndSuggestsGain() async throws {
        let library = try makeLibrary()
        let imports = try makeImportFolder()
        try await library.addImportFolder(imports, licence: FolderLicence.presets["mixkit"])
        let project = ProjectFolder(root: tempFolder("project"))
        let sfx = try XCTUnwrap(library.search(AssetQuery(text: "whoosh")).first)

        let placement = try await library.use(sfx.id, in: project, projectID: "prj_test")

        let item = try XCTUnwrap(placement.mediaItem)
        XCTAssertEqual(item.kind, .audio)
        XCTAssertEqual(item.role, .sfx)
        XCTAssertTrue(item.hasAudio)
        XCTAssertFalse(item.hasVideo)
        XCTAssertEqual(try XCTUnwrap(item.duration).seconds, 0.5, accuracy: 0.001)
        XCTAssertTrue(item.path.hasPrefix("assets/sfx/whoosh-01-"), item.path)
        XCTAssertTrue(item.path.hasSuffix(".wav"))
        XCTAssertEqual(item.id, AssetLibrary.mediaID(for: sfx.id))
        XCTAssertEqual(placement.trackName, "SFX")
        XCTAssertEqual(placement.gainDB, -15)
        XCTAssertEqual(placement.files, [item.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.url(forPath: item.path).path))

        let usage = try library.catalog.usage(forProject: "prj_test")
        XCTAssertEqual(usage.map(\.assetID), [sfx.id])
        XCTAssertEqual(usage.first?.mediaID, item.id)
        XCTAssertEqual(usage.first?.mediaPath, item.path)
        XCTAssertEqual(try library.search(.inProject("prj_test")).map(\.id), [sfx.id])
        XCTAssertEqual(try library.search(.recentlyUsed()).map(\.id), [sfx.id])

        // Using it again reuses the same media ID and file.
        let again = try await library.use(sfx.id, in: project, projectID: "prj_test")
        XCTAssertEqual(again.mediaItem?.id, item.id)
        XCTAssertEqual(again.mediaItem?.path, item.path)
        let files = try FileManager.default.contentsOfDirectory(atPath: project.assetsFolder.appendingPathComponent("sfx").path)
        XCTAssertEqual(files.count, 1)
    }

    func testMusicGetsTheBedDefaults() async throws {
        let library = try makeLibrary()
        try await library.addImportFolder(try makeImportFolder(), licence: FolderLicence.presets["envato"])
        let bed = try XCTUnwrap(library.search(AssetQuery(text: "lounge")).first)
        XCTAssertEqual(bed.kind, .music)

        let placement = try await library.use(bed.id, in: ProjectFolder(root: tempFolder("project")), projectID: "prj_music")

        XCTAssertEqual(placement.role, .music)
        XCTAssertEqual(placement.trackName, "Music")
        XCTAssertEqual(placement.audio?.gainDB, -31)
        XCTAssertEqual(placement.audio?.fadeOut, Time(seconds: 2))
        XCTAssertTrue(placement.mediaItem?.path.hasPrefix("assets/music/lounge-bed-") == true)
    }

    func testPlacedMediaWorksWithTheEditEngine() async throws {
        // The media item goes straight into addMedia and placeMedia, and lands
        // on the track its role says.
        let transport = try notoTransport()
        let library = try makeLibrary(transport)
        _ = await library.searchProviders(ProviderQuery(text: "rocket"), providerIDs: ["noto"])
        try await library.addImportFolder(try makeImportFolder(), licence: FolderLicence.presets["mixkit"])
        let whoosh = try XCTUnwrap(library.search(AssetQuery(text: "whoosh")).first)
        let folder = ProjectFolder(root: tempFolder("project"))
        let coordinator = ProjectCoordinator(project: Project.standard(name: "Assets"))

        let sticker = try await library.use("noto:1f680", in: folder, projectID: coordinator.project.id)
        let sound = try await library.use(whoosh.id, in: folder, projectID: coordinator.project.id)
        let stickerItem = try XCTUnwrap(sticker.mediaItem)
        let soundItem = try XCTUnwrap(sound.mediaItem)
        XCTAssertEqual(stickerItem.kind, .video)
        XCTAssertEqual(stickerItem.role, .sticker)
        XCTAssertTrue(stickerItem.hasAlpha)
        XCTAssertEqual(sticker.trackName, "Graphics")

        try coordinator.apply(EditBatch(label: "Add assets", commands: [
            .addMedia(item: stickerItem),
            .addMedia(item: soundItem),
            .placeMedia(mediaIDs: [stickerItem.id], at: Time(seconds: 1)),
            .placeMedia(mediaIDs: [soundItem.id], at: Time(seconds: 1))
        ]))
        XCTAssertEqual(coordinator.project.track(named: "Graphics")?.clips.count, 1)
        XCTAssertEqual(coordinator.project.track(named: "SFX")?.clips.first?.audio?.gainDB, -15)

        let credits = try library.credits(for: coordinator.project)
        XCTAssertEqual(credits.text(), "Credits\n\(NotoEmojiProvider.creditLine)")
        XCTAssertEqual(Set(credits.assets.map(\.id)), ["noto:1f680", whoosh.id])
    }

    func testFontsAreCopiedAndRegisteredButNotPlaced() async throws {
        guard let font = Generated.systemFont() else { throw XCTSkip("no system TTF found") }
        let imports = tempFolder("fonts")
        try FileManager.default.copyItem(at: font, to: imports.appendingPathComponent("Display.ttf"))
        let library = try makeLibrary()
        try await library.addImportFolder(imports, licence: FolderLicence(source: "Test", licence: "OFL", licenceClass: .noCredit))
        let asset = try XCTUnwrap(library.search(AssetQuery(kinds: [.font])).first)

        let placement = try await library.use(asset.id, in: ProjectFolder(root: tempFolder("project")), projectID: "prj_font")

        XCTAssertNil(placement.mediaItem)
        XCTAssertEqual(placement.files.count, 1)
        XCTAssertTrue(placement.files[0].hasPrefix("assets/font/"))
        XCTAssertEqual(placement.role, .other)
        let fetched = try XCTUnwrap(library.asset(asset.id))
        XCTAssertFalse((fetched.remote["fonts"] ?? "").isEmpty)
    }

    func testSuggestionsAndFrameRates() {
        XCTAssertEqual(AssetLibrary.suggestions(for: .music).audio?.gainDB, -31)
        XCTAssertEqual(AssetLibrary.suggestions(for: .sfx).audio?.gainDB, -15)
        XCTAssertEqual(AssetLibrary.suggestions(for: .sticker).role, .sticker)
        XCTAssertEqual(AssetLibrary.suggestions(for: .overlay).role, .graphic)
        XCTAssertEqual(AssetLibrary.suggestions(for: .logo).track, "Graphics")
        XCTAssertEqual(AssetLibrary.suggestions(for: .video).role, .broll)
        XCTAssertEqual(AssetLibrary.frameRate(60), FrameRate(60))
        XCTAssertEqual(AssetLibrary.frameRate(29.97), FrameRate(30_000, 1001))
        XCTAssertEqual(AssetLibrary.frameRate(33.333), FrameRate(33_333, 1000))
    }
}

final class CreditsTests: XCTestCase {
    /// Puts an asset, its licence and one use in project "prj" into the
    /// catalogue, and returns its media item.
    func add(_ library: AssetLibrary, _ asset: Asset, licence: AssetLicence?) throws -> MediaItem {
        try library.catalog.upsert(asset)
        if let licence { try library.catalog.addLicence(licence, for: asset.id) }
        let item = MediaItem(id: AssetLibrary.mediaID(for: asset.id), path: "assets/\(asset.kind.rawValue)/\(asset.providerID).wav", kind: .audio, role: .sfx, hasAudio: true)
        try library.catalog.recordUsage(AssetUsage(assetID: asset.id, projectID: "prj", mediaID: item.id, mediaPath: item.path))
        return item
    }

    func testCreditsGroupRequiredOptionalAndWarnings() throws {
        let library = try makeLibrary()
        var media: [MediaItem] = []
        media.append(try add(library, sampleAsset(provider: "noto", id: "1f680", kind: .sticker, name: "Rocket", licence: .creditNeeded, credit: NotoEmojiProvider.creditLine),
                             licence: AssetLicence(name: "CC BY 4.0", spdx: "CC-BY-4.0", licenceClass: .creditNeeded, creditLine: NotoEmojiProvider.creditLine)))
        media.append(try add(library, sampleAsset(provider: "noto", id: "1f525", kind: .sticker, name: "Fire", licence: .creditNeeded, credit: NotoEmojiProvider.creditLine),
                             licence: AssetLicence(name: "CC BY 4.0", spdx: "CC-BY-4.0", licenceClass: .creditNeeded, creditLine: NotoEmojiProvider.creditLine)))
        media.append(try add(library, sampleAsset(provider: "freesound", id: "346373", name: "Whoosh Heavy Spear", licence: .creditNeeded),
                             licence: AssetLicence(name: "CC BY 4.0", licenceClass: .creditNeeded, creditLine: "\"Whoosh Heavy Spear\" by denao270, CC BY 4.0")))
        media.append(try add(library, sampleAsset(provider: "pexels", id: "video-1", kind: .video, name: "Servers", licence: .noCredit),
                             licence: AssetLicence(name: "Pexels License", licenceClass: .noCredit, creditLine: "Video by Brett Sayles on Pexels")))
        media.append(try add(library, sampleAsset(provider: "import", id: "envato/a.wav", name: "Riser", licence: .subscription),
                             licence: AssetLicence(name: "Envato Elements licence", licenceClass: .subscription, holder: "Envato Elements", notes: "Register each video on Envato.")))
        media.append(try add(library, sampleAsset(provider: "import", id: "misc/b.wav", name: "Mystery hit", licence: .unknown), licence: nil))
        media.append(try add(library, sampleAsset(provider: "import", id: "yt/c.wav", name: "Track needing credit", licence: .creditNeeded),
                             licence: AssetLicence(name: "YouTube Audio Library licence", licenceClass: .creditNeeded)))
        media.append(try add(library, sampleAsset(provider: "elevenlabs", id: "sfx_1", name: "Generated click", licence: .aiGenerated),
                             licence: AssetLicence(name: "ElevenLabs Terms", licenceClass: .aiGenerated)))
        // Used once but since removed from the project: no credit needed.
        _ = try add(library, sampleAsset(provider: "freesound", id: "999", name: "Removed", licence: .creditNeeded),
                    licence: AssetLicence(name: "CC BY 4.0", licenceClass: .creditNeeded, creditLine: "\"Removed\" by someone, CC BY 4.0"))
        var project = Project.standard(name: "Credits")
        project.id = "prj"
        project.media = media

        let credits = try library.credits(for: project)

        XCTAssertEqual(credits.entries.map(\.line), [
            NotoEmojiProvider.creditLine,
            "\"Whoosh Heavy Spear\" by denao270, CC BY 4.0",
            "Video by Brett Sayles on Pexels"
        ])
        XCTAssertEqual(credits.entries[0].assetNames, ["Rocket", "Fire"])
        XCTAssertEqual(credits.entries.map(\.required), [true, true, false])
        XCTAssertEqual(credits.assets.count, 8)
        XCTAssertEqual(credits.text(), """
        Credits
        \(NotoEmojiProvider.creditLine)
        "Whoosh Heavy Spear" by denao270, CC BY 4.0
        """)
        XCTAssertEqual(credits.text(includeOptional: true), """
        Credits
        \(NotoEmojiProvider.creditLine)
        "Whoosh Heavy Spear" by denao270, CC BY 4.0

        Thanks to
        Video by Brett Sayles on Pexels
        """)
        XCTAssertEqual(credits.warnings.count, 3)
        XCTAssertTrue(credits.warnings[0].contains("\"Mystery hit\""))
        XCTAssertTrue(credits.warnings[1].contains("\"Track needing credit\""))
        XCTAssertEqual(credits.warnings[2], "1 asset from Envato Elements. Register each video on Envato.")
    }

    func testNothingToCreditIsEmpty() throws {
        let library = try makeLibrary()
        var project = Project.standard(name: "Empty")
        project.id = "prj_none"
        let credits = try library.credits(for: project)
        XCTAssertEqual(credits.text(), "")
        XCTAssertTrue(credits.entries.isEmpty)
        XCTAssertTrue(credits.warnings.isEmpty)
    }

    func testCreditsSurviveTheAssetRowGoing() throws {
        // The licence snapshot keeps the credit even if the catalogue row
        // was deleted (an import file removed after use).
        let library = try makeLibrary()
        let item = try add(library, sampleAsset(provider: "import", id: "gone.wav", name: "Gone", licence: .creditNeeded),
                           licence: AssetLicence(name: "CC BY 4.0", licenceClass: .creditNeeded, creditLine: "Gone by someone, CC BY 4.0"))
        try library.catalog.delete(id: "import:gone.wav")
        var project = Project.standard(name: "x")
        project.id = "prj"
        project.media = [item]
        XCTAssertEqual(try library.credits(for: project).text(), "Credits\nGone by someone, CC BY 4.0")
    }
}

final class ImportFolderTests: XCTestCase {
    func testScanIndexesMediaWithTheFolderLicence() async throws {
        let folder = tempFolder("envato")
        let fileManager = FileManager.default
        for sub in ["sfx/whooshes", "music", "stickers", "logos"] {
            try fileManager.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Generated.sineWAV(at: folder.appendingPathComponent("sfx/whooshes/Fast_Whoosh.wav"), seconds: 0.3)
        try Generated.sineWAV(at: folder.appendingPathComponent("music/Chill Bed.wav"), seconds: 1)
        try Generated.animatedGIF(at: folder.appendingPathComponent("stickers/party.gif"))
        try Generated.svg(at: folder.appendingPathComponent("logos/brand.svg"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        let library = try makeLibrary()

        let report = try await library.addImportFolder(folder, name: "Envato", licence: FolderLicence.presets["envato"])

        XCTAssertEqual(report.added, 4)
        XCTAssertEqual(report.skipped, ["readme.txt"])
        XCTAssertFalse(report.missingLicence)
        XCTAssertTrue(fileManager.fileExists(atPath: folder.appendingPathComponent(FolderLicence.fileName).path))
        let assets = try library.search(AssetQuery(providers: ["import"]))
        func kind(_ text: String) throws -> AssetKind? { try library.search(AssetQuery(text: text, providers: ["import"])).first?.kind }
        XCTAssertEqual(assets.count, 4)
        XCTAssertEqual(try kind("fast whoosh"), .sfx)
        XCTAssertEqual(try kind("chill bed"), .music)
        XCTAssertEqual(try kind("party"), .sticker)
        XCTAssertEqual(try kind("brand"), .logo)
        XCTAssertTrue(assets.allSatisfy { $0.licenceClass == .subscription && $0.state == .original })
        let whoosh = try XCTUnwrap(library.search(AssetQuery(text: "whooshes")).first)
        XCTAssertEqual(try XCTUnwrap(whoosh.duration), 0.3, accuracy: 0.01)
        XCTAssertTrue(whoosh.tags.contains("sfx"))
        XCTAssertEqual(try library.importFolders().map(\.name), ["Envato"])

        // Using it normalises into the library and snapshots the note.
        let fetched = try await library.fetch(whoosh.id)
        XCTAssertEqual(fetched.state, .normalised)
        XCTAssertTrue(fetched.files.folder?.hasPrefix("import/") == true)
        XCTAssertEqual(fetched.files.original, folder.appendingPathComponent("sfx/whooshes/Fast_Whoosh.wav").standardizedFileURL.path)
        let licence = try XCTUnwrap(library.licence(for: whoosh.id))
        XCTAssertEqual(licence.name, "Envato Elements licence")
        XCTAssertEqual(licence.licenceClass, .subscription)
        XCTAssertTrue(licence.text?.contains("Envato Elements") == true)
    }

    func testRescanNoticesChangesAndRemovals() async throws {
        let folder = tempFolder("mixkit")
        try Generated.sineWAV(at: folder.appendingPathComponent("click.wav"), seconds: 0.2)
        try Generated.sineWAV(at: folder.appendingPathComponent("pop.wav"), seconds: 0.2)
        try Generated.sineWAV(at: folder.appendingPathComponent("kept.wav"), seconds: 0.2)
        let library = try makeLibrary()
        try await library.addImportFolder(folder)
        let kept = try XCTUnwrap(library.search(AssetQuery(text: "kept")).first)
        try library.catalog.recordUsage(AssetUsage(assetID: kept.id, projectID: "prj"))

        var reports = try await library.rescanImportFolders()
        XCTAssertEqual(reports.first?.unchanged, 3)
        XCTAssertEqual(reports.first?.missingLicence, true)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("pop.wav"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("kept.wav"))
        try Generated.sineWAV(at: folder.appendingPathComponent("click.wav"), seconds: 0.4)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: folder.appendingPathComponent("click.wav").path)
        try Generated.sineWAV(at: folder.appendingPathComponent("new.wav"), seconds: 0.2)

        reports = try await library.rescanImportFolders()
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.removed, 2)
        XCTAssertNil(try library.search(AssetQuery(text: "pop")).first)
        // A used asset stays, marked missing, so its credits survive.
        let stillThere = try XCTUnwrap(library.asset(kept.id))
        XCTAssertEqual(stillThere.remote["missing"], "1")
        XCTAssertEqual(stillThere.state, .remote)
        let click = try XCTUnwrap(library.search(AssetQuery(text: "click")).first)
        XCTAssertEqual(try XCTUnwrap(click.duration), 0.4, accuracy: 0.01)
        // Without a note, the licence is unknown and says what to do.
        XCTAssertEqual(click.licenceClass, .unknown)
        let licence = try await library.provider("import")!.licence(for: click)
        XCTAssertEqual(licence.licenceClass, .unknown)
        XCTAssertTrue(licence.notes?.contains(FolderLicence.fileName) == true)
    }

    func testRemovingAFolderKeepsUsedAssets() async throws {
        let folder = tempFolder("remove")
        try Generated.sineWAV(at: folder.appendingPathComponent("a.wav"), seconds: 0.2)
        try Generated.sineWAV(at: folder.appendingPathComponent("b.wav"), seconds: 0.2)
        let library = try makeLibrary()
        try await library.addImportFolder(folder)
        let record = try XCTUnwrap(library.importFolders().first)
        let used = try XCTUnwrap(library.search(AssetQuery(text: "a", providers: ["import"])).first { $0.name == "A" })
        try library.setFavourite(used.id, true)
        try library.removeImportFolder(record.id)
        XCTAssertEqual(try library.importFolders().count, 0)
        XCTAssertEqual(try library.search(AssetQuery(providers: ["import"])).map(\.id), [used.id])
    }

    func testFolderLicenceDecodesLenientlyAndPresetsAreSensible() throws {
        let note = try JSONDecoder().decode(FolderLicence.self, from: Data(#"{"source": "Sonniss", "licenceClass": "noCredit"}"#.utf8))
        XCTAssertEqual(note.source, "Sonniss")
        XCTAssertEqual(note.licence, "Unknown licence")
        XCTAssertEqual(note.licenceClass, .noCredit)
        XCTAssertEqual(FolderLicence.presets["envato"]?.licenceClass, .subscription)
        XCTAssertEqual(FolderLicence.presets["mixkit"]?.licenceClass, .noCredit)
        XCTAssertEqual(FolderLicence.presets["sonniss"]?.kind, .sfx)
        XCTAssertEqual(ImportFolderProvider.audioKind(path: "packs/music/x.wav", duration: 5), .music)
        XCTAssertEqual(ImportFolderProvider.audioKind(path: "packs/ui/long.wav", duration: 90), .sfx)
        XCTAssertEqual(ImportFolderProvider.audioKind(path: "packs/x.wav", duration: 90), .music)
        XCTAssertEqual(ImportFolderProvider.audioKind(path: "packs/x.wav", duration: 2), .sfx)
    }

    func testWatcherReportsChanges() async throws {
        let folder = tempFolder("watched")
        let library = try makeLibrary()
        try await library.addImportFolder(folder)
        let expectation = expectation(description: "rescanned after a new file")
        let fulfilled = LockedFlag()
        let watcher = try library.watchImportFolders { reports in
            if reports.contains(where: { $0.added > 0 }), fulfilled.setOnce() { expectation.fulfill() }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        try Generated.sineWAV(at: folder.appendingPathComponent("arrived.wav"), seconds: 0.2)
        await fulfillment(of: [expectation], timeout: 15)
        watcher.stop()
        XCTAssertEqual(try library.search(AssetQuery(text: "arrived")).count, 1)
    }
}

/// True the first time `setOnce` is called.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if set { return false }
        set = true
        return true
    }
}
