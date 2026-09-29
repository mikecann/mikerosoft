import XCTest
import TandemCore
import TandemMedia
@testable import TandemAssets

/// The shared library folder (`~/Movies/Tandem Library` for real; a temp
/// folder here): made with friendly folders, watched, indexed by folder,
/// and used where it is.
final class SharedLibraryTests: XCTestCase {
    /// A library in a temp folder with its shared folder made.
    func makeShared(settings: AssetSettings = AssetSettings()) throws -> (AssetLibrary, SharedLibrary) {
        let library = try makeLibrary(settings: settings)
        let shared = library.sharedLibrary
        XCTAssertFalse(shared.exists, "opening the library never makes the folder")
        try library.createSharedLibrary()
        return (library, shared)
    }

    /// A path in the library, its folder made.
    func file(_ shared: SharedLibrary, _ path: String) -> URL {
        let url = shared.root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    func testItsMadeWithFriendlyFoldersAndReadmesThatStayAsMikeLeavesThem() throws {
        let (library, shared) = try makeShared()
        let names = try FileManager.default.contentsOfDirectory(atPath: shared.root.path).sorted()
        XCTAssertEqual(names, ["Fonts", "Graphics", "Looks", "Music", "README.txt", "Segments", "Sound effects", "Stickers"])
        for folder in SharedLibrary.Folder.allCases {
            let readme = try String(contentsOf: shared.url(folder).appendingPathComponent("README.txt"), encoding: .utf8)
            XCTAssertTrue(readme.hasPrefix(folder.rawValue), readme)
            XCTAssertFalse(readme.contains("\u{2014}"), "no long dashes")
        }
        // An edited README survives making it again.
        let readme = file(shared, "Stickers/README.txt")
        try Data("mine".utf8).write(to: readme)
        XCTAssertEqual(try library.createSharedLibrary(), [])
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), "mine")
    }

    func testWhereItIs() throws {
        let temp = tempFolder("where")
        XCTAssertEqual(SharedLibrary.root(for: AssetSettings(), assetsRoot: AssetLibrary.defaultRoot), SharedLibrary.standardRoot)
        XCTAssertTrue(SharedLibrary.standardRoot.path.hasSuffix("/Movies/Tandem Library"))
        // Any other asset library (tests, $TANDEM_ASSETS_ROOT) keeps its own.
        XCTAssertEqual(SharedLibrary.root(for: AssetSettings(), assetsRoot: temp).path, temp.appendingPathComponent("Tandem Library").path)
        XCTAssertEqual(SharedLibrary.root(for: AssetSettings(sharedLibrary: "/Volumes/Work/Library"), assetsRoot: temp).path, "/Volumes/Work/Library")
        XCTAssertEqual(SharedLibrary.root(for: AssetSettings(sharedLibrary: "~/Shared"), assetsRoot: temp).path, NSHomeDirectory() + "/Shared")

        XCTAssertEqual(SharedLibrary.locate(environment: ["TANDEM_LIBRARY": temp.appendingPathComponent("lib").path]).root.path, temp.appendingPathComponent("lib").standardizedFileURL.path)
        XCTAssertEqual(SharedLibrary.locate(environment: ["TANDEM_ASSETS_ROOT": temp.path]).root.path, temp.appendingPathComponent("Tandem Library").standardizedFileURL.path)
        try AssetSettings(sharedLibrary: temp.appendingPathComponent("moved").path).save(to: temp)
        XCTAssertEqual(SharedLibrary.locate(environment: ["TANDEM_ASSETS_ROOT": temp.path]).root.path, temp.appendingPathComponent("moved").path)
        // The settings file keeps what it had.
        XCTAssertEqual(AssetSettings.load(from: temp).sharedLibrary, temp.appendingPathComponent("moved").path)
    }

    func testFilesDroppedInAreIndexedByTheirFolder() async throws {
        let (library, shared) = try makeShared()
        try Generated.sineWAV(at: file(shared, "Sound effects/Whoosh.wav"), seconds: 0.3)
        // Long for a sound effect, but it's in Music.
        try Generated.sineWAV(at: file(shared, "Music/Sting.wav"), seconds: 0.4)
        try Generated.animatedGIF(at: file(shared, "Stickers/Party/Dance.gif"))
        try Generated.svg(at: file(shared, "Graphics/Convex logo.svg"))
        try Generated.animatedGIF(at: file(shared, "Graphics/Lower third.gif"))
        try Data("TITLE Warm\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8).write(to: file(shared, "Looks/Warm.cube"))
        try FileManager.default.createDirectory(at: file(shared, "Segments/Intro"), withIntermediateDirectories: true)
        try Generated.sineWAV(at: file(shared, "Segments/Intro/sting.wav"), seconds: 0.2)

        let scanned = try await library.rescanSharedLibrary()
        let report = try XCTUnwrap(scanned)
        XCTAssertEqual(report.added, 6)
        XCTAssertEqual(report.skipped, [], "READMEs and segments aren't listed")
        let assets = try library.search(AssetQuery(providers: ["shared"]))
        let kinds = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.kind) })
        XCTAssertEqual(kinds, [
            "shared:Sound effects/Whoosh.wav": .sfx,
            "shared:Music/Sting.wav": .music,
            "shared:Stickers/Party/Dance.gif": .sticker,
            "shared:Graphics/Convex logo.svg": .logo,
            "shared:Graphics/Lower third.gif": .overlay,
            "shared:Looks/Warm.cube": .lut
        ])
        XCTAssertTrue(try XCTUnwrap(library.asset("shared:Stickers/Party/Dance.gif")).tags.contains("Party"))
        XCTAssertEqual(try library.asset("shared:Music/Sting.wav")?.files.original, file(shared, "Music/Sting.wav").standardizedFileURL.path)
        // Searchable like everything else, under the Shared library chip.
        XCTAssertEqual(try library.search(AssetQuery(text: "whoosh")).map(\.id), ["shared:Sound effects/Whoosh.wav"])
        let info = await library.providerInfo()
        XCTAssertEqual(info.first?.id, "shared")
        XCTAssertEqual(info.first?.displayName, "Shared library")
        let again = try await library.rescanSharedLibrary()
        XCTAssertEqual(again?.unchanged, 6)
    }

    func testTheNearestLicenceNoteCoversAFile() async throws {
        let (library, shared) = try makeShared()
        try Generated.sineWAV(at: file(shared, "Sound effects/Mine/Pop.wav"), seconds: 0.2)
        try Generated.sineWAV(at: file(shared, "Sound effects/Envato/Hit.wav"), seconds: 0.2)
        try Generated.sineWAV(at: file(shared, "Music/Bed.wav"), seconds: 0.2)
        try FolderLicence(source: "Mike", licence: "Own work", licenceClass: .noCredit).write(in: shared.root)
        try FolderLicence.presets["envato"]!.write(in: file(shared, "Sound effects/Envato"))

        try await library.rescanSharedLibrary()
        XCTAssertEqual(try library.asset("shared:Sound effects/Mine/Pop.wav")?.licenceClass, .noCredit)
        XCTAssertEqual(try library.asset("shared:Sound effects/Envato/Hit.wav")?.licenceClass, .subscription)
        XCTAssertEqual(try library.asset("shared:Music/Bed.wav")?.licenceClass, .noCredit)
        let hit = try XCTUnwrap(library.asset("shared:Sound effects/Envato/Hit.wav"))
        let licence = try await library.sharedProvider!.licence(for: hit)
        XCTAssertEqual(licence.name, "Envato Elements licence")

        // A note added lower down later relicenses what's under it.
        try FolderLicence(source: "Pixabay", licence: "Pixabay Content License", licenceClass: .noCredit, credit: "Music from Pixabay").write(in: file(shared, "Music"))
        let rescanned = try await library.rescanSharedLibrary()
        let report = try XCTUnwrap(rescanned)
        XCTAssertEqual(report.relicensed, 1)
        XCTAssertEqual(try library.asset("shared:Music/Bed.wav")?.creditLine, "Music from Pixabay")
    }

    func testWatchingPicksUpNewFiles() async throws {
        let (library, shared) = try makeShared()
        let arrived = expectation(description: "a new sound was indexed")
        let fulfilled = LockedFlag()
        let watcher = try XCTUnwrap(library.watchSharedLibrary { report in
            if report.added > 0, fulfilled.setOnce() { arrived.fulfill() }
        })
        try await Task.sleep(nanoseconds: 300_000_000)
        try Generated.sineWAV(at: file(shared, "Sound effects/Arrived.wav"), seconds: 0.2)
        await fulfillment(of: [arrived], timeout: 15)
        watcher.stop()
        XCTAssertEqual(try library.search(AssetQuery(text: "arrived", providers: ["shared"])).count, 1)
    }

    func testNoFolderNoWatcherAndNoScan() async throws {
        let library = try makeLibrary()
        XCTAssertNil(library.watchSharedLibrary { _ in })
        let report = try await library.rescanSharedLibrary()
        XCTAssertNil(report)
        XCTAssertFalse(library.sharedLibrary.exists, "nothing made it")
    }

    func testUsingASharedFileReferencesItWhereItIs() async throws {
        let (library, shared) = try makeShared()
        // 44.1 kHz, so an import folder's copy would be a 48 kHz WAV.
        try Generated.sineWAV(at: file(shared, "Sound effects/Whoosh.wav"), seconds: 0.5)
        try Data("TITLE Warm\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8).write(to: file(shared, "Looks/Warm.cube"))
        try await library.rescanSharedLibrary()
        let project = ProjectFolder(root: tempFolder("project"))

        let placement = try await library.use("shared:Sound effects/Whoosh.wav", in: project, projectID: "prj_shared")
        let item = try XCTUnwrap(placement.mediaItem)
        XCTAssertTrue(placement.referencedInPlace)
        XCTAssertEqual(item.path, file(shared, "Sound effects/Whoosh.wav").standardizedFileURL.path, "the file where it is")
        XCTAssertEqual(placement.files, [item.path])
        XCTAssertEqual(placement.trackName, "SFX")
        XCTAssertEqual(placement.gainDB, -15)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.assetsFolder.path), "nothing copied into the project")
        let fetched = try XCTUnwrap(library.asset("shared:Sound effects/Whoosh.wav"))
        XCTAssertEqual(fetched.state, .normalised)
        XCTAssertNil(fetched.files.normalised, "no 48 kHz copy of a file used where it is")
        XCTAssertNotNil(fetched.loudness)
        XCTAssertNotNil(library.waveform(for: fetched))
        let usage = try library.catalog.usage(forProject: "prj_shared")
        XCTAssertEqual(usage.first?.mediaPath, item.path)
        XCTAssertEqual(try library.credits(for: Project(id: "prj_shared", name: "x", media: [item])).assets.map(\.id), ["shared:Sound effects/Whoosh.wav"])

        let look = try await library.use("shared:Looks/Warm.cube", in: project, projectID: "prj_shared")
        XCTAssertNil(look.mediaItem)
        XCTAssertEqual(look.files, [file(shared, "Looks/Warm.cube").standardizedFileURL.path])

        // Import folders still copy.
        let imports = tempFolder("imports")
        try Generated.sineWAV(at: imports.appendingPathComponent("Click.wav"), seconds: 0.2)
        try await library.addImportFolder(imports)
        let click = try XCTUnwrap(library.search(AssetQuery(text: "click", providers: ["import"])).first)
        let copied = try await library.use(click.id, in: project, projectID: "prj_shared")
        XCTAssertFalse(copied.referencedInPlace)
        XCTAssertTrue(copied.mediaItem?.path.hasPrefix("assets/sfx/") == true)
    }

    /// A sticker a project can't play as it is plays from the library's
    /// converted copy; changing the sticker converts it again in place, so
    /// the project follows.
    func testAConvertedStickerIsMadeAgainWhenItChanges() async throws {
        let (library, shared) = try makeShared()
        let gif = file(shared, "Stickers/Spin.gif")
        try Generated.animatedGIF(at: gif, frames: 6)
        try await library.rescanSharedLibrary()
        let project = ProjectFolder(root: tempFolder("project"))
        let placement = try await library.use("shared:Stickers/Spin.gif", in: project, projectID: "prj_sticker")
        let path = try XCTUnwrap(placement.mediaItem?.path)
        XCTAssertTrue(path.hasSuffix("/normalised.mov"), path)
        XCTAssertEqual(placement.mediaItem?.kind, .video)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        try Generated.animatedGIF(at: gif, size: 96, frames: 12)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: gif.path)
        let rescanned = try await library.rescanSharedLibrary()
        let report = try XCTUnwrap(rescanned)
        XCTAssertEqual(report.updatedIDs, ["shared:Stickers/Spin.gif"])
        let refreshed = await library.refreshChangedSharedFiles(report)
        XCTAssertEqual(refreshed, ["shared:Stickers/Spin.gif"])
        XCTAssertNotEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "the same path, the new sticker")
        XCTAssertEqual(library.playableURL(for: try XCTUnwrap(library.asset("shared:Stickers/Spin.gif")))?.path, path)
    }

    func testMovingTheLibraryPointsItsFilesAtTheNewFolder() async throws {
        let (library, shared) = try makeShared()
        try Generated.sineWAV(at: file(shared, "Sound effects/Kept.wav"), seconds: 0.2)
        try Generated.sineWAV(at: file(shared, "Sound effects/Left.wav"), seconds: 0.2)
        try await library.rescanSharedLibrary()

        let moved = tempFolder("moved").appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: moved.appendingPathComponent("Sound effects"), withIntermediateDirectories: true)
        // Copied across with its date, as Finder does.
        try FileManager.default.copyItem(at: file(shared, "Sound effects/Kept.wav"), to: moved.appendingPathComponent("Sound effects/Kept.wav"))
        let movedScan = try await library.moveSharedLibrary(to: moved)
        let report = try XCTUnwrap(movedScan)
        XCTAssertEqual(report.removed, 1)
        XCTAssertEqual(library.sharedLibrary.root.path, moved.standardizedFileURL.path)
        XCTAssertEqual(library.settings.sharedLibrary, moved.standardizedFileURL.path)
        XCTAssertEqual(AssetSettings.load(from: library.root).sharedLibrary, moved.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Segments/README.txt").path), "made with its folders")
        XCTAssertEqual(try library.asset("shared:Sound effects/Kept.wav")?.files.original, moved.appendingPathComponent("Sound effects/Kept.wav").standardizedFileURL.path)
        XCTAssertNil(try library.asset("shared:Sound effects/Left.wav"))

        // Back to the default.
        try await library.moveSharedLibrary(to: nil)
        XCTAssertEqual(library.sharedLibrary.root.path, library.root.appendingPathComponent("Tandem Library").standardizedFileURL.path)
        XCTAssertNil(AssetSettings.load(from: library.root).sharedLibrary)
    }

    func testSharedOriginalsStayWhenFilesAreEvictedAndCantBeRemoved() async throws {
        let (library, shared) = try makeShared()
        try Generated.sineWAV(at: file(shared, "Music/Bed.wav"), seconds: 0.2)
        try await library.rescanSharedLibrary()
        var bed = try await library.fetch("shared:Music/Bed.wav")
        bed.updatedAt = Date(timeIntervalSinceNow: -365 * 24 * 3600)
        try library.catalog.upsert(bed)
        XCTAssertEqual(try library.evictUnpinnedFiles(), ["shared:Music/Bed.wav"])
        XCTAssertEqual(try library.asset("shared:Music/Bed.wav")?.files.original, file(shared, "Music/Bed.wav").standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file(shared, "Music/Bed.wav").path))
        XCTAssertThrowsError(try library.remove("shared:Music/Bed.wav"))
    }

    /// A saved segment's clips name the library assets they came from, so
    /// the credits of a video the segment goes into list them.
    func testCreditsFollowAssetTagsOnClips() async throws {
        let (library, shared) = try makeShared()
        try Generated.sineWAV(at: file(shared, "Music/Sting.wav"), seconds: 0.2)
        try FolderLicence(source: "Test Sounds", licence: "CC BY 4.0", licenceClass: .creditNeeded, credit: "Sting by Test Sounds (CC BY 4.0)").write(in: file(shared, "Music"))
        try await library.rescanSharedLibrary()
        var project = Project(id: "prj_tags", name: "Tagged")
        // What matters is the tag, whatever the clip is.
        project.videoTracks = [Track(id: "trk_text", kind: .video, name: "Text", clips: [
            Clip(id: "clip_title", content: .text(TextContent(text: "Intro")), start: .zero, duration: Time(seconds: 1), tags: ["template:segment:Intro", "asset:shared:Music/Sting.wav"])
        ])]
        let credits = try library.credits(for: project)
        XCTAssertEqual(credits.entries.map(\.line), ["Sting by Test Sounds (CC BY 4.0)"])
        project.videoTracks[0].clips = []
        XCTAssertEqual(try library.credits(for: project).entries, [], "gone with its clip")
    }

    func testSharedFontsAreFoundForRegistering() throws {
        guard let font = Generated.systemFont() else { throw XCTSkip("no system TTF found") }
        let (library, shared) = try makeShared()
        try FileManager.default.copyItem(at: font, to: file(shared, "Fonts/Face.ttf"))
        XCTAssertEqual(library.sharedFontFiles().map(\.lastPathComponent), ["Face.ttf"])
    }

    func testPathsInsideTheLibraryFollowLinks() throws {
        let (_, shared) = try makeShared()
        let link = tempFolder("links").appendingPathComponent("Linked library")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared.root)
        XCTAssertEqual(shared.relativePath(of: shared.root.appendingPathComponent("Stickers/a.mov")), "Stickers/a.mov")
        XCTAssertEqual(shared.relativePath(of: link.appendingPathComponent("Stickers/README.txt")), "Stickers/README.txt")
        XCTAssertEqual(SharedLibrary(root: link).relativePath(of: shared.root.appendingPathComponent("Looks/README.txt")), "Looks/README.txt")
        XCTAssertNil(shared.relativePath(of: URL(fileURLWithPath: "/tmp/elsewhere.mov")))
        XCTAssertEqual(SharedLibrary.Folder.of("sound effects/x.wav"), .soundEffects)
        XCTAssertNil(SharedLibrary.Folder.of("Other/x.wav"))
    }
}
