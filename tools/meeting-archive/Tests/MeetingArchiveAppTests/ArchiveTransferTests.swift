import CryptoKit
import Foundation
import XCTest
import MeetingArchiveCore
@testable import MeetingArchiveApp

final class ArchiveTransferTests: XCTestCase {
    func testUploadVerifiesFilesUsesBoundedCommandsAndPersistsAcknowledgement() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let acknowledgement = ArchiveAcknowledgement(
            meetingID: fixture.manifest.meetingID,
            manifestRevision: fixture.manifest.revision,
            manifestSHA256: fixture.manifest.sha256Hex(),
            archivePath: "/Volumes/CannMedia/MeetingArchive/meetings/2026/09/\(fixture.manifest.meetingID.uuidString.lowercased())",
            acceptedAt: Date(timeIntervalSince1970: 1_800_000_100),
            verifiedFiles: fixture.manifest.files,
            queueJobID: "job-1",
            cleanupAllowed: true
        )
        let runner = StubProcessRunner(results: [
            .success(stdout: volumeInformation(uuid: ArchiveTransfer.cannMediaVolumeUUID)),
            .success(stdout: Data("42:Directory\n42:Directory\n42:Directory\n".utf8)),
            .success(),
            .success(),
            .success(stdout: try acknowledgementWithMediaProof(acknowledgement)),
        ])
        let transfer = ArchiveTransfer(processRunner: runner)

        let received = try await transfer.upload(
            sourceDirectory: fixture.directory,
            manifest: fixture.manifest,
            configuration: .bruce
        )

