import Foundation
import XCTest
@testable import VideoHQApp

private final class RecordingDescriptionGenerator: VideoDescriptionGenerating {
    private(set) var receivedTranscript = ""

    func generate(transcript: String) async throws -> String {
        receivedTranscript = transcript
        return "Generated video description"
    }
}

final class VideoDescriptionWorkflowTests: XCTestCase {
    func testGenerateUsesTranscriptAndPersistsReloadableDescription() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let video = directory.appendingPathComponent("Demo.mp4")
        try Data().write(to: video)
        try """
        1
        00:00:05,000 --> 00:00:07,000
        A useful section.

        """.write(
            to: directory.appendingPathComponent("Demo.srt"),
            atomically: true,
            encoding: .utf8
        )
        let generator = RecordingDescriptionGenerator()

        let reply = try await VideoDescriptionWorkflow(generator: generator).generate(for: video)

        XCTAssertEqual(reply, "Generated video description")
        XCTAssertEqual(generator.receivedTranscript, "[00:00:05] A useful section.")
        XCTAssertEqual(try VideoSidecars.load(for: video).description, reply)
    }
}
