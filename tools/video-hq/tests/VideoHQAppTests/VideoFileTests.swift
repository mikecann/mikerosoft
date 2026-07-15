import Foundation
import XCTest
@testable import VideoHQApp

final class VideoFileTests: XCTestCase {
    func testSupportedVideoCheckIsCaseInsensitiveAndRejectsOtherFiles() {
        XCTAssertTrue(VideoFile.isSupported(URL(fileURLWithPath: "/tmp/demo.mp4")))
        XCTAssertTrue(VideoFile.isSupported(URL(fileURLWithPath: "/tmp/demo.MOV")))
        XCTAssertTrue(VideoFile.isSupported(URL(fileURLWithPath: "/tmp/demo.mkv")))
        XCTAssertFalse(VideoFile.isSupported(URL(fileURLWithPath: "/tmp/transcript.srt")))
    }
}
