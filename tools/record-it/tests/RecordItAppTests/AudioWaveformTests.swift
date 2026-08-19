import AVFoundation
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

    func testPeakLevelComesFromThePCMBufferThatWillBeWritten() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4
        ))
        buffer.frameLength = 4
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let samples = try XCTUnwrap(audioBuffers.first?.mData?.assumingMemoryBound(to: Int16.self))
        for index in 0 ..< 8 {
            samples[index] = index == 3 ? 16_384 : 0
        }

        XCTAssertEqual(peakDecibels(in: buffer), -6.02, accuracy: 0.05)
    }

    func testAudioFingerprintChangesWhenAnyPCMSampleChanges() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try XCTUnwrap(
            UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                .first?.mData?.assumingMemoryBound(to: Int16.self)
        )
        for index in 0..<4 { samples[index] = Int16(index) }
        let original = audioFingerprint(in: buffer)

        samples[3] = 99

        XCTAssertNotEqual(audioFingerprint(in: buffer), original)
    }
}
