import Foundation
import XCTest
@testable import RecordItApp

@MainActor
final class RecordingViewModelTests: XCTestCase {
    func testResetFileNameReplacesAnOverrideWithTheCurrentTimestampDefault() {
        let model = RecordingViewModel()
        model.fileName = "launch-demo"

        model.resetFileName(
            at: Date(timeIntervalSince1970: 1_721_035_800),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(model.fileName, "2024-07-15_093000")
    }
}
