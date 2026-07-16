import Foundation
import XCTest
@testable import RecordItApp

final class RecordingPreferencesTests: XCTestCase {
    func testOpenFinderSettingDefaultsOnAndPersists() {
        let suiteName = "record-it-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = RecordingPreferences(defaults: defaults)
        XCTAssertTrue(initial.openFinderAfterRecording)

        initial.openFinderAfterRecording = false

        XCTAssertFalse(RecordingPreferences(defaults: defaults).openFinderAfterRecording)
    }
}
