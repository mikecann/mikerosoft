import AppKit
import XCTest
@testable import TaskbarApp

private func mouseStateItem(
    owner: String,
    isPinned: Bool = true,
    pinOrder: Int? = 0,
    title: String = "",
    windowID: Int? = nil
) -> TaskbarItem {
    TaskbarItem(
        owner: owner,
        pid: nil,
        title: title,
        windowCount: 0,
        windowIDs: windowID.map { [$0] } ?? [],
        windowBounds: nil,
        accessibilitySignature: "",
        isFrontmost: false,
        isMinimized: false,
        bundleID: "com.example.\(owner.lowercased())",
        appPath: "/Applications/\(owner).app",
        isPinned: isPinned,
        pinOrder: pinOrder
    )
}

private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 0
    )!
}

private func trackingEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
    NSEvent.enterExitEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        trackingNumber: 0,
        userData: nil
    )!
}

private func mouseStateView(items: [TaskbarItem]) -> TaskbarView {
    let view = TaskbarView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
    var settings = TaskbarSettingValues.defaults
    settings.dateTimeWidget.isEnabled = false
    settings.statsWidget.isEnabled = false
    settings.batteryWidget.isEnabled = false
    view.update(items: items, settings: settings)
    return view
}

final class TaskbarMouseStateTests: XCTestCase {
    private let bounds = NSRect(x: 0, y: 0, width: 300, height: 30)
    private let firstRect = NSRect(x: 10, y: 4, width: 80, height: 22)
    private let secondRect = NSRect(x: 94, y: 4, width: 80, height: 22)

    func testSubThresholdPinnedWobbleActivatesWithoutReordering() {
        let item = mouseStateItem(owner: "Safari")

        let action = resolveTaskbarMouseUpAction(
            pressedItem: item,
            mouseDownPoint: NSPoint(x: 20, y: 15),
            mouseUpPoint: NSPoint(x: 21, y: 15),
            didDragPinnedItem: false,
            tileRects: [(rect: firstRect, item: item)],
            bounds: bounds
        )

        XCTAssertEqual(action, .activate)
    }

    func testRealPinnedDragReleasedOverSelfDoesNothing() {
        let item = mouseStateItem(owner: "Safari")

        let action = resolveTaskbarMouseUpAction(
            pressedItem: item,
            mouseDownPoint: NSPoint(x: 20, y: 15),
            mouseUpPoint: NSPoint(x: 20, y: 15),
            didDragPinnedItem: true,
            tileRects: [(rect: firstRect, item: item)],
            bounds: bounds
        )

        XCTAssertEqual(action, .none)
    }

    func testReleaseOutsidePressedTileDoesNothing() {
        let item = mouseStateItem(owner: "Notes", isPinned: false, pinOrder: nil)

        let action = resolveTaskbarMouseUpAction(
            pressedItem: item,
            mouseDownPoint: NSPoint(x: 20, y: 15),
            mouseUpPoint: NSPoint(x: 150, y: 15),
            didDragPinnedItem: false,
            tileRects: [(rect: firstRect, item: item)],
            bounds: bounds
        )

        XCTAssertEqual(action, .none)
    }

    func testRealPinnedDragOverDifferentPinnedTileReordersBeforeIt() {
        let safari = mouseStateItem(owner: "Safari", pinOrder: 0)
        let notes = mouseStateItem(owner: "Notes", pinOrder: 1)

        let action = resolveTaskbarMouseUpAction(
            pressedItem: safari,
            mouseDownPoint: NSPoint(x: 20, y: 15),
            mouseUpPoint: NSPoint(x: 110, y: 15),
            didDragPinnedItem: true,
            tileRects: [
                (rect: firstRect, item: safari),
                (rect: secondRect, item: notes)
            ],
            bounds: bounds
        )

        XCTAssertEqual(action, .movePinnedItem(before: notes))
    }

