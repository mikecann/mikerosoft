import Foundation
import XCTest
@testable import VideoHQApp

final class VideoTranscriberTests: XCTestCase {
    func testTranscribeRunsConfiguredLauncherAndReturnsCreatedSidecar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let video = directory.appendingPathComponent("Clip with spaces.mp4")
        let launcher = directory.appendingPathComponent("transcribe")
        try Data().write(to: video)
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        output="${1%.*}.srt"
        printf '1\n00:00:02,000 --> 00:00:04,000\nGenerated words.\n' > "$output"
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let transcript = try VideoTranscriber(executableURL: launcher).transcribe(videoURL: video)

        XCTAssertEqual(transcript, "[00:00:02] Generated words.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Clip with spaces.srt").path))
    }
}
