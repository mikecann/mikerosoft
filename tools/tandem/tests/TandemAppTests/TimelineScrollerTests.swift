import XCTest
@testable import TandemApp

/// The scroll bar under the tracks: where its thumb sits and what dragging
/// it, its ends or the bar does.
final class TimelineScrollerTests: XCTestCase {
    /// A 10 minute video with a minute on screen, on a 400 pt bar.
    private func scroller(scroll: Double = 0, visible: Double = 60, duration: Double = 600) -> TimelineScroller {
        TimelineScroller(scrollSeconds: scroll, visibleSeconds: visible, duration: duration, width: 400)
    }

    func testTheThumbShowsWhatsOnScreen() {
        let start = scroller()
        // Scrollable to where the end sits mid-screen: 570 s, so the bar
        // stands for 630 s and a minute is 38 pt of it.
        XCTAssertEqual(start.maxScrollSeconds, 570, accuracy: 1e-9)
        XCTAssertEqual(start.thumbWidth, 400 * 60 / 630, accuracy: 1e-6)
        XCTAssertEqual(start.thumbX, 0, accuracy: 1e-9)
        let end = scroller(scroll: 570)
        XCTAssertEqual(end.thumbX + end.thumbWidth, 400, accuracy: 1e-6, "all the way right")
        let middle = scroller(scroll: 285)
        XCTAssertEqual(middle.thumbX, (400 - middle.thumbWidth) / 2, accuracy: 1e-6)
    }

    func testAThumbStaysBigEnoughToGrab() {
        let long = scroller(visible: 2, duration: 3_600)
        XCTAssertEqual(long.thumbWidth, TimelineScroller.minimumThumb)
        XCTAssertEqual(scroller(scroll: 3_599, visible: 2, duration: 3_600).thumbX + TimelineScroller.minimumThumb, 400, accuracy: 1e-6)
    }

    func testWithEverythingOnScreenThereIsNothingToScroll() {
        let fitted = scroller(visible: 1_300)
        XCTAssertFalse(fitted.canScroll)
        XCTAssertEqual(fitted.thumbWidth, 400)
        XCTAssertEqual(fitted.scrollSeconds(draggedFrom: 0, by: 100), 0)
    }

    func testDraggingTheThumbScrolls() {
        let bar = scroller()
        let travel = 400 - bar.thumbWidth
        XCTAssertEqual(bar.scrollSeconds(draggedFrom: 0, by: travel / 2), 285, accuracy: 1e-6)
        XCTAssertEqual(bar.scrollSeconds(draggedFrom: 0, by: 10_000), 570, "stops at the end")
        XCTAssertEqual(bar.scrollSeconds(draggedFrom: 100, by: -10_000), 0, "and at the start")
    }

    func testClickingTheBarCentresTheThumbThere() {
        let bar = scroller()
        let scroll = bar.scrollSeconds(centredOn: 200)
        let moved = scroller(scroll: scroll)
        XCTAssertEqual(moved.thumbX + moved.thumbWidth / 2, 200, accuracy: 1e-6)
    }

    func testTheEndsZoomAndTheMiddleScrolls() {
        let bar = scroller(scroll: 285)
        XCTAssertEqual(bar.part(at: bar.thumbX + 2), .leadingEdge)
        XCTAssertEqual(bar.part(at: bar.thumbX + bar.thumbWidth - 2), .trailingEdge)
        XCTAssertEqual(bar.part(at: bar.thumbX + bar.thumbWidth / 2), .thumb)
        XCTAssertEqual(bar.part(at: 5), .track)
        // A small thumb keeps a middle to drag.
        let small = scroller(scroll: 285, visible: 2, duration: 3_600)
        XCTAssertEqual(small.part(at: small.thumbX + small.thumbWidth / 2), .thumb)
    }

    /// Dragging an end sets how much is on screen, keeping the other end's
    /// time where it was, like Premiere's zoom scroll bar.
    func testDraggingAnEndZooms() {
        let bar = scroller(scroll: 120)
        // The trailing end dragged right by the bar's worth of 60 s.
        let wider = bar.range(draggingTrailingEdgeBy: CGFloat(60 / bar.span) * 400, minimumSeconds: 0.5)
        XCTAssertEqual(wider.start, 120, accuracy: 1e-6, "the start stays")
        XCTAssertEqual(wider.end, 240, accuracy: 1e-6)
        let narrower = bar.range(draggingLeadingEdgeBy: CGFloat(30 / bar.span) * 400, minimumSeconds: 0.5)
        XCTAssertEqual(narrower.start, 150, accuracy: 1e-6)
        XCTAssertEqual(narrower.end, 180, accuracy: 1e-6, "the end stays")
        // An end can't cross the other or go past the start of the video.
        XCTAssertEqual(bar.range(draggingLeadingEdgeBy: 10_000, minimumSeconds: 0.5).start, 179.5, accuracy: 1e-6)
        XCTAssertEqual(bar.range(draggingLeadingEdgeBy: -10_000, minimumSeconds: 0.5).start, 0)
    }

    func testThePlayheadTickFollowsTheBar() {
        let bar = scroller()
        XCTAssertEqual(bar.x(forSeconds: 0), 0)
        XCTAssertEqual(bar.x(forSeconds: bar.span / 2), 200, accuracy: 1e-6)
    }
}
