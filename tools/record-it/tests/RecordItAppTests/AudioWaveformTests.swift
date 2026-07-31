import XCTest
@testable import RecordItApp

final class AudioWaveformTests: XCTestCase {
    func testDecibelLevelsAreScaledIntoTheVisibleWaveformRange() {
        XCTAssertEqual(normalizedAudioLevel(decibels: -80), 0, accuracy: 0.001)
        XCTAssertEqual(normalizedAudioLevel(decibels: -60), 0, accuracy: 0.001)
        XCTAssertEqual(normalizedAudioLevel(decibels: -30), 0.5, accuracy: 0.001)
        XCTAssertEqual(normalizedAudioLevel(decibels: 0), 1, accuracy: 0.001)
        XCTAssertEqual(normalizedAudioLevel(decibels: 6), 1, accuracy: 0.001)
    }

    func testWaveformBufferKeepsOnlyTheNewestLevels() {
        var waveform = AudioWaveformBuffer(capacity: 3)

        waveform.append(decibels: -60)
        waveform.append(decibels: -40)
        waveform.append(decibels: -20)
        waveform.append(decibels: 0)

        XCTAssertEqual(waveform.levels.count, 3)
        XCTAssertEqual(waveform.levels[0], 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(waveform.levels[1], 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(waveform.levels[2], 1, accuracy: 0.001)
    }

    func testInvalidMeterReadingsBecomeSilence() {
        XCTAssertEqual(normalizedAudioLevel(decibels: -.infinity), 0)
        XCTAssertEqual(normalizedAudioLevel(decibels: .nan), 0)
    }
}
