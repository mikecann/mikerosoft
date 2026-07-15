import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import RecordItApp

final class MovieWriterIntegrationTests: XCTestCase {
    func testWriterFinalizesAPlayableHEVCMovie() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("record-it-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let writer = try MovieWriter(
            outputURL: outputURL,
            width: 128,
            height: 128,
            includesAudio: false
        )

        for frame in [0, 1, 3] {
            writer.appendVideo(try videoSampleBuffer(frame: frame, width: 128, height: 128))
        }
        try await writer.finish()

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(size.width, 128)
        XCTAssertEqual(size.height, 128)
        XCTAssertEqual(nominalFrameRate, 30, accuracy: 0.01)
        XCTAssertGreaterThan(duration.seconds, 0)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frameCount = 0
        while output.copyNextSampleBuffer() != nil {
            frameCount += 1
        }
        XCTAssertEqual(frameCount, 4, "The missing source frame should be duplicated for constant 30 fps output.")
    }
}

private func videoSampleBuffer(frame: Int, width: Int, height: Int) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    let pixelStatus = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    )
    guard pixelStatus == kCVReturnSuccess, let pixelBuffer else {
        throw RecordItError.message("Could not create a test pixel buffer.")
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(baseAddress, Int32(frame * 40), CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    var formatDescription: CMVideoFormatDescription?
    try checkOSStatus(
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
    )
    guard let formatDescription else {
        throw RecordItError.message("Could not create a test video format.")
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 30),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    try checkOSStatus(
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
    )
    guard let sampleBuffer else {
        throw RecordItError.message("Could not create a test video sample.")
    }
    return sampleBuffer
}

private func checkOSStatus(_ status: OSStatus) throws {
    guard status == noErr else {
        throw RecordItError.message("Core Media returned OSStatus \(status).")
    }
}
