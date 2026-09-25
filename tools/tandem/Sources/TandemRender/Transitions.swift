import CoreImage
import Foundation
import TandemCore

/// Draws transitions. Each one combines the outgoing and incoming layers of
/// one track (either may be missing at a clip's head or tail) into a single
/// image, which is then composited over the tracks below like any layer.
enum TransitionRenderer {
    /// Unit vector of motion on the canvas, y down.
    static func vector(_ direction: Direction?) -> CGVector {
        switch direction ?? .left {
        case .left: return CGVector(dx: -1, dy: 0)
        case .right: return CGVector(dx: 1, dy: 0)
        case .up: return CGVector(dx: 0, dy: -1)
        case .down: return CGVector(dx: 0, dy: 1)
        }
    }

    /// Eased progress for a type. Cut Slide is a short, fast push: it
    /// spends its time at the ends and whips through the middle.
    static func eased(_ type: TransitionType, _ p: Double) -> Double {
        let p = min(max(p, 0), 1)
        switch type {
        case .dissolve, .fadeToBlack, .fadeFromBlack: return p
        case .cutSlide: return p < 0.5 ? 16 * pow(p, 5) : 1 - pow(-2 * p + 2, 5) / 2
        default: return Easing.apply(.easeInOut, p)
        }
    }

    /// Where the outgoing and incoming layers sit, as fractions of the
    /// canvas (y down), for push-style motion.
    static func offsets(_ type: TransitionType, direction: Direction?, progress p: Double) -> (from: CGVector, to: CGVector) {
        let v = vector(direction)
        let e = eased(type, p)
        switch type {
        case .push, .cutSlide:
            return (CGVector(dx: v.dx * e, dy: v.dy * e), CGVector(dx: v.dx * (e - 1), dy: v.dy * (e - 1)))
        case .slide:
            return (.zero, CGVector(dx: v.dx * (e - 1), dy: v.dy * (e - 1)))
        default:
            return (.zero, .zero)
        }
    }

    /// Colour multipliers for a dip to black: the outgoing side darkens in
    /// the first half and the incoming side brightens in the second. A
    /// one-sided dip uses its whole length.
    static func dipLevels(progress p: Double, hasFrom: Bool, hasTo: Bool) -> (from: Double, to: Double) {
        switch (hasFrom, hasTo) {
        case (true, true): return (max(0, 1 - 2 * p), max(0, 2 * p - 1))
        case (true, false): return (1 - p, 0)
        case (false, true): return (0, p)
        default: return (0, 0)
        }
    }

    static func render(
        _ ref: TransitionRef,
        from: CIImage?,
        to: CIImage?,
        at time: Time,
        canvas: CGSize,
        frameDuration: Time
    ) -> CIImage {
        let rect = CGRect(origin: .zero, size: canvas)
        let clear = CIImage.clear.cropped(to: rect)
        let window = ref.window
        let p = window.duration > .zero ? min(max((time - window.start).seconds / window.duration.seconds, 0), 1) : 1
        let type = ref.transition.type
        let a = from ?? clear
        let b = to ?? clear

        func moved(_ image: CIImage, _ offset: CGVector) -> CIImage {
            // Canvas fractions, y down, to Core Image pixels, y up.
            image.transformed(by: CGAffineTransform(translationX: offset.dx * canvas.width, y: -offset.dy * canvas.height))
        }

        switch type {
        case .dissolve:
            return dissolve(a, b, p, rect)

        case .fadeToBlack, .fadeFromBlack:
            let levels = dipLevels(progress: p, hasFrom: from != nil, hasTo: to != nil)
            if from != nil && (to == nil || p < 0.5) { return a.tandemDarkened(levels.from).cropped(to: rect) }
            return b.tandemDarkened(levels.to).cropped(to: rect)

        case .push, .slide, .cutSlide:
            let o = offsets(type, direction: ref.transition.direction, progress: p)
            var combined = moved(b, o.to).composited(over: moved(a, o.from))
            if type == .cutSlide {
                combined = motionBlurred(combined, ref: ref, progress: p, canvas: canvas, frameDuration: frameDuration)
            }
            return combined.cropped(to: rect)

        case .wipe:
            return wipe(a, b, progress: eased(type, p), direction: ref.transition.direction, canvas: canvas)

        case .zoom:
            // Fly into the outgoing shot while the incoming one grows into
            // place, crossfading on the way.
            let e = eased(type, p)
            let centre = CGAffineTransform(translationX: -canvas.width / 2, y: -canvas.height / 2)
            func zoomed(_ image: CIImage, _ s: CGFloat) -> CIImage {
                image.transformed(by: centre.concatenating(CGAffineTransform(scaleX: s, y: s))
                    .concatenating(CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2)))
            }
            return dissolve(zoomed(a, 1 + CGFloat(e)), zoomed(b, 0.5 + 0.5 * CGFloat(e)), e, rect)
        }
    }

    static func dissolve(_ a: CIImage, _ b: CIImage, _ p: Double, _ rect: CGRect) -> CIImage {
        if p <= 0 { return a.cropped(to: rect) }
        if p >= 1 { return b.cropped(to: rect) }
        return a.cropped(to: rect).applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: b.cropped(to: rect),
            kCIInputTimeKey: p
        ]).cropped(to: rect)
    }

    /// A soft edge sweeps across in the direction of motion, revealing the
    /// incoming shot behind it.
    static func wipe(_ a: CIImage, _ b: CIImage, progress e: Double, direction: Direction?, canvas: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: canvas)
        let v = vector(direction)
        let horizontal = v.dx != 0
        let length = horizontal ? canvas.width : canvas.height
        let soft = length * 0.06
        // The edge travels from just before the start to just past the end.
        let edge = -soft + CGFloat(e) * (length + 2 * soft)
        // Core Image is y up, so "down" starts at the top (max y).
        let forward = horizontal ? v.dx > 0 : v.dy < 0
        let start = forward ? edge - soft / 2 : length - edge + soft / 2
        let end = forward ? edge + soft / 2 : length - edge - soft / 2
        let p0 = horizontal ? CIVector(x: start, y: 0) : CIVector(x: 0, y: start)
        let p1 = horizontal ? CIVector(x: end, y: 0) : CIVector(x: 0, y: end)
        guard let mask = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": p0, "inputPoint1": p1,
            "inputColor0": CIColor.white, "inputColor1": CIColor.black
        ])?.outputImage?.cropped(to: rect) else { return b.cropped(to: rect) }
        return b.cropped(to: rect).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: a.cropped(to: rect),
            kCIInputMaskImageKey: mask
        ]).cropped(to: rect)
    }

    /// Blur along the motion, as long as the move covers in half a frame (a
    /// 180 degree shutter), toned down to a hint.
    static func motionBlurred(_ image: CIImage, ref: TransitionRef, progress p: Double, canvas: CGSize, frameDuration: Time) -> CIImage {
        let window = ref.window.duration.seconds
        guard window > 0 else { return image }
        let halfFrame = frameDuration.seconds / window / 2
        let v = vector(ref.transition.direction)
        let travel = abs(eased(.cutSlide, p + halfFrame / 2) - eased(.cutSlide, p - halfFrame / 2))
        let extent = v.dx != 0 ? canvas.width : canvas.height
        let length = CGFloat(travel) * extent * 0.6
        guard length > 1 else { return image }
        return image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
            kCIInputRadiusKey: min(length / 2, extent * 0.04),
            kCIInputAngleKey: v.dx != 0 ? 0 : Double.pi / 2
        ]).cropped(to: CGRect(origin: .zero, size: canvas))
    }
}
