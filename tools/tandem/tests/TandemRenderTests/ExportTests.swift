import AVFoundation
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

final class ExportTests: XCTestCase {
    /// A small, fast preset.
    func preset(codec: ExportPreset.Codec = .h264, loudness: Double? = -14, range: TimeRange? = nil, format: String? = nil) -> ExportPreset {
        ExportPreset(name: "Test", codec: codec, videoBitrate: 4_000_000, audioBitrate: 192_000, loudnessTarget: loudness, truePeakCeiling: loudness == nil ? nil : -1, range: range, format: format)
    }

    func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    /// Presentation time of the first frame whose centre is bright.
    func firstBrightFrame(_ url: URL) async throws -> Double? {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(output)
        reader.startReading()
        var best: Double?
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let row = CVPixelBufferGetHeight(pixels) / 2
            let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!
                .load(fromByteOffset: row * CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) + CVPixelBufferGetWidth(pixels) / 2, as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if luma > 128, best.map({ time < $0 }) ?? true { best = time }
        }
        return best
    }

    func testExportMakesATaggedFileWithASnapshot() async throws {
        let media = try TestMedia()
        try await media.movie("av.mov", seconds: 3, draw: { TestMedia.fill($1, 0.2, 0.4, 0.8) }, sound: { i in Float(0.1 * sin(2 * Double.pi * 440 * Double(i) / 48_000)) })
        let item = media.item("med_av", "av.mov", seconds: 3, audio: true)
        let picture = Clip(id: "clip_v", content: .media(mediaID: "med_av"), start: .zero, duration: t(2), linkGroup: "lnk_1")
        let sound = Clip(id: "clip_a", content: .media(mediaID: "med_av"), start: .zero, duration: t(2), linkGroup: "lnk_1")
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [picture])], audio: [Track(kind: .audio, name: "A1", clips: [sound])], media: [item])
        let out = media.folder.appendingPathComponent("exports/Test.mp4")
        final class Reports: @unchecked Sendable { var values: [Double] = [] }
        let reports = Reports()
        let result = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder), preset: preset(codec: .hevc), output: out)
            .run { reports.values.append($0) }

        XCTAssertEqual(result.duration, t(2))
        XCTAssertGreaterThan(result.elapsed, 0)
        let fileDuration = try await duration(out)
        XCTAssertEqual(fileDuration, 2, accuracy: 0.05)
        XCTAssertEqual(reports.values.last, 1)
        XCTAssertEqual(reports.values, reports.values.sorted())

        let asset = AVURLAsset(url: out)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let video = try await videoTracks[0].load(.formatDescriptions)[0]
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(video), kCMVideoCodecType_HEVC)
        let dims = CMVideoFormatDescriptionGetDimensions(video)
        XCTAssertEqual(dims.width, 320)
        XCTAssertEqual(dims.height, 180)
        let ext = CMFormatDescriptionGetExtensions(video) as? [String: Any] ?? [:]
        XCTAssertEqual(ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        XCTAssertEqual(ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String, kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        XCTAssertEqual(ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        XCTAssertNotEqual(ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool, true)
        let audio = try await audioTracks[0].load(.formatDescriptions)[0]
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audio)!.pointee
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(asbd.mSampleRate, 48_000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)

        // The snapshot beside the file reopens as a project.
        let snapshot = URL(fileURLWithPath: out.path + ".tandem")
        let (saved, _) = try ProjectFile.load(from: snapshot)
        XCTAssertEqual(saved.media[0].path, media.folder.appendingPathComponent("av.mov").standardizedFileURL.path)
        XCTAssertEqual(saved.metadata["export.preset"], "Test")
        XCTAssertTrue(saved.metadata["export.loudness"]?.hasSuffix("dBTP") ?? false)
        XCTAssertEqual(saved.videoTracks[0].clips, project.videoTracks[0].clips)

        // Colours come through: the frame is the source's blue-ish grey.
        let frame = Bitmap(try await AVAssetImageGenerator(asset: asset).image(at: CMTime(value: 1, timescale: 1)).image)
        assertColor(frame[160, 90], [51, 102, 204], tolerance: 8)
    }

    func testFlashAndBeepStayInSync() async throws {
        let media = try TestMedia()
        // A white flash at 1.5 s (frames 45 to 47) and a 1 kHz beep at the
        // same moment, in one file like a camera recording.
        try await media.movie("sync.mov", seconds: 3, draw: { i, c in
            let on = (45...47).contains(i)
            TestMedia.fill(c, on ? 1 : 0, on ? 1 : 0, on ? 1 : 0)
        }, sound: { i in
            (72_000..<74_400).contains(i) ? Float(0.25 * sin(2 * Double.pi * 1000 * Double(i) / 48_000)) : 0
        })
        let item = media.item("med_s", "sync.mov", seconds: 3, audio: true)
        // Placed 0.2 s in, from 0.5 s into the file: the flash lands at 1.2 s.
        let picture = Clip(id: "clip_v", content: .media(mediaID: "med_s"), start: t(0.2), duration: t(2.3), sourceStart: t(0.5), linkGroup: "lnk_1")
        let sound = Clip(id: "clip_a", content: .media(mediaID: "med_s"), start: t(0.2), duration: t(2.3), sourceStart: t(0.5), linkGroup: "lnk_1")
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [picture])], audio: [Track(kind: .audio, name: "A1", clips: [sound])], media: [item])
        let out = media.folder.appendingPathComponent("sync.mp4")
        _ = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder), preset: preset(), output: out).run()

        let flash = try await firstBrightFrame(out)
        let samples = try await decodeAudio(out)
        let beepIndex = stride(from: 0, to: samples.count, by: 2).first { abs(samples[$0]) > 0.05 }
        let flashTime = try XCTUnwrap(flash)
        let beepTime = Double(try XCTUnwrap(beepIndex) / 2) / 48_000
        XCTAssertEqual(flashTime, 1.2, accuracy: 0.034)
        XCTAssertEqual(beepTime, 1.2, accuracy: 0.034)
        XCTAssertLessThan(abs(flashTime - beepTime), 1.0 / 30)
    }

    func testLoudnessIsMasteredToTheTarget() async throws {
        let media = try TestMedia()
        // A quiet tone at -30 dBFS with loud clicks: +16 dB of gain brings it
        // to -14 LUFS, and the limiter has to catch the clicks.
        try await media.movie("quiet.mov", seconds: 2.5, draw: { TestMedia.fill($1, 0, 0, 0) }, sound: { i in
            if i % 12_000 == 6_000 { return 0.9 }
            return Float(pow(10, -30.0 / 20) * sin(2 * Double.pi * 1000 * Double(i) / 48_000))
        })
        let item = media.item("med_q", "quiet.mov", seconds: 2.5, audio: true)
        let sound = Clip(id: "clip_a", content: .media(mediaID: "med_q"), start: .zero, duration: t(2.5))
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "A1", clips: [sound])], media: [item])
        let out = media.folder.appendingPathComponent("loud.m4v")
        let result = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder), preset: preset(), output: out).run()

        let reported = try XCTUnwrap(result.integratedLUFS)
        XCTAssertEqual(reported, -14, accuracy: 0.5)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.truePeakDBTP), -1 + 0.05)
        var meter = LoudnessMeter(sampleRate: 48_000, channels: 2)
        meter.process(interleaved: try await decodeAudio(out))
        XCTAssertEqual(meter.integrated, -14, accuracy: 0.5)
        // AAC adds a little overshoot; the limiter's margin keeps it close.
        XCTAssertLessThanOrEqual(meter.truePeak, -1 + 0.5)
    }

    func testWithoutATargetTheMixIsLeftAlone() async throws {
        let media = try TestMedia()
        try await media.movie("tone.mov", seconds: 2, draw: { TestMedia.fill($1, 0, 0, 0) }, sound: { i in
            Float(pow(10, -20.0 / 20) * sin(2 * Double.pi * 1000 * Double(i) / 48_000))
        })
        let item = media.item("med_t", "tone.mov", seconds: 2, audio: true)
        let sound = Clip(id: "clip_a", content: .media(mediaID: "med_t"), start: .zero, duration: t(2))
        let project = smallProject(video: [], audio: [Track(kind: .audio, name: "A1", clips: [sound])], media: [item])
        let out = media.folder.appendingPathComponent("tone.mov")
        let result = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder), preset: preset(loudness: nil), output: out).run()
        XCTAssertEqual(try XCTUnwrap(result.integratedLUFS), -20, accuracy: 0.3)
    }

    func testRangeExport() async throws {
        let media = try TestMedia()
        try await media.movie("index.mov", seconds: 3, draw: { TestMedia.drawIndex($0, $1) })
        let clip = Clip(id: "clip_i", content: .media(mediaID: "med_i"), start: .zero, duration: t(3))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_i", "index.mov", seconds: 3)])
        let out = media.folder.appendingPathComponent("range.mp4")
        let result = try await Exporter(
            context: RenderContext(project: project, folder: media.projectFolder),
            preset: preset(range: TimeRange(start: t(0.5), duration: t(1))),
            output: out
        ).run()
        XCTAssertEqual(result.duration, t(1))
        let fileDuration = try await duration(out)
        XCTAssertEqual(fileDuration, 1, accuracy: 0.05)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = Bitmap(try await generator.image(at: .zero).image)
        XCTAssertEqual(TestMedia.readIndex(first, in: CGRect(x: 0, y: 0, width: 320, height: 180)), 15)
    }

    func testAlternateFormatAndSilentAudio() async throws {
        let media = try TestMedia()
        let title = Clip(id: "clip_t", content: .text(TextContent(text: "Short", preset: "label")), start: .zero, duration: t(1))
        var project = smallProject(video: [Track(kind: .video, name: "Text", clips: [title])], media: [])
        project.settings.alternateFormats = [OutputFormat(id: "portrait", name: "Short", width: 180, height: 320)]
        let out = media.folder.appendingPathComponent("short.mp4")
        let result = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder), preset: preset(format: "portrait"), output: out).run()
        let asset = AVURLAsset(url: out)
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 180, height: 320))
        // There's always a sound track, silent here.
        let samples = try await decodeAudio(out)
        XCTAssertGreaterThan(samples.count, 90_000)
        XCTAssertEqual(samples.map(abs).max() ?? 1, 0, accuracy: 1e-4)
        XCTAssertNil(result.integratedLUFS)
    }

    func testPresetSizeOverridesTheCanvas() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 1, draw: { TestMedia.fill($1, 1, 0, 0) })
        let clip = Clip(id: "clip_s", content: .media(mediaID: "med_r"), start: .zero, duration: t(1))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_r", "red.mov", seconds: 1)])
        let out = media.folder.appendingPathComponent("small.mp4")
        var small = preset(loudness: nil)
        small.width = 160
        small.height = 90
        _ = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder), preset: small, output: out).run()
        let size = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 160, height: 90))
    }

    func testCancellingStopsAndRemovesTheFile() async throws {
        let media = try TestMedia()
        try await media.movie("long.mov", seconds: 6, draw: { TestMedia.drawIndex($0, $1) })
        let clip = Clip(id: "clip_l", content: .media(mediaID: "med_l"), start: .zero, duration: t(6))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_l", "long.mov", seconds: 6)])
        let out = media.folder.appendingPathComponent("cancelled.mp4")
        let exporter = Exporter(context: RenderContext(project: project, folder: media.projectFolder), preset: preset(loudness: nil), output: out)
        do {
            _ = try await exporter.run { progress in
                if progress > 0.2 { exporter.cancel() }
            }
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? RenderError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))

        // Cancelled before it starts: nothing happens.
        let early = Exporter(context: RenderContext(project: project, folder: media.projectFolder), preset: preset(loudness: nil), output: out)
        early.cancel()
        do {
            _ = try await early.run()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? RenderError, .cancelled)
        }
    }
}
