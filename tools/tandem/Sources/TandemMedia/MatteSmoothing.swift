import Accelerate
import CoreVideo
import Foundation

/// A frame's picture, small and blurred, for telling where it moved: luma
/// (full range) and both chroma channels, so a skin-coloured hand passing a
/// wall of the same brightness still counts.
struct MotionPicture {
    let width: Int
    let height: Int
    var luma: [UInt8]
    var cb: [UInt8]
    var cr: [UInt8]

    init(width: Int, height: Int, luma: [UInt8], cb: [UInt8], cr: [UInt8]) {
        self.width = width
        self.height = height
        self.luma = luma
        self.cb = cb
        self.cr = cr
    }

    /// From a 420 biplanar frame, scaled to `width` x `height` and blurred
    /// 3x3. Video range luma is stretched to full range so the thresholds
    /// mean the same either way. A frame it can't read gives a black
    /// picture, which counts as motion against its neighbours: the matte
    /// there is left as Vision made it.
    init(frame: CVPixelBuffer, width: Int, height: Int) {
        self.width = width
        self.height = height
        let count = width * height
        var luma = [UInt8](repeating: 0, count: count)
        var cb = [UInt8](repeating: 128, count: count)
        var cr = [UInt8](repeating: 128, count: count)
        let format = CVPixelBufferGetPixelFormatType(frame)
        if CVPixelBufferGetPlaneCount(frame) == 2,
           format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            var source = vImage_Buffer(
                data: CVPixelBufferGetBaseAddressOfPlane(frame, 0), height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(frame, 0)),
                width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(frame, 0)), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
            )
            _ = MatteBlender.withImage(&luma, width, height) { destination in
                vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
            }
            if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                Self.fullRange.withUnsafeBufferPointer { table in
                    _ = MatteBlender.withImage(&luma, width, height) { image in
                        vImageTableLookUp_Planar8(&image, &image, table.baseAddress!, vImage_Flags(kvImageNoFlags))
                    }
                }
            }
            // The chroma plane is Cb and Cr interleaved at half size.
            var chromaSource = vImage_Buffer(
                data: CVPixelBufferGetBaseAddressOfPlane(frame, 1), height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(frame, 1)),
                width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(frame, 1)), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(frame, 1)
            )
            var pairs = [UInt8](repeating: 128, count: count * 2)
            let scaled = pairs.withUnsafeMutableBytes { raw in
                var destination = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 2)
                return vImageScale_CbCr8(&chromaSource, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
            }
            if scaled == kvImageNoError {
                for i in 0..<count {
                    cb[i] = pairs[2 * i]
                    cr[i] = pairs[2 * i + 1]
                }
            }
        }
        self.luma = Self.blurred(luma, width, height)
        self.cb = Self.blurred(cb, width, height)
        self.cr = Self.blurred(cr, width, height)
    }

    /// Video range 16...235 to 0...255.
    static let fullRange: [UInt8] = (0..<256).map { UInt8(max(0, min(255, ($0 - 16) * 255 / 219))) }

    static func blurred(_ plane: [UInt8], _ width: Int, _ height: Int) -> [UInt8] {
        var source = plane
        var out = [UInt8](repeating: 0, count: plane.count)
        MatteBlender.withImage(&source, width, height) { input in
            MatteBlender.withImage(&out, width, height) { output in
                _ = vImageBoxConvolve_Planar8(&input, &output, nil, 0, 0, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }
}

/// Steadies a matte over time without trails behind moving hands.
///
/// Vision segments every frame on its own, so edges shimmer and patches
/// Vision is half sure of (the desk, a mic it loses) pop in and out. Three
/// steps take that out, each only where the picture itself is still:
///
/// 1. The median of each frame with the ones either side. A one-frame pop
///    goes.
/// 2. The median over seven frames (three each side), where the picture is
///    still across all seven. Pops up to three frames long go, and a change
///    that stays lands on the frame it happens.
/// 3. An average with the frames before, where the picture has been still
///    for three frames and the matte moved by less than a quarter. That
///    calms the edge shimmer the medians leave.
///
/// "Still" comes from `MotionPicture`s of the source: luma and chroma at a
/// quarter size, blurred, compared frame to frame. Where the picture moved,
/// the matte is taken as Vision made it. That matters even for step 1: a
/// fast hand is in each place for one frame only, and a plain median of
/// three cut its fingers off and dragged a one-frame pop into the frame
/// after it wherever the arm arrived next. Mattes come out `delay` frames
/// after they go in.
///
/// Measured on 20 s ranges of two of Mike's takes (docs/MEDIA.md), the
/// three steps cut the matte's frame-to-frame change where the picture is
/// still to between a quarter and a third of what the subject blend alone
/// leaves.
final class MatteSmoother {
    let width: Int
    let height: Int
    /// Frames each side of the step 2 median.
    static let radius = 3
    /// Frames of stillness before step 3 averages.
    static let restMemory = 3
    /// Step 3's weight on the new frame, and the change (of 255) it always takes at once.
    static let restWeight: Float = 0.2
    static let restTolerance: Float = 64
    /// Picture change (luma, or twice the chroma change, 0...255) below
    /// which a pixel is still and above which it moved; blended between.
    static let stillBelow: Float = 3
    static let movedAbove: Float = 12
    /// Motion is grown by this many picture pixels, so a moving hand's
    /// edges and the matte's soft band around them count as moving too.
    /// Step 1 only compares neighbouring frames, so it needs less.
    static let grow = 2
    static let neighbourGrow = 1
    static let delay = radius + 1

    /// Picture change to weight: 0 where still, 255 where it moved.
    static let weightTable: [UInt8] = (0..<256).map { value in
        UInt8((min(1, max(0, (Float(value) - stillBelow) / (movedAbove - stillBelow))) * 255).rounded())
    }

    private var raw: [[UInt8]] = []
    /// Step 1 results by frame index.
    private var medians: [Int: [UInt8]] = [:]
    /// Picture change into each frame (frame 0: none).
    private var changes: [Int: [UInt8]] = [:]
    private var lastPicture: MotionPicture?
    private var pictureWidth = 0
    private var pictureHeight = 0
    private var rest: [Float] = []
    private var received = 0
    private var emitted = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Takes the next frame's matte and picture; returns the mattes that are
    /// now ready, oldest first.
    func push(_ matte: [UInt8], picture: MotionPicture) -> [[UInt8]] {
        let index = received
        if let lastPicture {
            changes[index] = Self.change(from: lastPicture, to: picture)
        } else {
            pictureWidth = picture.width
            pictureHeight = picture.height
            changes[index] = [UInt8](repeating: 0, count: picture.width * picture.height)
        }
        lastPicture = picture
        raw.append(matte)
        if raw.count > 3 { raw.removeFirst() }
        received += 1
        if index == 1 { medians[0] = raw[0] }
        if index >= 2 {
            let still = weight(changesFrom: index - 1, through: index, grow: Self.neighbourGrow)
            medians[index - 1] = Self.stillMedian3(raw[0], raw[1], raw[2], weight: still)
        }
        var ready: [[UInt8]] = []
        while emitted + Self.radius <= index - 1 { ready.append(emit(last: index - 1)) }
        return ready
    }

    /// Returns the mattes still held, once every frame has gone in.
    func finish() -> [[UInt8]] {
        guard received > 0 else { return [] }
        let last = received - 1
        // The last frame has nothing after it for step 1.
        medians[last] = raw[raw.count - 1]
        var ready: [[UInt8]] = []
        while emitted <= last { ready.append(emit(last: last)) }
        return ready
    }

    /// Steps 2 and 3 for the next frame out; `last` is the newest frame
    /// with a step 1 result.
    private func emit(last: Int) -> [UInt8] {
        let t = emitted
        let lo = max(0, t - Self.radius), hi = min(last, t + Self.radius)
        let window = (lo...hi).map { medians[$0]! }
        let still = weight(changesFrom: lo + 1, through: hi, grow: Self.grow)
        let steadied = Self.stillMedian(window, centre: t - lo, weight: still)
        let out: [UInt8]
        if t == 0 {
            rest = steadied.map { Float($0) }
            out = steadied
        } else {
            out = restAverage(steadied, weight: weight(changesFrom: t - Self.restMemory + 1, through: t, grow: Self.grow))
        }
        emitted += 1
        // What the next frame out no longer needs.
        medians = medians.filter { $0.key >= emitted - Self.radius }
        changes = changes.filter { $0.key >= emitted - max(Self.radius, Self.restMemory) + 1 }
        return out
    }

    /// How much each matte pixel moved over the picture changes
    /// `first...last`, as a 0 (still) to 255 (moved) weight at matte size.
    private func weight(changesFrom first: Int, through last: Int, grow: Int) -> [UInt8] {
        var peak = [UInt8](repeating: 0, count: pictureWidth * pictureHeight)
        if max(1, first) <= last {
            for k in max(1, first)...last {
                guard let change = changes[k] else { continue }
                peak.withUnsafeMutableBufferPointer { p in
                    change.withUnsafeBufferPointer { c in
                        for i in 0..<p.count { p[i] = max(p[i], c[i]) }
                    }
                }
            }
        }
        var grown = [UInt8](repeating: 0, count: peak.count)
        let kernel = vImagePixelCount(2 * grow + 1)
        MatteBlender.withImage(&peak, pictureWidth, pictureHeight) { source in
            MatteBlender.withImage(&grown, pictureWidth, pictureHeight) { destination in
                _ = vImageMax_Planar8(&source, &destination, nil, 0, 0, kernel, kernel, vImage_Flags(kvImageNoFlags))
            }
        }
        var weight = [UInt8](repeating: 0, count: width * height)
        MatteBlender.withImage(&grown, pictureWidth, pictureHeight) { source in
            MatteBlender.withImage(&weight, width, height) { destination in
                _ = vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        Self.weightTable.withUnsafeBufferPointer { table in
            _ = MatteBlender.withImage(&weight, width, height) { image in
                vImageTableLookUp_Planar8(&image, &image, table.baseAddress!, vImage_Flags(kvImageNoFlags))
            }
        }
        return weight
    }

    /// Step 3: averages toward the new value where the weight says still
    /// and the change is small; takes it at once anywhere else.
    private func restAverage(_ steadied: [UInt8], weight: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: steadied.count)
        let alpha = Self.restWeight, inverseTolerance = 1 / Self.restTolerance
        rest.withUnsafeMutableBufferPointer { state in
            steadied.withUnsafeBufferPointer { values in
                weight.withUnsafeBufferPointer { weights in
                    out.withUnsafeMutableBufferPointer { result in
                        for i in 0..<state.count {
                            let value = Float(values[i]), previous = state[i]
                            let gate = min(1, (abs(value - previous) * inverseTolerance) * (abs(value - previous) * inverseTolerance))
                            let a = max(Float(weights[i]) * (1 / 255), gate, alpha)
                            let next = previous + a * (value - previous)
                            state[i] = next
                            result[i] = UInt8(max(0, min(255, next + 0.5)))
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - Per-pixel pieces

    /// The largest of the luma change and twice the chroma changes.
    static func change(from a: MotionPicture, to b: MotionPicture) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: a.luma.count)
        guard a.luma.count == b.luma.count else { return [UInt8](repeating: 255, count: b.luma.count) }
        for i in 0..<out.count {
            let luma = abs(Int(a.luma[i]) - Int(b.luma[i]))
            let chroma = 2 * max(abs(Int(a.cb[i]) - Int(b.cb[i])), abs(Int(a.cr[i]) - Int(b.cr[i])))
            out[i] = UInt8(min(255, max(luma, chroma)))
        }
        return out
    }

    /// Step 1: the median of `b` and its neighbours where `weight` says
    /// still, blended toward `b` as it says moved.
    static func stillMedian3(_ a: [UInt8], _ b: [UInt8], _ c: [UInt8], weight: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: b.count)
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                c.withUnsafeBufferPointer { c in
                    weight.withUnsafeBufferPointer { weight in
                        out.withUnsafeMutableBufferPointer { out in
                            for i in 0..<out.count {
                                let median = max(min(a[i], b[i]), min(max(a[i], b[i]), c[i]))
                                out[i] = blend(b[i], median, weight[i])
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Step 2: the window's median where `weight` says still, blended
    /// toward the centre frame as it says moved.
    static func stillMedian(_ window: [[UInt8]], centre: Int, weight: [UInt8]) -> [UInt8] {
        var out = window[centre]
        if window.count == 7 {
            withPointers(window) { p in
                let (p0, p1, p2, p3, p4, p5, p6) = (p[0], p[1], p[2], p[3], p[4], p[5], p[6])
                let middle = p[centre]
                weight.withUnsafeBufferPointer { weight in
                    out.withUnsafeMutableBufferPointer { out in
                        for i in 0..<out.count where weight[i] < 255 {
                            let values = (p0[i], p1[i], p2[i], p3[i], p4[i], p5[i], p6[i])
                            let low = min(min(min(values.0, values.1), min(values.2, values.3)), min(min(values.4, values.5), values.6))
                            let high = max(max(max(values.0, values.1), max(values.2, values.3)), max(max(values.4, values.5), values.6))
                            if low == high { continue }
                            out[i] = blend(middle[i], median7(values), weight[i])
                        }
                    }
                }
            }
        } else {
            // The first and last frames of a take have shorter windows.
            var values = [UInt8](repeating: 0, count: window.count)
            for i in 0..<out.count where weight[i] < 255 {
                for k in 0..<window.count { values[k] = window[k][i] }
                values.sort()
                out[i] = blend(window[centre][i], values[values.count / 2], weight[i])
            }
        }
        return out
    }

    /// `weight` of 255 gives `moving`, 0 gives `still`.
    @inline(__always)
    static func blend(_ moving: UInt8, _ still: UInt8, _ weight: UInt8) -> UInt8 {
        UInt8((Int(weight) * Int(moving) + (255 - Int(weight)) * Int(still) + 127) / 255)
    }

    /// The median of seven values, by the comparisons of a sorting network
    /// that the middle output depends on.
    @inline(__always)
    static func median7(_ values: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> UInt8 {
        var v = values
        @inline(__always) func order(_ a: inout UInt8, _ b: inout UInt8) {
            let low = min(a, b)
            b = max(a, b)
            a = low
        }
        order(&v.0, &v.6); order(&v.2, &v.3); order(&v.4, &v.5)
        order(&v.0, &v.2); order(&v.1, &v.4); order(&v.3, &v.6)
        order(&v.0, &v.1); order(&v.2, &v.5); order(&v.3, &v.4)
        order(&v.1, &v.2); order(&v.4, &v.6)
        order(&v.2, &v.3); order(&v.4, &v.5)
        order(&v.3, &v.4)
        return v.3
    }

    /// Base addresses of several planes at once.
    static func withPointers<R>(_ planes: [[UInt8]], _ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        func next(_ index: Int) -> R {
            if index == planes.count { return body(pointers) }
            return planes[index].withUnsafeBufferPointer { buffer in
                pointers.append(buffer.baseAddress!)
                return next(index + 1)
            }
        }
        return next(0)
    }
}
