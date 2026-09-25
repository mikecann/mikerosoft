import XCTest
@testable import TandemAPI
@testable import TandemCore

final class ProjectSessionTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCreateSaveAndReopen() throws {
        let url = folder.appendingPathComponent("Video.tandem")
        let session = try ProjectSession.create(at: url, owner: .cli)
        XCTAssertEqual(session.coordinator.project.videoTracks.map(\.name), ["Screen", "Camera", "B-roll", "Graphics", "Text"])
        try session.coordinator.apply(EditBatch(label: "Marker", commands: [.addMarker(marker: Marker(id: "mk_a", time: Time(seconds: 3), name: "Hook"))]))
        try session.save()
        XCTAssertFalse(session.isDirty)
        session.close()
        let reopened = try ProjectSession.open(url, owner: .cli)
        XCTAssertEqual(reopened.coordinator.project.markers.map(\.id), ["mk_a"])
        reopened.close()
    }

    func testJournalRecoversUnsavedEdits() throws {
        let url = folder.appendingPathComponent("Crash.tandem")
        let session = try ProjectSession.create(at: url, owner: .cli)
        session.autosaveDelay = 3600
        try session.coordinator.apply(EditBatch(label: "Marker", commands: [.addMarker(marker: Marker(id: "mk_b", time: Time(seconds: 1), name: "B"))]))
        // Simulate a crash: no save, no close, lock left behind by a dead pid.
        let lockURL = ProjectSession.lockURL(for: url)
        try FileManager.default.removeItem(at: lockURL)
        let reopened = try ProjectSession.open(url, owner: .cli)
        XCTAssertTrue(reopened.recoveredEdits)
        XCTAssertEqual(reopened.coordinator.project.markers.map(\.id), ["mk_b"])
        reopened.close()
    }

    func testANewProjectDoesntInheritWhatAnOldOneLeftBehind() throws {
        // A project of this name crashed with unsaved edits and was then
        // deleted, and the CLI had kept undo history for it.
        let url = folder.appendingPathComponent("Video.tandem")
        var old = Project.standard(name: "Old")
        old.markers = [Marker(id: "mk_old", time: t(1), name: "Old")]
        ProjectJournal.forProject(at: url).appendSnapshot(project: old, revision: 3, reason: "undo")
        try FileManager.default.createDirectory(at: ProjectFile.supportFolder(for: url), withIntermediateDirectories: true)
        let stale = #"{"revision": 1, "undo": [], "redo": [], "idempotent": []}"#
        try Data(stale.utf8).write(to: ProjectFile.undoHistoryURL(for: url))

        let session = try ProjectSession.create(at: url, name: "New", owner: .cli)
        defer { session.close() }
        XCTAssertFalse(session.recoveredEdits)
        XCTAssertEqual(session.coordinator.project.name, "New")
        XCTAssertEqual(session.coordinator.project.markers, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectFile.undoHistoryURL(for: url).path))
    }

    func testSavesFollowTheFolderWhenItsRenamed() throws {
        // Mike renames the video folder in Finder with the project open.
        let before = folder.appendingPathComponent("working title", isDirectory: true)
        let after = folder.appendingPathComponent("decision-models", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        let session = try ProjectSession.create(at: before.appendingPathComponent("Video.tandem"), owner: .app)
        session.autosaveDelay = 3600
        try session.coordinator.apply(EditBatch(label: "Before", commands: [.addMarker(marker: Marker(id: "mk_1", time: t(1), name: "1"))]))
        try FileManager.default.moveItem(at: before, to: after)
        // Something recreates the old path (the analysis cache writing into
        // .tandem/cache, say); the project still belongs in the renamed folder.
        try FileManager.default.createDirectory(at: before.appendingPathComponent(".tandem/cache"), withIntermediateDirectories: true)
        try session.coordinator.apply(EditBatch(label: "After", commands: [.addMarker(marker: Marker(id: "mk_2", time: t(2), name: "2"))]))
        session.close()

        let moved = after.appendingPathComponent("Video.tandem")
        XCTAssertEqual(try ProjectFile.load(from: moved).project.markers.map(\.id), ["mk_1", "mk_2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: before.appendingPathComponent("Video.tandem").path))
        XCTAssertEqual(session.fileURL.lastPathComponent, "Video.tandem")
        XCTAssertEqual(session.fileURL.deletingLastPathComponent().lastPathComponent, "decision-models")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectSession.lockURL(for: moved).path), "the lock goes with it")
    }

    func testAnEditThatLandsDuringASaveIsStillJournaled() throws {
        let url = folder.appendingPathComponent("Race.tandem")
        let session = try ProjectSession.create(at: url, owner: .app)
        session.autosaveDelay = 3600
        try session.coordinator.apply(EditBatch(label: "First", commands: [.addMarker(marker: Marker(id: "mk_1", time: t(1), name: "1"))]))
        // What the journal holds when an agent's edit commits after the save
        // has taken its snapshot but before it clears the journal: an entry
        // for the next revision, which the file being written doesn't have.
        let late = EditBatch(label: "Late", commands: [.addMarker(marker: Marker(id: "mk_2", time: t(2), name: "2"))])
        ProjectJournal.forProject(at: url).append(batch: late, revision: session.coordinator.revision + 1, seed: 7)
        try session.save()

        // The app dies before the next autosave.
        try FileManager.default.removeItem(at: ProjectSession.lockURL(for: url))
        let reopened = try ProjectSession.open(url, owner: .app)
        defer { reopened.close() }
        XCTAssertEqual(reopened.coordinator.project.markers.map(\.id), ["mk_1", "mk_2"])
    }

    func testAnUndoFromTheDiskHistorySurvivesACrash() throws {
        // A CLI edit, then the app opens the project and an agent undoes
        // that edit through the app's API (from the history kept on disk),
        // then edits on. The app dies before autosaving.
        let url = try APIFixture.write(to: folder)
        let original = try ProjectFile.load(from: url).project
        try headless(url) { service in
            _ = try service.apply(ApplyRequest(label: "Cut", commands: [.blade(at: t(10))]), context: CallContext(author: "claude"))
        }
        let session = try ProjectSession.open(url, owner: .app)
        session.autosaveDelay = 3600
        let service = TandemService(session: session, mode: .hosted, analysis: FakeAnalysis(), renderer: FakeRenderer())
        XCTAssertEqual(try service.undo(expectedRevision: nil).label, "Cut")
        try service.apply(ApplyRequest(label: "Marker", commands: [.addMarker(marker: Marker(id: "mk_after", time: t(3), name: "After"))]), context: CallContext(author: "claude"))
        let expected = session.coordinator.project
        service.shutdown()
        try FileManager.default.removeItem(at: ProjectSession.lockURL(for: url))

        let reopened = try ProjectSession.open(url, owner: .app)
        defer { reopened.close() }
        XCTAssertTrue(reopened.recoveredEdits)
        XCTAssertEqual(reopened.coordinator.project, expected, "the undone cut stays undone")
        XCTAssertEqual(reopened.coordinator.project.track(named: "Camera")?.clips, original.track(named: "Camera")?.clips)
    }

    func testAutosaveWritesAfterAnEdit() throws {
        let url = folder.appendingPathComponent("Auto.tandem")
        let session = try ProjectSession.create(at: url, owner: .cli)
        session.autosaveDelay = 0.05
        try session.coordinator.apply(EditBatch(label: "Marker", commands: [.addMarker(marker: Marker(time: Time(seconds: 2), name: "C"))]))
        let deadline = Date().addingTimeInterval(3)
        while session.isDirty && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(try ProjectFile.load(from: url).project.markers.count, 1)
        session.close()
    }
}

