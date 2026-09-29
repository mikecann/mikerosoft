import AVFoundation
import TandemCore
import XCTest
@testable import TandemMedia

/// The first frame's pixel at (x, y), top-left origin, as BGRA read by
/// AVFoundation.
func firstFramePixel(_ url: URL, x: Int, y: Int) async throws -> (red: Int, green: Int, blue: Int, alpha: Int) {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()
    let sample = try XCTUnwrap(output.copyNextSampleBuffer(), "\(reader.error as Any)")
    reader.cancelReading()
    let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return (Int(base[offset + 2]), Int(base[offset + 1]), Int(base[offset]), Int(base[offset + 3]))
}

/// Stock stickers come as QuickTime Animation or PNG in a MOV, which macOS
/// can't decode. The probe notices, a `converted` analysis makes an HEVC
/// copy with the alpha kept, and the analyses that read the picture read
/// that copy.
final class ConvertedMediaTests: TempFolderTestCase {
    var folder: ProjectFolder { ProjectFolder(root: temp) }

    func analysis() -> MediaAnalysis {
        MediaAnalysis(folder: folder, encoderLock: EncoderLock())
    }

    func sticker(_ codec: String) async throws -> MediaItem {
        let url = file("stickers/\(codec).mov")
        try SyntheticMedia.writeUndecodableSticker(to: url, codec: codec)
        return try await MediaScanner.probe(url, folder: folder)
    }

    func testProbeFlagsCodecsMacOSCantDecode() async throws {
        let animation = try await sticker("qtrle")
        XCTAssertEqual(animation.undecodableCodec, "rle ")
        XCTAssertEqual(animation.undecodableCodecName, "QuickTime Animation")
        XCTAssertEqual(animation.kind, .video)
        XCTAssertTrue(animation.hasAlpha)
        XCTAssertEqual(animation.width, 96)
        XCTAssertEqual(animation.height, 64)
        XCTAssertEqual(animation.duration?.seconds ?? 0, 0.5, accuracy: 0.05)

        let png = try await sticker("png")
        XCTAssertEqual(png.undecodableCodec, "png ")
        XCTAssertEqual(png.undecodableCodecName, "PNG video")
        XCTAssertTrue(png.hasAlpha)

        // H.264 and ProRes 4444 play as they are.
        let camera = file("camera.mov")
        try await SyntheticMedia.writeMovie(to: camera, .init(duration: 0.5))
        let cameraItem = try await MediaScanner.probe(camera, folder: folder)
        XCTAssertNil(cameraItem.undecodableCodec)
        XCTAssertNil(cameraItem.undecodableCodecName)
        let prores = file("stickers/prores.mov")
        try XCTUnwrap(FFmpeg.locate()).run([
            "-y", "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=96x64:d=0.5:r=30,format=rgba",
            "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", prores.path
        ])
        let proresItem = try await MediaScanner.probe(prores, folder: folder)
        XCTAssertNil(proresItem.undecodableCodec)
        XCTAssertTrue(proresItem.hasAlpha)
    }

    func testTheFlagSurvivesJSONAndARescan() async throws {
        _ = try await sticker("qtrle")
        let first = try await MediaScanner.scan(folder, known: [])
        XCTAssertEqual(first.map(\.undecodableCodec), ["rle "])
        let decoded = try JSONDecoder().decode([MediaItem].self, from: JSONEncoder().encode(first))
        XCTAssertEqual(decoded, first)
        let again = try await MediaScanner.scan(folder, known: decoded)
        XCTAssertEqual(again, first)
    }

    func testARescanMarksStickersScannedBeforeTandemLooked() async throws {
        _ = try await sticker("qtrle")
        var scanned = try await MediaScanner.scan(folder, known: [])
        scanned[0].undecodableCodec = nil
        let again = try await MediaScanner.scan(folder, known: scanned)
        XCTAssertEqual(again.map(\.id), scanned.map(\.id))
        XCTAssertEqual(again.first?.undecodableCodec, "rle ")
    }

