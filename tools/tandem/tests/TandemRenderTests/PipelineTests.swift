import AVFoundation
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// Frames through the real AVFoundation path: composition, custom
/// compositor and AVAssetImageGenerator at zero tolerance.
final class PipelineTests: XCTestCase {
    let size = CGSize(width: 320, height: 180)

    func grab(_ context: RenderContext, _ seconds: Double) async throws -> Bitmap {
        Bitmap(try await FrameRenderer(context: context).image(at: t(seconds)))
    }

    func indexMovie(_ media: TestMedia, seconds: Double = 3) async throws {
        try await media.movie("index.mov", seconds: seconds, draw: { TestMedia.drawIndex($0, $1) })
    }

    func testFrameGrabsAreExact() async throws {
        let media = try TestMedia()
        try await indexMovie(media)
        let clip = Clip(id: "clip_a", content: .media(mediaID: "med_i"), start: .zero, duration: t(2), sourceStart: t(0.5))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_i", "index.mov", seconds: 3)])
        let renderer = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder))
        for (time, expected) in [(0.0, 15), (0.3, 24), (1.0, 45), (1.9667, 74)] {
            let frame = Bitmap(try await renderer.image(at: t(time)))
            XCTAssertEqual(TestMedia.readIndex(frame, in: CGRect(x: 0, y: 0, width: 320, height: 180)), expected, "at \(time)")
        }
        // Past the end clamps to the last frame.
        let last = Bitmap(try await renderer.image(at: t(9)))
        XCTAssertEqual(TestMedia.readIndex(last, in: CGRect(x: 0, y: 0, width: 320, height: 180)), 74)
    }

    func testSpeedAndFreezeFrames() async throws {
        let media = try TestMedia()
        try await indexMovie(media, seconds: 4)
        let fast = Clip(id: "clip_f", content: .media(mediaID: "med_i"), start: .zero, duration: t(1), sourceStart: t(0.2), speed: 2)
        var frozen = Clip(id: "clip_z", content: .media(mediaID: "med_i"), start: t(1), duration: t(1), sourceStart: t(1.5))
        frozen.freezeFrame = true
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [fast, frozen])], media: [media.item("med_i", "index.mov", seconds: 4)])
        let context = RenderContext(project: project, folder: media.projectFolder)
        let whole = CGRect(x: 0, y: 0, width: 320, height: 180)
        // Twice as fast: 0.5 s into the clip is 1 s into the media after 0.2.
        let fastFrame = try await grab(context, 0.5)
        XCTAssertEqual(TestMedia.readIndex(fastFrame, in: whole), 36)
        let frozenStart = try await grab(context, 1.1)
        let frozenEnd = try await grab(context, 1.9)
        XCTAssertEqual(TestMedia.readIndex(frozenStart, in: whole), 45)
        XCTAssertEqual(TestMedia.readIndex(frozenEnd, in: whole), 45)
    }

    func testPiPOverScreen() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 2, draw: { TestMedia.fill($1, 1, 0, 0) })
        try await media.movie("blue.mov", seconds: 2, draw: { TestMedia.fill($1, 0, 0, 1) })
        let screen = Clip(id: "clip_s", content: .media(mediaID: "med_r"), start: .zero, duration: t(2))
        let camera = Clip(id: "clip_c", content: .media(mediaID: "med_b"), start: .zero, duration: t(2),
                          video: VideoProperties(transform: Transform(position: Point(x: 0.75, y: 0.75), scale: 0.5)))
        let project = smallProject(
            video: [Track(kind: .video, name: "Screen", clips: [screen]), Track(kind: .video, name: "Camera", clips: [camera])],
            media: [media.item("med_r", "red.mov", seconds: 2), media.item("med_b", "blue.mov", seconds: 2)]
        )
        let frame = try await grab(RenderContext(project: project, folder: media.projectFolder), 1)
        assertColor(frame[240, 135], [0, 0, 255], tolerance: 8)
        assertColor(frame[60, 60], [255, 0, 0], tolerance: 8)
        assertColor(frame[150, 135], [255, 0, 0], tolerance: 8)
    }

    func testDissolveUsesBothClipsAtOnce() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 4, draw: { TestMedia.fill($1, 1, 0, 0) })
        try await media.movie("green.mov", seconds: 4, draw: { TestMedia.fill($1, 0, 1, 0) })
        let a = Clip(id: "clip_a", content: .media(mediaID: "med_r"), start: .zero, duration: t(2), sourceStart: t(1))
        let b = Clip(id: "clip_b", content: .media(mediaID: "med_g"), start: t(2), duration: t(1), sourceStart: t(1))
        let dissolve = Transition(type: .dissolve, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b")
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [a, b], transitions: [dissolve])],
            media: [media.item("med_r", "red.mov", seconds: 4), media.item("med_g", "green.mov", seconds: 4)]
        )
        let context = RenderContext(project: project, folder: media.projectFolder)
        let built = try await CompositionBuilder.build(context)
        // Base plus A and B.
        XCTAssertEqual(built.composition.tracks(withMediaType: .video).count, 3)
        assertColor(try await grab(context, 2)[160, 90], [128, 128, 0], tolerance: 8)
        assertColor(try await grab(context, 1.2)[160, 90], [255, 0, 0], tolerance: 8)
        assertColor(try await grab(context, 2.8)[160, 90], [0, 255, 0], tolerance: 8)
    }

    func testCutoutWithAMatteFile() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 2, draw: { TestMedia.fill($1, 1, 0, 0) })
        try await media.movie("blue.mov", seconds: 2, draw: { TestMedia.fill($1, 0, 0, 1) })
        // The matte: the "person" is the left half.
        let matte = try await media.movie("matte.mov", seconds: 2, size: CGSize(width: 160, height: 90), draw: { _, c in
            TestMedia.fill(c, 0, 0, 0, size: CGSize(width: 160, height: 90))
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 80, height: 90))
        })
        let screen = Clip(id: "clip_s", content: .media(mediaID: "med_r"), start: .zero, duration: t(2))
        let camera = Clip(id: "clip_c", content: .media(mediaID: "med_b"), start: .zero, duration: t(2),
                          video: VideoProperties(cutout: Cutout(edgeFeather: 0)))
        let project = smallProject(
            video: [Track(kind: .video, name: "Screen", clips: [screen]), Track(kind: .video, name: "Camera", clips: [camera])],
            media: [media.item("med_r", "red.mov", seconds: 2), media.item("med_b", "blue.mov", seconds: 2)]
        )
        let assets = FakeAssets()
        assets.mattes["med_b"] = matte
        let frame = try await grab(RenderContext(project: project, folder: media.projectFolder, assets: assets), 1)
        assertColor(frame[60, 90], [0, 0, 255], tolerance: 8)
        assertColor(frame[260, 90], [255, 0, 0], tolerance: 8)
    }

    func testProxiesAreUsedForPlaybackOnly() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 2, draw: { TestMedia.fill($1, 1, 0, 0) })
        let proxy = try await media.movie("proxy.mov", seconds: 2, draw: { TestMedia.fill($1, 0, 1, 0) })
        let clip = Clip(id: "clip_s", content: .media(mediaID: "med_r"), start: .zero, duration: t(2))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_r", "red.mov", seconds: 2)])
        let assets = FakeAssets()
        assets.proxies["med_r"] = proxy
        let playback = RenderContext(project: project, folder: media.projectFolder, useProxies: true, assets: assets)
        assertColor(try await grab(playback, 1)[160, 90], [0, 255, 0], tolerance: 8)
        let export = RenderContext(project: project, folder: media.projectFolder, useProxies: false, assets: assets)
        assertColor(try await grab(export, 1)[160, 90], [255, 0, 0], tolerance: 8)
    }

    func testRotatedPhoneClipIsShownUpright() async throws {
        let media = try TestMedia()
        let url = media.folder.appendingPathComponent("phone.mov")
        // Encoded landscape: top half red, bottom half blue.
        try await media.movie("phone-raw.mov", seconds: 1, draw: { _, c in
            TestMedia.fill(c, 0, 0, 1)
            c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 320, height: 90))
        })
        // Copy with a 90 degree preferred transform, as a phone writes it.
        let raw = AVURLAsset(url: media.folder.appendingPathComponent("phone-raw.mov"))
        let composition = AVMutableComposition()
        let source = try await raw.loadTracks(withMediaType: .video)[0]
        let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try track.insertTimeRange(try await source.load(.timeRange), of: source, at: .zero)
        track.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await export.export(to: url, as: .mov)

        let clip = Clip(id: "clip_p", content: .media(mediaID: "med_p"), start: .zero, duration: t(1))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_p", "phone.mov", seconds: 1)])
        let frame = try await grab(RenderContext(project: project, folder: media.projectFolder), 0.5)
        // Upright 180x320 fitted into 320x180: about 101 wide, centred.
        // The encoded top edge is now on the right.
        assertColor(frame[190, 90], [255, 0, 0], tolerance: 8)
        assertColor(frame[130, 90], [0, 0, 255], tolerance: 8)
        assertColor(frame[20, 90], [0, 0, 0], tolerance: 4)
    }

    func testGrabsScaleDownToAMaximumSize() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 1, draw: { TestMedia.fill($1, 1, 0, 0) })
        let clip = Clip(id: "clip_s", content: .media(mediaID: "med_r"), start: .zero, duration: t(1))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_r", "red.mov", seconds: 1)])
        let renderer = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder))
        let small = try await renderer.image(at: t(0.5), maxSize: CGSize(width: 160, height: 160))
        XCTAssertEqual(small.width, 160)
        XCTAssertEqual(small.height, 90)
        assertColor(Bitmap(small)[80, 45], [255, 0, 0], tolerance: 8)
        let png = try await renderer.pngData(at: t(0.5))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testVideoCompositionPassesAVFoundationValidation() async throws {
        let media = try TestMedia()
        try await media.movie("red.mov", seconds: 4, draw: { TestMedia.fill($1, 1, 0, 0) }, sound: { _ in 0.05 })
        let a = Clip(id: "clip_a", content: .media(mediaID: "med_r"), start: .zero, duration: t(2), sourceStart: t(1))
        let b = Clip(id: "clip_b", content: .media(mediaID: "med_r"), start: t(2), duration: t(1), sourceStart: t(2))
        let title = Clip(id: "clip_t", content: .text(TextContent(text: "Hi")), start: t(0.5), duration: t(3))
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [a, b], transitions: [Transition(type: .push, duration: t(0.6), fromClipID: "clip_a", toClipID: "clip_b")]),
                    Track(kind: .video, name: "Text", clips: [title])],
            audio: [Track(kind: .audio, name: "A1", clips: [Clip(id: "clip_s", content: .media(mediaID: "med_r"), start: .zero, duration: t(3))])],
            media: [media.item("med_r", "red.mov", seconds: 4, audio: true)]
        )
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
        let tracks = try await built.composition.load(.tracks)
        let valid = built.videoComposition.isValid(for: tracks, assetDuration: built.composition.duration, timeRange: CMTimeRange(start: .zero, duration: built.composition.duration), validationDelegate: nil)
        XCTAssertTrue(valid)
    }

    func testTitlesOnlyTimeline() async throws {
        let media = try TestMedia()
        let title = Clip(id: "clip_t", content: .text(TextContent(text: "v1.46.0", preset: "version")), start: .zero, duration: t(2))
        let project = smallProject(video: [Track(kind: .video, name: "Text", clips: [title])], media: [])
        let frame = try await grab(RenderContext(project: project, folder: media.projectFolder), 1)
        XCTAssertGreaterThan(frame.litPixels(), 1_000)
        assertColor(frame[2, 2], [0, 0, 0])
    }

    func testMissingMediaIsAWarningNotAFailure() async throws {
        let media = try TestMedia()
        let clip = Clip(id: "clip_x", content: .media(mediaID: "med_x"), start: .zero, duration: t(2))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_x", "gone.mov", seconds: 2)])
        let renderer = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder))
        let frame = Bitmap(try await renderer.image(at: t(1)))
        assertColor(frame[160, 90], [0, 0, 0])
        let warnings = try await renderer.warnings()
        XCTAssertTrue(warnings.contains { $0.contains("gone.mov") }, "\(warnings)")
    }

    func testEmptyTimelineThrows() async throws {
        let media = try TestMedia()
        let project = smallProject(video: [Track(kind: .video, name: "V1")], media: [])
        do {
            _ = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RenderError, .emptyTimeline)
        }
    }

    func testCompositionStructure() async throws {
        let media = try TestMedia()
        try await media.movie("av.mov", seconds: 3, draw: { TestMedia.fill($1, 1, 1, 1) }, sound: { _ in 0.1 })
        let item = media.item("med_av", "av.mov", seconds: 3, audio: true)
        let picture = Clip(id: "clip_v", content: .media(mediaID: "med_av"), start: .zero, duration: t(2), linkGroup: "lnk_a")
        let sound = Clip(id: "clip_a", content: .media(mediaID: "med_av"), start: .zero, duration: t(2), linkGroup: "lnk_a")
        let music = Clip(id: "clip_m", content: .media(mediaID: "med_av"), start: t(1), duration: t(2))
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [picture])],
            audio: [Track(kind: .audio, name: "Voice", clips: [sound]), Track(kind: .audio, name: "Music", clips: [music])],
            media: [item]
        )
        let built = try await CompositionBuilder.build(RenderContext(project: project, folder: media.projectFolder))
        XCTAssertEqual(built.duration, t(3))
        XCTAssertEqual(built.renderSize, size)
        XCTAssertEqual(built.composition.tracks(withMediaType: .video).count, 2)
        XCTAssertEqual(built.composition.tracks(withMediaType: .audio).count, 2)
        XCTAssertEqual(built.videoComposition.frameDuration, CMTime(value: 1, timescale: 30))
        let ranges = built.videoComposition.instructions.map(\.timeRange)
        XCTAssertEqual(ranges.first?.start, .zero)
        XCTAssertEqual(ranges.last.map { Time(cmTime: $0.end) }, t(3))
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(a.end, b.start)
        }
        XCTAssertEqual((built.audioMix.inputParameters).count, 2)
        // The blocking builder gives the same shape.
        let sync = try buildBlocking(RenderContext(project: project, folder: media.projectFolder))
        XCTAssertEqual(sync.duration, built.duration)
    }

    /// Synchronous callers get the blocking overload.
    func buildBlocking(_ context: RenderContext) throws -> BuiltComposition {
        try CompositionBuilder.build(context)
    }
}
