import XCTest
@testable import TandemApp
@testable import TandemCore
import TandemMedia

final class FileImportTests: XCTestCase {
    private var root: URL!
    private var project: URL { root.appendingPathComponent("talk", isDirectory: true) }
    private var outside: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    private var folder: ProjectFolder { ProjectFolder(root: project) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: project.appendingPathComponent("broll"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func file(_ url: URL, _ contents: String = "data") throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testFoldersAreSearchedAndOtherFilesSkipped() throws {
        let dropped = outside.appendingPathComponent("shoot", isDirectory: true)
        try file(dropped.appendingPathComponent("a.mov"))
        try file(dropped.appendingPathComponent("notes.txt"))
        try file(dropped.appendingPathComponent(".hidden.mov"))
        try file(dropped.appendingPathComponent("sub/c.MP3"))
        let single = try file(outside.appendingPathComponent("b.png"))
        let files = FileImport.mediaFiles(in: [dropped, single, single])
        XCTAssertEqual(files.map(\.lastPathComponent), ["a.mov", "c.MP3", "b.png"])
    }

    func testFilesAreUsedWhereTheyAreOrBroughtIn() throws {
        let inside = try file(project.appendingPathComponent("broll/servers.mp4"))
        let video = try file(outside.appendingPathComponent("drone.mov"))
        let image = try file(outside.appendingPathComponent("diagram.png"))
        let sound = try file(outside.appendingPathComponent("whoosh.wav"))
        let plan = FileImport.plan([inside, video, image, sound], folder: folder) { _ in true }
        XCTAssertEqual(plan.map(\.destination), ["broll/servers.mp4", "broll/drone.mov", "graphics/diagram.png", "audio/whoosh.wav"])
        XCTAssertEqual(plan.map(\.action), [.inPlace, .copy, .copy, .copy])
    }

    func testAnotherDiskGetsALink() throws {
        let video = try file(outside.appendingPathComponent("interview.mov"))
        let plan = FileImport.plan([video], folder: folder) { _ in false }
        XCTAssertEqual(plan.first?.destination, "linked-media/interview.mov")
        XCTAssertEqual(plan.first?.action, .link)
    }

    func testNamesDontClobberOtherFiles() throws {
        try file(project.appendingPathComponent("broll/drone.mov"), "something else")
        try file(project.appendingPathComponent("broll/drone 2.mov"), "and another")
        let video = try file(outside.appendingPathComponent("drone.mov"), "the new one")
        XCTAssertEqual(FileImport.plan([video], folder: folder) { _ in true }.first?.destination, "broll/drone 3.mov")
        // The same file dropped again isn't copied twice.
        try file(project.appendingPathComponent("broll/drone 3.mov"), "the new one")
        let again = FileImport.plan([video], folder: folder) { _ in true }.first
        XCTAssertEqual(again?.destination, "broll/drone 3.mov")
        XCTAssertEqual(again?.action, .inPlace)
    }

    func testPerformingCopiesAndLinks() throws {
        let video = try file(outside.appendingPathComponent("drone.mov"), "frames")
        let far = try file(outside.appendingPathComponent("far.mov"), "far frames")
        let plan = [
            FileImportPlan(source: video, destination: "broll/drone.mov", action: .copy),
            FileImportPlan(source: far, destination: "linked-media/far.mov", action: .link)
        ]
        let placed = try FileImport.perform(plan, folder: folder)
        XCTAssertEqual(placed.map { folder.path(for: $0) }, ["broll/drone.mov", "linked-media/far.mov"])
        XCTAssertEqual(try String(contentsOf: placed[0], encoding: .utf8), "frames")
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: placed[1].path)
        XCTAssertEqual(URL(fileURLWithPath: link).standardizedFileURL, far)
        // The scanner finds both, as refreshMedia would.
        XCTAssertEqual(Set(MediaScanner.mediaFiles(in: folder).map { folder.path(for: $0) }), ["broll/drone.mov", "linked-media/far.mov"])
    }

    func testTheEditAddsNewMediaAndPlacesFilesInTurn() throws {
        var project = Project.standard(name: "Import")
        project.media = [MediaItem(id: "med_known", path: "broll/servers.mp4", kind: .video, role: .broll, duration: t(3), hasVideo: true)]
        let items = [
            MediaItem(id: "med_new", path: "broll/drone.mov", kind: .video, role: .broll, duration: t(4), hasVideo: true),
            MediaItem(id: "med_again", path: "broll/servers.mp4", kind: .video, role: .broll, duration: t(3), hasVideo: true),
            MediaItem(id: "med_png", path: "graphics/diagram.png", kind: .image, role: .graphic, hasVideo: true)
        ]
        let batch = try XCTUnwrap(FileImport.batch(items, into: project, at: t(10), trackID: nil))
        XCTAssertEqual(batch.label, "Add 3 files")
        let added = batch.commands.compactMap { command -> String? in
            if case .addMedia(let item) = command { return item.id }
            return nil
        }
        XCTAssertEqual(added, ["med_new", "med_png"], "the file already in the project isn't added twice")
        let placed = batch.commands.compactMap { command -> (String, Time)? in
            if case .placeMedia(let ids, let at, _, _, _, _, _, _) = command { return (ids[0], at) }
            return nil
        }
        XCTAssertEqual(placed.map(\.0), ["med_new", "med_known", "med_png"])
        XCTAssertEqual(placed.map(\.1), [t(10), t(14), t(17)], "one after another; a still takes 5 s")

        let coordinator = ProjectCoordinator(project: project)
        XCTAssertNoThrow(try coordinator.apply(batch))
        assertValid(coordinator.project)

        let justAdd = try XCTUnwrap(FileImport.batch(items, into: project, at: nil, trackID: nil))
        // Finder and the scanner can spell an accented name differently.
        let decomposed = MediaItem(id: "med_nfd", path: "broll/cafe\u{301}.mov", kind: .video, role: .broll, duration: t(2), hasVideo: true)
        let composed = MediaItem(id: "med_nfc", path: "broll/caf\u{e9}.mov", kind: .video, role: .broll, duration: t(2), hasVideo: true)
        var accented = project
        accented.media.append(decomposed)
        XCTAssertNil(FileImport.batch([composed], into: accented, folder: folder, at: nil, trackID: nil), "the same file isn't added twice")
        XCTAssertEqual(justAdd.label, "Add 2 files to the media")
        XCTAssertFalse(justAdd.commands.contains { if case .placeMedia = $0 { return true } else { return false } })
        XCTAssertNil(FileImport.batch([items[1]], into: project, at: nil, trackID: nil), "nothing new to add")
    }

    /// Files from Finder dropped above the tracks get a new video track,
    /// like library media. A file with no picture can't go there, so it's
    /// placed as usual.
    func testFilesDroppedAboveTheTracksGoOnANewVideoTrack() throws {
        let project = Project.standard(name: "Import")
        let items = [
            MediaItem(id: "med_drone", path: "broll/drone.mov", kind: .video, role: .broll, duration: t(4), hasVideo: true),
            MediaItem(id: "med_whoosh", path: "audio/whoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true),
            MediaItem(id: "med_png", path: "graphics/diagram.png", kind: .image, role: .graphic, hasVideo: true)
        ]
        let batch = try XCTUnwrap(FileImport.batch(items, into: project, at: t(10), trackID: nil, newTrack: (.video, "trk_new")))
        XCTAssertEqual(batch.label, "Add 3 files on a new video track")
        let coordinator = ProjectCoordinator(project: project)
        _ = try coordinator.apply(batch)
        assertValid(coordinator.project)
        let result = coordinator.project
        XCTAssertEqual(result.videoTracks.count, project.videoTracks.count + 1)
        XCTAssertEqual(result.videoTracks.last?.id, "trk_new", "on top of the video tracks")
        let onNew = result.track("trk_new")?.clips ?? []
        XCTAssertEqual(onNew.map(\.mediaID), ["med_drone", "med_png"])
        XCTAssertEqual(onNew.map(\.start), [t(10), t(15)], "one after another, the sound's second still counted")
        XCTAssertTrue(result.audioTracks.flatMap(\.clips).contains { $0.mediaID == "med_whoosh" }, "the sound is placed as usual")
    }

    func testSoundDroppedBelowTheTracksGoesOnANewAudioTrack() throws {
        let project = Project.standard(name: "Import")
        let items = [MediaItem(id: "med_whoosh", path: "audio/whoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)]
        let batch = try XCTUnwrap(FileImport.batch(items, into: project, at: t(3), trackID: nil, newTrack: (.audio, "trk_sound")))
        let coordinator = ProjectCoordinator(project: project)
        _ = try coordinator.apply(batch)
        XCTAssertEqual(coordinator.project.audioTracks.last?.id, "trk_sound", "below the other audio tracks")
        XCTAssertEqual(coordinator.project.track("trk_sound")?.clips.map(\.mediaID), ["med_whoosh"])
        // Nothing fits a new track: no empty track is made.
        let still = [MediaItem(id: "med_png", path: "graphics/diagram.png", kind: .image, role: .graphic, hasVideo: true)]
        let placed = try XCTUnwrap(FileImport.batch(still, into: project, at: t(3), trackID: nil, newTrack: (.audio, "trk_sound")))
        XCTAssertFalse(placed.commands.contains { if case .addTrack = $0 { return true } else { return false } })
    }

    func testADropIsWorkedOutAgainstTheProjectWhenItLands() throws {
        let coordinator = ProjectCoordinator(project: Project.standard(name: "Import"))
        let dropped = MediaItem(id: "med_drop", path: "broll/drone.mov", kind: .video, role: .broll, duration: t(4), hasVideo: true)
        // The folder watcher's scan finds the copied file first, under its
        // own ID, after the drop's edit was worked out.
        let scanned = MediaItem(id: "med_scan", path: "broll/drone.mov", kind: .video, role: .broll, duration: t(4), hasVideo: true)
        var landed = false
        let committed = try XCTUnwrap(FileImport.commit([dropped], to: coordinator, folder: folder, at: t(2), trackID: nil) {
            guard !landed else { return }
            landed = true
            _ = try? coordinator.apply(EditBatch(label: "Found new media", author: "system", commands: [.addMedia(item: scanned)]))
        })
        let project = coordinator.project
        XCTAssertEqual(project.media.filter { $0.path == "broll/drone.mov" }.map(\.id), ["med_scan"], "added once, under the scan's ID")
        XCTAssertEqual(project.allTracks.flatMap(\.clips).compactMap(\.mediaID), ["med_scan"], "and placed")
        XCTAssertFalse(committed.batch.commands.contains { if case .addMedia = $0 { return true } else { return false } })
        XCTAssertEqual(committed.batch.expectedRevision, 1, "sent against the revision it was worked out from")
        assertValid(project)
        // Dropped on the media browser again: nothing left to do.
        XCTAssertNil(try FileImport.commit([dropped], to: coordinator, folder: folder, at: nil, trackID: nil))
        // An edit that keeps landing first gives up rather than looping.
        XCTAssertThrowsError(try FileImport.commit([MediaItem(id: "med_other", path: "broll/other.mov", kind: .video, role: .broll, duration: t(1), hasVideo: true)], to: coordinator, folder: folder, at: nil, trackID: nil, attempts: 3) {
            _ = try? coordinator.apply(EditBatch(label: "Marker", commands: [.addMarker(marker: Marker(time: t(1), name: "Busy"))]))
        })
    }
}
