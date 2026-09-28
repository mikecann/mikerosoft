import CoreGraphics
import XCTest
@testable import MikeyMouse

final class ScrollPolicyTests: XCTestCase {
    func testNotchedWheelTickIsSmoothed() {
        XCTAssertEqual(ScrollPolicy.decide(wheel(y: -1), enabled: true), .smooth(x: 0, y: -1))
    }

    func testAcceleratedLineDeltaStillCountsAsOneTick() {
        // macOS already accelerates line deltas. The animator applies its own
        // acceleration from tick timing, so only the direction is used.
        XCTAssertEqual(ScrollPolicy.decide(wheel(y: 4), enabled: true), .smooth(x: 0, y: 1))
    }

    func testHorizontalWheelTickIsSmoothed() {
        XCTAssertEqual(ScrollPolicy.decide(wheel(x: 1), enabled: true), .smooth(x: 1, y: 0))
    }

    func testFractionalOnlyDeltaUsesItsDirection() {
        var input = wheel()
        input.fixedDeltaY = -0.3

        XCTAssertEqual(ScrollPolicy.decide(input, enabled: true), .smooth(x: 0, y: -1))
    }

    func testTrackpadAndMagicMouseScrollingPassThrough() {
        var input = wheel(y: -1)
        input.isContinuous = true

        XCTAssertEqual(ScrollPolicy.decide(input, enabled: true), .passThrough)
    }

    func testPhasedScrollingPassesThrough() {
        var scrolling = wheel(y: -1)
        scrolling.scrollPhase = 2
        var momentum = wheel(y: -1)
        momentum.momentumPhase = 1

        XCTAssertEqual(ScrollPolicy.decide(scrolling, enabled: true), .passThrough)
        XCTAssertEqual(ScrollPolicy.decide(momentum, enabled: true), .passThrough)
    }

    func testModifierScrollsKeepTheirNativeBehaviour() {
        let modifiers: [CGEventFlags] = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        for modifier in modifiers {
            var input = wheel(y: -1)
            input.flags = modifier

            XCTAssertEqual(ScrollPolicy.decide(input, enabled: true), .passThrough, "\(modifier)")
        }
    }

    func testNonModifierFlagsStillSmooth() {
        var input = wheel(y: -1)
        input.flags = [.maskNonCoalesced, .maskNumericPad]

        XCTAssertEqual(ScrollPolicy.decide(input, enabled: true), .smooth(x: 0, y: -1))
    }

    func testOwnSyntheticEventsPassThrough() {
        var input = wheel(y: -1)
        input.isSynthetic = true

        XCTAssertEqual(ScrollPolicy.decide(input, enabled: true), .passThrough)
    }

    func testDisabledSmoothingPassesThrough() {
        XCTAssertEqual(ScrollPolicy.decide(wheel(y: -1), enabled: false), .passThrough)
    }

    func testEmptyScrollEventPassesThrough() {
        XCTAssertEqual(ScrollPolicy.decide(wheel(), enabled: true), .passThrough)
    }

    func testReadsNotchedWheelEventsFromCoreGraphics() throws {
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 2,
                wheel1: -1,
                wheel2: 0,
                wheel3: 0
            )
        )

        let input = ScrollInput(event: event)

        XCTAssertFalse(input.isContinuous)
        XCTAssertEqual(input.lineDeltaY, -1)
        XCTAssertEqual(ScrollPolicy.decide(input, enabled: true), .smooth(x: 0, y: -1))
    }

    func testReadsPixelEventsAsContinuous() throws {
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: -7,
                wheel2: 0,
                wheel3: 0
            )
        )

        XCTAssertEqual(ScrollPolicy.decide(ScrollInput(event: event), enabled: true), .passThrough)
    }

    func testPostedScrollEventsAreMarkedAsOurs() throws {
        let event = try XCTUnwrap(SmoothScrollPoster.makeEvent(PixelDelta(x: 0, y: -5), flags: []))

        let input = ScrollInput(event: event)

        XCTAssertTrue(input.isSynthetic)
        XCTAssertTrue(input.isContinuous)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), -5)
    }

    private func wheel(x: Int64 = 0, y: Int64 = 0) -> ScrollInput {
        ScrollInput(
            isContinuous: false,
            scrollPhase: 0,
            momentumPhase: 0,
            lineDeltaX: x,
            lineDeltaY: y,
            fixedDeltaX: Double(x),
            fixedDeltaY: Double(y),
            flags: [],
            isSynthetic: false
        )
    }
}
