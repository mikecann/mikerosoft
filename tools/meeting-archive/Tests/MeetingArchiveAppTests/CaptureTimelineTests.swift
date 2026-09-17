import XCTest
@testable import MeetingArchiveApp

final class CaptureTimelineTests: XCTestCase {
    func testTracksKeepTheirOffsetsInsteadOfEachStartingAtZero() throws {
        var timeline = CaptureTimeline(origin: 100)
        XCTAssertEqual(try timeline.accept(track: .microphone, timestamp: 100.1, duration: 0.02), 0.1, accuracy: 0.00001)
        XCTAssertEqual(try timeline.accept(track: .incoming, timestamp: 100.4, duration: 0.02), 0.4, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(timeline.tracks[.microphone]).firstOffset, 0.1, accuracy: 0.00001)
        XCTAssertEqual(timeline.duration, 0.42, accuracy: 0.00001)
    }

    func testStaticVideoDoesNotRequireManufacturedFrames() throws {
        var timeline = CaptureTimeline(origin: 10)
        try timeline.accept(track: .video, timestamp: 10, duration: 0)
        try timeline.accept(track: .incoming, timestamp: 70, duration: 0.02)
        XCTAssertEqual(timeline.tracks[.video]?.sampleCount, 1)
        XCTAssertEqual(timeline.duration, 60.02, accuracy: 0.00001)
    }

    func testInvalidAndReversingSamplesAreRejected() throws {
        var timeline = CaptureTimeline(origin: 10)
        XCTAssertThrowsError(try timeline.accept(track: .microphone, timestamp: 9, duration: 0.1))
        XCTAssertThrowsError(try timeline.accept(track: .microphone, timestamp: .nan, duration: 0.1))
        try timeline.accept(track: .microphone, timestamp: 12, duration: 0.1)
        XCTAssertThrowsError(try timeline.accept(track: .microphone, timestamp: 11, duration: 0.1))
    }
}
