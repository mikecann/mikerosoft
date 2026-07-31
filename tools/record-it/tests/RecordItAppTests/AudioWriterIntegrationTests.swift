import AVFoundation
import CoreMedia
import XCTest
@testable import RecordItApp

final class AudioWriterIntegrationTests: XCTestCase {
    func testWriterFinalizesAPlayableAACFileWithoutAVideoTrack() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-it-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let firstSample = try audioSampleBuffer(startingFrame: 0, sampleValue: 12_000)
        let sourceFormatHint = try XCTUnwrap(CMSampleBufferGetFormatDescription(firstSample))
        let writer = try AudioWriter(
            outputURL: outputURL,
            sourceFormatHint: sourceFormatHint
        )

        XCTAssertTrue(try writer.appendAudio(firstSample))
        for startingFrame in [480, 960] {
            XCTAssertTrue(try writer.appendAudio(try audioSampleBuffer(
                startingFrame: startingFrame,
                sampleValue: 12_000
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
            Float(12_000) / Float(Int16.max),
            accuracy: 0.1
        )
    }

    func testWriterPreservesAMonoCaptureSourceInsteadOfForcingStereo() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-it-mono-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let firstSample = try audioSampleBuffer(startingFrame: 0, channelCount: 1)
        let sourceFormatHint = try XCTUnwrap(CMSampleBufferGetFormatDescription(firstSample))
        let writer = try AudioWriter(
            outputURL: outputURL,
            sourceFormatHint: sourceFormatHint
        )

        XCTAssertTrue(try writer.appendAudio(firstSample))
        XCTAssertTrue(try writer.appendAudio(audioSampleBuffer(startingFrame: 480, channelCount: 1)))
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
}

private func audioSampleBuffer(
    startingFrame: Int,
    frameCount: Int = 480,
    channelCount: UInt32 = 2,
    sampleValue: Int16 = 0
) throws -> CMSampleBuffer {
    let sampleRate: Int32 = 48_000
    let bytesPerFrame = Int(channelCount) * MemoryLayout<Int16>.size
    var streamDescription = AudioStreamBasicDescription(
        mSampleRate: Float64(sampleRate),
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(bytesPerFrame),
        mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(bytesPerFrame),
        mChannelsPerFrame: channelCount,
        mBitsPerChannel: 16,
        mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    try checkAudioOSStatus(CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &streamDescription,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    ))
    guard let formatDescription else {
        throw RecordItError.message("Could not create a test audio format.")
    }

    let dataLength = frameCount * bytesPerFrame
    var blockBuffer: CMBlockBuffer?
    try checkAudioOSStatus(CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: dataLength,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: dataLength,
        flags: 0,
        blockBufferOut: &blockBuffer
    ))
    guard let blockBuffer else {
        throw RecordItError.message("Could not create a test audio block buffer.")
    }
    let samples = [Int16](repeating: sampleValue, count: frameCount * Int(channelCount))
    try samples.withUnsafeBytes { bytes in
        try checkAudioOSStatus(CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: dataLength
        ))
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: sampleRate),
        presentationTimeStamp: CMTime(value: CMTimeValue(startingFrame), timescale: sampleRate),
        decodeTimeStamp: .invalid
    )
    var sampleSize = bytesPerFrame
    var sampleBuffer: CMSampleBuffer?
    try checkAudioOSStatus(CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: frameCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    ))
    guard let sampleBuffer else {
        throw RecordItError.message("Could not create a test audio sample.")
    }
    return sampleBuffer
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

private func checkAudioOSStatus(_ status: OSStatus) throws {
    guard status == noErr else {
        throw RecordItError.message("Core Media returned OSStatus \(status).")
    }
}
