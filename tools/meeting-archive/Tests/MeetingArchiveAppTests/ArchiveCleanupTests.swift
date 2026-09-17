import Foundation
import XCTest
import MeetingArchiveCore
@testable import MeetingArchiveApp

final class ArchiveCleanupTests: XCTestCase {
    func testRefusesUnacknowledgedCleanup() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let manifest = TransferManifest(meetingID: UUID(), revision: 1, files: [
            .init(path: "metadata.json", sizeBytes: 2, sha256: String(repeating: "0", count: 64), kind: .metadata),
        ])
        try manifest.canonicalData().write(to: source.appendingPathComponent("manifest.json"))
        let acknowledgement = ArchiveAcknowledgement(
            meetingID: manifest.meetingID,
            manifestRevision: 1,
            manifestSHA256: manifest.sha256Hex(),
            archivePath: "/archive",
            acceptedAt: Date(),
            verifiedFiles: manifest.files,
            queueJobID: "1",
            cleanupAllowed: false
        )

        XCTAssertThrowsError(
            try ArchiveCleanup.perform(
                source: source,
                index: source.appendingPathComponent("index"),
                acknowledgement: acknowledgement
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("index").path))
    }

    func testRejectsParentDirectorySymlinkWithoutDeletingExternalFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalMicrophone = external.appendingPathComponent("microphone.m4a")
        let externalIncoming = external.appendingPathComponent("incoming.m4a")
        try fixture.microphoneBytes.write(to: externalMicrophone)
        try fixture.incomingBytes.write(to: externalIncoming)
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("media"))
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("media"),
            withDestinationURL: external
        )

        XCTAssertThrowsError(
            try ArchiveCleanup.perform(
                source: fixture.source,
                index: fixture.index,
                acknowledgement: fixture.acknowledgement
            )
        )
        XCTAssertEqual(try Data(contentsOf: externalMicrophone), fixture.microphoneBytes)
        XCTAssertEqual(try Data(contentsOf: externalIncoming), fixture.incomingBytes)
    }

    func testRejectsRawAcknowledgementWhoseIdentityDiffersFromPassedAcknowledgement() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tampered = ArchiveAcknowledgement(
            meetingID: UUID(),
            manifestRevision: fixture.manifest.revision,
            manifestSHA256: fixture.manifest.sha256Hex(),
            archivePath: fixture.acknowledgement.archivePath,
            acceptedAt: fixture.acknowledgement.acceptedAt,
            verifiedFiles: fixture.manifest.files,
            queueJobID: fixture.acknowledgement.queueJobID,
            cleanupAllowed: true
        )
        try acknowledgementData(tampered).write(
            to: fixture.source.appendingPathComponent("acknowledgement.json")
        )

        XCTAssertThrowsError(
            try ArchiveCleanup.perform(
                source: fixture.source,
                index: fixture.index,
                acknowledgement: fixture.acknowledgement
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.source.appendingPathComponent("media/microphone.m4a").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.index.path))
    }

    func testSuccessfulCleanupPreservesRawValidatedReceiptAndOnlyRemovesManifestMedia() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unmanifested = fixture.source.appendingPathComponent("keep-me.txt")
        try Data("local note".utf8).write(to: unmanifested)

        try ArchiveCleanup.perform(
            source: fixture.source,
            index: fixture.index,
            acknowledgement: fixture.acknowledgement
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.source.appendingPathComponent("media/microphone.m4a").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.source.appendingPathComponent("media/incoming.m4a").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanifested.path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.index.appendingPathComponent("acknowledgement.json")),
            fixture.receipt
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.index.appendingPathComponent("manifest.json")),
            try Data(contentsOf: fixture.source.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.index.appendingPathComponent("metadata.json")),
            try Data(contentsOf: fixture.source.appendingPathComponent("metadata.json"))
        )
        let rawReceipt = try JSONSerialization.jsonObject(with: fixture.receipt) as! [String: Any]
        XCTAssertEqual(
            (rawReceipt["media_validation"] as? [String: Any])?["status"] as? String,
            "passed"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.index.appendingPathComponent("cleanup-complete.json").path
        ))
    }

    func testRerunAfterPartialDeletionRemovesRemainingMediaAndSucceedsAgain() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(
            at: fixture.source.appendingPathComponent("media/microphone.m4a")
        )

        try ArchiveCleanup.perform(
            source: fixture.source,
            index: fixture.index,
            acknowledgement: fixture.acknowledgement
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.source.appendingPathComponent("media/incoming.m4a").path
        ))

        XCTAssertNoThrow(
            try ArchiveCleanup.perform(
                source: fixture.source,
                index: fixture.index,
                acknowledgement: fixture.acknowledgement
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.index.appendingPathComponent("acknowledgement.json")),
            fixture.receipt
        )
    }

    private struct Fixture {
        var root: URL
        var source: URL
        var index: URL
        var manifest: TransferManifest
        var acknowledgement: ArchiveAcknowledgement
        var receipt: Data
        var microphoneBytes: Data
        var incomingBytes: Data
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-cleanup-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("spool", isDirectory: true)
        let index = root.appendingPathComponent("index", isDirectory: true)
        let media = source.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let metadata = Data("{}".utf8)
        let microphone = Data("microphone bytes".utf8)
        let incoming = Data("incoming bytes".utf8)
        let metadataURL = source.appendingPathComponent("metadata.json")
        let microphoneURL = media.appendingPathComponent("microphone.m4a")
        let incomingURL = media.appendingPathComponent("incoming.m4a")
        try metadata.write(to: metadataURL)
        try microphone.write(to: microphoneURL)
        try incoming.write(to: incomingURL)
        let manifest = TransferManifest(meetingID: UUID(), revision: 1, files: [
            .init(
                path: "metadata.json",
                sizeBytes: Int64(metadata.count),
                sha256: try SpoolBundle.hash(metadataURL),
                kind: .metadata
            ),
            .init(
                path: "media/microphone.m4a",
                sizeBytes: Int64(microphone.count),
                sha256: try SpoolBundle.hash(microphoneURL),
                kind: .microphoneAudio
            ),
            .init(
                path: "media/incoming.m4a",
                sizeBytes: Int64(incoming.count),
                sha256: try SpoolBundle.hash(incomingURL),
                kind: .incomingAudio
            ),
        ])
        try manifest.canonicalData().write(to: source.appendingPathComponent("manifest.json"))
        let acknowledgement = ArchiveAcknowledgement(
            meetingID: manifest.meetingID,
            manifestRevision: manifest.revision,
            manifestSHA256: manifest.sha256Hex(),
            archivePath: "/Volumes/CannMedia/MeetingArchive/meetings/fixture",
            acceptedAt: Date(timeIntervalSince1970: 1_800_000_100),
            verifiedFiles: manifest.files,
            queueJobID: "job-1",
            cleanupAllowed: true
        )
        let receipt = try acknowledgementData(acknowledgement)
        try receipt.write(to: source.appendingPathComponent("acknowledgement.json"))
        return Fixture(
            root: root,
            source: source,
            index: index,
            manifest: manifest,
            acknowledgement: acknowledgement,
            receipt: receipt,
            microphoneBytes: microphone,
            incomingBytes: incoming
        )
    }

    private func acknowledgementData(_ acknowledgement: ArchiveAcknowledgement) throws -> Data {
        var value = try JSONSerialization.jsonObject(
            with: ModelCodec.encoder.encode(acknowledgement)
        ) as! [String: Any]
        value["media_validation"] = [
            "status": "passed",
            "full_decode": true,
            "files": acknowledgement.verifiedFiles
                .filter { $0.kind != .metadata }
                .map { [
                    "path": $0.path,
                    "full_decode": true,
                    "duration_seconds": 5.0,
                ] as [String: Any] },
        ]
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
