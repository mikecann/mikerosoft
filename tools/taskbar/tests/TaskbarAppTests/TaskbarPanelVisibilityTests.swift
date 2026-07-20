import XCTest
@testable import TaskbarApp

final class TaskbarPanelVisibilityTests: XCTestCase {
    func testFullscreenWindowOverridesConfiguredVisibility() {
        XCTAssertFalse(
            taskbarPanelShouldBeVisible(
                configuredVisible: true,
                isObscuredByFullscreenWindow: true
            )
        )
        XCTAssertTrue(
            taskbarPanelShouldBeVisible(
                configuredVisible: true,
                isObscuredByFullscreenWindow: false
            )
        )
    }

    func testAnimatedRepeatForInFlightStateDoesNothing() {
        XCTAssertEqual(
            taskbarSetShownAction(
                targetShown: false,
                currentShown: false,
                frameMatchesTarget: false,
                animatedRequested: true
            ),
            .nothing
        )
    }

    func testStateFlipAnimatesWhenRequested() {
        XCTAssertEqual(
            taskbarSetShownAction(
                targetShown: true,
                currentShown: false,
                frameMatchesTarget: false,
                animatedRequested: true
            ),
            .animate
        )
    }

    func testGeometryDriftInSameStateSnapsDuringNonAnimatedSync() {
        XCTAssertEqual(
            taskbarSetShownAction(
                targetShown: true,
                currentShown: true,
                frameMatchesTarget: false,
                animatedRequested: false
            ),
            .snap
        )
    }

    func testNonAnimatedStateFlipSnapsExactlyOnce() {
        XCTAssertEqual(
            taskbarSetShownAction(
                targetShown: false,
                currentShown: true,
                frameMatchesTarget: false,
                animatedRequested: false
            ),
            .snap
        )
        XCTAssertEqual(
            taskbarSetShownAction(
                targetShown: false,
                currentShown: false,
                frameMatchesTarget: true,
                animatedRequested: false
            ),
            .nothing
        )
    }
}
