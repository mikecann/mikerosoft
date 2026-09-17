import CryptoKit
import Foundation
import XCTest
@testable import MeetingArchiveCore

final class ManifestTests: XCTestCase {
    func testManifestUsesWorkerContractAndHashesRawCanonicalBytes() throws {
        let manifest = TransferManifest(
            meetingID: UUID(uuidString: "3F679ACB-96D4-4EE0-AA4E-36E96A1FE41D")!,
            revision: 2,
            files: [
                .init(path: "metadata.json", sizeBytes: 123, sha256: String(repeating: "a", count: 64), kind: .metadata),
                .init(path: "media/incoming-0001.m4a", sizeBytes: 456, sha256: String(repeating: "b", count: 64), kind: .incomingAudio),
            ]
        )

        try manifest.validate()
        let bytes = try manifest.canonicalData()
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(json.contains("\"schema_version\":1"), json)
        XCTAssertTrue(json.contains("\"meeting_id\":\"3f679acb-96d4-4ee0-aa4e-36e96a1fe41d\""), json)
        XCTAssertTrue(json.contains("\"revision\":2"), json)
        XCTAssertFalse(json.contains("manifest_sha256"), json)
        XCTAssertEqual(manifest.sha256Hex(), SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    func testMetadataMustBeListedAndPathsCannotEscapeBundle() {
        let noMetadata = TransferManifest(meetingID: UUID(), revision: 1, files: [])
        XCTAssertThrowsError(try noMetadata.validate())

        let traversal = TransferManifest(
            meetingID: UUID(),
            revision: 1,
            files: [.init(path: "../metadata.json", sizeBytes: 10, sha256: String(repeating: "a", count: 64), kind: .metadata)]
        )
        XCTAssertThrowsError(try traversal.validate())
    }

    func testWorkerMetadataContractIsValidated() throws {
        let metadata = WorkerMeetingMetadata(
            meetingID: UUID(),
            manifestRevision: 1,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_120),
            durationSeconds: 120,
            timezone: "Australia/Perth",
            sourceApp: "Zoom"
        )
        try metadata.validate()
        let json = try XCTUnwrap(String(data: try metadata.canonicalData(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"manifest_revision\":1"), json)
        XCTAssertTrue(json.contains("\"started_at\":\""), json)
        XCTAssertTrue(json.contains("Z\""), json)

        var invalid = metadata
        invalid.timezone = ""
        XCTAssertThrowsError(try invalid.validate())
    }

    func testMetadataRevisionMustMatchManifestAndAcknowledgementCoversEveryFile() throws {
        let meetingID = UUID()
        let files = [
            ManifestFile(path: "metadata.json", sizeBytes: 20, sha256: String(repeating: "a", count: 64), kind: .metadata),
            ManifestFile(path: "media/video.mov", sizeBytes: 40, sha256: String(repeating: "b", count: 64), kind: .video),
        ]
        let manifest = TransferManifest(meetingID: meetingID, revision: 3, files: files)
        let metadata = WorkerMeetingMetadata(
            meetingID: meetingID,
            manifestRevision: 2,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_001),
            durationSeconds: 1,
            timezone: "Australia/Perth",
            sourceApp: "Slack"
        )
        XCTAssertThrowsError(try metadata.validate(against: manifest))

        let acknowledgement = ArchiveAcknowledgement(
            meetingID: meetingID,
            manifestRevision: 3,
            manifestSHA256: manifest.sha256Hex(),
            archivePath: "/Volumes/CannMedia/MeetingArchive/2027/01/\(meetingID.uuidString.lowercased())",
            acceptedAt: Date(timeIntervalSince1970: 1_800_000_010),
            verifiedFiles: files,
            queueJobID: "job-1",
            cleanupAllowed: true
        )
        try acknowledgement.validate(against: manifest)

        var incomplete = acknowledgement
        incomplete.verifiedFiles.removeLast()
        XCTAssertThrowsError(try incomplete.validate(against: manifest))
    }

    func testAcknowledgementDecodesPythonFractionalOffsetTimestamp() throws {
        let id = "3f679acb-96d4-4ee0-aa4e-36e96a1fe41d"
        let json = """
        {"schema_version":1,"meeting_id":"\(id)","manifest_revision":1,"manifest_sha256":"\(String(repeating: "a", count: 64))","archive_path":"/archive","accepted_at":"2026-09-17T10:11:12.345678+00:00","verified_files":[],"queue_job_id":"job-1","cleanup_allowed":true}
        """
        let acknowledgement = try ModelCodec.decoder.decode(ArchiveAcknowledgement.self, from: Data(json.utf8))
        XCTAssertEqual(acknowledgement.meetingID.uuidString.lowercased(), id)
    }
}
