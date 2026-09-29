import AVFoundation
import XCTest
import TandemCore
@testable import TandemMedia
@testable import TandemRender

/// Stickers in codecs macOS can't decode (QuickTime Animation, PNG in a
/// MOV) render from their converted copy, and never take the whole render
/// down with them ("Cannot Decode").
final class UndecodableMediaTests: XCTestCase {
    /// A blue background, with a 320x180 sticker on the track above: the
    /// left third opaque red, the middle third red at half alpha, the right
    /// third clear. `flagged: false` is a sticker scanned before Tandem
    /// looked for codecs it can't decode.
    func project(_ media: TestMedia, codec: String = "qtrle", flagged: Bool = true) async throws -> Project {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        try await media.movie("blue.mov", seconds: 1, draw: { TestMedia.fill($1, 0, 0, 1) })
        let url = media.folder.appendingPathComponent("stickers/pop.mov")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ffmpeg.run([
            "-y", "-v", "error", "-f", "lavfi",
            "-i", "color=c=red:s=320x180:d=1:r=30,format=rgba,geq=r='255':g='0':b='0':a='if(lt(X,W/3),255,if(lt(X,2*W/3),128,0))'",
            "-c:v", codec, "-pix_fmt", codec == "qtrle" ? "argb" : "rgba", url.path
        ])
        var sticker = try await MediaScanner.probe(url, folder: media.projectFolder, id: "med_pop")
        XCTAssertNotNil(sticker.undecodableCodec)
        if !flagged { sticker.undecodableCodec = nil }
        return smallProject(video: [
            Track(kind: .video, name: "V1", clips: [Clip(id: "clip_bg", content: .media(mediaID: "med_bg"), start: .zero, duration: t(1))]),
            Track(kind: .video, name: "V2", clips: [Clip(id: "clip_pop", content: .media(mediaID: "med_pop"), start: .zero, duration: t(1))])
        ], media: [media.item("med_bg", "blue.mov", seconds: 1), sticker])
    }

    func analysis(_ media: TestMedia) -> MediaAnalysis {
        MediaAnalysis(folder: media.projectFolder, encoderLock: EncoderLock())
    }

    func testStickersRenderFromTheirConvertedCopy() async throws {
        for codec in ["qtrle", "png"] {
            let media = try TestMedia()
            let project = try await project(media, codec: codec)
            // Frame grabs convert what they need before building.
            let renderer = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder, analysis: analysis(media)))
            let frame = Bitmap(try await renderer.image(at: t(0.5)))
            assertColor(frame[53, 90], [255, 0, 0], tolerance: 12, codec)
            assertColor(frame[160, 90], [128, 0, 127], tolerance: 16, "straight alpha over blue, \(codec)")
            assertColor(frame[266, 90], [0, 0, 255], tolerance: 12, codec)
            let warnings = try await renderer.warnings()
            XCTAssertEqual(warnings, [], codec)
        }
    }

    func testWithoutAConvertedCopyTheStickerIsLeftOutWithAWarning() async throws {
        let media = try TestMedia()
        let project = try await project(media)
        // No analysis: nothing can convert it.
        let renderer = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder))
        let frame = Bitmap(try await renderer.image(at: t(0.5)))
        assertColor(frame[53, 90], [0, 0, 255], tolerance: 12, "the background shows where the sticker would be")
        let warnings = try await renderer.warnings()
        XCTAssertTrue(warnings.contains { $0.contains("stickers/pop.mov") && $0.contains("QuickTime Animation") }, "\(warnings)")
    }

    func testWhenTheConversionFailsTheWarningSaysWhy() async throws {
        let media = try TestMedia()
        let project = try await project(media, codec: "png")
        let analysis = analysis(media)
        analysis.ffmpeg = nil
        let renderer = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder, analysis: analysis))
        let frame = Bitmap(try await renderer.image(at: t(0.5)))
        assertColor(frame[53, 90], [0, 0, 255], tolerance: 12)
        let warnings = try await renderer.warnings()
        XCTAssertTrue(warnings.contains { $0.contains("stickers/pop.mov") && $0.contains("ffmpeg") }, "\(warnings)")
    }

    func testAStickerScannedBeforeTandemLookedDoesntStopTheRender() async throws {
        let media = try TestMedia()
        let project = try await project(media, flagged: false)
        // Playback builds straight away: the clip is left out, and says so.
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder, analysis: analysis(media)))
        XCTAssertTrue(built.warnings.contains { $0.contains("stickers/pop.mov") && $0.contains("can't decode") }, "\(built.warnings)")
        let unconverted = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder))
        assertColor(Bitmap(try await unconverted.image(at: t(0.5)))[53, 90], [0, 0, 255], tolerance: 12)
        // A frame grab notices and converts it.
        let renderer = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder, analysis: analysis(media)))
        let frame = Bitmap(try await renderer.image(at: t(0.5)))
        assertColor(frame[53, 90], [255, 0, 0], tolerance: 12)
        let warnings = try await renderer.warnings()
        XCTAssertEqual(warnings, [])
    }

    func testExportWaitsForTheConversion() async throws {
        let media = try TestMedia()
        let project = try await project(media, codec: "png")
        let output = media.folder.appendingPathComponent("exports/Stickers.mp4")
        let preset = ExportPreset(name: "Test", codec: .h264, videoBitrate: 4_000_000, audioBitrate: 192_000, loudnessTarget: nil, truePeakCeiling: nil)
        _ = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder, analysis: analysis(media)), preset: preset, output: output).run()

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = Bitmap(try await generator.image(at: CMTime(value: 15, timescale: 30)).image)
        assertColor(frame[53, 90], [255, 0, 0], tolerance: 20)
        assertColor(frame[266, 90], [0, 0, 255], tolerance: 20)
    }
}
