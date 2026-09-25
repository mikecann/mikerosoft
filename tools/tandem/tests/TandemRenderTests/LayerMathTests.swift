import CoreGraphics
import XCTest
import TandemCore
@testable import TandemRender

final class LayerMathTests: XCTestCase {
    let uhd = CGSize(width: 3840, height: 2160)

    func assertPoint(_ p: CGPoint, _ x: CGFloat, _ y: CGFloat, accuracy: CGFloat = 0.001, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: accuracy, "y", file: file, line: line)
    }

    func testFitScaleLetterboxesAndPillarboxes() {
        XCTAssertEqual(LayerMath.fitScale(source: CGSize(width: 3200, height: 1800), canvas: uhd), 1.2, accuracy: 1e-9)
        // A portrait phone clip in a landscape canvas fits its height.
        XCTAssertEqual(LayerMath.fitScale(source: CGSize(width: 1080, height: 1920), canvas: uhd), 2160.0 / 1920.0, accuracy: 1e-9)
        // A landscape screen in a portrait canvas fits its width.
        XCTAssertEqual(LayerMath.fitScale(source: CGSize(width: 3840, height: 2160), canvas: CGSize(width: 1080, height: 1920)), 1080.0 / 3840.0, accuracy: 1e-9)
        XCTAssertEqual(LayerMath.fitScale(source: .zero, canvas: uhd), 0)
    }

    func testIdentityTransformFillsTheCanvas() {
        let t = LayerMath.placement(source: CGSize(width: 3200, height: 1800), canvas: uhd, transform: Transform())
        assertPoint(CGPoint.zero.applying(t), 0, 0)
        assertPoint(CGPoint(x: 3200, y: 1800).applying(t), 3840, 2160)
    }

    func testMikesPiPLandsBottomRight() {
        // Scale 0.5 at (0.87, 0.77): the centre goes to 87% across and 77%
        // down, and the layer is half the canvas.
        let pip = Transform(position: Point(x: 0.87, y: 0.77), scale: 0.5)
        let t = LayerMath.placement(source: uhd, canvas: uhd, transform: pip)
        assertPoint(CGPoint(x: 1920, y: 1080).applying(t), 3340.8, 1663.2)
        assertPoint(CGPoint.zero.applying(t), 3340.8 - 960, 1663.2 - 540)
        assertPoint(CGPoint(x: 3840, y: 2160).applying(t), 3340.8 + 960, 1663.2 + 540)
    }

    func testRotationIsClockwiseOnScreen() {
        // Rotating 90 degrees clockwise about the centre moves the top-left
        // corner of a square to the top-right.
        let square = CGSize(width: 100, height: 100)
        let canvas = CGSize(width: 100, height: 100)
        let t = LayerMath.placement(source: square, canvas: canvas, transform: Transform(rotation: 90))
        assertPoint(CGPoint.zero.applying(t), 100, 0)
        assertPoint(CGPoint(x: 100, y: 0).applying(t), 100, 100)
    }

    func testTextLayersAreNotFitted() {
        let t = LayerMath.placement(source: CGSize(width: 400, height: 100), canvas: uhd, transform: Transform(), fitToCanvas: false)
        assertPoint(CGPoint.zero.applying(t), 1920 - 200, 1080 - 50)
    }

    func testPortraitPhoneClipOrientation() {
        // An iPhone portrait clip: 1920x1080 encoded, rotated 90 degrees to
        // show 1080x1920. The encoded top-left ends up top-right.
        let natural = CGSize(width: 1920, height: 1080)
        let preferred = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let (o, size) = LayerMath.orientation(natural: natural, preferredTransform: preferred)
        XCTAssertEqual(size.width, 1080, accuracy: 1e-9)
        XCTAssertEqual(size.height, 1920, accuracy: 1e-9)
        assertPoint(CGPoint.zero.applying(o), 1080, 0)
        assertPoint(CGPoint(x: 1920, y: 1080).applying(o), 0, 1920)
    }

    func testOrientationNormalisesTranslation() {
        // Some files carry a rotation without the translation that keeps the
        // frame in positive space. The orientation still starts at 0, 0.
        let natural = CGSize(width: 200, height: 100)
        let rotateOnly = CGAffineTransform(rotationAngle: .pi)
        let (o, size) = LayerMath.orientation(natural: natural, preferredTransform: rotateOnly)
        XCTAssertEqual(size.width, 200, accuracy: 1e-9)
        XCTAssertEqual(size.height, 100, accuracy: 1e-9)
        assertPoint(CGPoint.zero.applying(o), 200, 100)
        assertPoint(CGPoint(x: 200, y: 100).applying(o), 0, 0)
    }

    func testCropRect() {
        let r = LayerMath.cropRect(source: CGSize(width: 1000, height: 500), crop: Crop(left: 0.1, top: 0.2, right: 0.3, bottom: 0.4))
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 600, height: 200))
        // Crops that meet collapse to nothing instead of going negative.
        let gone = LayerMath.cropRect(source: CGSize(width: 1000, height: 500), crop: Crop(left: 0.7, right: 0.6))
        XCTAssertEqual(gone.width, 0)
    }

    func testCroppingDoesNotMoveTheSourceCentre() {
        // Cropping hides edges without rescaling: the uncropped centre stays
        // on `position`, so the visible part shifts with the crop.
        let canvas = CGSize(width: 1000, height: 1000)
        let t = LayerMath.placement(source: canvas, canvas: canvas, transform: Transform())
        let visible = LayerMath.cropRect(source: canvas, crop: Crop(left: 0.5)).applying(t)
        XCTAssertEqual(visible, CGRect(x: 500, y: 0, width: 500, height: 1000))
    }

    func testZoomToRectangleOnSameAspectCanvas() {
        // Zooming into the top-left quarter of a screen recording: scale 2,
        // and the quarter's centre lands on the canvas centre.
        let screen = CGSize(width: 3200, height: 1800)
        let zoom = LayerMath.zoom(to: Rect(x: 0, y: 0, width: 0.5, height: 0.5), source: screen, canvas: uhd)
        XCTAssertEqual(zoom.scale, 2, accuracy: 1e-9)
        let t = LayerMath.placement(source: screen, canvas: uhd, transform: zoom)
        assertPoint(CGPoint(x: 800, y: 450).applying(t), 1920, 1080)
        assertPoint(CGPoint.zero.applying(t), 0, 0)
        assertPoint(CGPoint(x: 1600, y: 900).applying(t), 3840, 2160)
    }

    func testZoomToWideRectangleFitsItsWidth() {
        // min(1/w, 1/h): a wide, short rectangle is limited by its width.
        let zoom = LayerMath.zoom(to: Rect(x: 0.25, y: 0.4, width: 0.5, height: 0.1), source: uhd, canvas: uhd)
        XCTAssertEqual(zoom.scale, 2, accuracy: 1e-9)
        let t = LayerMath.placement(source: uhd, canvas: uhd, transform: zoom)
        assertPoint(CGPoint(x: 1920, y: 0.45 * 2160).applying(t), 1920, 1080)
    }

    func testZoomOnDifferentAspectCanvas() {
        // A 16:9 screen zoomed for the 9:16 short: the rectangle's centre
        // lands mid-canvas and it fills the width.
        let portrait = CGSize(width: 1080, height: 1920)
        let rect = Rect(x: 0.5, y: 0.25, width: 0.25, height: 0.5)
        let zoom = LayerMath.zoom(to: rect, source: uhd, canvas: portrait)
        let t = LayerMath.placement(source: uhd, canvas: portrait, transform: zoom)
        let r = CGRect(x: 0.5 * 3840, y: 0.25 * 2160, width: 0.25 * 3840, height: 0.5 * 2160).applying(t)
        XCTAssertEqual(r.midX, 540, accuracy: 0.01)
        XCTAssertEqual(r.midY, 960, accuracy: 0.01)
        XCTAssertEqual(min(1080 / r.width, 1920 / r.height), 1, accuracy: 1e-6)
    }

    func testCoreImageConversionFlipsBothSpaces() {
        // The PiP's top-left corner in y-down canvas space is its top-left in
        // Core Image too, just measured from the bottom.
        let pip = Transform(position: Point(x: 0.75, y: 0.25), scale: 0.5)
        let down = LayerMath.placement(source: uhd, canvas: uhd, transform: pip)
        let up = LayerMath.coreImage(down, sourceHeight: 2160, canvasHeight: 2160)
        // Source top-left is (0, 2160) in Core Image space.
        assertPoint(CGPoint(x: 0, y: 2160).applying(up), 1920, 2160)
        assertPoint(CGPoint(x: 3840, y: 0).applying(up), 3840, 1080)
    }

    func testPixelScaleUsesTheShortSide() {
        XCTAssertEqual(LayerMath.pixelScale(canvas: uhd), 2)
        XCTAssertEqual(LayerMath.pixelScale(canvas: CGSize(width: 1080, height: 1920)), 1)
        XCTAssertEqual(LayerMath.pixelScale(canvas: CGSize(width: 1280, height: 720)), 720.0 / 1080.0, accuracy: 1e-9)
    }

    func testCanvasQuadForViewerHandles() {
        let pip = Transform(position: Point(x: 0.5, y: 0.5), scale: 0.5)
        let quad = LayerMath.canvasQuad(source: uhd, canvas: uhd, transform: pip, crop: Crop(left: 0.5))
        assertPoint(quad[0], 1920, 540)
        assertPoint(quad[1], 2880, 540)
        assertPoint(quad[2], 2880, 1620)
        assertPoint(quad[3], 1920, 1620)
    }

    func testFormatOverridesReplacePlacement() {
        var clip = Clip(content: .solid(color: .black), start: .zero, duration: Time(seconds: 2))
        clip.video = VideoProperties(
            transform: Transform(position: Point(x: 0.87, y: 0.77), scale: 0.5),
            formatOverrides: [
                "portrait": FormatOverride(transform: Transform(position: Point(x: 0.5, y: 0.75), scale: 1.5), crop: Crop(left: 0.2)),
                "square": FormatOverride(hidden: true)
            ]
        )
        clip.keyframes["video.transform.scale"] = [
            Keyframe(time: .zero, value: .number(0.5)),
            Keyframe(time: Time(seconds: 2), value: .number(1))
        ]
        clip.keyframes["video.opacity"] = [Keyframe(time: .zero, value: .number(0.25))]

        // Main format: keyframes drive the scale.
        let main = clip.resolvedVideo(at: Time(seconds: 1), format: nil)
        XCTAssertEqual(main?.transform.scale ?? 0, 0.75, accuracy: 1e-9)
        // Portrait: the override wins over the transform keyframes, but other
        // animation (opacity) still applies.
        let portrait = clip.resolvedVideo(at: Time(seconds: 1), format: "portrait")
        XCTAssertEqual(portrait?.transform.scale, 1.5)
        XCTAssertEqual(portrait?.transform.position, Point(x: 0.5, y: 0.75))
        XCTAssertEqual(portrait?.crop.left, 0.2)
        XCTAssertEqual(portrait?.opacity, 0.25)
        // Hidden in a format means no layer at all.
        XCTAssertNil(clip.resolvedVideo(at: .zero, format: "square"))
        XCTAssertTrue(clip.isHidden(inFormat: "square"))
        XCTAssertFalse(clip.isHidden(inFormat: "portrait"))
        // Unknown formats use the main placement.
        XCTAssertEqual(clip.resolvedVideo(at: .zero, format: "other")?.transform.position, Point(x: 0.87, y: 0.77))
    }
}
