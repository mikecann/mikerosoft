import CoreImage
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// Golden-pixel tests of the layer pipeline on a 320x180 canvas.
final class CompositorTests: XCTestCase {
    let red = [255, 0, 0], green = [0, 255, 0], blue = [0, 0, 255], black = [0, 0, 0], white = [255, 255, 255]

    func clip(_ id: String, _ media: String, start: Double = 0, duration: Double = 4, video: VideoProperties? = nil) -> Clip {
        Clip(id: id, content: .media(mediaID: media), start: t(start), duration: t(duration), sourceStart: t(10), video: video)
    }

    /// Red screen on V1, blue camera on V2.
    func screenAndCamera(_ camera: VideoProperties?) -> CompositorHarness {
        let v1 = Track(kind: .video, name: "Screen", clips: [clip("clip_s", "med_red")])
        let v2 = Track(kind: .video, name: "Camera", clips: [clip("clip_c", "med_blue", video: camera)])
        var h = CompositorHarness(smallProject(video: [v1, v2], media: [redMedia, blueMedia]))
        h.pictures = ["med_red": solid(1, 0, 0), "med_blue": solid(0, 0, 1)]
        return h
    }

    func testBitmapIsTopDown() {
        // Core Image is y up: the top half of this picture is its high y.
        let v1 = Track(kind: .video, name: "V1", clips: [clip("clip_s", "med_red")])
        var h = CompositorHarness(smallProject(video: [v1], media: [redMedia]))
        h.pictures["med_red"] = solid(0, 0, 1).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 90))
            .composited(over: solid(1, 0, 0))
        let frame = h.render(at: t(1))
        assertColor(frame[160, 20], red)
        assertColor(frame[160, 160], blue)
    }

    func testLayerOrderAndPiPPlacement() {
        let frame = screenAndCamera(VideoProperties(transform: Transform(position: Point(x: 0.75, y: 0.75), scale: 0.5))).render(at: t(1))
        // PiP covers x 160...320, y 90...180.
        assertColor(frame[240, 135], blue)
        assertColor(frame[164, 94], blue)
        assertColor(frame[155, 94], red)
        assertColor(frame[164, 85], red)
        assertColor(frame[40, 40], red)
    }

    func testRotationTurnsTheLayerClockwise() {
        // A wide bar rotated 90 degrees stands upright in the middle.
        let bar = VideoProperties(transform: Transform(scale: 0.5, rotation: 90))
        let frame = screenAndCamera(bar).render(at: t(1))
        // Upright: 90 wide, 160 tall, centred.
        assertColor(frame[160, 20], blue)
        assertColor(frame[160, 160], blue)
        assertColor(frame[100, 90], red)
        assertColor(frame[220, 90], red)
    }

    func testCropHidesEdgesWithoutMovingTheLayer() {
        let frame = screenAndCamera(VideoProperties(crop: Crop(left: 0.5))).render(at: t(1))
        assertColor(frame[80, 90], red)
        assertColor(frame[240, 90], blue)
    }

    func testOpacityMultipliesTheLayer() {
        let frame = screenAndCamera(VideoProperties(opacity: 0.5)).render(at: t(1))
        assertColor(frame[160, 90], [128, 0, 128], tolerance: 3)
    }

    func testKeyframedOpacityIsEvaluatedPerFrame() {
        var h = screenAndCamera(nil)
        h.project.videoTracks[1].clips[0].keyframes["video.opacity"] = [
            Keyframe(time: t(0), value: .number(0), interpolation: .linear),
            Keyframe(time: t(2), value: .number(1))
        ]
        assertColor(h.render(at: t(0))[160, 90], red)
        assertColor(h.render(at: t(1))[160, 90], [128, 0, 128], tolerance: 3)
        assertColor(h.render(at: t(3))[160, 90], blue)
    }

    func testKeyframedPositionMovesTheLayer() {
        var h = screenAndCamera(VideoProperties(transform: Transform(scale: 0.25)))
        h.project.videoTracks[1].clips[0].keyframes["video.transform.position"] = [
            Keyframe(time: t(0), value: .point(Point(x: 0.25, y: 0.5)), interpolation: .linear),
            Keyframe(time: t(2), value: .point(Point(x: 0.75, y: 0.5)))
        ]
        assertColor(h.render(at: t(0))[80, 90], blue)
        assertColor(h.render(at: t(0))[240, 90], red)
        assertColor(h.render(at: t(1))[160, 90], blue)
        assertColor(h.render(at: t(2))[240, 90], blue)
        assertColor(h.render(at: t(2))[80, 90], red)
    }

    func testHiddenTrackAndGapShowBlack() {
        var h = screenAndCamera(nil)
        h.project.videoTracks[1].hidden = true
        assertColor(h.render(at: t(1))[160, 90], red)
        assertColor(h.render(at: t(5))[160, 90], black)
    }

    func testSolidsAndPortraitFormatOverride() {
        var v2 = Track(kind: .video, name: "V2", clips: [clip("clip_c", "med_blue", video: VideoProperties(
            transform: Transform(position: Point(x: 0.87, y: 0.77), scale: 0.5),
            formatOverrides: ["portrait": FormatOverride(transform: Transform(position: Point(x: 0.5, y: 0.75), scale: 1))]
        ))])
        v2.clips.append(Clip(id: "clip_k", content: .solid(color: RGBA(r: 0, g: 1, b: 0)), start: t(4), duration: t(2)))
        var project = smallProject(video: [v2], media: [blueMedia])
        project.settings.alternateFormats = [OutputFormat(id: "portrait", name: "Short", width: 90, height: 160)]
        var h = CompositorHarness(project)
        h.pictures["med_blue"] = solid(0, 0, 1)
        h.format = "portrait"
        h.canvas = CGSize(width: 90, height: 160)
        let frame = h.render(at: t(1))
        // 320x180 fitted into 90 wide is 90x50.6, centred at y = 120.
        assertColor(frame[45, 120], blue)
        assertColor(frame[45, 90], black)
        assertColor(frame[45, 20], black)
        // A solid fills the canvas.
        assertColor(h.render(at: t(5))[10, 10], green)
    }

    func testImagesAreDrawnByTheCompositor() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-render-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("shot.png")
        let cg = RenderEngine.context.createCGImage(solid(0, 1, 0, width: 64, height: 64), from: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
        let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let still = MediaItem(id: "med_png", path: "shot.png", kind: .image, role: .image, width: 64, height: 64)
        let v1 = Track(kind: .video, name: "V1", clips: [Clip(id: "clip_i", content: .media(mediaID: "med_png"), start: .zero, duration: t(2))])
        var h = CompositorHarness(smallProject(video: [v1], media: [still]))
        h.folder = ProjectFolder(root: folder)
        let frame = h.render(at: t(1))
        // A square fits the canvas height: 180x180 in the middle.
        assertColor(frame[160, 90], green)
        assertColor(frame[40, 90], black)
    }

    // MARK: Transitions

    func twoClips(_ transition: Transition) -> CompositorHarness {
        let a = clip("clip_a", "med_red", start: 0, duration: 2)
        let b = clip("clip_b", "med_green", start: 2, duration: 2)
        let v1 = Track(kind: .video, name: "V1", clips: [a, b], transitions: [transition])
        var h = CompositorHarness(smallProject(video: [v1], media: [redMedia, greenMedia]))
        h.pictures = ["med_red": solid(1, 0, 0), "med_green": solid(0, 1, 0)]
        return h
    }

    func testDissolveMidpointIsAnEvenMix() {
        let h = twoClips(Transition(type: .dissolve, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b"))
        assertColor(h.render(at: t(1.4))[160, 90], red)
        assertColor(h.render(at: t(2))[160, 90], [128, 128, 0], tolerance: 3)
        assertColor(h.render(at: t(2.6))[160, 90], green)
    }

    func testDipToBlack() {
        let h = twoClips(Transition(type: .fadeToBlack, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b"))
        assertColor(h.render(at: t(1.75))[160, 90], [128, 0, 0], tolerance: 3)
        assertColor(h.render(at: t(2))[160, 90], black)
        assertColor(h.render(at: t(2.25))[160, 90], [0, 128, 0], tolerance: 3)

        // One-sided at the end of the video: the whole length fades.
        let a = clip("clip_a", "med_red", start: 0, duration: 2)
        var h2 = CompositorHarness(smallProject(video: [Track(kind: .video, name: "V1", clips: [a], transitions: [
            Transition(type: .fadeToBlack, duration: t(1), fromClipID: "clip_a", toClipID: nil)
        ])], media: [redMedia]))
        h2.pictures["med_red"] = solid(1, 0, 0)
        assertColor(h2.render(at: t(1.5))[160, 90], [128, 0, 0], tolerance: 3)
    }

    func testPushLeftHalfway() {
        let h = twoClips(Transition(type: .push, direction: .left, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b"))
        let frame = h.render(at: t(2))
        assertColor(frame[40, 90], red)
        assertColor(frame[280, 90], green)
        // A quarter in (eased), the incoming shot has barely entered.
        let early = h.render(at: t(1.75))
        assertColor(early[280, 90], red)
        assertColor(early[318, 90], green)
    }

    func testPushDownBringsTheNewShotFromTheTop() {
        let h = twoClips(Transition(type: .push, direction: .down, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b"))
        let frame = h.render(at: t(2))
        assertColor(frame[160, 20], green)
        assertColor(frame[160, 160], red)
    }

    func testSlideKeepsTheOutgoingShotStill() {
        var h = twoClips(Transition(type: .slide, direction: .left, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b"))
        // A split picture shows whether the outgoing shot moved.
        h.pictures["med_red"] = split(CIColor(red: 1, green: 0, blue: 0), CIColor(red: 0, green: 0, blue: 1))
        let frame = h.render(at: t(2))
        assertColor(frame[40, 90], red)
        assertColor(frame[280, 90], green)
    }

    func testCutSlideIsFastAndBlurred() {
        let h = twoClips(Transition(type: .cutSlide, direction: .left, duration: t(0.6), fromClipID: "clip_a", toClipID: "clip_b"))
        // Mostly still near the ends: the move happens in the middle.
        assertColor(h.render(at: t(1.72))[160, 90], red, tolerance: 12)
        let middle = h.render(at: t(2))
        // The seam is soft rather than a hard edge.
        let seam = middle[160, 90]
        XCTAssertGreaterThan(seam[0], 30)
        XCTAssertGreaterThan(seam[1], 30)
    }

    func testWipeRevealsFromTheLeft() {
        let h = twoClips(Transition(type: .wipe, direction: .right, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b"))
        let frame = h.render(at: t(2))
        assertColor(frame[20, 90], green)
        assertColor(frame[300, 90], red)
    }

    func testZoomCrossfades() {
        let h = twoClips(Transition(type: .zoom, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b"))
        let frame = h.render(at: t(2))
        let centre = frame[160, 90]
        XCTAssertGreaterThan(centre[0], 60)
        XCTAssertGreaterThan(centre[1], 60)
    }

    func testDissolveAtTheHeadFadesInOverTheTrackBelow() {
        let v1 = Track(kind: .video, name: "V1", clips: [clip("clip_s", "med_red")])
        let v2 = Track(kind: .video, name: "V2", clips: [clip("clip_c", "med_blue", start: 1, duration: 2)], transitions: [
            Transition(type: .dissolve, duration: t(1), fromClipID: nil, toClipID: "clip_c")
        ])
        var h = CompositorHarness(smallProject(video: [v1, v2], media: [redMedia, blueMedia]))
        h.pictures = ["med_red": solid(1, 0, 0), "med_blue": solid(0, 0, 1)]
        assertColor(h.render(at: t(1.5))[160, 90], [128, 0, 128], tolerance: 3)
    }

    // MARK: Cutout, style effects, adjustment layers

    func testCutoutUsesTheMatteAsAlpha() {
        var h = screenAndCamera(VideoProperties(cutout: Cutout(edgeFeather: 0)))
        // Person on the left half only.
        h.mattes["med_blue"] = split(.white, .black, width: 160, height: 90)
        let frame = h.render(at: t(1))
        assertColor(frame[60, 90], blue)
        assertColor(frame[260, 90], red)
    }

    func testCutoutWithoutAMatteShowsTheWholeFrame() {
        let frame = screenAndCamera(VideoProperties(cutout: Cutout())).render(at: t(1))
        assertColor(frame[260, 90], blue)
    }

    func testRepairMaskForcesAnAreaIn() {
        var cutout = Cutout(edgeFeather: 0)
        cutout.repairMasks = [Mask(shape: .rectangle, mode: .include, rect: Rect(x: 0.75, y: 0, width: 0.25, height: 1))]
        var h = screenAndCamera(VideoProperties(cutout: cutout))
        h.mattes["med_blue"] = split(.white, .black, width: 160, height: 90)
        let frame = h.render(at: t(1))
        assertColor(frame[200, 90], red)
        assertColor(frame[300, 90], blue)
    }

    func testDropShadowFollowsTheLayer() {
        let pip = VideoProperties(
            transform: Transform(scale: 0.5),
            effects: [Effect(type: "dropShadow", params: ["distance": .number(85), "blur": .number(0), "opacity": .number(100)])]
        )
        var h = screenAndCamera(pip)
        h.pictures["med_red"] = solid(0.5, 0.5, 0.5)
        let frame = h.render(at: t(1))
        // 85 px at 1080 is about 14 px here, or 10 px right and 10 down at
        // 135 degrees. The PiP covers x 80...240, y 45...135.
        assertColor(frame[160, 90], blue)
        XCTAssertLessThan(frame.luma(245, 100), 5)
        XCTAssertLessThan(frame.luma(160, 140), 5)
        assertColor(frame[75, 90], [128, 128, 128])
        assertColor(frame[160, 40], [128, 128, 128])
    }

    func testRoundedCornersAndBorder() {
        let pip = VideoProperties(
            transform: Transform(scale: 0.5),
            effects: [
                Effect(type: "roundedCorners", params: ["radius": .number(60)]),
                Effect(type: "border", params: ["width": .number(12), "color": .color(.white)])
            ]
        )
        let frame = screenAndCamera(pip).render(at: t(1))
        // Border 2 px outside the 160x90 PiP (80...240, 45...135).
        assertColor(frame[160, 44], white)
        assertColor(frame[160, 136], white)
        assertColor(frame[160, 90], blue)
        // The corner is cut away (rounded), showing the frame colour or red.
        XCTAssertNotEqual(frame[81, 46], [0, 0, 255, 255])
    }

    func testAdjustmentLayerChangesOnlyTracksBelow() {
        let v1 = Track(kind: .video, name: "V1", clips: [clip("clip_s", "med_red")])
        let adjust = Clip(id: "clip_adj", content: .adjustment, start: .zero, duration: t(4), video: VideoProperties(effects: [
            Effect(type: "colorAdjust", params: ["saturation": .number(-100)])
        ]))
        let v2 = Track(kind: .video, name: "Adjust", clips: [adjust])
        let v3 = Track(kind: .video, name: "PiP", clips: [clip("clip_c", "med_blue", video: VideoProperties(transform: Transform(position: Point(x: 0.75, y: 0.75), scale: 0.5)))])
        var h = CompositorHarness(smallProject(video: [v1, v2, v3], media: [redMedia, blueMedia]))
        h.pictures = ["med_red": solid(1, 0, 0), "med_blue": solid(0, 0, 1)]
        let frame = h.render(at: t(1))
        let grey = frame[40, 40]
        XCTAssertEqual(grey[0], grey[1], accuracy: 2)
        XCTAssertEqual(grey[1], grey[2], accuracy: 2)
        assertColor(frame[240, 135], blue)
    }

    func testMediaLookRunsBeforeClipEffects() {
        // The look desaturates; the clip's warmth then tints the grey. The
        // other way round would leave a neutral grey.
        var h = screenAndCamera(VideoProperties(effects: [Effect(type: "colorAdjust", params: ["temperature": .number(100)])]))
        h.project.media[1].look = [Effect(type: "colorAdjust", params: ["saturation": .number(-100)])]
        h.pictures["med_blue"] = solid(0.2, 0.4, 0.6)
        let p = h.render(at: t(1))[160, 90]
        XCTAssertGreaterThan(p[0] - p[2], 12)
    }
}

final class LiveOverrideTests: XCTestCase {
    /// Dragging a picture in picture in the viewer moves the picture itself
    /// on the next frame, before the edit is committed.
    func testOverridesMoveTheLayerUntilCleared() {
        let pip = VideoProperties(transform: Transform(position: Point(x: 0.75, y: 0.75), scale: 0.4))
        let v1 = Track(kind: .video, name: "V1", clips: [Clip(id: "clip_b", content: .media(mediaID: "med_blue"), start: .zero, duration: Time(seconds: 4), video: pip)])
        var h = CompositorHarness(smallProject(video: [v1], media: [blueMedia]))
        h.pictures["med_blue"] = solid(0, 0, 1)
        let overrides = LiveVideoOverrides()
        h.overrides = overrides
        let blue = [0, 0, 255], black = [0, 0, 0]
        // 320x180 canvas: the PiP centre sits at (240, 135).
        assertColor(h.render(at: Time(seconds: 1))[240, 135], blue)
        assertColor(h.render(at: Time(seconds: 1))[80, 45], black)

        var dragged = pip
        dragged.transform.position = Point(x: 0.25, y: 0.25)
        overrides.set(["clip_b": dragged])
        assertColor(h.render(at: Time(seconds: 1))[80, 45], blue, "the dragged position")
        assertColor(h.render(at: Time(seconds: 1))[240, 135], black, "not where it was")

        overrides.set([:])
        assertColor(h.render(at: Time(seconds: 1))[240, 135], blue, "back to the clip's own")
    }
}