    func testRealPinnedDragRejectsInvalidReorderTargets() {
        let safari = mouseStateItem(owner: "Safari", pinOrder: 0)
        let unpinnedNotes = mouseStateItem(owner: "Notes", isPinned: false, pinOrder: nil)
        let secondSafariWindow = mouseStateItem(
            owner: "Safari",
            pinOrder: 0,
            title: "Second window",
            windowID: 2
        )
        let tiles = [
            (rect: firstRect, item: safari),
            (rect: secondRect, item: unpinnedNotes)
        ]

        XCTAssertEqual(resolveTaskbarMouseUpAction(
            pressedItem: safari,
            mouseDownPoint: NSPoint(x: 20, y: 15),
            mouseUpPoint: NSPoint(x: 250, y: 15),
            didDragPinnedItem: true,
            tileRects: tiles,
            bounds: bounds
        ), .none)
        XCTAssertEqual(resolveTaskbarMouseUpAction(
            pressedItem: safari,
            mouseDownPoint: NSPoint(x: 20, y: 15),
            mouseUpPoint: NSPoint(x: 110, y: 15),
            didDragPinnedItem: true,
            tileRects: tiles,
            bounds: bounds
        ), .none)
        XCTAssertEqual(resolveTaskbarMouseUpAction(
            pressedItem: safari,
            mouseDownPoint: NSPoint(x: 20, y: 15),
            mouseUpPoint: NSPoint(x: 110, y: 15),
            didDragPinnedItem: true,
            tileRects: [
                (rect: firstRect, item: safari),
                (rect: secondRect, item: secondSafariWindow)
            ],
            bounds: bounds
        ), .none)
    }

    func testFourPointPinnedMovementStartsDrag() {
        let item = mouseStateItem(owner: "Safari")

        let action = resolveTaskbarMouseUpAction(
            pressedItem: item,
            mouseDownPoint: NSPoint(x: 20, y: 15),
            mouseUpPoint: NSPoint(x: 24, y: 15),
            didDragPinnedItem: false,
            tileRects: [(rect: firstRect, item: item)],
            bounds: bounds
        )

        XCTAssertEqual(action, .none)
    }

    func testReleaseOverDifferentTileFromSameAppDoesNotActivatePressedWindow() {
        let firstWindow = mouseStateItem(
            owner: "Notes",
            isPinned: false,
            pinOrder: nil,
            title: "First",
            windowID: 1
        )
        let secondWindow = mouseStateItem(
            owner: "Notes",
            isPinned: false,
            pinOrder: nil,
            title: "Second",
            windowID: 2
        )

        let action = resolveTaskbarMouseUpAction(
            pressedItem: secondWindow,
            mouseDownPoint: NSPoint(x: 110, y: 15),
            mouseUpPoint: NSPoint(x: 20, y: 15),
            didDragPinnedItem: false,
            tileRects: [
                (rect: firstRect, item: firstWindow),
                (rect: secondRect, item: secondWindow)
            ],
            bounds: bounds
        )

        XCTAssertEqual(action, .none)
    }

    func testPinnedDragRemainsLatchedAfterPointerReturnsInsideThreshold() {
        XCTAssertTrue(updatedTaskbarPinnedDragState(
            wasDragging: true,
            mouseDownPoint: NSPoint(x: 20, y: 15),
            currentPoint: NSPoint(x: 21, y: 15)
        ))
    }

