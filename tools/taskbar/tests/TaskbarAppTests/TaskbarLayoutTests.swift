import AppKit
import XCTest
@testable import TaskbarApp

private func layoutItem(
    index: Int,
    pid: pid_t? = nil,
    windowCount: Int = 1,
    isFrontmost: Bool = false,
    isPinned: Bool = false
) -> TaskbarItem {
    TaskbarItem(
        owner: "App \(index)",
        pid: pid,
        title: "Window \(index)",
        windowCount: windowCount,
        windowIDs: [index],
        windowBounds: nil,
        accessibilitySignature: "",
        isFrontmost: isFrontmost,
        isMinimized: false,
        bundleID: "com.example.app-\(index)",
        appPath: "/Applications/App \(index).app",
        isPinned: isPinned,
        pinOrder: isPinned ? index : nil
    )
}

private func layoutMouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
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

final class TaskbarLayoutTests: XCTestCase {
    func testClosedPinnedAppUsesIconOnlyWidthAndHidesItsLabel() {
        let item = layoutItem(index: 0, windowCount: 0, isPinned: true)
        let iconSize: CGFloat = 24

        XCTAssertFalse(taskbarItemShowsLabel(item))
        XCTAssertEqual(
            preferredTaskbarItemWidth(
                for: item,
                textWidth: 120,
                iconSize: iconSize,
                minimumWidth: 96,
                maximumWidth: 220
            ),
            TaskbarItemMetrics.iconOnlyWidth(iconSize: iconSize)
        )
    }

    func testRunningPinnedAppKeepsItsNormalLabelledWidth() {
        let item = layoutItem(index: 0, pid: 42, isPinned: true)
        let iconSize: CGFloat = 24

        XCTAssertTrue(taskbarItemShowsLabel(item))
        XCTAssertEqual(
            preferredTaskbarItemWidth(
                for: item,
                textWidth: 120,
                iconSize: iconSize,
                minimumWidth: 96,
                maximumWidth: 220
            ),
            TaskbarItemMetrics.naturalWidth(textWidth: 120, iconSize: iconSize)
        )
    }

    func testCrowdedWindowsHaveEqualWidthsDespiteDifferentTitleLengths() {
        var settings = TaskbarSettingValues.defaults
        settings.statsWidget.isEnabled = false
        settings.batteryWidget.isEnabled = false
        settings.dateTimeWidget.isEnabled = false
        let items = (0..<4).map { layoutItem(index: $0, pid: 42) }
        let layout = taskbarLayout(
            bounds: NSRect(x: 0, y: 0, width: 400, height: 32),
            items: items, settings: settings, tileHeight: 24,
            preferredTileWidths: [96, 220, 137, 220]
        )
        for tile in layout.tiles {
            XCTAssertEqual(tile.rect.width, layout.tiles[0].rect.width, accuracy: 0.001)
            XCTAssertGreaterThan(tile.rect.width, 60)
        }
    }

    func testSelectedWindowReservesLabelSpaceAndOtherWindowsShareTheRemainder() {
        var settings = TaskbarSettingValues.defaults
        settings.statsWidget.isEnabled = false
        settings.batteryWidget.isEnabled = false
        settings.dateTimeWidget.isEnabled = false
        let items = (0..<4).map { layoutItem(index: $0, pid: 42, isFrontmost: $0 == 0) }
        let layout = taskbarLayout(
            bounds: NSRect(x: 0, y: 0, width: 500, height: 32),
            items: items, settings: settings, tileHeight: 24,
            preferredTileWidths: [220, 220, 137, 220]
        )
        XCTAssertEqual(layout.tiles[0].rect.width, 220, accuracy: 0.001)
        for tile in layout.tiles.dropFirst() {
            XCTAssertEqual(tile.rect.width, layout.tiles[1].rect.width, accuracy: 0.001)
            XCTAssertLessThan(tile.rect.width, layout.tiles[0].rect.width)
        }
        XCTAssertLessThanOrEqual(layout.tiles.last!.rect.maxX, 500)
    }

