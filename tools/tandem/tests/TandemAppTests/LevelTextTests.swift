import XCTest
@testable import TandemApp
@testable import TandemCore

/// What the Audio tab says about levels.
final class LevelTextTests: XCTestCase {
    func testMeasuredShowsTheGainNormalisingAdds() {
        XCTAssertEqual(AudioLevelText.measured(lufs: -32.2, peak: -5.3, normalizeTo: -20), "−32.2 LUFS · +12.2 dB to −20")
        XCTAssertEqual(AudioLevelText.measured(lufs: -14.3, peak: -1, normalizeTo: -20), "−14.3 LUFS · −5.7 dB to −20")
        XCTAssertEqual(AudioLevelText.measured(lufs: -20, peak: -4, normalizeTo: -20), "−20.0 LUFS · 0 dB to −20")
        XCTAssertEqual(AudioLevelText.measured(lufs: -62, peak: -40, normalizeTo: -18.5), "−62.0 LUFS · +30.0 dB (the most it adds) to −18.5")
    }

    func testMeasuredWithoutNormalisingOrAMeasurement() {
        XCTAssertEqual(AudioLevelText.measured(lufs: -32.2, peak: -5.3, normalizeTo: nil), "−32.2 LUFS · peak −5.3 dBTP")
        XCTAssertNil(AudioLevelText.measured(lufs: nil, peak: nil, normalizeTo: nil))
        XCTAssertEqual(AudioLevelText.measured(lufs: nil, peak: nil, normalizeTo: -20), "Not measured yet, so not levelled")
        XCTAssertEqual(AudioLevelText.measured(lufs: -.infinity, peak: -.infinity, normalizeTo: -20), "Silent, nothing to level")
        XCTAssertEqual(AudioLevelText.measured(lufs: -.infinity, peak: -.infinity, normalizeTo: nil), "Silent")
    }

    func testLevelsAndGains() {
        XCTAssertEqual(AudioLevelText.lufs(-20), "−20 LUFS")
        XCTAssertEqual(AudioLevelText.lufs(-18.5), "−18.5 LUFS")
        XCTAssertEqual(AudioLevelText.lufs(-18, decimals: 1), "−18.0 LUFS")
        XCTAssertEqual(AudioLevelText.gain(12.24), "+12.2 dB")
        XCTAssertEqual(AudioLevelText.gain(-3.5), "−3.5 dB")
        XCTAssertEqual(AudioLevelText.gain(0.01), "0 dB")
    }

    func testSpeechStatus() {
        XCTAssertEqual(AudioLevelText.speechStatus(speech: 229, unlevelled: 0, level: -20), "All 229 speech clips are at −20 LUFS.")
        XCTAssertEqual(AudioLevelText.speechStatus(speech: 229, unlevelled: 96, level: -20), "96 of 229 speech clips have their own gain or level.")
        XCTAssertEqual(AudioLevelText.speechStatus(speech: 229, unlevelled: 1, level: -20), "1 of 229 speech clips has its own gain or level.")
        XCTAssertEqual(AudioLevelText.speechStatus(speech: 1, unlevelled: 0, level: -18), "The speech clip is at −18 LUFS.")
        XCTAssertEqual(AudioLevelText.speechStatus(speech: 1, unlevelled: 1, level: -18), "The speech clip has its own gain or level.")
        XCTAssertEqual(AudioLevelText.speechStatus(speech: 0, unlevelled: 0, level: -20), "No speech clips on the timeline yet.")
    }

    func testTheNoteSaysHowGainAndNormaliseCombine() {
        let note = AudioLevelText.combineNote(ProjectSettings())
        XCTAssertEqual(note, "Normalise sets the clip's level from its file's measured loudness, then Gain is added on top. Export brings the whole mix to −14 LUFS with peaks under −1 dBTP.")
        XCTAssertTrue(AudioLevelText.normaliseHelp(normalizeTo: nil, speechLevel: -20).contains("−20 LUFS"))
        XCTAssertTrue(AudioLevelText.normaliseHelp(normalizeTo: -14, speechLevel: -20).hasPrefix("Levelled to −14 LUFS, not the project's speech level (−20 LUFS)"))
    }
}
