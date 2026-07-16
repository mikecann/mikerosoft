import Foundation
import XCTest
@testable import VideoHQApp

final class VideoSidecarsTests: XCTestCase {
    func testSelectingVideoLoadsTranscriptAndLatestLegacyDescription() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let video = directory.appendingPathComponent("Demo.v2.mp4")
        let transcript = directory.appendingPathComponent("Demo.v2.srt")
        let description = directory.appendingPathComponent("Demo.v2-description.txt")
        try Data().write(to: video)
        try """
        1
        00:00:01,000 --> 00:00:03,000
        Hello from the video.

        """.write(to: transcript, atomically: true, encoding: .utf8)
        try """
        [2026-07-15 09:00:00]
        You: Please generate a description.

        Gemini:
        Old description

        ------------------------------------------------------------

        [2026-07-15 09:05:00]
        You: Make it shorter.

        Gemini:
        Latest description

        ------------------------------------------------------------
        """.write(to: description, atomically: true, encoding: .utf8)

        let loaded = try VideoSidecars.load(for: video)

        XCTAssertEqual(loaded.transcript, "[00:00:01] Hello from the video.")
        XCTAssertEqual(loaded.description, "Latest description")
        XCTAssertEqual(loaded.transcriptURL, transcript)
        XCTAssertEqual(loaded.descriptionURL, description)
    }
}