    func testSelectedButtonFitsItsLabelUpToConfiguredMaximum() {
        let item = layoutItem(index: 0, pid: 42, isFrontmost: true)
        XCTAssertEqual(preferredTaskbarItemWidth(
            for: item, textWidth: 40, iconSize: 24,
            minimumWidth: 96, maximumWidth: 220
        ), 82)
        XCTAssertEqual(preferredTaskbarItemWidth(
            for: item, textWidth: 600, iconSize: 24,
            minimumWidth: 96, maximumWidth: 220
        ), 220)
    }

    func testCrowdedLayoutKeepsClosedPinsCompactAsSelectionMoves() {
        var settings = TaskbarSettingValues.defaults
        settings.statsWidget.isEnabled = false
        settings.batteryWidget.isEnabled = false
        settings.dateTimeWidget.isEnabled = false
        let pinWidth = TaskbarItemMetrics.iconOnlyWidth(iconSize: 20)
        for selected in 1...3 {
            let items = [layoutItem(index: 0, windowCount: 0, isPinned: true)]
                + (1...3).map { layoutItem(index: $0, pid: 42, isFrontmost: $0 == selected) }
            let layout = taskbarLayout(
                bounds: NSRect(x: 0, y: 0, width: 500, height: 32),
                items: items, settings: settings, tileHeight: 24,
                preferredTileWidths: [pinWidth, 220, 220, 220]
            )
            XCTAssertEqual(layout.tiles[0].rect.width, pinWidth, accuracy: 0.001)
            XCTAssertEqual(layout.tiles[selected].rect.width, 220, accuracy: 0.001)
            let others = (1...3).filter { $0 != selected }.map { layout.tiles[$0].rect.width }
            XCTAssertEqual(others[0], others[1], accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(others[0], pinWidth)
            XCTAssertLessThanOrEqual(layout.tiles.last!.rect.maxX, 500)
        }
    }

    func testSelectionCannotStarveOtherIconsOnExtremelyNarrowBar() {
        let widths = fittedTaskbarItemWidths(
            preferredWidths: [320, 220, 220], softMinimumWidth: 38,
            availableWidth: 60, selectedIndex: 0
        )
        XCTAssertEqual(widths, [20, 20, 20])
    }

    func testWidgetsNeverIntersectTilesAcrossLayoutMatrix() {
        var largestWidgets = TaskbarSettingValues.defaults
        largestWidgets.dateTimeWidget.dateDisplay = .always
        largestWidgets.dateTimeWidget.showSeconds = true
        let installedWidgets = activeTaskbarWidgets(for: largestWidgets)
        // Include every widget minimum, gaps, existing taskbar margins, and one
        // point of tile area so the smallest matrix case is still meaningful.
        let smallestBarWidth = ceil(
            installedWidgets.reduce(CGFloat(0)) {
                $0 + $1.minimumWidth(in: largestWidgets, height: 22)
            }
            + taskbarWidgetSpacing(widgetSpacing: largestWidgets.widgetSpacing) * CGFloat(max(0, installedWidgets.count - 1))
            + 27
        )
        let barWidths: [CGFloat] = [smallestBarWidth, max(600, smallestBarWidth), 900, 1_440]
        let itemCounts = [1, 3, 6, 12]
        let itemSpacings: [Double] = [0, 3, 24]
        let widgetStates = [
            (name: "all", statsEnabled: true, batteryEnabled: true, dateEnabled: true),
            (name: "stats-battery", statsEnabled: true, batteryEnabled: true, dateEnabled: false),
            (name: "stats-date", statsEnabled: true, batteryEnabled: false, dateEnabled: true),
            (name: "battery-date", statsEnabled: false, batteryEnabled: true, dateEnabled: true),
            (name: "stats", statsEnabled: true, batteryEnabled: false, dateEnabled: false),
            (name: "battery", statsEnabled: false, batteryEnabled: true, dateEnabled: false),
            (name: "date", statsEnabled: false, batteryEnabled: false, dateEnabled: true),
            (name: "none", statsEnabled: false, batteryEnabled: false, dateEnabled: false)
        ]

        for barWidth in barWidths {
            for itemCount in itemCounts {
                let items = (0..<itemCount).map { layoutItem(index: $0) }
                for widgetState in widgetStates {
                    for showSeconds in [false, true] {
                        for dateDisplay in DateTimeDateDisplay.allCases {
                            for itemSpacing in itemSpacings {
                                var settings = TaskbarSettingValues.defaults
                                settings.statsWidget.isEnabled = widgetState.statsEnabled
                                settings.batteryWidget.isEnabled = widgetState.batteryEnabled
                                settings.dateTimeWidget.isEnabled = widgetState.dateEnabled
                                settings.dateTimeWidget.showSeconds = showSeconds
                                settings.dateTimeWidget.dateDisplay = dateDisplay
                                settings.itemSpacing = itemSpacing
                                let layout = taskbarLayout(
                                    bounds: NSRect(x: 0, y: 0, width: barWidth, height: 30),
                                    items: items,
                                    settings: settings,
                                    tileHeight: 22,
                                    preferredTileWidths: Array(repeating: 120, count: itemCount)
                                )
                                let context = "width=\(barWidth), items=\(itemCount), widgets=\(widgetState.name), seconds=\(showSeconds), date=\(dateDisplay), spacing=\(itemSpacing)"
                                let expectedWidgets = activeTaskbarWidgets(for: settings)

                                XCTAssertEqual(
                                    layout.widgets.map { $0.id },
                                    expectedWidgets.map { $0.id },
                                    context
                                )
                                for (widgetRect, widget) in zip(layout.widgets, expectedWidgets) {
                                    XCTAssertGreaterThanOrEqual(
                                        widgetRect.rect.width,
                                        widget.minimumWidth(in: settings, height: 22),
                                        context
                                    )
                                }
                                for (leftWidget, rightWidget) in zip(layout.widgets, layout.widgets.dropFirst()) {
                                    XCTAssertGreaterThanOrEqual(
                                        rightWidget.rect.minX - leftWidget.rect.maxX,
                                        taskbarWidgetSpacing(widgetSpacing: CGFloat(settings.widgetSpacing)),
                                        context
                                    )
                                }

                                for tile in layout.tiles {
                                    XCTAssertGreaterThan(tile.rect.width, 0, context)
                                    for widget in layout.widgets {
                                        XCTAssertFalse(
                                            tile.rect.intersects(widget.rect),
                                            "\(context), tile=\(tile.rect), widget=\(widget.id):\(widget.rect)"
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testClickInFormerWidgetOverlapActivatesTrailingTile() throws {
        let trailingItem = layoutItem(index: 2, isFrontmost: true)
        let items = [layoutItem(index: 0), layoutItem(index: 1), trailingItem]
        let view = TaskbarView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        view.update(items: items, settings: .defaults)
        let trailingTile = try XCTUnwrap(view.frontmostTileLayout()?.rect)
        let formerOverlapPoint = NSPoint(x: trailingTile.maxX - 10, y: trailingTile.midY)
        var activatedItems: [TaskbarItem] = []
        var activatedWidgets: [TaskbarWidgetID] = []
        view.onActivate = { activatedItems.append($0) }
        view.onWidgetActivate = { id, _, _, _ in activatedWidgets.append(id) }

        view.mouseDown(with: layoutMouseEvent(.leftMouseDown, at: formerOverlapPoint))
        view.mouseUp(with: layoutMouseEvent(.leftMouseUp, at: formerOverlapPoint))

        XCTAssertEqual(activatedItems, [trailingItem])
        XCTAssertTrue(activatedWidgets.isEmpty)
    }

    func testFrontmostTileUsesLatestCachedLayoutWithoutRemeasuringTitles() throws {
        let view = TaskbarView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        var measurementCount = 0
        view.onMeasurePreferredTileWidth = { measurementCount += 1 }
        let firstFrontmost = layoutItem(index: 1, isFrontmost: true)

        view.update(items: [layoutItem(index: 0), firstFrontmost], settings: .defaults)

        XCTAssertEqual(measurementCount, 2)
        XCTAssertEqual(try XCTUnwrap(view.frontmostTileLayout()?.item), firstFrontmost)
        XCTAssertEqual(measurementCount, 2)

        let latestFrontmost = layoutItem(index: 2, isFrontmost: true)
        view.update(items: [layoutItem(index: 1), latestFrontmost], settings: .defaults)

        XCTAssertEqual(measurementCount, 4)
        XCTAssertEqual(try XCTUnwrap(view.frontmostTileLayout()?.item), latestFrontmost)
        XCTAssertEqual(measurementCount, 4)
    }

    func testConditionalDateUsesOnlySpaceLeftAfterOtherWidgetMinimums() throws {
        let items = (0..<3).map { layoutItem(index: $0) }
        let settings = TaskbarSettingValues.defaults
        let layout = taskbarLayout(
            bounds: NSRect(x: 0, y: 0, width: 600, height: 30),
            items: items,
            settings: settings,
            tileHeight: 22,
            preferredTileWidths: Array(repeating: 120, count: items.count)
        )
        let dateRect = try XCTUnwrap(layout.widgets.first { $0.id == .dateTime }?.rect)

        XCTAssertEqual(
            dateRect.width,
            DateTimeWidgetMetrics.compactWidth(
                for: settings.dateTimeWidget,
                fontSize: DateTimeWidgetMetrics.fontSize(forHeight: 22)
            )
        )
    }

    func testWidgetsReachPreferredWidthsWhenTilesLeaveGenuineFreeSpace() throws {
        let items = [layoutItem(index: 0)]
        let settings = TaskbarSettingValues.defaults
        let layout = taskbarLayout(
            bounds: NSRect(x: 0, y: 0, width: 1_200, height: 30),
            items: items,
            settings: settings,
            tileHeight: 22,
            preferredTileWidths: [120]
        )
        let statsRect = try XCTUnwrap(layout.widgets.first { $0.id == .stats }?.rect)
        let dateRect = try XCTUnwrap(layout.widgets.first { $0.id == .dateTime }?.rect)

        XCTAssertEqual(statsRect.width, StatsWidgetMetrics.preferredWidth(for: .defaults))
        XCTAssertEqual(
            dateRect.width,
            DateTimeWidgetMetrics.expandedWidth(
                for: settings.dateTimeWidget,
                fontSize: DateTimeWidgetMetrics.fontSize(forHeight: 22)
            )
        )
    }

    func testWidgetSpacingIsIndependentFromAppItemSpacing() throws {
        var settings = TaskbarSettingValues.defaults
        settings.statsWidget.isEnabled = false
        settings.controlCenterLightsWidget.isEnabled = false
        settings.itemSpacing = 24
        settings.widgetSpacing = 7
        let layout = taskbarLayout(
            bounds: NSRect(x: 0, y: 0, width: 600, height: 30),
            items: [],
            settings: settings,
            tileHeight: 22,
            preferredTileWidths: []
        )
        let battery = try XCTUnwrap(layout.widgets.first { $0.id == .battery }?.rect)
        let date = try XCTUnwrap(layout.widgets.first { $0.id == .dateTime }?.rect)

        XCTAssertEqual(date.minX - battery.maxX, 7, accuracy: 0.001)
    }

    func testNoWidgetLayoutKeepsExistingTrailingPadding() throws {
        var settings = TaskbarSettingValues.defaults
        settings.statsWidget.isEnabled = false
        settings.batteryWidget.isEnabled = false
        settings.controlCenterLightsWidget.isEnabled = false
        settings.dateTimeWidget.isEnabled = false
        let layout = taskbarLayout(
            bounds: NSRect(x: 0, y: 0, width: 600, height: 30),
            items: [layoutItem(index: 0)],
            settings: settings,
            tileHeight: 22,
            preferredTileWidths: [1_000]
        )

        XCTAssertEqual(try XCTUnwrap(layout.tiles.first?.rect.maxX), 584)
        XCTAssertTrue(layout.widgets.isEmpty)
    }
}
