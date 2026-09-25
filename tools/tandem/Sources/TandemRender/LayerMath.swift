import CoreGraphics
import Foundation
import TandemCore

/// Placement maths shared by the viewer and the export, so the two can
/// never disagree. Everything here is pure.
///
/// Spaces, all in pixels:
/// - *natural*: the frame as the file stores it, origin top left, y down.
/// - *display*: the frame the right way up, after the track's preferred
///   transform. Crops, masks and repair shapes are fractions of this.
/// - *canvas*: the output frame, origin top left, y down.
///
/// Core Image works y up, so `coreImage(_:sourceHeight:canvasHeight:)`
/// converts any of these transforms for use on a `CIImage`.
public enum LayerMath {
    /// Output pixels per model pixel. Sizes in the model (shadow blur,
    /// border width, text size) are given for a 1080p frame and scale with
    /// the canvas's short side, so a 4K export doubles them and a 9:16 short
    /// keeps them.
    public static func pixelScale(canvas: CGSize) -> CGFloat {
        max(min(canvas.width, canvas.height), 1) / 1080
    }

    /// The scale that fits the whole source inside the canvas.
    public static func fitScale(source: CGSize, canvas: CGSize) -> CGFloat {
        guard source.width > 0, source.height > 0 else { return 0 }
        return min(canvas.width / source.width, canvas.height / source.height)
    }

    /// Natural-to-display transform and the display size for a track's
    /// `preferredTransform`. The translation is normalised so the display
    /// frame starts at 0, 0 even when a file only stores the rotation.
    public static func orientation(natural: CGSize, preferredTransform: CGAffineTransform) -> (transform: CGAffineTransform, size: CGSize) {
        let box = CGRect(origin: .zero, size: natural).applying(preferredTransform)
        let transform = preferredTransform.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
        // Rotations by multiples of 90 degrees leave tiny float errors.
        let size = CGSize(width: box.width.rounded(toPlaces: 6), height: box.height.rounded(toPlaces: 6))
        return (transform, size)
    }

    /// Display-to-canvas transform for a layer: aspect fit (unless the
    /// source is already in canvas pixels, like rendered text), then
    /// `transform.scale`, rotation clockwise about the centre, and the
    /// uncropped centre placed at `transform.position`.
    public static func placement(source: CGSize, canvas: CGSize, transform: Transform, fitToCanvas: Bool = true) -> CGAffineTransform {
        let fit = fitToCanvas ? fitScale(source: source, canvas: canvas) : 1
        let scale = fit * CGFloat(transform.scale)
        let angle = CGFloat(transform.rotation) * .pi / 180
        return CGAffineTransform(translationX: -source.width / 2, y: -source.height / 2)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            // Positive angles turn +x towards +y, which is clockwise when y
            // points down.
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(
                translationX: CGFloat(transform.position.x) * canvas.width,
                y: CGFloat(transform.position.y) * canvas.height
            ))
    }

    /// Display pixels to canvas pixels, ignoring rotation: fit times scale.
    public static func totalScale(source: CGSize, canvas: CGSize, transform: Transform, fitToCanvas: Bool = true) -> CGFloat {
        (fitToCanvas ? fitScale(source: source, canvas: canvas) : 1) * CGFloat(transform.scale)
    }

    /// The part of the source left after cropping, in display pixels.
    /// Crops that meet or overlap leave an empty rectangle.
    public static func cropRect(source: CGSize, crop: Crop) -> CGRect {
        let left = clamp01(crop.left), right = clamp01(crop.right)
        let top = clamp01(crop.top), bottom = clamp01(crop.bottom)
        let x0 = left * source.width
        let x1 = max(x0, (1 - right) * source.width)
        let y0 = top * source.height
        let y1 = max(y0, (1 - bottom) * source.height)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The transform that fills the canvas with `rect` (fractions of the
    /// source): `scale = min(1/w, 1/h)` on a same-aspect canvas, with the
    /// rectangle's centre on the canvas centre. Works for any aspect: the
    /// rectangle is fitted inside the canvas.
    public static func zoom(to rect: Rect, source: CGSize, canvas: CGSize) -> Transform {
        let fit = fitScale(source: source, canvas: canvas)
        let w = max(rect.width, 1e-6) * Double(source.width * fit)
        let h = max(rect.height, 1e-6) * Double(source.height * fit)
        let scale = min(Double(canvas.width) / w, Double(canvas.height) / h)
        let cx = rect.x + rect.width / 2
        let cy = rect.y + rect.height / 2
        let total = Double(fit) * scale
        let x = 0.5 - (cx - 0.5) * Double(source.width) * total / Double(canvas.width)
        let y = 0.5 - (cy - 0.5) * Double(source.height) * total / Double(canvas.height)
        return Transform(position: Point(x: x, y: y), scale: scale)
    }

    /// Corners of the visible (cropped) layer on the canvas, clockwise from
    /// the top left, for the viewer's handles and hit testing.
    public static func canvasQuad(source: CGSize, canvas: CGSize, transform: Transform, crop: Crop = Crop(), fitToCanvas: Bool = true) -> [CGPoint] {
        let t = placement(source: source, canvas: canvas, transform: transform, fitToCanvas: fitToCanvas)
        let r = cropRect(source: source, crop: crop)
        return [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)
        ].map { $0.applying(t) }
    }

    /// Maps between a y-down space `height` pixels tall and Core Image's
    /// y-up space. It is its own inverse.
    public static func flip(height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }

    /// Converts a y-down transform from a space `sourceHeight` tall to one
    /// `canvasHeight` tall into the same mapping between y-up spaces.
    public static func coreImage(_ transform: CGAffineTransform, sourceHeight: CGFloat, canvasHeight: CGFloat) -> CGAffineTransform {
        flip(height: sourceHeight).concatenating(transform).concatenating(flip(height: canvasHeight))
    }

    /// A y-down rectangle in a space `height` tall, as a Core Image rectangle.
    public static func coreImageRect(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func clamp01(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }
}

extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = pow(10, CGFloat(places))
        return (self * factor).rounded() / factor
    }
}

extension Clip {
    /// Video properties for an output format at a clip-relative time, with
    /// keyframes applied, or nil when the clip is hidden in that format.
    ///
    /// A format override's transform or crop replaces the main one, and the
    /// matching keyframes are ignored in that format (they animate the main
    /// layout). Other animation, such as opacity, still applies.
    public func resolvedVideo(at clipTime: Time, format: String?) -> VideoProperties? {
        var video = resolvedVideo(at: clipTime)
        guard let format, let override = self.video?.formatOverrides[format] else { return video }
        if override.hidden { return nil }
        if let transform = override.transform { video.transform = transform }
        if let crop = override.crop { video.crop = crop }
        return video
    }

    /// True when a format override hides this clip.
    public func isHidden(inFormat format: String?) -> Bool {
        guard let format else { return false }
        return video?.formatOverrides[format]?.hidden ?? false
    }
}
