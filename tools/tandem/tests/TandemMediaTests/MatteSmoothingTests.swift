import CoreVideo
import TandemCore
import XCTest
@testable import TandemMedia

/// The version 2 cutout: the subject blend and the smoothing over time, on
/// small made-up frames.
final class MatteSmoothingTests: XCTestCase {
    // Mattes are 128x72, pictures for motion 32x18 (a quarter each way, as
    // 1920x1080 mattes get 480x270 pictures).
    let width = 128, height = 72
    let pictureWidth = 32, pictureHeight = 18

    func plane(_ value: UInt8 = 0) -> [UInt8] { [UInt8](repeating: value, count: width * height) }

    /// Sets a rectangle of a plane.
    func fill(_ plane: inout [UInt8], x: Range<Int>, y: Range<Int>, _ value: UInt8, width: Int? = nil) {
        let w = width ?? self.width
        for row in y { for column in x { plane[row * w + column] = value } }
    }

    func values(_ plane: [UInt8], x: Range<Int>, y: Range<Int>) -> [UInt8] {
        y.flatMap { row in x.map { plane[row * width + $0] } }
    }

    /// A still grey picture, or one with a bright square at `square` (in picture pixels).
    func picture(square: (x: Int, y: Int)? = nil) -> MotionPicture {
        var luma = [UInt8](repeating: 60, count: pictureWidth * pictureHeight)
        if let square { fill(&luma, x: square.x..<min(pictureWidth, square.x + 8), y: square.y..<(square.y + 8), 220, width: pictureWidth) }
        let neutral = [UInt8](repeating: 128, count: pictureWidth * pictureHeight)
        return MotionPicture(width: pictureWidth, height: pictureHeight, luma: luma, cb: neutral, cr: neutral)
    }

    func smooth(_ mattes: [[UInt8]], pictures: [MotionPicture]) -> [[UInt8]] {
        let smoother = MatteSmoother(width: width, height: height)
        var out: [[UInt8]] = []
        for (matte, picture) in zip(mattes, pictures) { out += smoother.push(matte, picture: picture) }
        return out + smoother.finish()
    }

    // MARK: - Smoothing

    func testAOneFramePopInAStillPictureIsDropped() {
        var mattes = [[UInt8]](repeating: plane(), count: 10)
        fill(&mattes[5], x: 40..<60, y: 20..<40, 255)
        let out = smooth(mattes, pictures: Array(repeating: picture(), count: 10))
        XCTAssertEqual(out.count, 10)
        XCTAssertEqual(out[5].max(), 0, "Vision's one-frame guess at a desk patch goes")
    }

    func testPopsUpToThreeFramesLongGoWhereThePictureIsStill() {
        for length in 2...3 {
            var mattes = [[UInt8]](repeating: plane(), count: 14)
            for t in 5..<(5 + length) { fill(&mattes[t], x: 40..<60, y: 20..<40, 255) }
            let out = smooth(mattes, pictures: Array(repeating: picture(), count: 14))
            XCTAssertEqual(out.map { $0.max() ?? 0 }, Array(repeating: 0, count: 14), "a \(length)-frame pop")
        }
    }

    func testAChangeThatStaysLandsOnTheFrameItHappens() {
        // The mic coming in while nothing else moves (it's dark on dark):
        // no lag, no fade.
        var mattes = [[UInt8]](repeating: plane(), count: 12)
        for t in 6..<12 { fill(&mattes[t], x: 40..<60, y: 20..<40, 255) }
        let out = smooth(mattes, pictures: Array(repeating: picture(), count: 12))
        XCTAssertEqual(values(out[5], x: 40..<60, y: 20..<40).max(), 0)
        XCTAssertEqual(values(out[6], x: 40..<60, y: 20..<40).min(), 255)
        XCTAssertEqual(values(out[11], x: 40..<60, y: 20..<40).min(), 255)
    }

