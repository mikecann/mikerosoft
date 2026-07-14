import AppKit
import XCTest
@testable import TaskbarApp

final class TaskbarSettingsTests: XCTestCase {
    func values(
        isVisible: Bool = true,
        groupByApp: Bool = true,
        clockMode: ClockMode = .time,
        dateTimeWidget: DateTimeWidgetSettings? = nil,
        statsWidget: StatsWidgetSettings? = nil,
        showWindowCounts: Bool = true,
        taskbarHeight: Double = 54,
        minimumItemWidth: Double = 96,
        maximumItemWidth: Double = 220,
        itemSpacing: Double = 3,
        backgroundOpacity: Double = 0.72,
        avoidOverlappingWindows: Bool = true,
        autoHide: Bool = false,
        revealAnimation: RevealAnimation = .ease,
        revealAnimationDuration: Double = 0.18,
        pinnedApps: [PinnedApp] = []
    ) -> TaskbarSettingValues {
        TaskbarSettingValues(
            isVisible: isVisible,
            groupByApp: groupByApp,
            clockMode: clockMode,
            dateTimeWidget: dateTimeWidget,
            statsWidget: statsWidget,
            showWindowCounts: showWindowCounts,
            taskbarHeight: taskbarHeight,
            minimumItemWidth: minimumItemWidth,
            maximumItemWidth: maximumItemWidth,
            itemSpacing: itemSpacing,
            backgroundOpacity: backgroundOpacity,
            avoidOverlappingWindows: avoidOverlappingWindows,
            autoHide: autoHide,
            revealAnimation: revealAnimation,
            revealAnimationDuration: revealAnimationDuration,
            pinnedApps: pinnedApps
        )
    }

    func testMonitorOverrideOnlyReplacesSpecifiedFields() {
        var preferences = TaskbarPreferences(
            general: values(
                pinnedApps: [
                    PinnedApp(displayName: "Finder", bundleID: "com.apple.finder", appPath: "/System/Library/CoreServices/Finder.app")
                ]
            ),
            monitorOverrides: [:]
        )

        preferences.monitorOverrides["123"] = TaskbarMonitorOverrides(
            isVisible: false,
            groupByApp: false,
            dateTimeWidget: DateTimeWidgetSettings(
                isEnabled: true,
                dateDisplay: .always,
                showDayOfWeek: true,
                showSeconds: true,
                use24HourClock: false
            ),
            statsWidget: StatsWidgetSettings(
                isEnabled: true,
                showCPU: false,
                showMemory: true,
                showNetwork: false,
                showMiniGraph: false
            ),
            showWindowCounts: false,
            taskbarHeight: 72,
            minimumItemWidth: 120,
            maximumItemWidth: 260,
            itemSpacing: 12,
            backgroundOpacity: 0.5,
            avoidOverlappingWindows: false,
            autoHide: true,
            revealAnimation: .linear,
            revealAnimationDuration: 0.4,
            pinnedApps: [
                PinnedApp(displayName: "Safari", bundleID: "com.apple.Safari", appPath: "/Applications/Safari.app")
            ]
        )

        let resolved = preferences.resolvedValues(for: 123)

        XCTAssertEqual(resolved.isVisible, false)
        XCTAssertEqual(resolved.groupByApp, false)
        XCTAssertEqual(resolved.dateTimeWidget.dateDisplay, .always)
        XCTAssertTrue(resolved.dateTimeWidget.showSeconds)
        XCTAssertFalse(resolved.dateTimeWidget.use24HourClock)
        XCTAssertFalse(resolved.statsWidget.showCPU)
        XCTAssertTrue(resolved.statsWidget.showMemory)
        XCTAssertFalse(resolved.statsWidget.showNetwork)
        XCTAssertFalse(resolved.statsWidget.showMiniGraph)
        XCTAssertEqual(resolved.showWindowCounts, false)
        XCTAssertEqual(resolved.taskbarHeight, 72)
        XCTAssertEqual(resolved.minimumItemWidth, 120)
        XCTAssertEqual(resolved.maximumItemWidth, 260)
        XCTAssertEqual(resolved.itemSpacing, 12)
        XCTAssertEqual(resolved.backgroundOpacity, 0.5)
        XCTAssertEqual(resolved.avoidOverlappingWindows, false)
        XCTAssertEqual(resolved.autoHide, true)
        XCTAssertEqual(resolved.revealAnimation, .linear)
        XCTAssertEqual(resolved.revealAnimationDuration, 0.4)
        XCTAssertEqual(resolved.pinnedApps.map(\.displayName), ["Safari"])
    }

