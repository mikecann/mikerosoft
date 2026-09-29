import XCTest
@testable import TandemCore

final class LayoutTests: XCTestCase {
    func testPipRightAddsCutoutAndShadowOnce() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("PiP", .applyLayout(clipIDs: [camera], preset: .pipRight))
        try c.run("PiP again", .applyLayout(clipIDs: [camera], preset: .pipRight))
        let video = try XCTUnwrap(c.project.clip(camera)?.video)
        XCTAssertEqual(video.transform.scale, 0.5)
        XCTAssertEqual(video.transform.position, LayoutPreset.pipRightPosition)
        XCTAssertEqual(video.cutout?.enabled, true)
        XCTAssertEqual(video.cutout?.mode, .personAndProps)
        XCTAssertEqual(video.effects.filter { $0.type == "dropShadow" }.count, 1)
        XCTAssertEqual(video.layoutPreset, "pipRight")
    }

    func testFullRemovesThePipLook() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("PiP", .applyLayout(clipIDs: [camera], preset: .pipLeft))
        try c.run("Full", .applyLayout(clipIDs: [camera], preset: .full))
        let video = try XCTUnwrap(c.project.clip(camera)?.video)
        XCTAssertEqual(video.transform, Transform())
        XCTAssertEqual(video.cutout?.enabled, false)
        XCTAssertTrue(video.effects.isEmpty)
    }

    func testLayoutSkipsAudioClips() throws {
        let (f, c) = try Fixture.edited()
        XCTAssertThrowsError(try c.run("Voice", .applyLayout(clipIDs: [f.clips("Voice")[0].id], preset: .pipRight)))
    }

    func testShowingARegion() {
        // A 16:9 source on a 16:9 canvas: the right half, middle, is 2x.
        let t = Transform.showing(Rect(x: 0.5, y: 0.25, width: 0.5, height: 0.5), sourceWidth: 3840, sourceHeight: 2160, canvasWidth: 3840, canvasHeight: 2160)
        XCTAssertEqual(t.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(t.position.x, 0, accuracy: 1e-9)
        XCTAssertEqual(t.position.y, 0.5, accuracy: 1e-9)
        // The whole frame is identity.
        let identity = Transform.showing(Rect(x: 0, y: 0, width: 1, height: 1), sourceWidth: 3200, sourceHeight: 1800, canvasWidth: 3840, canvasHeight: 2160)
        XCTAssertEqual(identity.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(identity.position.x, 0.5, accuracy: 1e-9)
    }

    func testAnimatedZoomAddsEasedKeyframes() throws {
        let (f, c) = try Fixture.edited()
        let screen = f.clips("Screen")[0].id
        try c.run("Zoom", .zoomToRegion(clipID: screen, rect: Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), at: t(10), duration: t(0.5)))
        let clip = try XCTUnwrap(c.project.clip(screen))
        XCTAssertEqual(clip.resolvedVideo(at: t(5)).transform.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(clip.resolvedVideo(at: t(11)).transform.scale, 2, accuracy: 1e-9)
        let mid = clip.resolvedVideo(at: t(10.25)).transform.scale
        XCTAssertGreaterThan(mid, 1)
        XCTAssertLessThan(mid, 2)
        try c.run("Out", .zoomToRegion(clipID: screen, rect: Rect(x: 0, y: 0, width: 1, height: 1), at: t(20)))
        XCTAssertEqual(c.project.clip(screen)!.resolvedVideo(at: t(21)).transform.scale, 1, accuracy: 1e-9)
    }
}

final class PortraitLayoutTests: XCTestCase {
    func testFillingTheBottomHalfOfAShort() {
        // A 16:9 camera on 1080x1920: fitted it's 1080x607.5, so filling a
        // 960 px tall half needs 960 / 607.5.
        let t = Transform.filling(.bottom, sourceWidth: 3840, sourceHeight: 2160, canvasWidth: 1080, canvasHeight: 1920)
        XCTAssertEqual(t.scale, 960 / 607.5, accuracy: 1e-9)
        XCTAssertEqual(t.position, Point(x: 0.5, y: 0.75))
        let full = Transform.filling(.full, sourceWidth: 3840, sourceHeight: 2160, canvasWidth: 1080, canvasHeight: 1920)
        XCTAssertEqual(full.scale, 1920 / 607.5, accuracy: 1e-9)
    }

    func testSetFormatLayoutNeedsTheFormatAndKeepsTheMainLayout() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        XCTAssertThrowsError(try c.run("Short", .setFormatLayout(clipIDs: [camera], format: "portrait", slot: .bottom)))
        try c.run("Format", .updateSettings(patch: .object(["alternateFormats": .array([try JSONValue.from(OutputFormat.portrait)])])))
        try c.run("PiP", .applyLayout(clipIDs: [camera], preset: .pipRight))
        try c.run("Short", .setFormatLayout(clipIDs: [camera], format: "portrait", slot: .bottom, cutout: false))
        let video = try XCTUnwrap(c.project.clip(camera)?.video)
        XCTAssertEqual(video.transform.scale, 0.5, "the landscape layout is untouched")
        let override = try XCTUnwrap(video.formatOverrides["portrait"])
        XCTAssertEqual(override.transform?.position, Point(x: 0.5, y: 0.75))
        XCTAssertEqual(override.cutout, false)
    }
}

