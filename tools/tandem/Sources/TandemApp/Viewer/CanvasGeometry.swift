import CoreGraphics
import Foundation
import TandemCore

/// Where a clip's picture lands on the canvas, following the transform
/// contract in ARCHITECTURE.md, so the viewer's schematic and its selection
/// box agree with the export:
///
/// 1. The source is aspect-fitted into the canvas, then multiplied by scale.
/// 2. Position is where the centre of the uncropped source lands (0...1).
/// 3. Rotation is degrees clockwise about that centre.
/// 4. Crop hides fractions of the source edges without rescaling.
enum CanvasGeometry {
    /// The canvas inside `bounds`, at the project's aspect, with a margin.
    static func canvasRect(in bounds: CGRect, width: Int, height: Int, margin: CGFloat = 14, zoom: CGFloat = 1, pan: CGPoint = .zero) -> CGRect {
        guard width > 0, height > 0 else { return .zero }
        let available = bounds.insetBy(dx: margin, dy: margin)
        let fit = min(available.width / CGFloat(width), available.height / CGFloat(height)) * zoom
        let size = CGSize(width: (CGFloat(width) * fit).rounded(), height: (CGFloat(height) * fit).rounded())
        return CGRect(x: (bounds.midX - size.width / 2 + pan.x).rounded(), y: (bounds.midY - size.height / 2 + pan.y).rounded(), width: size.width, height: size.height)
    }

    /// The source size for a clip: the media's pixels, or the canvas for
    /// text, solids and anything unprobed.
    static func sourceSize(of clip: Clip, in project: Project) -> CGSize {
        if let item = clip.mediaID.flatMap({ project.media($0) }), let w = item.width, let h = item.height, w > 0, h > 0 {
            return CGSize(width: w, height: h)
        }
        return CGSize(width: project.settings.width, height: project.settings.height)
    }

    /// The uncropped, unrotated rectangle of the source on `canvas`
    /// (top-left origin, y down).
    static func frame(source: CGSize, transform: Transform, canvas: CGRect) -> CGRect {
        let fit = min(canvas.width / source.width, canvas.height / source.height)
        let width = source.width * fit * CGFloat(transform.scale)
        let height = source.height * fit * CGFloat(transform.scale)
        let centre = CGPoint(x: canvas.minX + CGFloat(transform.position.x) * canvas.width, y: canvas.minY + CGFloat(transform.position.y) * canvas.height)
        return CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
    }

    /// The part of `frame` the crop leaves visible.
    static func cropped(_ frame: CGRect, crop: Crop) -> CGRect {
        CGRect(
            x: frame.minX + frame.width * CGFloat(crop.left),
            y: frame.minY + frame.height * CGFloat(crop.top),
            width: frame.width * CGFloat(max(0, 1 - crop.left - crop.right)),
            height: frame.height * CGFloat(max(0, 1 - crop.top - crop.bottom))
        )
    }

    /// Moves a transform's position by a drag on the canvas.
    static func moved(_ transform: Transform, by translation: CGSize, canvas: CGRect) -> Transform {
        var result = transform
        guard canvas.width > 0, canvas.height > 0 else { return result }
        result.position.x += Double(translation.width / canvas.width)
        result.position.y += Double(translation.height / canvas.height)
        return result
    }

    /// Scales a transform so a corner dragged from `start` to `end` keeps
    /// the centre fixed.
    static func scaled(_ transform: Transform, centre: CGPoint, from start: CGPoint, to end: CGPoint) -> Transform {
        var result = transform
        let before = hypot(start.x - centre.x, start.y - centre.y)
        let after = hypot(end.x - centre.x, end.y - centre.y)
        guard before > 1 else { return result }
        result.scale = min(max(transform.scale * Double(after / before), 0.05), 8)
        return result
    }

    /// A viewer rectangle (in canvas coordinates) as a rectangle of the
    /// clip's source, 0...1, for zooming a screen recording into it.
    static func sourceRect(for selection: CGRect, clipFrame: CGRect) -> Rect? {
        guard clipFrame.width > 0, clipFrame.height > 0 else { return nil }
        let clipped = selection.intersection(clipFrame)
        guard !clipped.isNull, clipped.width > 4, clipped.height > 4 else { return nil }
        return Rect(
            x: Double((clipped.minX - clipFrame.minX) / clipFrame.width),
            y: Double((clipped.minY - clipFrame.minY) / clipFrame.height),
            width: Double(clipped.width / clipFrame.width),
            height: Double(clipped.height / clipFrame.height)
        )
    }
}
