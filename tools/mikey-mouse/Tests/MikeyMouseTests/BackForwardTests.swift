import CoreGraphics
import XCTest
@testable import MikeyMouse

final class BackForwardTests: XCTestCase {
    func testFinderSideButtonsBecomeSwipes() {
        XCTAssertEqual(route(button: 3, app: "com.apple.finder"), .back)
        XCTAssertEqual(route(button: 4, app: "com.apple.finder"), .forward)
    }

    func testOtherAppleAppsAreIncluded() {
        XCTAssertEqual(route(button: 3, app: "com.apple.Safari"), .back)
        XCTAssertEqual(route(button: 4, app: "com.apple.dt.Xcode"), .forward)
    }

    func testFirefoxAndForkLiftAreIncluded() {
        XCTAssertEqual(route(button: 3, app: "org.mozilla.firefox"), .back)
        XCTAssertEqual(route(button: 3, app: "com.binarynights.ForkLift-3"), .back)
    }

    func testAppsThatHandleSideButtonsThemselvesAreLeftAlone() {
        XCTAssertNil(route(button: 3, app: "com.google.Chrome"))
        XCTAssertNil(route(button: 4, app: "com.microsoft.VSCode"))
        XCTAssertNil(route(button: 3, app: "com.apple"))
    }

    func testUnknownTargetIsLeftAlone() {
        XCTAssertNil(route(button: 3, app: nil))
    }

    func testOtherButtonsAreLeftAlone() {
        XCTAssertNil(route(button: 2, app: "com.apple.finder"))
        XCTAssertNil(route(button: 5, app: "com.apple.finder"))
    }

    func testDisabledSettingLeavesButtonsAlone() {
        XCTAssertNil(
            BackForwardRouter.direction(forButton: 3, targetBundleID: "com.apple.finder", enabled: false)
        )
    }

    func testConvertedPressSwallowsItsDragAndRelease() {
        var state = SideButtonState()

        XCTAssertEqual(state.mouseDown(button: 3, direction: .back), .swipe(.back))
        XCTAssertTrue(state.swallowsDrag(button: 3))
        XCTAssertTrue(state.mouseUp(button: 3))
        XCTAssertFalse(state.mouseUp(button: 3))
    }

    func testPassedThroughPressKeepsItsRelease() {
        var state = SideButtonState()

        XCTAssertEqual(state.mouseDown(button: 3, direction: nil), .passThrough)
        XCTAssertFalse(state.swallowsDrag(button: 3))
        XCTAssertFalse(state.mouseUp(button: 3))
    }

    func testButtonsAreTrackedIndependently() {
        var state = SideButtonState()

        _ = state.mouseDown(button: 3, direction: .back)
        _ = state.mouseDown(button: 4, direction: nil)

        XCTAssertFalse(state.mouseUp(button: 4))
        XCTAssertTrue(state.mouseUp(button: 3))
    }

    func testBackSwipeEventsDescribeANavigationGesture() {
        let events = NavigationSwipe.events(for: .back)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.type.rawValue), [29, 29])
        XCTAssertEqual(events.map { $0.getIntegerValueField(NavigationSwipe.hidTypeField) }, [16, 16])
        XCTAssertEqual(events.map { $0.getIntegerValueField(NavigationSwipe.phaseField) }, [1, 4])
        XCTAssertEqual(events[0].getIntegerValueField(NavigationSwipe.directionField), 4)
    }

    func testForwardSwipeUsesTheOppositeDirection() {
        let events = NavigationSwipe.events(for: .forward)

        XCTAssertEqual(events[0].getIntegerValueField(NavigationSwipe.directionField), 8)
    }

    private func route(button: Int64, app: String?) -> NavigationDirection? {
        BackForwardRouter.direction(forButton: button, targetBundleID: app, enabled: true)
    }
}
