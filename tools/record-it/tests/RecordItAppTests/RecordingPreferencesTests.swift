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

    func testEncoderSettingsDefaultToVBRAndPersistEveryControl() {
        let suiteName = "record-it-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = RecordingPreferences(defaults: defaults)
        XCTAssertEqual(initial.rateControl, .vbr)
        XCTAssertEqual(initial.bitRateMbps, 60)
        XCTAssertEqual(initial.maximumBitRateMbps, 80)
        XCTAssertEqual(initial.qualityParameter, 20)

        initial.selectedEncoderID = "hardware-h264"
        initial.rateControl = .cqp
        initial.bitRateMbps = 45
        initial.maximumBitRateMbps = 72
        initial.qualityParameter = 17

        let restored = RecordingPreferences(defaults: defaults)
        XCTAssertEqual(restored.selectedEncoderID, "hardware-h264")
        XCTAssertEqual(restored.rateControl, .cqp)
        XCTAssertEqual(restored.bitRateMbps, 45)
        XCTAssertEqual(restored.maximumBitRateMbps, 72)
        XCTAssertEqual(restored.qualityParameter, 17)
    }

    func testEncoderNumericSettingsAreClampedBeforeTheyAreSaved() {
        let suiteName = "record-it-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = RecordingPreferences(defaults: defaults)

        preferences.bitRateMbps = 0
        preferences.maximumBitRateMbps = 900
        preferences.qualityParameter = 72

        XCTAssertEqual(preferences.bitRateMbps, 1)
        XCTAssertEqual(preferences.maximumBitRateMbps, 500)
        XCTAssertEqual(preferences.qualityParameter, 51)

        let restored = RecordingPreferences(defaults: defaults)
        XCTAssertEqual(restored.bitRateMbps, 1)
        XCTAssertEqual(restored.maximumBitRateMbps, 500)
        XCTAssertEqual(restored.qualityParameter, 51)
    }
}
