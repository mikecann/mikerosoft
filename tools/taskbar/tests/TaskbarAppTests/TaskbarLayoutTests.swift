import AppKit
import XCTest
@testable import TaskbarApp

private func layoutItem(index: Int, isFrontmost: Bool = false) -> TaskbarItem {
    TaskbarItem(
        owner: "App \(index)",
        pid: nil,
        title: "Window \(index)",
        windowCount: 1,
        windowIDs: [index],
        windowBounds: nil,
        accessibilitySignature: "",
        isFrontmost: isFrontmost,
        isMinimized: false,
        bundleID: "com.example.app-\(index)",
        appPath: "/Applications/App \(index).app",
        isPinned: false,
        pinOrder: nil
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
    func testWidgetsNeverIntersectTilesAcrossLayoutMatrix() {
        // 397 pt is the smallest width that can hold the largest configured
        // widget minima, the existing margins, and one point of tile area.
        let barWidths: [CGFloat] = [397, 480, 600, 900, 1_440]
        let itemCounts = [1, 3, 6, 12]
        let itemSpacings: [Double] = [0, 3, 24]
        let widgetStates = [
            (name: "both", statsEnabled: true, dateEnabled: true),
            (name: "stats", statsEnabled: true, dateEnabled: false),
            (name: "date", statsEnabled: false, dateEnabled: true),
            (name: "none", statsEnabled: false, dateEnabled: false)
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
                                        taskbarWidgetSpacing(itemSpacing: CGFloat(settings.itemSpacing)),
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

    func testConditionalDateUsesOnlySpaceLeftAfterOtherWidgetMinimums() throws {
        let items = (0..<3).map { layoutItem(index: $0) }
        let layout = taskbarLayout(
            bounds: NSRect(x: 0, y: 0, width: 600, height: 30),
            items: items,
            settings: .defaults,
            tileHeight: 22,
            preferredTileWidths: Array(repeating: 120, count: items.count)
        )
        let dateRect = try XCTUnwrap(layout.widgets.first { $0.id == .dateTime }?.rect)

        XCTAssertEqual(dateRect.width, DateTimeWidgetMetrics.compactWidth)
    }

    func testWidgetsReachPreferredWidthsWhenTilesLeaveGenuineFreeSpace() throws {
        let items = [layoutItem(index: 0)]
        let layout = taskbarLayout(
            bounds: NSRect(x: 0, y: 0, width: 1_200, height: 30),
            items: items,
            settings: .defaults,
            tileHeight: 22,
            preferredTileWidths: [120]
        )
        let statsRect = try XCTUnwrap(layout.widgets.first { $0.id == .stats }?.rect)
        let dateRect = try XCTUnwrap(layout.widgets.first { $0.id == .dateTime }?.rect)

        XCTAssertEqual(statsRect.width, StatsWidgetMetrics.preferredWidth(for: .defaults))
        XCTAssertEqual(dateRect.width, DateTimeWidgetMetrics.expandedWidth)
    }

    func testNoWidgetLayoutKeepsExistingTrailingPadding() throws {
        var settings = TaskbarSettingValues.defaults
        settings.statsWidget.isEnabled = false
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
