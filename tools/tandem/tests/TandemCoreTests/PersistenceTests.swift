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
}