    func testEmptySpaceMouseDownClearsStaleItemPress() {
        let item = mouseStateItem(owner: "Safari")
        let view = mouseStateView(items: [item])
        var activatedItems: [TaskbarItem] = []
        view.onActivate = { activatedItems.append($0) }

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 15)))
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 500, y: 15)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 20, y: 15)))

        XCTAssertTrue(activatedItems.isEmpty)
    }

    func testViewTreatsOnePointPinnedWobbleAsActivation() {
        let item = mouseStateItem(owner: "Safari")
        let view = mouseStateView(items: [item])
        var activatedItems: [TaskbarItem] = []
        var moveCount = 0
        view.onActivate = { activatedItems.append($0) }
        view.onMovePinnedItem = { _, _ in moveCount += 1 }

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 15)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 21, y: 15)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 21, y: 15)))

        XCTAssertEqual(activatedItems, [item])
        XCTAssertEqual(moveCount, 0)
    }

    func testWidgetClickStillActivatesPressedWidget() {
        let view = TaskbarView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        var settings = TaskbarSettingValues.defaults
        settings.statsWidget.isEnabled = false
        view.update(items: [], settings: settings)
        var activatedWidgets: [TaskbarWidgetID] = []
        view.onWidgetActivate = { id, _, _, _ in activatedWidgets.append(id) }

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 550, y: 15)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 550, y: 15)))

        XCTAssertEqual(activatedWidgets, [.dateTime])
    }

    func testEmptySpaceMouseDownClearsStaleWidgetPress() {
        let view = TaskbarView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        var settings = TaskbarSettingValues.defaults
        settings.statsWidget.isEnabled = false
        view.update(items: [], settings: settings)
        var activatedWidgets: [TaskbarWidgetID] = []
        view.onWidgetActivate = { id, _, _, _ in activatedWidgets.append(id) }

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 550, y: 15)))
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 300, y: 15)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 550, y: 15)))

        XCTAssertTrue(activatedWidgets.isEmpty)
    }

    func testPointerHoverFindsTaskbarItemAcrossFullBarHeight() {
        let safari = mouseStateItem(owner: "Safari")
        let notes = mouseStateItem(owner: "Notes", pinOrder: 1)

        let target = taskbarHoverTarget(
            at: NSPoint(x: 110, y: 29),
            tileRects: [
                (rect: firstRect, item: safari),
                (rect: secondRect, item: notes)
            ],
            bounds: bounds
        )

        XCTAssertEqual(target, notes)
    }

    func testPointerHoverIgnoresEmptySpace() {
        let safari = mouseStateItem(owner: "Safari")

        XCTAssertNil(taskbarHoverTarget(
            at: NSPoint(x: 250, y: 15),
            tileRects: [(rect: firstRect, item: safari)],
            bounds: bounds
        ))
    }

    func testTaskbarClaimsTheNormalArrowCursor() {
        XCTAssertTrue(taskbarPointerCursor() === NSCursor.arrow)
    }

    func testPointerEntryImmediatelyHighlightsTheItemUnderTheCursor() {
        let view = mouseStateView(items: [mouseStateItem(owner: "Safari")])

        view.mouseEntered(with: trackingEvent(.mouseEntered, at: NSPoint(x: 20, y: 15)))

        XCTAssertNotNil(view.hoveredItemKey)
    }

    func testLayoutRefreshRecomputesHoverForAStationaryPointer() {
        let safari = mouseStateItem(owner: "Safari", pinOrder: 0)
        let notes = mouseStateItem(owner: "Notes", pinOrder: 1)
        let view = mouseStateView(items: [safari, notes])
        view.pointerLocationProvider = { NSPoint(x: 20, y: 15) }
        view.update(items: [safari, notes], settings: view.settings)
        let initialHoveredKey = view.hoveredItemKey

        view.update(items: [notes, safari], settings: view.settings)

        XCTAssertNotNil(initialHoveredKey)
        XCTAssertNotEqual(view.hoveredItemKey, initialHoveredKey)
    }

    func testBackgroundCursorPermissionTargetsTheMainWindowServerConnection() {
        var capturedSource: Int32?
        var capturedTarget: Int32?
        var capturedKey: String?
        var capturedValue: CFTypeRef?

        let result = enableTaskbarBackgroundCursorUpdates(
            mainConnectionID: { 42 },
            setConnectionProperty: { source, target, key, value in
                capturedSource = source
                capturedTarget = target
                capturedKey = key as String
                capturedValue = value
                return .success
            }
        )

        XCTAssertEqual(result, .success)
        XCTAssertEqual(capturedSource, 42)
        XCTAssertEqual(capturedTarget, 42)
        XCTAssertEqual(capturedKey, "SetsCursorInBackground")
        XCTAssertTrue(capturedValue === kCFBooleanTrue)
    }
}