    func testAMovingHandLeavesNoTrail() {
        // A hand (bright square) crosses the picture 2 picture pixels, 8
        // matte pixels, a frame, and the matte follows it exactly.
        var mattes: [[UInt8]] = [], pictures: [MotionPicture] = []
        for t in 0..<12 {
            pictures.append(picture(square: (x: 2 * t, y: 5)))
            var matte = plane()
            fill(&matte, x: (8 * t)..<min(width, 8 * t + 32), y: 20..<52, 255)
            mattes.append(matte)
        }
        let out = smooth(mattes, pictures: pictures)
        XCTAssertEqual(out.count, 12)
        for t in 0..<12 {
            let worst = zip(out[t], mattes[t]).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 1, "frame \(t)")
        }
    }

    func testAHandThatIsSomewhereForOneFrameIsKept() {
        // A fast swipe: the hand is never in the same place twice, so a
        // plain median of three frames would cut it away.
        var mattes: [[UInt8]] = [], pictures: [MotionPicture] = []
        for t in 0..<4 {
            pictures.append(picture(square: (x: 8 * t, y: 5)))
            var matte = plane()
            fill(&matte, x: (32 * t)..<(32 * t + 32), y: 20..<52, 255)
            mattes.append(matte)
        }
        let out = smooth(mattes, pictures: pictures)
        for t in 0..<4 {
            XCTAssertEqual(values(out[t], x: (32 * t + 4)..<(32 * t + 28), y: 24..<48).min(), 255, "the hand at frame \(t)")
        }
    }

    func testAPopBesideAMovingArmDoesNotSpreadToTheNextFrame() {
        // Frame 4 takes a patch of sofa for a person for one frame; the arm
        // arrives over that patch at frame 6. Frame 5 has neither.
        var mattes = [[UInt8]](repeating: plane(), count: 10), pictures: [MotionPicture] = []
        fill(&mattes[4], x: 0..<48, y: 0..<32, 255)
        for t in 0..<10 {
            pictures.append(t < 6 ? picture() : picture(square: (x: 0, y: 0)))
            if t >= 6 { fill(&mattes[t], x: 0..<32, y: 0..<32, 255) }
        }
        let out = smooth(mattes, pictures: pictures)
        XCTAssertEqual(out[5].max(), 0, "nothing where frame 5 had nothing")
        XCTAssertEqual(values(out[4], x: 0..<48, y: 0..<32).max(), 0, "the one-frame sofa patch goes")
        XCTAssertEqual(values(out[6], x: 0..<32, y: 0..<32).min(), 255, "the arm lands at once")
    }

    func testEdgeShimmerWhereThePictureIsStillIsCalmed() {
        // An edge band whose value wanders frame to frame around 128.
        var seed: UInt32 = 12345
        func noise() -> Int {
            seed = seed &* 1_103_515_245 &+ 12345
            return Int((seed >> 16) % 61) - 30
        }
        var mattes: [[UInt8]] = []
        for _ in 0..<30 {
            var matte = plane()
            fill(&matte, x: 0..<40, y: 0..<72, 255)
            for row in 0..<72 { for column in 40..<44 { matte[row * width + column] = UInt8(128 + noise()) } }
            mattes.append(matte)
        }
        let out = smooth(mattes, pictures: Array(repeating: picture(), count: 30))
        func change(_ frames: [[UInt8]]) -> Double {
            var total = 0
            for t in 1..<frames.count { total += zip(frames[t], frames[t - 1]).map { abs(Int($0) - Int($1)) }.reduce(0, +) }
            return Double(total) / Double(frames.count - 1)
        }
        XCTAssertLessThan(change(out), change(mattes) / 3)
        XCTAssertEqual(values(out[15], x: 0..<40, y: 0..<72).min(), 255, "solid person stays solid")
        XCTAssertEqual(values(out[15], x: 44..<128, y: 0..<72).max(), 0, "background stays clear")
    }

    func testEveryFrameComesOutOnceInOrder() {
        // Everything moves, so nothing is held back or averaged.
        for count in 0...9 {
            var mattes: [[UInt8]] = [], pictures: [MotionPicture] = []
            for t in 0..<count {
                mattes.append(plane(UInt8(20 * t)))
                pictures.append(MotionPicture(width: pictureWidth, height: pictureHeight,
                                              luma: [UInt8](repeating: UInt8(40 * (t % 2) + 60), count: pictureWidth * pictureHeight),
                                              cb: [UInt8](repeating: 128, count: pictureWidth * pictureHeight),
                                              cr: [UInt8](repeating: 128, count: pictureWidth * pictureHeight)))
            }
            let out = smooth(mattes, pictures: pictures)
            XCTAssertEqual(out.map { $0[0] }, (0..<count).map { UInt8(20 * $0) }, "\(count) frames")
        }
    }

    func testMotionPicturesComeFromLumaAndChroma() throws {
        for (format, black, white) in [(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, UInt8(0), UInt8(255)),
                                       (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, UInt8(16), UInt8(235))] {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 256, 144, format, [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &buffer)
            let frame = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(frame, [])
            let luma = CVPixelBufferGetBaseAddressOfPlane(frame, 0)!.assumingMemoryBound(to: UInt8.self)
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
            for y in 0..<144 { for x in 0..<256 { luma[y * lumaStride + x] = x < 128 ? black : white } }
            let chroma = CVPixelBufferGetBaseAddressOfPlane(frame, 1)!.assumingMemoryBound(to: UInt8.self)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 1)
            for y in 0..<72 { for x in 0..<128 { chroma[y * chromaStride + 2 * x] = 90; chroma[y * chromaStride + 2 * x + 1] = 170 } }
            CVPixelBufferUnlockBaseAddress(frame, [])

            let picture = MotionPicture(frame: frame, width: 64, height: 36)
            XCTAssertEqual(picture.luma[10 * 64 + 5], 0, "black reads as 0 in either range")
            XCTAssertEqual(picture.luma[10 * 64 + 60], 255, "white reads as 255 in either range")
            XCTAssertEqual(picture.cb[10 * 64 + 20], 90)
            XCTAssertEqual(picture.cr[10 * 64 + 20], 170)
        }
    }

    // MARK: - Subject blend

    /// A person: head and body, with a hole where the mic hides the chest.
    func person() -> [UInt8] {
        var p = plane()
        fill(&p, x: 48..<80, y: 8..<30, 255)
        fill(&p, x: 32..<96, y: 30..<72, 255)
        fill(&p, x: 56..<68, y: 40..<60, 0)
        return p
    }

    func testTheSubjectKeepsTheMicInsideThePerson() {
        var subject = person()
        fill(&subject, x: 56..<68, y: 40..<60, 255)
        let matte = MatteBlender.keepSubject(person: person(), subject: subject, width: width, height: height)
        XCTAssertEqual(values(matte, x: 56..<68, y: 40..<60).min(), 255)
        XCTAssertEqual(values(matte, x: 32..<96, y: 30..<72).min(), 255)
    }

    func testASubjectFarFromThePersonStaysOut() {
        var subject = person()
        fill(&subject, x: 0..<10, y: 0..<10, 255)
        let matte = MatteBlender.keepSubject(person: person(), subject: subject, width: width, height: height)
        XCTAssertEqual(values(matte, x: 0..<10, y: 0..<10).max(), 0)
    }

    func testAwayFromTheSubjectOnlyConfidentPersonPixelsCount() {
        var p = person()
        fill(&p, x: 104..<120, y: 40..<56, 250)
        fill(&p, x: 104..<120, y: 60..<70, 140)
        fill(&p, x: 96..<100, y: 30..<72, 100)
        var subject = person()
        fill(&subject, x: 56..<68, y: 40..<60, 255)
        let matte = MatteBlender.keepSubject(person: p, subject: subject, width: width, height: height)
        XCTAssertEqual(values(matte, x: 104..<120, y: 40..<56).min(), 255, "a hand held out, Vision sure of it")
        XCTAssertEqual(values(matte, x: 104..<120, y: 60..<70).max(), 0, "a half-sure patch of desk")
        XCTAssertEqual(Set(values(matte, x: 96..<97, y: 32..<70)), [100], "a soft edge next to the subject stays soft")
    }

    func testWithoutASubjectThePersonMaskIsUsed() {
        XCTAssertEqual(MatteBlender.keepSubject(person: person(), subject: nil, width: width, height: height), person())
    }

    // MARK: - Settings

    func testMatteSettingsGoInTheCacheKey() {
        let standard = AnalysisSettings(matteModel: .vision)
        XCTAssertEqual(standard.matteProps, .subject)
        XCTAssertEqual(standard.matteSmoothing, .steady)
        XCTAssertEqual(AnalysisKind.matte.algorithmVersion, 2, "version 1 mattes flicker; they rebuild")
        var old = standard
        old.matteProps = .personInstances
        old.matteSmoothing = .off
        XCTAssertNotEqual(old.canonical(for: .matte), standard.canonical(for: .matte))
        var rough = standard
        rough.matteSmoothing = .off
        XCTAssertNotEqual(rough.canonical(for: .matte), standard.canonical(for: .matte))
        // A person-only matte has no props to find.
        var person = standard
        person.matteMode = .person
        var personOld = old
        personOld.matteMode = .person
        personOld.matteSmoothing = .steady
        XCTAssertEqual(person.canonical(for: .matte), personOld.canonical(for: .matte))
        XCTAssertEqual(AnalysisKind.allCases.filter { standard.canonical(for: $0) != old.canonical(for: $0) }, [.matte])
    }
}
