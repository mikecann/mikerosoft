import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TandemCore
@testable import TandemImport

/// The AVFoundation probe against small files made on the spot, so no
/// media is committed.
final class ProbeTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = try Fixtures.temporaryFolder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// One second of 48 kHz mono silence.
    func writeWAV(_ url: URL, seconds: Double = 1) throws {
        let frames = Int(48_000 * seconds)
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 2)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(16); append16(1); append16(1); append(48_000); append(96_000); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 2))
        data.append(Data(count: frames * 2))
        try data.write(to: url)
    }

    func writePNG(_ url: URL, width: Int, height: Int) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// A short H.264 movie. `times` are the frame times in seconds.
    func writeMovie(_ url: URL, times: [Double], size: Int = 64) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // No frame reordering, so frame durations are exactly as written.
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for time in times {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue((time * 30).rounded()), timescale: 30))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue((times.last! * 30).rounded()) + 1, timescale: 30))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    func testProbesSound() async throws {
        let url = folder.appendingPathComponent("tone.wav")
        try writeWAV(url, seconds: 1.5)
        let probed = try await AVFoundationProbe().probe(url)
        XCTAssertEqual(probed.kind, .audio)
        XCTAssertTrue(probed.hasAudio)
        XCTAssertFalse(probed.hasVideo)
        XCTAssertEqual(probed.duration?.seconds ?? 0, 1.5, accuracy: 0.01)
    }

    func testProbesSoundBehindAMisleadingExtension() async throws {
        let url = folder.appendingPathComponent("downloadCommonCfg.cof")
        try writeWAV(url)
        let probed = try await AVFoundationProbe().probe(url)
        XCTAssertEqual(probed.kind, .audio)
        XCTAssertEqual(probed.duration?.seconds ?? 0, 1, accuracy: 0.01)
    }

    func testProbesStills() async throws {
        let url = folder.appendingPathComponent("logo.png")
        try writePNG(url, width: 64, height: 32)
        let probed = try await AVFoundationProbe().probe(url)
        XCTAssertEqual(probed.kind, .image)
        XCTAssertEqual(probed.width, 64)
        XCTAssertEqual(probed.height, 32)
        XCTAssertTrue(probed.hasAlpha)
        XCTAssertNil(probed.duration)
    }

    func testProbesMoviesAndSpotsVariableFrameRates() async throws {
        let steady = folder.appendingPathComponent("steady.mov")
        try await writeMovie(steady, times: (0..<30).map { Double($0) / 30 })
        let probed = try await AVFoundationProbe().probe(steady)
        XCTAssertEqual(probed.kind, .video)
        XCTAssertTrue(probed.hasVideo)
        XCTAssertFalse(probed.hasAudio)
        XCTAssertEqual(probed.width, 64)
        XCTAssertEqual(probed.frameRate, .fps30)
        XCTAssertFalse(probed.variableFrameRate)
        XCTAssertEqual(probed.duration?.seconds ?? 0, 1, accuracy: 0.05)

        // A screen recording writes frames only when something changes.
        let screen = folder.appendingPathComponent("screen.mov")
        try await writeMovie(screen, times: [0, 1.0 / 30, 2.0 / 30, 1, 1 + 1.0 / 30, 2])
        let sparse = try await AVFoundationProbe().probe(screen)
        XCTAssertTrue(sparse.variableFrameRate)
        XCTAssertEqual(sparse.frameRate, .fps30, "the rate it records at, not the average")
    }

    func testMissingAndUndecodableFilesThrow() async throws {
        do {
            _ = try await AVFoundationProbe().probe(folder.appendingPathComponent("nope.mov"))
            XCTFail("a missing file should throw")
        } catch {}
        let webm = folder.appendingPathComponent("sticker.webm")
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0]).write(to: webm)
        do {
            _ = try await AVFoundationProbe().probe(webm)
            XCTFail("WebM should throw")
        } catch {
            XCTAssertTrue("\(error)".contains("WebM"), "\(error)")
        }
    }
}
