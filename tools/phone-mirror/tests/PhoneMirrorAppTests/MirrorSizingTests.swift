import XCTest
@testable import PhoneMirrorApp

final class MirrorSizingTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let xsMaxPortrait = CGSize(width: 1242, height: 2688)

    func testFirstWindowFitsMostOfTheScreenHeight() {
        let size = MirrorSizing.initialContentSize(for: xsMaxPortrait, visibleFrame: laptop)
        XCTAssertEqual(size.height, (944 * 0.85).rounded())
        XCTAssertEqual(size.width / size.height, 1242 / 2688, accuracy: 0.01)
    }

    func testFirstWindowLongEdgeIsCappedOnTallScreens() {
        let tall = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        let size = MirrorSizing.initialContentSize(for: xsMaxPortrait, visibleFrame: tall)
        XCTAssertEqual(size.height, MirrorSizing.maxInitialLongEdge)
    }

    func testFirstLandscapeWindowFitsTheScreenWidth() {
        let narrow = CGRect(x: 0, y: 0, width: 800, height: 944)
        let size = MirrorSizing.initialContentSize(for: CGSize(width: 2688, height: 1242), visibleFrame: narrow)
        XCTAssertEqual(size.width, 720)
        XCTAssertEqual(size.width / size.height, 2688 / 1242, accuracy: 0.01)
    }

    func testRotatingKeepsTheLongEdge() {
        let portrait = CGSize(width: 372, height: 804)
        let landscape = MirrorSizing.contentSize(for: CGSize(width: 2688, height: 1242), keepingLongEdgeOf: portrait)
        XCTAssertEqual(landscape.width, 804)
        XCTAssertEqual(landscape.height, (804 * 1242 / 2688).rounded())
    }

    func testIgnoresEmptyVideoSizes() {
        let current = CGSize(width: 372, height: 804)
        XCTAssertEqual(MirrorSizing.contentSize(for: .zero, keepingLongEdgeOf: current), current)
        XCTAssertEqual(MirrorSizing.initialContentSize(for: .zero, visibleFrame: laptop), MirrorSizing.placeholderSize)
    }

    func testFindsTheLetterboxedVideo() {
        let rect = MirrorSizing.videoRect(in: CGSize(width: 500, height: 800), video: CGSize(width: 1242, height: 2688))
        XCTAssertEqual(rect.height, 800)
        XCTAssertEqual(rect.width, 800 * 1242 / 2688, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 250, accuracy: 0.001)
    }

    func testConvertsViewPointsToScreenFractionsFromTheTopLeft() {
        let bounds = CGSize(width: 400, height: 800), video = CGSize(width: 1000, height: 2000)
        XCTAssertEqual(MirrorSizing.fraction(of: CGPoint(x: 100, y: 600), in: bounds, video: video), CGPoint(x: 0.25, y: 0.25))
        XCTAssertEqual(MirrorSizing.fraction(of: CGPoint(x: 400, y: 0), in: bounds, video: video), CGPoint(x: 1, y: 1))
    }

    func testIgnoresTheLetterboxUnlessClamped() {
        let bounds = CGSize(width: 600, height: 800), video = CGSize(width: 1000, height: 2000)
        XCTAssertNil(MirrorSizing.fraction(of: CGPoint(x: 10, y: 400), in: bounds, video: video))
        XCTAssertEqual(MirrorSizing.fraction(of: CGPoint(x: 10, y: 400), in: bounds, video: video, clamped: true), CGPoint(x: 0, y: 0.5))
    }

    func testKeepsTheTopLeftCornerWhenTheSizeChanges() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 800)
        let resized = MirrorSizing.frame(frame, resizedTo: CGSize(width: 800, height: 400))
        XCTAssertEqual(resized.minX, 100)
        XCTAssertEqual(resized.maxY, frame.maxY)
        XCTAssertEqual(resized.size, CGSize(width: 800, height: 400))
    }
}