final class MediaRefreshTests: XCTestCase {
    /// A tiny WAV: silence at 48 kHz, 16-bit mono.
    static func wav(samples: Int) -> Data {
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append(UInt32(36 + samples * 2)); wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(48_000)); append(UInt32(96_000)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8)); append(UInt32(samples * 2)); wav.append(Data(count: samples * 2))
        return wav
    }

    func testARefreshUpdatesKnownFilesAndAddsNewOnes() async throws {
        // An imported project: its media is listed by absolute path and has
        // no fingerprint, so the first scan updates it as well as adding
        // the file that's new.
        let folder = TempFolder()
        try FileManager.default.createDirectory(at: folder.file("sfx"), withIntermediateDirectories: true)
        try Self.wav(samples: 4_800).write(to: folder.file("sfx/click.wav"))
        var project = Project.standard(name: "Imported")
        project.media = [MediaItem(id: "med_click", path: folder.file("sfx/click.wav").path, kind: .audio, role: .sfx, duration: t(0.1), hasAudio: true)]
        let url = folder.file("Imported.tandem")
        try ProjectFile.save(project, revision: 0, to: url)
        try Self.wav(samples: 9_600).write(to: folder.file("sfx/new.wav"))

        let session = try ProjectSession.open(url, owner: .cli)
        defer { session.close() }
        let added = try await session.refreshMedia()
        XCTAssertEqual(added.count, 1)
        let media = session.coordinator.project.media
        XCTAssertEqual(media.map(\.path), ["sfx/click.wav", "sfx/new.wav"])
        XCTAssertNotNil(media[0].fingerprint)
        XCTAssertEqual(media[0].role, .sfx)
    }
}

final class SessionWatchingTests: XCTestCase {
    func testNewFilesJoinAWatchedProject() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Watch.tandem"), owner: .cli)
        defer { session.close() }
        session.startWatching()
        XCTAssertTrue(session.isWatching)
        // A tiny WAV: 0.1 s of silence at 48 kHz, 16-bit mono.
        let samples = 4_800
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append(UInt32(36 + samples * 2)); wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(48_000)); append(UInt32(96_000)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8)); append(UInt32(samples * 2)); wav.append(Data(count: samples * 2))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sfx"), withIntermediateDirectories: true)
        try wav.write(to: folder.appendingPathComponent("sfx/click.wav"))
        let deadline = Date().addingTimeInterval(15)
        while session.coordinator.project.media.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(session.coordinator.project.media.map(\.path), ["sfx/click.wav"])
        session.stopWatching()
        XCTAssertFalse(session.isWatching)
    }
}
