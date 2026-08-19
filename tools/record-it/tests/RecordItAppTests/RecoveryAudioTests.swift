import Foundation
import XCTest
@testable import RecordItApp

final class RecoveryAudioTests: XCTestCase {
    func testRecoveryAudioUsesAnAppManagedTemporarySpool() {
        let home = URL(fileURLWithPath: "/Users/m5-mike", isDirectory: true)

        XCTAssertEqual(
            recoveryAudioDirectory(homeDirectory: home),
            home.appendingPathComponent(
                "Library/Application Support/Record It/Recovery Audio",
                isDirectory: true
            )
        )
    }

    func testRecoveryAudioFileKeepsTheTakeNameAndUsesLosslessCAF() {
        let directory = URL(fileURLWithPath: "/recovery", isDirectory: true)

        XCTAssertEqual(
            recoveryAudioURL(baseName: "2026-08-19_123343", directory: directory),
            directory.appendingPathComponent("2026-08-19_123343-backup-audio.caf")
        )
    }

    func testBuiltInMacBookMicrophoneIsPreferredAsASeparateBackup() {
        let devices = [
            CaptureAudioDevice(id: "yeti", name: "Yeti Stereo Microphone"),
            CaptureAudioDevice(id: "camera", name: "Razer Kiyo Pro Ultra"),
            CaptureAudioDevice(id: "builtin", name: "MacBook Pro Microphone")
        ]

        XCTAssertEqual(
            preferredRecoveryAudioDevice(primaryID: "yeti", in: devices)?.id,
            "builtin"
        )
    }

    func testPrimaryMicrophoneCannotAlsoBeTheBackup() {
        let devices = [
            CaptureAudioDevice(id: "builtin", name: "MacBook Pro Microphone")
        ]

        XCTAssertNil(preferredRecoveryAudioDevice(primaryID: "builtin", in: devices))
    }

    func testCleanupOnlyRemovesFinalizedRecoveryAudioOlderThanRetention() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("record-it-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let oldCAF = directory.appendingPathComponent("old-backup-audio.caf")
        let recentCAF = directory.appendingPathComponent("recent-backup-audio.caf")
        let unrelatedFile = directory.appendingPathComponent("keep.txt")
        XCTAssertTrue(fileManager.createFile(atPath: oldCAF.path, contents: Data()))
        XCTAssertTrue(fileManager.createFile(atPath: recentCAF.path, contents: Data()))
        XCTAssertTrue(fileManager.createFile(atPath: unrelatedFile.path, contents: Data()))

        let now = Date(timeIntervalSince1970: 2_000_000)
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-15 * 24 * 60 * 60)],
            ofItemAtPath: oldCAF.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-13 * 24 * 60 * 60)],
            ofItemAtPath: recentCAF.path
        )

        try cleanupExpiredRecoveryAudio(
            in: directory,
            now: now,
            retention: 14 * 24 * 60 * 60,
            fileManager: fileManager
        )

        XCTAssertFalse(fileManager.fileExists(atPath: oldCAF.path))
        XCTAssertTrue(fileManager.fileExists(atPath: recentCAF.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedFile.path))
    }

    func testUnexpectedRecoveryHelperExitIsReportedAsAFailure() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("record-it-helper-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let helper = directory.appendingPathComponent("fake-recovery-helper")
        let script = """
        #!/bin/sh
        touch "$2"
        touch "$4"
        sleep 1
        echo "simulated recovery helper crash" >&2
        exit 1
        """
        try Data(script.utf8).write(to: helper)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )

        let failure = expectation(description: "unexpected helper exit")
        let recording = RecoveryAudioRecording(
            device: CaptureAudioDevice(id: "backup", name: "Backup Mic"),
            outputURL: directory.appendingPathComponent("take-backup-audio.caf"),
            helperURL: helper
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("simulated recovery helper crash"))
            failure.fulfill()
        }

        try await recording.start()
        await fulfillment(of: [failure], timeout: 3)
        try await recording.stop()
    }
}