final class StillsTests: XCTestCase {
    /// A landscape photo in a 1080x1920 short.
    func shortWithPhoto() throws -> (ProjectCoordinator, String) {
        var p = Project.standard(name: "Short")
        p.settings.width = 1080
        p.settings.height = 1920
        p.media = [MediaItem(id: "med_photo", path: "photos/bench.jpg", kind: .image, role: .image, width: 4032, height: 3024, hasVideo: false)]
        let c = ProjectCoordinator(project: p)
        try c.run("Place", .placeMedia(mediaIDs: ["med_photo"], at: .zero, duration: Time(seconds: 4)))
        return (c, c.project.track(named: "B-roll")!.clips[0].id)
    }

    func testFillCoversAPortraitFrame() throws {
        let (c, photo) = try shortWithPhoto()
        try c.run("Fill", .applyLayout(clipIDs: [photo], preset: .fill))
        // 4032x3024 fitted into 1080x1920 is 1080x810; covering 1920 tall
        // needs 1920 / 810.
        let scale = try XCTUnwrap(c.project.clip(photo)?.video?.transform.scale)
        XCTAssertEqual(scale, 1920 / 810, accuracy: 1e-9)
        XCTAssertEqual(c.project.clip(photo)?.video?.layoutPreset, "fill")
    }

    func testZoomInMovesFromTheFillToABitCloser() throws {
        let (c, photo) = try shortWithPhoto()
        try c.run("Fill", .applyLayout(clipIDs: [photo], preset: .fill))
        try c.run("Push", .addMotion(clipIDs: [photo], style: .zoomIn))
        let clip = try XCTUnwrap(c.project.clip(photo))
        let fill = 1920.0 / 810
        XCTAssertEqual(clip.resolvedVideo(at: .zero).transform.scale, fill, accuracy: 1e-6)
        XCTAssertEqual(clip.resolvedVideo(at: clip.duration).transform.scale, fill * 1.12, accuracy: 1e-6)
        XCTAssertEqual(clip.resolvedVideo(at: Time(seconds: 2)).transform.scale, fill * 1.06, accuracy: 1e-6, "linear, not eased")
    }

    func testPanLeftTravelsAcrossTheOverflowWithoutShowingAnEdge() throws {
        let (c, photo) = try shortWithPhoto()
        try c.run("Fill", .applyLayout(clipIDs: [photo], preset: .fill))
        try c.run("Pan", .addMotion(clipIDs: [photo], style: .panLeft))
        let clip = try XCTUnwrap(c.project.clip(photo))
        let start = clip.resolvedVideo(at: .zero).transform.position.x
        let end = clip.resolvedVideo(at: clip.duration).transform.position.x
        XCTAssertGreaterThan(start, 0.5)
        XCTAssertLessThan(end, 0.5)
        // The photo is 1080 * 1920/810 = 2560 px wide on a 1080 px frame:
        // its centre can move 0.685 either way; the pan uses 80% of that.
        let room = (2560.0 / 1080 - 1) / 2
        XCTAssertEqual(start - 0.5, room * 0.8, accuracy: 1e-6)
    }

    func testMotionAmountIsChecked() throws {
        let (c, photo) = try shortWithPhoto()
        XCTAssertThrowsError(try c.run("Too much", .addMotion(clipIDs: [photo], style: .zoomIn, amount: 5)))
    }
}
