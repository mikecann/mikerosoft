import XCTest
@testable import TandemAPI
@testable import TandemCore

/// Saves that fail say why, keep trying, and lose nothing the journal can
/// bring back.
final class SaveProblemTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        writable(true)
        try? FileManager.default.removeItem(at: folder)
    }

    /// A folder the project file can't be written into, like a disk that
    /// went read-only. `.tandem` inside it stays writable, as the journal's
    /// folder usually does.
    private func writable(_ on: Bool) {
        try? FileManager.default.setAttributes([.posixPermissions: on ? 0o755 : 0o555], ofItemAtPath: folder.path)
    }

    private func marker(_ id: String) -> EditBatch {
        EditBatch(label: "Marker", commands: [.addMarker(marker: Marker(id: id, time: Time(seconds: 1), name: id))])
    }

    func testAFailedSaveSaysWhyUntilOneWorks() throws {
        let url = folder.appendingPathComponent("Video.tandem")
        let session = try ProjectSession.create(at: url, owner: .cli)
        session.autosaveDelay = 3600
        try session.coordinator.apply(marker("mk_a"))
        XCTAssertNil(session.saveProblem)

        writable(false)
        XCTAssertThrowsError(try session.save())
        XCTAssertNotNil(session.saveProblem)
        XCTAssertTrue(session.isDirty)

        writable(true)
        try session.save()
        XCTAssertNil(session.saveProblem)
        XCTAssertFalse(session.isDirty)

        // Closing says when its last save fails, and the journal brings
        // the edit back next time.
        try session.coordinator.apply(marker("mk_b"))
        writable(false)
        XCTAssertNotNil(session.close())
        writable(true)
        let reopened = try ProjectSession.open(url, owner: .cli)
        XCTAssertTrue(reopened.recoveredEdits)
        XCTAssertEqual(Set(reopened.coordinator.project.markers.map(\.id)), ["mk_a", "mk_b"])
        XCTAssertNil(reopened.close())
    }

    func testAutosaveKeepsTryingUntilItWorks() throws {
        let url = folder.appendingPathComponent("Video.tandem")
        let session = try ProjectSession.create(at: url, owner: .cli)
        session.autosaveDelay = 0.05
        session.autosaveRetryDelay = 0.1
        writable(false)
        try session.coordinator.apply(marker("mk_a"))
        XCTAssertTrue(wait { session.saveProblem != nil }, "the failure is recorded")
        writable(true)
        XCTAssertTrue(wait { session.saveProblem == nil && !session.isDirty }, "and a later try saves without another edit")
        session.close()
    }

    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
