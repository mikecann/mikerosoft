import XCTest
@testable import MeetingArchiveApp
import MeetingArchiveCore

final class SpoolBundleTests: XCTestCase {
    func testExportContainsHashedMetadataAndIndependentTracks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("microphone".utf8).write(to: directory.appendingPathComponent("microphone.m4a"))
        try Data("video".utf8).write(to: directory.appendingPathComponent("meeting-view.mov"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let record = MeetingRecord(title: "Planning", sourceApplication: .init(bundleIdentifier: "us.zoom.xos", displayName: "Zoom", kind: .zoom), startedAt: now, endedAt: now.addingTimeInterval(60), timezoneIdentifier: "Australia/Perth", video: .init(surfaceID: "1", codec: "hevc", width: 1920, height: 1080), microphone: .init(deviceUID: "default", displayName: "Default", sampleRate: 48000, channels: 1), incomingAudio: .init(sourceApplicationBundleIdentifier: "us.zoom.xos", sampleRate: 48000, channels: 2), finalizedAt: now.addingTimeInterval(60))
        let manifest = try SpoolBundle.prepare(record: record, directory: directory)
        try manifest.validate()
        XCTAssertEqual(Set(manifest.files.map(\.path)), ["metadata.json", "meeting-view.mov", "microphone.m4a"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), manifest.canonicalData())
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("metadata.json"))) as! [String: Any]
        XCTAssertEqual(metadata["title"] as? String, "Planning")
        XCTAssertEqual(metadata["duration_seconds"] as? Double, 60)
    }

    func testBundleRefusesMissingAudio() throws {
        XCTAssertThrowsError(try SpoolBundle.mediaFiles(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
}