    func testMonitorWithoutOverrideUsesGeneralValues() {
        let preferences = TaskbarPreferences(
            general: values(
                groupByApp: false,
                clockMode: .hidden,
                taskbarHeight: 60,
                minimumItemWidth: 110,
                maximumItemWidth: 240,
                itemSpacing: 9,
                backgroundOpacity: 0.6,
                avoidOverlappingWindows: false,
                autoHide: true,
                revealAnimation: .instant,
                revealAnimationDuration: 0.05,
                pinnedApps: [
                    PinnedApp(displayName: "Finder", bundleID: "com.apple.finder", appPath: "/System/Library/CoreServices/Finder.app")
                ]
            ),
            monitorOverrides: [:]
        )

        let resolved = preferences.resolvedValues(for: 999)

        XCTAssertEqual(resolved.isVisible, true)
        XCTAssertEqual(resolved.groupByApp, false)
        XCTAssertEqual(resolved.clockMode, .hidden)
        XCTAssertEqual(resolved.statsWidget, .defaults)
        XCTAssertEqual(resolved.showWindowCounts, true)
        XCTAssertEqual(resolved.taskbarHeight, 60)
        XCTAssertEqual(resolved.minimumItemWidth, 110)
        XCTAssertEqual(resolved.maximumItemWidth, 240)
        XCTAssertEqual(resolved.itemSpacing, 9)
        XCTAssertEqual(resolved.backgroundOpacity, 0.6)
        XCTAssertEqual(resolved.avoidOverlappingWindows, false)
        XCTAssertEqual(resolved.autoHide, true)
        XCTAssertEqual(resolved.revealAnimation, .instant)
        XCTAssertEqual(resolved.revealAnimationDuration, 0.05)
        XCTAssertEqual(resolved.pinnedApps.map(\.displayName), ["Finder"])
    }

    func testTaskbarHeightIsClampedToUsefulRange() {
        XCTAssertEqual(TaskbarSettingValues.clampedTaskbarHeight(12), 24)
        XCTAssertEqual(TaskbarSettingValues.clampedTaskbarHeight(120), 96)
        XCTAssertEqual(TaskbarSettingValues.clampedTaskbarHeight(64), 64)
        XCTAssertEqual(TaskbarSettingValues.clampedItemSpacing(-3), 0)
        XCTAssertEqual(TaskbarSettingValues.clampedItemSpacing(12), 12)
        XCTAssertEqual(TaskbarSettingValues.clampedItemSpacing(30), 24)
    }

    func testVisualSettingsAreClampedToUsefulRanges() {
        var values = values(
            minimumItemWidth: 10,
            maximumItemWidth: 20,
            itemSpacing: 50,
            backgroundOpacity: 2,
            revealAnimationDuration: 5
        )

        values.clamp()

        XCTAssertEqual(values.minimumItemWidth, 56)
        XCTAssertEqual(values.maximumItemWidth, 56)
        XCTAssertEqual(values.itemSpacing, 24)
        XCTAssertEqual(values.backgroundOpacity, 1)
        XCTAssertEqual(values.revealAnimationDuration, 1)
    }

    func testTaskbarItemWidthUsesMinimumAndMaximum() {
        XCTAssertEqual(taskbarItemWidth(textWidth: 5, iconSize: 20, minimumWidth: 120, maximumWidth: 240), 120)
        XCTAssertEqual(taskbarItemWidth(textWidth: 400, iconSize: 20, minimumWidth: 120, maximumWidth: 240), 240)
    }

    func testTaskbarItemWidthUsesCompactContentInsets() {
        XCTAssertEqual(taskbarItemWidth(textWidth: 50, iconSize: 20, minimumWidth: 40, maximumWidth: 240), 88)
    }

    func testTaskbarItemWidthsShrinkToFitAvailableSpace() {
        let widths = fittedTaskbarItemWidths(
            preferredWidths: [120, 120, 120],
            softMinimumWidth: 40,
            availableWidth: 240
        )

        XCTAssertEqual(widths.count, 3)
        XCTAssertEqual(widths.reduce(0, +), 240, accuracy: 0.001)
        XCTAssertEqual(widths, [80, 80, 80])
    }

    func testTaskbarItemWidthsCanShrinkBelowSoftMinimumWhenCrowded() {
        let widths = fittedTaskbarItemWidths(
            preferredWidths: [120, 120, 120, 120],
            softMinimumWidth: 40,
            availableWidth: 80
        )

        XCTAssertEqual(widths.count, 4)
        XCTAssertEqual(widths.reduce(0, +), 80, accuracy: 0.001)
        XCTAssertEqual(widths, [20, 20, 20, 20])
    }

