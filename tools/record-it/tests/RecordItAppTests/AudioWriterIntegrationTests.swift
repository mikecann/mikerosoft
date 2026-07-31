import AVFoundation
import CoreMedia
import XCTest
@testable import RecordItApp

final class AudioWriterIntegrationTests: XCTestCase {
    func testWriterFinalizesAPlayableAACFileWithoutAVideoTrack() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-it-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let writer = try AudioWriter(
            outputURL: outputURL,
            processingFormat: format
        )

        for _ in 0 ..< 100 {
            XCTAssertTrue(try writer.appendAudio(try floatAudioBuffer(
                format: format,
                sampleValue: 0.25
            )))
        }
        try await writer.finish()

        let asset = AVURLAsset(url: outputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertTrue(videoTracks.isEmpty)
        XCTAssertGreaterThan(duration.seconds, 0)
        XCTAssertGreaterThan(
            try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0,
            0
        )
        XCTAssertEqual(
            try decodedPeakAmplitude(at: outputURL),
            0.25,
            accuracy: 0.08
        )
    }

    func testWriterPreservesAMonoCaptureSourceInsteadOfForcingStereo() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-it-mono-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let writer = try AudioWriter(
            outputURL: outputURL,
            processingFormat: format
        )

        XCTAssertTrue(try writer.appendAudio(floatAudioBuffer(format: format)))
        XCTAssertTrue(try writer.appendAudio(floatAudioBuffer(format: format)))
        try await writer.finish()

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let formatDescriptions = try await track.load(.formatDescriptions)
        let formatDescription = try XCTUnwrap(formatDescriptions.first)
        let streamDescription = try XCTUnwrap(
            CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        )
        XCTAssertEqual(streamDescription.pointee.mChannelsPerFrame, 1)
    }

    func testOutputSettingsUseACompactVoiceAppropriateAACBitrate() throws {
        let mono = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let stereo = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))

        XCTAssertEqual(audioOutputSettings(for: mono)[AVEncoderBitRateKey] as? Int, 96_000)
        XCTAssertEqual(audioOutputSettings(for: stereo)[AVEncoderBitRateKey] as? Int, 128_000)
    }
}

private func floatAudioBuffer(
    format: AVAudioFormat,
    frameCount: AVAudioFrameCount = 480,
    sampleValue: Float = 0
) throws -> AVAudioPCMBuffer {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
          let channels = buffer.floatChannelData else {
        throw RecordItError.message("Could not create a floating-point test audio buffer.")
    }
    buffer.frameLength = frameCount
    for channel in 0 ..< Int(format.channelCount) {
        for frame in 0 ..< Int(frameCount) {
            channels[channel][frame] = sampleValue
        }
    }
    return buffer
}

private func decodedPeakAmplitude(at url: URL) throws -> Float {
    let file = try AVAudioFile(forReading: url)
    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: frameCount
    ) else {
        throw RecordItError.message("Could not allocate a decoded test audio buffer.")
    }
    try file.read(into: buffer)
    guard let channels = buffer.floatChannelData else {
        throw RecordItError.message("Decoded test audio was not floating-point PCM.")
    }

    var peak: Float = 0
    for channel in 0 ..< Int(buffer.format.channelCount) {
        for frame in 0 ..< Int(buffer.frameLength) {
            peak = max(peak, abs(channels[channel][frame]))
        }
    }
    return peak
}