        XCTAssertEqual(received, acknowledgement)
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[0].executable.path, "/usr/bin/ssh")
        XCTAssertTrue(requests[0].arguments.contains("BatchMode=yes"))
        XCTAssertTrue(requests[0].arguments.contains("ConnectTimeout=5"))
        XCTAssertTrue(requests[0].arguments.contains("/usr/sbin/diskutil"))
        XCTAssertTrue(requests[1].arguments.contains("/usr/bin/stat"))
        XCTAssertTrue(requests[2].arguments.contains("mkdir"))
        XCTAssertEqual(requests[3].executable.path, "/usr/bin/rsync")
        XCTAssertFalse(requests[3].arguments.contains("--delete"))
        XCTAssertTrue(requests[4].arguments.contains("--manifest-sha256"))
        XCTAssertTrue(requests[4].arguments.contains("--validate-media"))
        XCTAssertTrue(requests.allSatisfy { $0.timeout > 0 })

        let persisted = try ModelCodec.decoder.decode(
            ArchiveAcknowledgement.self,
            from: Data(contentsOf: fixture.directory.appendingPathComponent("acknowledgement.json"))
        )
        XCTAssertEqual(persisted, acknowledgement)
    }

    func testUploadStopsBeforeMkdirWhenCannMediaIsMissing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = StubProcessRunner(results: [
            .init(exitCode: 1, stdout: Data(), stderr: "Volume not found"),
        ])

        do {
            _ = try await ArchiveTransfer(processRunner: runner).upload(
                sourceDirectory: fixture.directory,
                manifest: fixture.manifest,
                configuration: .bruce
            )
            XCTFail("Expected missing volume failure")
        } catch let error as ArchiveTransferError {
            XCTAssertEqual(
                error,
                .commandFailed(executable: "/usr/bin/ssh", exitCode: 1, stderr: "Volume not found")
            )
        }
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].arguments.contains("/usr/sbin/diskutil"))
    }

    func testUploadStopsBeforeMkdirWhenCannMediaUUIDIsWrong() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = StubProcessRunner(results: [
            .success(stdout: volumeInformation(uuid: "00000000-0000-0000-0000-000000000000")),
        ])

        do {
            _ = try await ArchiveTransfer(processRunner: runner).upload(
                sourceDirectory: fixture.directory,
                manifest: fixture.manifest,
                configuration: .bruce
            )
            XCTFail("Expected wrong volume failure")
        } catch let error as ArchiveTransferError {
            XCTAssertEqual(
                error,
                .remoteVolumeMismatch(actual: "00000000-0000-0000-0000-000000000000")
            )
        }
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testUploadStopsBeforeMkdirWhenArchiveRootsAreMissing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = StubProcessRunner(results: [
            .success(stdout: volumeInformation(uuid: ArchiveTransfer.cannMediaVolumeUUID)),
            .init(exitCode: 1, stdout: Data(), stderr: "No such file or directory"),
        ])

        do {
            _ = try await ArchiveTransfer(processRunner: runner).upload(
                sourceDirectory: fixture.directory,
                manifest: fixture.manifest,
                configuration: .bruce
            )
            XCTFail("Expected missing roots failure")
        } catch let error as ArchiveTransferError {
            XCTAssertEqual(
                error,
                .commandFailed(executable: "/usr/bin/ssh", exitCode: 1, stderr: "No such file or directory")
            )
        }
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.contains { $0.arguments.contains("mkdir") })
    }

    func testMissingMediaProofCannotAuthorizeCleanup() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        XCTAssertThrowsError(try ArchiveReceiptVerification.requireMediaValidation(Data("{}".utf8), manifest: fixture.manifest))
    }

    private func acknowledgementWithMediaProof(_ acknowledgement: ArchiveAcknowledgement) throws -> Data {
        var value = try JSONSerialization.jsonObject(with: ModelCodec.encoder.encode(acknowledgement)) as! [String: Any]
        value["media_validation"] = ["status": "passed", "full_decode": true, "files": acknowledgement.verifiedFiles.filter { $0.kind != .metadata }.map { ["path": $0.path, "full_decode": true, "duration_seconds": 5] as [String: Any] }]
        return try JSONSerialization.data(withJSONObject: value)
    }

    func testUploadRejectsChangedRawManifestBeforeRunningProcesses() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("{\"schema_version\":1}".utf8).write(to: fixture.directory.appendingPathComponent("manifest.json"))
        let runner = StubProcessRunner(results: [])
        let transfer = ArchiveTransfer(processRunner: runner)

        do {
            _ = try await transfer.upload(sourceDirectory: fixture.directory, manifest: fixture.manifest, configuration: .bruce)
            XCTFail("Expected raw manifest mismatch")
        } catch let error as ArchiveTransferError {
            XCTAssertEqual(error, .manifestBytesChanged)
        }
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests, [])
    }

    func testUploadRejectsFileHashMismatchBeforeTransfer() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("changed".utf8).write(to: fixture.directory.appendingPathComponent("media/video.mov"))
        let runner = StubProcessRunner(results: [])

        do {
            _ = try await ArchiveTransfer(processRunner: runner).upload(
                sourceDirectory: fixture.directory,
                manifest: fixture.manifest,
                configuration: .bruce
            )
            XCTFail("Expected hash mismatch")
        } catch let error as ArchiveTransferError {
            XCTAssertEqual(error, .fileSizeMismatch("media/video.mov"))
        }
    }

    func testFailedRemoteCommandReturnsBoundedDiagnostic() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = StubProcessRunner(results: [.init(exitCode: 255, stdout: Data(), stderr: "connection refused")])

        do {
            _ = try await ArchiveTransfer(processRunner: runner).upload(
                sourceDirectory: fixture.directory,
                manifest: fixture.manifest,
                configuration: .bruce
            )
            XCTFail("Expected command failure")
        } catch let error as ArchiveTransferError {
            XCTAssertEqual(error, .commandFailed(executable: "/usr/bin/ssh", exitCode: 255, stderr: "connection refused"))
        }
    }

    func testFetchResolvesDatePartitionThenDownloadsValidatedArtifact() async throws {
        let meetingID = UUID()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("transcript.vtt")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let locate = Data("""
        {"schema_version":1,"meeting_id":"\(meetingID.uuidString.lowercased())","archive_path":"/Volumes/CannMedia/MeetingArchive/meetings/2026/09/\(meetingID.uuidString.lowercased())"}
        """.utf8)
        let runner = StubProcessRunner(results: [.success(stdout: locate), .success()])
        let transfer = ArchiveTransfer(processRunner: runner)

        let result = try await transfer.fetch(
            relativePath: "transcripts/v1/transcript.vtt",
            meetingID: meetingID,
            destination: destination,
            configuration: .bruce
        )

        XCTAssertEqual(result, destination.standardizedFileURL)
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].arguments.contains("locate"))
        XCTAssertTrue(requests[1].arguments.contains { $0.hasSuffix("/transcripts/v1/transcript.vtt") })
    }

    func testFetchRejectsArbitraryArchivePathBeforeRemoteCall() async {
        let runner = StubProcessRunner(results: [])
        do {
            _ = try await ArchiveTransfer(processRunner: runner).fetch(
                relativePath: "../../metadata.json",
                meetingID: UUID(),
                destination: FileManager.default.temporaryDirectory.appendingPathComponent("metadata.json"),
                configuration: .bruce
            )
            XCTFail("Expected path rejection")
        } catch let error as ArchiveTransferError {
            XCTAssertEqual(error, .unsupportedArtifactPath("../../metadata.json"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let requests = await runner.recordedRequests()
        XCTAssertEqual(requests, [])
    }

    private func makeFixture() throws -> (directory: URL, manifest: TransferManifest) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("media"), withIntermediateDirectories: true)
        let metadata = Data("metadata".utf8)
        let video = Data("video bytes".utf8)
        try metadata.write(to: directory.appendingPathComponent("metadata.json"))
        try video.write(to: directory.appendingPathComponent("media/video.mov"))
        let manifest = TransferManifest(
            meetingID: UUID(),
            revision: 1,
            files: [
                .init(path: "metadata.json", sizeBytes: Int64(metadata.count), sha256: sha256(metadata), kind: .metadata),
                .init(path: "media/video.mov", sizeBytes: Int64(video.count), sha256: sha256(video), kind: .video),
            ]
        )
        try manifest.canonicalData().write(to: directory.appendingPathComponent("manifest.json"))
        return (directory, manifest)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func volumeInformation(uuid: String) -> Data {
        try! PropertyListSerialization.data(
            fromPropertyList: ["VolumeUUID": uuid],
            format: .xml,
            options: 0
        )
    }
}

private actor StubProcessRunner: ArchiveProcessRunning {
    private var results: [ArchiveProcessResult]
    private var requests: [ArchiveProcessRequest] = []

    init(results: [ArchiveProcessResult]) {
        self.results = results
    }

    func run(_ request: ArchiveProcessRequest) async throws -> ArchiveProcessResult {
        requests.append(request)
        guard !results.isEmpty else { throw ArchiveTransferError.processLaunchFailed("Unexpected process") }
        return results.removeFirst()
    }

    func recordedRequests() -> [ArchiveProcessRequest] { requests }
}

private extension ArchiveProcessResult {
    static func success(stdout: Data = Data()) -> ArchiveProcessResult {
        ArchiveProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}