    func testPinnedAppsCanMoveBeforeAnotherPinnedApp() {
        let apps = [
            PinnedApp(displayName: "Finder", bundleID: "com.apple.finder", appPath: "/System/Library/CoreServices/Finder.app"),
            PinnedApp(displayName: "Safari", bundleID: "com.apple.Safari", appPath: "/Applications/Safari.app"),
            PinnedApp(displayName: "Notes", bundleID: "com.apple.Notes", appPath: "/System/Applications/Notes.app")
        ]

        let moved = movedPinnedApps(apps, movingIdentity: apps[2].identity, beforeIdentity: apps[0].identity)

        XCTAssertEqual(moved.map(\.displayName), ["Notes", "Finder", "Safari"])
    }

    func testStartAtLoginDefaultsTrueWhenMissingFromSavedPreferences() throws {
        let data = """
        {
          "general": {
            "isVisible": true,
            "groupByApp": true,
            "clockMode": "time",
            "showWindowCounts": true,
            "taskbarHeight": 54,
            "pinnedApps": []
          },
          "monitorOverrides": {}
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(TaskbarPreferences.self, from: data)

        XCTAssertTrue(preferences.startAtLogin)
    }

    func testLegacyShowClockMigratesToClockMode() throws {
        let data = """
        {
          "isVisible": true,
          "groupByApp": true,
          "showClock": false,
          "showWindowCounts": true,
          "taskbarHeight": 54,
          "pinnedApps": []
        }
        """.data(using: .utf8)!

        let values = try JSONDecoder().decode(TaskbarSettingValues.self, from: data)

        XCTAssertEqual(values.clockMode, .hidden)
        XCTAssertFalse(values.dateTimeWidget.isEnabled)
    }

    func testLegacyClockModeMigratesToDateTimeWidget() throws {
        let data = """
        {
          "isVisible": true,
          "groupByApp": true,
          "clockMode": "dateAndTime",
          "showWindowCounts": true,
          "taskbarHeight": 54,
          "pinnedApps": []
        }
        """.data(using: .utf8)!

        let values = try JSONDecoder().decode(TaskbarSettingValues.self, from: data)

        XCTAssertTrue(values.dateTimeWidget.isEnabled)
        XCTAssertEqual(values.dateTimeWidget.dateDisplay, .always)
        XCTAssertEqual(values.clockMode, .dateAndTime)
    }

    func testDateTimeWidgetOverrideReplacesGeneralSettings() {
        let generalDateTime = DateTimeWidgetSettings(
            isEnabled: true,
            dateDisplay: .never,
            showDayOfWeek: false,
            showSeconds: false,
            use24HourClock: true
        )
        let monitorDateTime = DateTimeWidgetSettings(
            isEnabled: true,
            dateDisplay: .always,
            showDayOfWeek: true,
            showSeconds: true,
            use24HourClock: false
        )
        let preferences = TaskbarPreferences(
            general: values(dateTimeWidget: generalDateTime),
            monitorOverrides: [
                "123": TaskbarMonitorOverrides(dateTimeWidget: monitorDateTime)
            ]
        )

        let resolved = preferences.resolvedValues(for: 123)

        XCTAssertEqual(resolved.dateTimeWidget, monitorDateTime)
        XCTAssertEqual(resolved.clockMode, .dateAndTime)
    }

    func testStatsWidgetOverrideReplacesGeneralSettings() {
        let generalStats = StatsWidgetSettings(
            isEnabled: true,
            showCPU: true,
            showMemory: true,
            showNetwork: true,
            showMiniGraph: true
        )
        let monitorStats = StatsWidgetSettings(
            isEnabled: false,
            showCPU: false,
            showMemory: true,
            showNetwork: false,
            showMiniGraph: false
        )
        let preferences = TaskbarPreferences(
            general: values(statsWidget: generalStats),
            monitorOverrides: [
                "123": TaskbarMonitorOverrides(statsWidget: monitorStats)
            ]
        )

        let resolved = preferences.resolvedValues(for: 123)

        XCTAssertEqual(resolved.statsWidget, monitorStats)
    }

    func testDateTimeWidgetEncodingDoesNotWriteLegacyClockKeys() throws {
        let values = TaskbarSettingValues(
            isVisible: true,
            groupByApp: true,
            clockMode: .dateAndTime,
            dateTimeWidget: DateTimeWidgetSettings(
                isEnabled: true,
                dateDisplay: .always,
                showDayOfWeek: true,
                showSeconds: true,
                use24HourClock: false
            ),
            statsWidget: StatsWidgetSettings(
                isEnabled: true,
                showCPU: true,
                showMemory: false,
                showNetwork: true,
                showMiniGraph: true
            ),
            showWindowCounts: true,
            taskbarHeight: 54,
            minimumItemWidth: 96,
            maximumItemWidth: 220,
            itemSpacing: 3,
            backgroundOpacity: 0.72,
            avoidOverlappingWindows: true,
            autoHide: false,
            revealAnimation: .ease,
            revealAnimationDuration: 0.18,
            pinnedApps: []
        )

        let data = try JSONEncoder().encode(values)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dateTimeWidget = object?["dateTimeWidget"] as? [String: Any]
        let statsWidget = object?["statsWidget"] as? [String: Any]

        XCTAssertNil(object?["clockMode"])
        XCTAssertEqual(dateTimeWidget?["dateDisplay"] as? String, "always")
        XCTAssertEqual(dateTimeWidget?["showSeconds"] as? Bool, true)
        XCTAssertEqual(dateTimeWidget?["use24HourClock"] as? Bool, false)
        XCTAssertEqual(statsWidget?["showMemory"] as? Bool, false)
        XCTAssertEqual(statsWidget?["showNetwork"] as? Bool, true)
        XCTAssertNil(object?["backgroundStyle"])
        XCTAssertNil(object?["glassAmount"])
        XCTAssertNil(object?["showClock"])
    }

    func testDateTimeWidgetFormatsMenuBarLikeTime() {
        let date = Date(timeIntervalSince1970: 0)
        let settings = DateTimeWidgetSettings(
            isEnabled: true,
            dateDisplay: .never,
            showDayOfWeek: true,
            showSeconds: false,
            use24HourClock: true
        )

        let text = dateTimeWidgetText(
            settings: settings,
            date: date,
            availableWidth: 80,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(text, "00:00")
    }

    func testDateTimeWidgetCanShowDateWhenSpaceAllows() {
        let date = Date(timeIntervalSince1970: 0)
        let settings = DateTimeWidgetSettings(
            isEnabled: true,
            dateDisplay: .whenSpaceAllows,
            showDayOfWeek: true,
            showSeconds: false,
            use24HourClock: true
        )

        let compact = dateTimeWidgetText(
            settings: settings,
            date: date,
            availableWidth: 58,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let expanded = dateTimeWidgetText(
            settings: settings,
            date: date,
            availableWidth: 128,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(compact, "00:00")
        XCTAssertEqual(expanded, "Thu Jan 1 00:00")
    }

    func testStatsWidgetFormatsPercentAndNetworkRates() {
        XCTAssertEqual(formattedStatsPercent(36.4), "36%")
        XCTAssertEqual(formattedStatsPercent(-12), "0%")
        XCTAssertEqual(formattedStatsPercent(122), "100%")
        XCTAssertEqual(formattedStatsBytesPerSecond(512), "512 B/s")
        XCTAssertEqual(formattedStatsBytesPerSecond(20_480), "20 KB/s")
        XCTAssertEqual(formattedStatsBytesPerSecond(1_572_864), "1.5 MB/s")
    }

    func testStatsWidgetModuleRectsFollowEnabledMetrics() {
        let settings = StatsWidgetSettings(
            isEnabled: true,
            showCPU: true,
            showMemory: false,
            showNetwork: true,
            showMiniGraph: true
        )

        let rects = statsWidgetModuleRects(settings: settings, in: NSRect(x: 0, y: 0, width: 180, height: 42))

        XCTAssertEqual(rects.map(\.0), [.cpu, .network])
        XCTAssertEqual(rects.count, 2)
        XCTAssertGreaterThan(rects[0].1.width, 40)
        XCTAssertGreaterThan(rects[1].1.minX, rects[0].1.maxX)
    }

    func testInstalledWidgetsIncludeStatsBeforeDateTime() {
        XCTAssertEqual(installedTaskbarWidgetIDs(), [.stats, .dateTime])
    }

    func testSettingsSidebarSeparatesWidgetPagesFromBarPages() {
        let first = ScreenInfo(
            id: 1,
            name: "LG Monitor",
            appKitFrame: .zero,
            quartzFrame: .zero
        )
        let second = ScreenInfo(
            id: 2,
            name: "Built-in Display",
            appKitFrame: .zero,
            quartzFrame: .zero
        )

        let items = taskbarSettingsSidebarItems(
            screens: [first, second],
            widgets: [.dateTime]
        )

        XCTAssertEqual(items, [
            .general,
            .widgets,
            .widget(.dateTime),
            .divider("Per Monitor"),
            .monitor(first),
            .monitorWidget(first, .dateTime),
            .monitor(second),
            .monitorWidget(second, .dateTime)
        ])
        XCTAssertEqual(items.map(\.title), [
            "General",
            "Widgets",
            "Date & Time",
            "Per Monitor",
            "LG Monitor",
            "Date & Time",
            "Built-in Display",
            "Date & Time"
        ])
        XCTAssertEqual(items.map(\.indentLevel), [0, 0, 1, 0, 0, 1, 0, 1])
        XCTAssertEqual(items.map(\.isSelectable), [true, true, true, false, true, true, true, true])
    }
}
