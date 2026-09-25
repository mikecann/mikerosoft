import XCTest
@testable import TandemCore

/// Saving, backups and the crash-recovery journal.
final class PersistenceTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    var backups: URL { folder.appendingPathComponent(".tandem/backups") }

    func backupNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()
    }

    func testPruningLeavesOtherVersionsBackupsAlone() throws {
        // `Video v2` is a Save As version of `Video` in the same folder. Its
        // backups start with "Video " too, but they aren't Video's.
        let project = Project.standard(name: "Video")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let versionBackups = ["Video v2 2026-09-25 10.00.01.tandem", "Video v2 2026-09-25 10.00.02.tandem", "Video v2 2026-09-25 10.00.03.tandem"]
        for name in versionBackups + ["Video 2026-09-24 09.00.00.tandem"] {
            try ProjectFile.encoder().encode(ProjectFile.Envelope(revision: 1, project: project)).write(to: backups.appendingPathComponent(name))
        }
        let url = folder.appendingPathComponent("Video.tandem")
        try ProjectFile.save(project, revision: 1, to: url, keepBackups: 2)
        try ProjectFile.save(project, revision: 2, to: url, keepBackups: 2)

        let names = try backupNames()
        XCTAssertEqual(names.filter { $0.hasPrefix("Video v2 ") }, versionBackups, "saving Video must not prune Video v2's backups")
        let own = names.filter { !$0.hasPrefix("Video v2 ") }
        XCTAssertEqual(own.count, 2, "Video keeps its own newest two: \(own)")
        XCTAssertTrue(own.contains("Video 2026-09-24 09.00.00.tandem"), "\(own)")
    }

    // MARK: - Journal

    func journal() -> ProjectJournal {
        ProjectJournal.forProject(at: folder.appendingPathComponent("Video.tandem"))
    }

    func marker(_ id: String, at seconds: Double) -> EditBatch {
        EditBatch(label: "Marker \(id)", commands: [.addMarker(marker: Marker(id: id, time: t(seconds), name: id))])
    }

    func testAReloadIsReplayedAfterACrash() throws {
        // The undo history kept on disk for CLI edits comes back through
        // `reload`. Edits after it are relative to the reloaded project, so
        // a replay has to land on it too.
        let saved = Project.standard(name: "Video")
        let journal = journal()
        let coordinator = ProjectCoordinator(project: saved, revision: 0, journal: journal)
        try coordinator.apply(marker("mk_a", at: 1))
        var restored = saved
        restored.markers = [Marker(id: "mk_old", time: t(9), name: "Old")]
        coordinator.reload(restored)
        try coordinator.apply(marker("mk_b", at: 2))

        let recovered = try XCTUnwrap(journal.recover(project: saved, revision: 0))
        XCTAssertEqual(recovered.revision, coordinator.revision)
        XCTAssertEqual(recovered.project, coordinator.project)
        XCTAssertEqual(recovered.project.markers.map(\.id), ["mk_b", "mk_old"], "mk_a was replaced by the reload")
    }

    func testForgettingHistoryClearsTheJournalAndUndoHistory() throws {
        let url = folder.appendingPathComponent("Video.tandem")
        journal().append(batch: marker("mk_1", at: 1), revision: 1, seed: 1)
        try Data("{}".utf8).write(to: ProjectFile.undoHistoryURL(for: url))
        ProjectFile.forgetHistory(of: url)
        XCTAssertEqual(journal().entries(after: 0).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectFile.undoHistoryURL(for: url).path))
        XCTAssertEqual(ProjectFile.undoHistoryURL(for: url).lastPathComponent, "Video.undo.json")
        XCTAssertEqual(ProjectFile.journalURL(for: url).lastPathComponent, "Video.journal.jsonl")
    }

    func testALineCutShortDoesntCostTheEntriesAroundIt() throws {
        // A crash or a full disk can leave the last line half written,
        // even in the middle of a character ("é" is two bytes).
        let journal = journal()
        journal.append(batch: marker("mk_1", at: 1), revision: 1, seed: 1)
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"batch":{"label":"Caf"#.utf8) + Data([0xC3]))
        try handle.close()

        journal.append(batch: marker("mk_2", at: 2), revision: 2, seed: 2)
        XCTAssertEqual(journal.entries(after: 0).map(\.revision), [1, 2])
        let recovered = try XCTUnwrap(journal.recover(project: Project.standard(name: "Video"), revision: 0))
        XCTAssertEqual(recovered.project.markers.map(\.id), ["mk_1", "mk_2"])
    }

    func testAnAppendThatCantOpenTheJournalLeavesItAlone() throws {
        let journal = journal()
        journal.append(batch: marker("mk_1", at: 1), revision: 1, seed: 1)
        journal.append(batch: marker("mk_2", at: 2), revision: 2, seed: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: journal.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journal.url.path) }
        journal.append(batch: marker("mk_3", at: 3), revision: 3, seed: 3)
        XCTAssertEqual(journal.entries(after: 0).map(\.revision), [1, 2], "the entries already there survive")
    }

    func testTheJournalFollowsARenamedFolder() throws {
        let before = folder.appendingPathComponent("working title/Video.tandem")
        let after = folder.appendingPathComponent("decision-models/Video.tandem")
        let journal = ProjectJournal.forProject(at: before)
        journal.append(batch: marker("mk_1", at: 1), revision: 1, seed: 1)
        try FileManager.default.moveItem(at: before.deletingLastPathComponent(), to: after.deletingLastPathComponent())
        journal.append(batch: marker("mk_2", at: 2), revision: 2, seed: 2)
        XCTAssertEqual(ProjectJournal.forProject(at: after).entries(after: 0).map(\.revision), [1, 2])
        XCTAssertEqual(journal.url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "decision-models")
    }

    func testTruncatingForASaveKeepsTheEditsItMissed() throws {
        let journal = journal()
        journal.append(batch: marker("mk_1", at: 1), revision: 1, seed: 1)
        journal.append(batch: marker("mk_2", at: 2), revision: 2, seed: 2)
        journal.append(batch: marker("mk_3", at: 3), revision: 3, seed: 3)
        // A save of revision 2: an edit committed while it was writing the
        // file (revision 3) isn't in the file, so its entry must stay.
        journal.truncate(through: 2)
        XCTAssertEqual(journal.entries(after: 0).map(\.revision), [3])
        journal.truncate(through: 3)
        XCTAssertEqual(journal.entries(after: 0).map(\.revision), [])
    }
}

final class BackupPolicyTests: XCTestCase {
    func testThinsOutOlderBackups() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }
        // Oldest first: two in one old day, one too old, a burst from
        // yesterday afternoon in the same ten minutes, and the last hour.
        let dates = [
            ago(40 * 86_400),          // 0: older than 30 days
            ago(5 * 86_400 + 100),     // 1: same day as 2, older
            ago(5 * 86_400),           // 2: newest that day
            ago(7200 + 120),           // 3: same ten minutes as 4
            ago(7200 + 60),            // 4: newest in its ten minutes
            ago(1800),                 // 5: last hour
            ago(600),                  // 6: last hour
            ago(60)                    // 7: last hour
        ]
        let kept = BackupPolicy.keep(dates, now: now)
        XCTAssertEqual(kept, [2, 4, 5, 6, 7])
    }

    func testAutosaveDoesNotBackUpEverySave() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Video.tandem")
        let project = Project.standard(name: "Video")
        for revision in 0..<5 {
            try ProjectFile.save(project, revision: revision, to: url)
        }
        XCTAssertEqual(ProjectFile.backups(of: url).count, 1, "one backup within the first minute, not one per save")
    }
}