    func testPlayableVideoNeedsNoConversion() async throws {
        let url = file("camera.mov")
        try await SyntheticMedia.writeMovie(to: url, .init(duration: 0.5))
        let item = try await MediaScanner.probe(url, folder: folder)
        XCTAssertFalse(AnalysisKind.converted.applies(to: item))
        XCTAssertEqual(analysis().state(.converted, for: item), .notApplicable)
        XCTAssertNil(analysis().convertedURL(for: item))
        XCTAssertFalse(MediaAnalysis.defaultKinds(for: item).contains(.converted))
    }

    func testConvertedCopyIsHEVCWithAlphaAtTheSameTimes() async throws {
        for codec in ["qtrle", "png"] {
            let item = try await sticker(codec)
            let analysis = analysis()
            XCTAssertEqual(analysis.state(.converted, for: item), .missing, codec)
            let state = await analysis.waitFor(.converted, for: item)
            XCTAssertEqual(state, .ready, codec)
            let copy = try XCTUnwrap(analysis.convertedURL(for: item), codec)

            let asset = AVURLAsset(url: copy)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let (decodable, formats, size) = try await track.load(.isDecodable, .formatDescriptions, .naturalSize)
            XCTAssertTrue(decodable, codec)
            XCTAssertEqual(formats.map(CMFormatDescriptionGetMediaSubType), [kCMVideoCodecType_HEVC], codec)
            XCTAssertTrue(formats.allSatisfy(MediaProbe.containsAlpha), codec)
            let tags = CMFormatDescriptionGetExtensions(formats[0]) as? [String: Any] ?? [:]
            XCTAssertEqual(tags[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String, codec)
            XCTAssertEqual(tags[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String, codec)
            XCTAssertEqual(size, CGSize(width: 96, height: 64), codec)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertTrue(audio.isEmpty, "the copy is video only; sound comes from the original")

            // Every frame at the original's time.
            let times = try await videoSampleTimes(copy).map(\.seconds)
            XCTAssertEqual(times.count, 15, codec)
            for (index, time) in times.enumerated() {
                XCTAssertEqual(time, Double(index) / 30, accuracy: 0.001, codec)
            }

            let opaque = try await firstFramePixel(copy, x: 16, y: 32)
            XCTAssertGreaterThan(opaque.alpha, 245, codec)
            XCTAssertGreaterThan(opaque.red, 235, codec)
            XCTAssertLessThan(opaque.green, 20, codec)
            // Straight alpha: the colour isn't darkened by it.
            let half = try await firstFramePixel(copy, x: 48, y: 32)
            XCTAssertEqual(Double(half.alpha), 128, accuracy: 8, codec)
            XCTAssertGreaterThan(half.red, 235, codec)
            let clear = try await firstFramePixel(copy, x: 80, y: 32)
            XCTAssertLessThan(clear.alpha, 8, codec)
        }
    }

    func testThumbnailsAreMadeFromTheConvertedCopy() async throws {
        let item = try await sticker("qtrle")
        let analysis = analysis()
        let state = await analysis.waitFor(.thumbnails, for: item)
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(analysis.state(.converted, for: item), .ready)
        let thumbnails = try XCTUnwrap(analysis.thumbnails(for: item))
        XCTAssertFalse(thumbnails.strip.files.isEmpty)
    }

    func testABackgroundRequestConvertsFirstThenMakesTheThumbnails() async throws {
        let item = try await sticker("png")
        let analysis = analysis()
        analysis.requestDefaults(for: [item], usedOnTimeline: [])
        let deadline = Date().addingTimeInterval(60)
        while !analysis.isCached(.thumbnails, for: item), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(analysis.isCached(.converted, for: item))
        XCTAssertTrue(analysis.isCached(.thumbnails, for: item))
    }

    func testWithoutFFmpegTheConversionFailsAndSaysWhy() async throws {
        let item = try await sticker("qtrle")
        let analysis = analysis()
        analysis.ffmpeg = nil
        let state = await analysis.waitFor(.converted, for: item)
        guard case .failed(let message) = state else { return XCTFail("\(state)") }
        XCTAssertTrue(message.contains("QuickTime Animation"), message)
        XCTAssertTrue(message.contains("ffmpeg"), message)
        XCTAssertNil(analysis.convertedURL(for: item))
        // The analyses that need the picture can't start either.
        let thumbnails = await analysis.waitFor(.thumbnails, for: item)
        XCTAssertEqual(thumbnails, state)
    }
}
