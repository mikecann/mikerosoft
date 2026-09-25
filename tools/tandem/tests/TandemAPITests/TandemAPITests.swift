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
