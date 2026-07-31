import AVFoundation
import CoreMedia
import XCTest
@testable import RecordItApp

final class AudioPCMBufferBridgeTests: XCTestCase {
    func testBridgePreservesInterleavedInt16SamplesWithoutReinterpretingTheirBytes() throws {
        let sampleValue: Int16 = 12_000
        let sampleBuffer = try interleavedInt16SampleBuffer(sampleValue: sampleValue)

        let result = try withAudioPCMBuffer(from: sampleBuffer) { buffer in
            (
                peak: peakDecibels(in: buffer),
                format: buffer.format.commonFormat,
                isInterleaved: buffer.format.isInterleaved,
                frames: buffer.frameLength
            )
        }

        XCTAssertEqual(result.format, .pcmFormatInt16)
        XCTAssertTrue(result.isInterleaved)
        XCTAssertEqual(result.frames, 512)
        XCTAssertEqual(
            result.peak,
            20 * log10(Float(sampleValue) / Float(Int16.max)),
            accuracy: 0.01
        )
    }

    func testBridgedInterleavedInt16BufferCanBeWrittenToAAC() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-it-bridged-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let sampleBuffer = try interleavedInt16SampleBuffer(sampleValue: 4_000)
        var writer: AudioWriter?

        try withAudioPCMBuffer(from: sampleBuffer) { buffer in
            writer = try AudioWriter(outputURL: outputURL, processingFormat: buffer.format)
            XCTAssertTrue(try XCTUnwrap(writer).appendAudio(buffer))
        }
        try withAudioPCMBuffer(
            from: interleavedInt16SampleBuffer(sampleValue: -4_000)
        ) { buffer in
            XCTAssertTrue(try XCTUnwrap(writer).appendAudio(buffer))
        }
        try await XCTUnwrap(writer).finish()

        let asset = AVURLAsset(url: outputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
    }
}

private func interleavedInt16SampleBuffer(
    frameCount: Int = 512,
    channelCount: UInt32 = 2,
    sampleValue: Int16
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
    try checkBridgeOSStatus(CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &streamDescription,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    ))

    let dataLength = frameCount * bytesPerFrame
    var blockBuffer: CMBlockBuffer?
    try checkBridgeOSStatus(CMBlockBufferCreateWithMemoryBlock(
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
    let samples = [Int16](repeating: sampleValue, count: frameCount * Int(channelCount))
    try samples.withUnsafeBytes { bytes in
        try checkBridgeOSStatus(CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!,
            blockBuffer: try XCTUnwrap(blockBuffer),
            offsetIntoDestination: 0,
            dataLength: dataLength
        ))
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: sampleRate),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sampleSize = bytesPerFrame
    var sampleBuffer: CMSampleBuffer?
    try checkBridgeOSStatus(CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: try XCTUnwrap(blockBuffer),
        formatDescription: try XCTUnwrap(formatDescription),
        sampleCount: frameCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    ))
    return try XCTUnwrap(sampleBuffer)
}

private func checkBridgeOSStatus(_ status: OSStatus) throws {
    guard status == noErr else {
        throw RecordItError.message("Core Media returned OSStatus \(status).")
    }
}
