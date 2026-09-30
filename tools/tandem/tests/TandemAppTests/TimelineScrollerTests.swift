import XCTest
@testable import TandemApp

/// The scroll bar under the tracks: where its thumb sits and what dragging
/// it, its ends or the bar does.
final class TimelineScrollerTests: XCTestCase {
    /// A 10 minute video with a minute on screen, on a 400 pt bar.
    private func scroller(scroll: Double = 0, visible: Double = 60, duration: Double = 600) -> TimelineScroller {
        TimelineScroller(scrollSeconds: scroll, visibleSeconds: visible, duration: duration, width: 400)
    }

    /// The bar is the video: a minute of ten is a tenth of it.
    func testTheThumbShowsWhatsOnScreen() {
        let start = scroller()
        XCTAssertEqual(start.thumbX, 0)
        XCTAssertEqual(start.thumbWidth, 40, accuracy: 1e-9)
        let middle = scroller(scroll: 270)
        XCTAssertEqual(middle.thumbX, 180, accuracy: 1e-9)
        let end = scroller(scroll: 540)
        XCTAssertEqual(end.thumbX + end.thumbWidth, 400, accuracy: 1e-9, "the last minute ends the bar")
    }

    /// Scrolled past the end (the timeline allows half a screen), the thumb
    /// shrinks against the end of the bar rather than leaving it.
    func testPastTheEndTheThumbShrinksAgainstTheEnd() {
        let past = scroller(scroll: 570)
        XCTAssertEqual(past.maxScrollSeconds, 570, accuracy: 1e-9)
        XCTAssertEqual(past.thumbX + past.thumbWidth, 400, accuracy: 1e-9)
        XCTAssertEqual(past.thumbWidth, TimelineScroller.minimumThumb)
    }

    func testAThumbStaysBigEnoughToGrab() {
        let long = scroller(scroll: 1_800, visible: 2, duration: 3_600)
        XCTAssertEqual(long.thumbWidth, TimelineScroller.minimumThumb)
        XCTAssertEqual(long.thumbX + long.thumbWidth / 2, 200, accuracy: 0.5, "centred on what's shown")
        XCTAssertEqual(scroller(scroll: 0, visible: 2, duration: 3_600).thumbX, 0, "kept on the bar")
    }

    /// With the whole video on screen the thumb fills the bar, whether or
    /// not the half screen past the end still scrolls.
    func testAllOnScreenFillsTheBar() {
        let fitted = scroller(visible: 630)
        XCTAssertTrue(fitted.canScroll)
        XCTAssertEqual(fitted.thumbX, 0)
        XCTAssertEqual(fitted.thumbWidth, 400)
        let wide = scroller(visible: 1_300)
        XCTAssertFalse(wide.canScroll)
        XCTAssertEqual(wide.thumbWidth, 400)
        XCTAssertEqual(wide.scrollSeconds(draggedFrom: 0, by: 100), 0)
    }

    func testDraggingTheThumbScrolls() {
        let bar = scroller()
        XCTAssertEqual(bar.scrollSeconds(draggedFrom: 0, by: 200), 300, accuracy: 1e-9, "half the bar is half the video")
        XCTAssertEqual(bar.scrollSeconds(draggedFrom: 0, by: 10_000), 570, "stops where the end is mid-screen")
        XCTAssertEqual(bar.scrollSeconds(draggedFrom: 100, by: -10_000), 0, "and at the start")
    }

    func testClickingTheBarCentresThatTime() {
        let bar = scroller()
        let moved = scroller(scroll: bar.scrollSeconds(centredOn: 200))
        XCTAssertEqual(moved.scrollSeconds, 270, accuracy: 1e-9)
        XCTAssertEqual(moved.thumbX + moved.thumbWidth / 2, 200, accuracy: 1e-9)
    }

    func testTheEndsZoomAndTheMiddleScrolls() {
        let bar = scroller(scroll: 270)
        XCTAssertEqual(bar.part(at: bar.thumbX + 2), .leadingEdge)
        XCTAssertEqual(bar.part(at: bar.thumbX + bar.thumbWidth - 2), .trailingEdge)
        XCTAssertEqual(bar.part(at: bar.thumbX + bar.thumbWidth / 2), .thumb)
        XCTAssertEqual(bar.part(at: 5), .track)
        // A small thumb keeps a middle to drag.
        let small = scroller(scroll: 1_800, visible: 2, duration: 3_600)
        XCTAssertEqual(small.part(at: small.thumbX + small.thumbWidth / 2), .thumb)
    }

    /// Dragging an end sets how much is on screen, keeping the other end's
    /// time where it was, like Premiere's zoom scroll bar.
    func testDraggingAnEndZooms() {
        let bar = scroller(scroll: 120)
        // 40 pt is a minute of the video.
        let wider = bar.range(draggingTrailingEdgeBy: 40, minimumSeconds: 0.5)
        XCTAssertEqual(wider.start, 120, accuracy: 1e-9, "the start stays")
        XCTAssertEqual(wider.end, 240, accuracy: 1e-9)
        let narrower = bar.range(draggingLeadingEdgeBy: 20, minimumSeconds: 0.5)
        XCTAssertEqual(narrower.start, 150, accuracy: 1e-9)
        XCTAssertEqual(narrower.end, 180, accuracy: 1e-9, "the end stays")
        // An end can't cross the other or go before the start of the video.
        XCTAssertEqual(bar.range(draggingLeadingEdgeBy: 10_000, minimumSeconds: 0.5).start, 179.5, accuracy: 1e-9)
        XCTAssertEqual(bar.range(draggingLeadingEdgeBy: -10_000, minimumSeconds: 0.5).start, 0)
        // Past the end, the trailing end moves from the end of the video,
        // where the thumb shows it.
        let past = scroller(scroll: 570)
        XCTAssertEqual(past.range(draggingTrailingEdgeBy: -40, minimumSeconds: 0.5).end, 570.5, accuracy: 1e-9)
    }

    func testThePlayheadTickFollowsTheBar() {
        let bar = scroller()
        XCTAssertEqual(bar.x(forSeconds: 0), 0)
        XCTAssertEqual(bar.x(forSeconds: 300), 200, accuracy: 1e-9)
        XCTAssertEqual(bar.x(forSeconds: 900), 400, "clamped to the bar")
    }
}
