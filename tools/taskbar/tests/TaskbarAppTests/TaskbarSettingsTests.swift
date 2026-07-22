import AppKit
import XCTest
@testable import TaskbarApp

final class TaskbarSettingsTests: XCTestCase {
    func values(
        isVisible: Bool = true,
        clockMode: ClockMode = .time,
        dateTimeWidget: DateTimeWidgetSettings? = nil,
        statsWidget: StatsWidgetSettings? = nil,
        taskbarHeight: Double = 54,
        minimumItemWidth: Double = 96,
        maximumItemWidth: Double = 220,
        itemSpacing: Double = 3,
        widgetSpacing: Double = 0,
        backgroundOpacity: Double = 0.72,
        avoidOverlappingWindows: Bool = true,
        showMinimizedWindows: Bool = true,
        autoHide: Bool = false,
        revealAnimation: RevealAnimation = .ease,
        revealAnimationDuration: Double = 0.18,
        pinnedApps: [PinnedApp] = []
    ) -> TaskbarSettingValues {
        TaskbarSettingValues(
            isVisible: isVisible,
            clockMode: clockMode,
            dateTimeWidget: dateTimeWidget,
            statsWidget: statsWidget,
            taskbarHeight: taskbarHeight,
            minimumItemWidth: minimumItemWidth,
            maximumItemWidth: maximumItemWidth,
            itemSpacing: itemSpacing,
            widgetSpacing: widgetSpacing,
            backgroundOpacity: backgroundOpacity,
            avoidOverlappingWindows: avoidOverlappingWindows,
            showMinimizedWindows: showMinimizedWindows,
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
                showGPU: false,
                showMemory: true,
                showNetwork: false,
                showMiniGraph: false
            ),
            taskbarHeight: 72,
            minimumItemWidth: 120,
            maximumItemWidth: 260,
            itemSpacing: 12,
            widgetSpacing: 6,
            backgroundOpacity: 0.5,
            avoidOverlappingWindows: false,
            showMinimizedWindows: false,
            autoHide: true,
            revealAnimation: .linear,
            revealAnimationDuration: 0.4,
            pinnedApps: [
                PinnedApp(displayName: "Safari", bundleID: "com.apple.Safari", appPath: "/Applications/Safari.app")
            ]
        )

        let resolved = preferences.resolvedValues(for: 123)

        XCTAssertEqual(resolved.isVisible, false)
        XCTAssertEqual(resolved.dateTimeWidget.dateDisplay, .always)
        XCTAssertTrue(resolved.dateTimeWidget.showSeconds)
        XCTAssertFalse(resolved.dateTimeWidget.use24HourClock)
        XCTAssertFalse(resolved.statsWidget.showCPU)
        XCTAssertFalse(resolved.statsWidget.showGPU)
        XCTAssertTrue(resolved.statsWidget.showMemory)
        XCTAssertFalse(resolved.statsWidget.showNetwork)
        XCTAssertFalse(resolved.statsWidget.showMiniGraph)
        XCTAssertEqual(resolved.taskbarHeight, 72)
        XCTAssertEqual(resolved.minimumItemWidth, 120)
        XCTAssertEqual(resolved.maximumItemWidth, 260)
        XCTAssertEqual(resolved.itemSpacing, 12)
        XCTAssertEqual(resolved.widgetSpacing, 6)
        XCTAssertEqual(resolved.backgroundOpacity, 0.5)
        XCTAssertEqual(resolved.avoidOverlappingWindows, false)
        XCTAssertEqual(resolved.showMinimizedWindows, false)
        XCTAssertEqual(resolved.autoHide, true)
        XCTAssertEqual(resolved.revealAnimation, .linear)
        XCTAssertEqual(resolved.revealAnimationDuration, 0.4)
        XCTAssertEqual(resolved.pinnedApps.map(\.displayName), ["Safari"])
    }

    func testMonitorWithoutOverrideUsesGeneralValues() {
        let preferences = TaskbarPreferences(
            general: values(
                clockMode: .hidden,
                taskbarHeight: 60,
                minimumItemWidth: 110,
                maximumItemWidth: 240,
                itemSpacing: 9,
                widgetSpacing: 7,
                backgroundOpacity: 0.6,
                avoidOverlappingWindows: false,
                showMinimizedWindows: false,
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
        XCTAssertEqual(resolved.clockMode, .hidden)
        XCTAssertEqual(resolved.statsWidget, .defaults)
        XCTAssertEqual(resolved.taskbarHeight, 60)
        XCTAssertEqual(resolved.minimumItemWidth, 110)
        XCTAssertEqual(resolved.maximumItemWidth, 240)
        XCTAssertEqual(resolved.itemSpacing, 9)
        XCTAssertEqual(resolved.widgetSpacing, 7)
        XCTAssertEqual(resolved.backgroundOpacity, 0.6)
        XCTAssertEqual(resolved.avoidOverlappingWindows, false)
        XCTAssertEqual(resolved.showMinimizedWindows, false)
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
        XCTAssertEqual(TaskbarSettingValues.clampedWidgetSpacing(-3), 0)
        XCTAssertEqual(TaskbarSettingValues.clampedWidgetSpacing(12), 12)
        XCTAssertEqual(TaskbarSettingValues.clampedWidgetSpacing(30), 24)
    }

    func testVisualSettingsAreClampedToUsefulRanges() {
        var values = values(
            minimumItemWidth: 10,
            maximumItemWidth: 20,
            itemSpacing: 50,
            widgetSpacing: 50,
            backgroundOpacity: 2,
            revealAnimationDuration: 5
        )

        values.clamp()

        XCTAssertEqual(values.minimumItemWidth, 56)
        XCTAssertEqual(values.maximumItemWidth, 56)
        XCTAssertEqual(values.itemSpacing, 24)
        XCTAssertEqual(values.widgetSpacing, 24)
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

    func testRemovedGroupingAndWindowCountKeysAreDecodeToleratedButNotReencoded() throws {
        let data = """
        {
          "general": {
            "isVisible": true,
            "groupByApp": false,
            "showWindowCounts": false
          },
          "monitorOverrides": {
            "123": {
              "groupByApp": true,
              "showWindowCounts": true
            }
          }
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(TaskbarPreferences.self, from: data)

        XCTAssertFalse(preferences.monitorOverrides["123"]?.hasAnyOverride ?? true)

        let encoded = try JSONEncoder().encode(preferences)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let general = try XCTUnwrap(object["general"] as? [String: Any])
        let overrides = try XCTUnwrap(object["monitorOverrides"] as? [String: Any])
        let monitor = try XCTUnwrap(overrides["123"] as? [String: Any])

        XCTAssertNil(general["groupByApp"])
        XCTAssertNil(general["showWindowCounts"])
        XCTAssertNil(monitor["groupByApp"])
        XCTAssertNil(monitor["showWindowCounts"])
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
            showGPU: true,
            showMemory: true,
            showNetwork: true,
            showMiniGraph: true,
            memoryDisplay: .pie
        )
        let monitorStats = StatsWidgetSettings(
            isEnabled: false,
            showCPU: false,
            showGPU: false,
            showMemory: true,
            showNetwork: false,
            showMiniGraph: false,
            memoryDisplay: .percent
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

    func testStatsWidgetDecodesMissingFieldsAsDefaults() throws {
        let json = """
        {
          "isEnabled": true,
          "showCPU": true,
          "showMemory": true,
          "showNetwork": true,
          "showMiniGraph": true
        }
        """

        let decoded = try JSONDecoder().decode(StatsWidgetSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.memoryDisplay, .percent)
        XCTAssertTrue(decoded.showGPU)
        XCTAssertEqual(decoded.cpuDisplay, .perCPU)
        XCTAssertEqual(decoded.cpuCoreColors, .defaults)
    }

    func testStatsWidgetMigratesDisabledLegacyGraphToPercentage() throws {
        let json = """
        {
          "isEnabled": true,
          "showCPU": true,
          "showMiniGraph": false
        }
        """

        let decoded = try JSONDecoder().decode(StatsWidgetSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.cpuDisplay, .percentage)
        XCTAssertFalse(decoded.showMiniGraph)
    }

    func testStatsWidgetPersistsPerCPUDisplayMode() throws {
        let settings = StatsWidgetSettings(
            isEnabled: true,
            showCPU: true,
            showGPU: true,
            showMemory: true,
            showNetwork: true,
            showMiniGraph: true,
            cpuDisplay: .perCPU
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StatsWidgetSettings.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(decoded.cpuDisplay, .perCPU)
        XCTAssertTrue(decoded.showMiniGraph)
        XCTAssertEqual(object?["cpuDisplay"] as? String, "perCPU")
    }

    func testStatsWidgetPersistsCustomCPUCoreColours() throws {
        var settings = StatsWidgetSettings.defaults
        settings.cpuCoreColors = StatsCPUCoreColors(
            superCore: "#112233",
            performance: "#445566",
            efficiency: "#778899"
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StatsWidgetSettings.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let colours = object?["cpuCoreColors"] as? [String: Any]

        XCTAssertEqual(decoded.cpuCoreColors, settings.cpuCoreColors)
        XCTAssertEqual(colours?["superCore"] as? String, "#112233")
        XCTAssertEqual(colours?["performance"] as? String, "#445566")
        XCTAssertEqual(colours?["efficiency"] as? String, "#778899")
    }

    func testDateTimeWidgetEncodingDoesNotWriteLegacyClockKeys() throws {
        let values = TaskbarSettingValues(
            isVisible: true,
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
                showGPU: true,
                showMemory: false,
                showNetwork: true,
                showMiniGraph: true
            ),
            taskbarHeight: 54,
            minimumItemWidth: 96,
            maximumItemWidth: 220,
            itemSpacing: 3,
            backgroundOpacity: 0.72,
            avoidOverlappingWindows: true,
            showMinimizedWindows: true,
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
        XCTAssertEqual(statsWidget?["showGPU"] as? Bool, true)
        XCTAssertEqual(statsWidget?["showMemory"] as? Bool, false)
        XCTAssertEqual(statsWidget?["showNetwork"] as? Bool, true)
        XCTAssertEqual(statsWidget?["memoryDisplay"] as? String, "percent")
        XCTAssertEqual(object?["widgetSpacing"] as? Double, 0)
        XCTAssertNil(object?["backgroundStyle"])
        XCTAssertNil(object?["glassAmount"])
        XCTAssertNil(object?["showClock"])
    }

    func testShowMinimizedWindowsDefaultsTrueWhenMissing() throws {
        let json = """
        {
          "isVisible": true,
          "groupByApp": true,
          "dateTimeWidget": {
            "isEnabled": true,
            "dateDisplay": "never",
            "showDayOfWeek": true,
            "showSeconds": false,
            "use24HourClock": true
          },
          "statsWidget": {
            "isEnabled": true,
            "showCPU": true,
            "showGPU": true,
            "showMemory": true,
            "showNetwork": true,
            "showMiniGraph": true,
            "memoryDisplay": "percent"
          },
          "showWindowCounts": true,
          "taskbarHeight": 54,
          "minimumItemWidth": 96,
          "maximumItemWidth": 220,
          "itemSpacing": 3,
          "backgroundOpacity": 0.72,
          "avoidOverlappingWindows": true,
          "autoHide": false,
          "revealAnimation": "ease",
          "revealAnimationDuration": 0.18,
          "pinnedApps": []
        }
        """

        let decoded = try JSONDecoder().decode(TaskbarSettingValues.self, from: Data(json.utf8))

        XCTAssertTrue(decoded.showMinimizedWindows)
        XCTAssertEqual(decoded.widgetSpacing, TaskbarSettingValues.defaultWidgetSpacing)
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

    func testDateTimeWidgetMetricsFitReferenceTextAcrossSettings() throws {
        let locale = Locale.current
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let referenceDates = try [10, 22].map { hour in
            try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2025,
                month: 9,
                day: 24,
                hour: hour,
                minute: 45,
                second: 33
            )))
        }
        let font = NSFont.menuBarFont(ofSize: 13)

        for use24HourClock in [false, true] {
            for showSeconds in [false, true] {
                for dateDisplay in DateTimeDateDisplay.allCases {
                    let settings = DateTimeWidgetSettings(
                        isEnabled: true,
                        dateDisplay: dateDisplay,
                        showDayOfWeek: true,
                        showSeconds: showSeconds,
                        use24HourClock: use24HourClock
                    )
                    let texts = referenceDates.map { date in
                        dateTimeWidgetText(
                            settings: settings,
                            date: date,
                            availableWidth: .greatestFiniteMagnitude,
                            locale: locale,
                            timeZone: timeZone
                        )
                    }
                    let measuredWidth = texts
                        .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
                        .max() ?? 0
                    let metricWidth = dateDisplay == .never
                        ? DateTimeWidgetMetrics.compactWidth(for: settings)
                        : DateTimeWidgetMetrics.expandedWidth(for: settings)
                    let context = "24-hour=\(use24HourClock), seconds=\(showSeconds), date=\(dateDisplay)"

                    XCTAssertGreaterThanOrEqual(metricWidth, measuredWidth, context)
                }
            }
        }
    }

    func testDateTimeWidgetWaitsForMeasuredExpandedWidthBeforeShowingDate() throws {
        let locale = Locale.current
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2025,
            month: 9,
            day: 24,
            hour: 22,
            minute: 45,
            second: 33
        )))
        let settings = DateTimeWidgetSettings(
            isEnabled: true,
            dateDisplay: .whenSpaceAllows,
            showDayOfWeek: true,
            showSeconds: true,
            use24HourClock: false
        )
        let compactWidth = DateTimeWidgetMetrics.compactWidth(for: settings)
        let expandedWidth = DateTimeWidgetMetrics.expandedWidth(for: settings)
        var compactSettings = settings
        compactSettings.dateDisplay = .never
        var expandedSettings = settings
        expandedSettings.dateDisplay = .always
        let compactText = dateTimeWidgetText(
            settings: compactSettings,
            date: date,
            availableWidth: .greatestFiniteMagnitude,
            locale: locale,
            timeZone: timeZone
        )
        let expandedText = dateTimeWidgetText(
            settings: expandedSettings,
            date: date,
            availableWidth: .greatestFiniteMagnitude,
            locale: locale,
            timeZone: timeZone
        )
        var values = TaskbarSettingValues.defaults
        values.dateTimeWidget = settings
        let plugin = DateTimeWidgetPlugin()

        XCTAssertEqual(
            plugin.preferredWidth(in: values, height: 22, availableWidth: expandedWidth - 1),
            compactWidth
        )
        XCTAssertEqual(
            dateTimeWidgetText(
                settings: settings,
                date: date,
                availableWidth: expandedWidth - 1,
                locale: locale,
                timeZone: timeZone
            ),
            compactText
        )
        XCTAssertEqual(
            plugin.preferredWidth(in: values, height: 22, availableWidth: expandedWidth),
            expandedWidth
        )
        XCTAssertEqual(
            dateTimeWidgetText(
                settings: settings,
                date: date,
                availableWidth: expandedWidth,
                locale: locale,
                timeZone: timeZone
            ),
            expandedText
        )
    }

    func testDateTimeWidgetMetricsKeepCompactConfigurationsTight() {
        let locale = Locale(identifier: "en_US_POSIX")
        let compact24Hour = DateTimeWidgetSettings(
            isEnabled: true,
            dateDisplay: .never,
            showDayOfWeek: true,
            showSeconds: false,
            use24HourClock: true
        )
        var compact12Hour = compact24Hour
        compact12Hour.use24HourClock = false
        var compactWithSeconds = compact24Hour
        compactWithSeconds.showSeconds = true
        var expanded24Hour = compact24Hour
        expanded24Hour.dateDisplay = .always

        let compactWidth = DateTimeWidgetMetrics.compactWidth(
            for: compact24Hour,
            locale: locale,
            fontSize: 13
        )

        XCTAssertLessThan(
            compactWidth,
            DateTimeWidgetMetrics.compactWidth(for: compact12Hour, locale: locale, fontSize: 13)
        )
        XCTAssertLessThan(
            compactWidth,
            DateTimeWidgetMetrics.compactWidth(for: compactWithSeconds, locale: locale, fontSize: 13)
        )
        XCTAssertLessThan(
            compactWidth,
            DateTimeWidgetMetrics.expandedWidth(for: expanded24Hour, locale: locale, fontSize: 13)
        )

        var values = TaskbarSettingValues.defaults
        values.dateTimeWidget = compact12Hour
        let plugin = DateTimeWidgetPlugin()
        XCTAssertLessThan(
            plugin.minimumWidth(in: values, height: 18),
            plugin.minimumWidth(in: values, height: 22)
        )
    }

    func testDateTimeWidgetMetricsMeasureEachLocaleIndependently() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let settings = DateTimeWidgetSettings(
            isEnabled: true,
            dateDisplay: .always,
            showDayOfWeek: true,
            showSeconds: true,
            use24HourClock: false
        )
        let font = NSFont.menuBarFont(ofSize: 13)
        let regressionCases = [
            (locale: "bn_BD", month: 10, day: 23),
            (locale: "my_MM", month: 10, day: 16),
            (locale: "th_TH", month: 4, day: 20),
            (locale: "pl_PL", month: 3, day: 23)
        ]

        for regressionCase in regressionCases {
            let locale = Locale(identifier: regressionCase.locale)
            let date = try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2025,
                month: regressionCase.month,
                day: regressionCase.day,
                hour: 0,
                minute: 45,
                second: 33
            )))
            let text = dateTimeWidgetText(
                settings: settings,
                date: date,
                availableWidth: .greatestFiniteMagnitude,
                locale: locale,
                timeZone: timeZone
            )
            let measuredWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)

            XCTAssertGreaterThanOrEqual(
                DateTimeWidgetMetrics.expandedWidth(
                    for: settings,
                    locale: locale,
                    fontSize: 13
                ),
                measuredWidth,
                "\(regressionCase.locale), text=\(text)"
            )
        }
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
            showGPU: false,
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

    func testStatsWidgetModuleRectsIncludeGPUWhenEnabled() {
        let settings = StatsWidgetSettings(
            isEnabled: true,
            showCPU: true,
            showGPU: true,
            showMemory: false,
            showNetwork: false,
            showMiniGraph: true
        )

        let rects = statsWidgetModuleRects(settings: settings, in: NSRect(x: 0, y: 0, width: 130, height: 42))

        XCTAssertEqual(rects.map(\.0), [.cpu, .gpu])
        XCTAssertGreaterThanOrEqual(rects[1].1.width, StatsWidgetMetrics.minimumGPUWidth)
    }

    func testStatsWidgetModuleRectsHonorEachMetricMinimumAtExactMinimumWidth() {
        let settings = StatsWidgetSettings(
            isEnabled: true,
            showCPU: true,
            showGPU: true,
            showMemory: true,
            showNetwork: true,
            showMiniGraph: true
        )
        let minimumWidth = StatsWidgetMetrics.minimumWidth(for: settings)

        let rects = statsWidgetModuleRects(
            settings: settings,
            in: NSRect(x: 0, y: 0, width: minimumWidth, height: 42)
        )

        XCTAssertEqual(rects.map(\.0), [.cpu, .gpu, .memory, .network])
        XCTAssertGreaterThanOrEqual(rects[0].1.width, StatsWidgetMetrics.minimumCPUWidth)
        XCTAssertGreaterThanOrEqual(rects[1].1.width, StatsWidgetMetrics.minimumGPUWidth)
        XCTAssertGreaterThanOrEqual(rects[2].1.width, StatsWidgetMetrics.minimumMemoryWidth)
        XCTAssertGreaterThanOrEqual(rects[3].1.width, StatsWidgetMetrics.minimumNetworkWidth)
        XCTAssertEqual(rects.last!.1.maxX, minimumWidth, accuracy: 0.001)
    }

    func testStatsWidgetMixedModulesKeepPreferredWidthsWhenSpaceAllows() {
        let settings = StatsWidgetSettings(
            isEnabled: true,
            showCPU: false,
            showGPU: true,
            showMemory: true,
            showNetwork: true,
            showMiniGraph: true
        )

        let rects = statsWidgetModuleRects(
            settings: settings,
            in: NSRect(x: 0, y: 0, width: 220, height: 42)
        )

        XCTAssertEqual(rects.map(\.0), [.gpu, .memory, .network])
        XCTAssertEqual(
            rects.map { $0.1.width },
            [
                StatsWidgetMetrics.preferredGPUWidth,
                StatsWidgetMetrics.preferredMemoryWidth,
                StatsWidgetMetrics.preferredNetworkWidth
            ]
        )
    }

    func testStatsWidgetMixedModulesFitWithinWidthBelowDeclaredMinimum() {
        let settings = StatsWidgetSettings(
            isEnabled: true,
            showCPU: false,
            showGPU: true,
            showMemory: true,
            showNetwork: true,
            showMiniGraph: true
        )
        let rect = NSRect(
            x: 7,
            y: 0,
            width: StatsWidgetMetrics.minimumWidth(for: settings) - 23,
            height: 42
        )
        let minimumWidths = [
            StatsWidgetMetrics.minimumGPUWidth,
            StatsWidgetMetrics.minimumMemoryWidth,
            StatsWidgetMetrics.minimumNetworkWidth
        ]
        let totalSpacing = StatsWidgetMetrics.moduleSpacing * 2
        let scale = (rect.width - totalSpacing) / minimumWidths.reduce(0, +)

        let rects = statsWidgetModuleRects(settings: settings, in: rect)
        let gaps = zip(rects, rects.dropFirst()).map { left, right in
            right.1.minX - left.1.maxX
        }

        XCTAssertEqual(rects.map(\.0), [.gpu, .memory, .network])
        XCTAssertEqual(gaps, [StatsWidgetMetrics.moduleSpacing, StatsWidgetMetrics.moduleSpacing])
        for (moduleRect, minimumWidth) in zip(rects.map({ $0.1 }), minimumWidths) {
            XCTAssertEqual(moduleRect.width, minimumWidth * scale, accuracy: 0.001)
        }
        XCTAssertEqual(
            rects.map { $0.1.width }.reduce(0, +) + gaps.reduce(0, +),
            rect.width,
            accuracy: 0.001
        )
        XCTAssertEqual(rects.last!.1.maxX, rect.maxX, accuracy: 0.001)
        XCTAssertLessThanOrEqual(rects.last!.1.maxX, rect.maxX + 0.001)
    }

    func testStatsWidgetUltraNarrowRectShrinksSpacingWithoutOverflow() {
        let settings = StatsWidgetSettings(
            isEnabled: true,
            showCPU: false,
            showGPU: true,
            showMemory: true,
            showNetwork: true,
            showMiniGraph: true
        )
        let rect = NSRect(x: 7, y: 0, width: 15, height: 42)

        let rects = statsWidgetModuleRects(settings: settings, in: rect)
        let gaps = zip(rects, rects.dropFirst()).map { left, right in
            right.1.minX - left.1.maxX
        }

        XCTAssertEqual(rects.map(\.0), [.gpu, .memory, .network])
        XCTAssertEqual(rects.map { $0.1.width }, [0, 0, 0])
        XCTAssertEqual(gaps.reduce(0, +), rect.width, accuracy: 0.001)
        XCTAssertEqual(rects.last!.1.maxX, rect.maxX, accuracy: 0.001)
        XCTAssertLessThanOrEqual(rects.last!.1.maxX, rect.maxX + 0.001)
    }

    func testStatsWidgetModuleSpacingIsCompact() {
        let settings = StatsWidgetSettings(
            isEnabled: true,
            showCPU: true,
            showGPU: true,
            showMemory: true,
            showNetwork: true,
            showMiniGraph: true
        )

        let rects = statsWidgetModuleRects(settings: settings, in: NSRect(x: 0, y: 0, width: 220, height: 42))
        let gaps = zip(rects, rects.dropFirst()).map { left, right in
            right.1.minX - left.1.maxX
        }

        XCTAssertEqual(gaps, [10, 10, 10])
        XCTAssertGreaterThan(StatsWidgetMetrics.preferredMemoryWidth, StatsWidgetMetrics.minimumMemoryWidth)
        XCTAssertLessThanOrEqual(StatsWidgetMetrics.preferredNetworkWidth, 72)
    }

    func testStatsMemoryModuleLeavesRoomForThreeDigitPercent() {
        let contentWidth = StatsWidgetMetrics.preferredMemoryWidth
            - StatsWidgetMetrics.sideLabelWidth
            - StatsWidgetMetrics.sideLabelGap

        XCTAssertGreaterThanOrEqual(contentWidth, 36)
        XCTAssertEqual(StatsWidgetMetrics.minimumMemoryWidth, 38)
    }

    func testStatsMiniGraphUsesOnePixelVerticalPadding() {
        let source = NSRect(x: 12, y: 4, width: 108, height: 22)

        let graph = statsMiniGraphRect(in: source, width: 42)

        XCTAssertEqual(graph.minY, 5)
        XCTAssertEqual(graph.height, 20)
    }

    func testStatsMiniGraphAllowsTwoPixelBarsWhenSpaceAllows() {
        let source = NSRect(x: 0, y: 0, width: 62, height: 22)

        let graphWidth = statsMiniGraphWidth(in: source, isEnabled: true)

        XCTAssertGreaterThanOrEqual(graphWidth, 53)
    }

    func testStatsCPUTaskbarFallsBackToPercentWhenGraphIsUnavailable() {
        let graphAvailable = statsCPUTaskbarRenderContent(
            in: NSRect(x: 0, y: 0, width: StatsWidgetMetrics.preferredCPUWidth, height: 42),
            showMiniGraph: true
        )
        let graphDisabled = statsCPUTaskbarRenderContent(
            in: NSRect(x: 0, y: 0, width: StatsWidgetMetrics.preferredCPUWidth, height: 42),
            showMiniGraph: false
        )
        let graphCannotFit = statsCPUTaskbarRenderContent(
            in: NSRect(
                x: 0,
                y: 0,
                width: StatsWidgetMetrics.sideLabelWidth + StatsWidgetMetrics.sideLabelGap + 17,
                height: 42
            ),
            showMiniGraph: true
        )

        XCTAssertEqual(graphAvailable, .miniGraph(width: 60))
        XCTAssertEqual(graphDisabled, .percent)
        XCTAssertEqual(graphCannotFit, .percent)
    }

    func testStatsCPUGraphUsesHistoryOrCurrentProcessorValuesForSelectedMode() {
        var snapshot = StatsSnapshot.empty
        snapshot.cpuHistory = [10, 20, 30]
        snapshot.cpuProcessorPercents = [40, 50]

        XCTAssertEqual(statsCPUGraphValues(snapshot: snapshot, display: .history), [10, 20, 30])
        XCTAssertEqual(statsCPUGraphValues(snapshot: snapshot, display: .perCPU), [40, 50])
        XCTAssertNil(statsCPUGraphValues(snapshot: snapshot, display: .percentage))
    }

    func testStatsCPUProcessorColoursFollowEachProcessorsPerformanceLevel() {
        var snapshot = StatsSnapshot.empty
        snapshot.cpuPerformanceLevels = [
            CPUPerformanceLevel(name: "Performance", processorCount: 2),
            CPUPerformanceLevel(name: "Efficiency", processorCount: 2)
        ]
        snapshot.cpuProcessorPerformanceLevelIndices = [1, 1, 0, 0]

        XCTAssertEqual(
            statsCPUProcessorColorRoles(snapshot: snapshot),
            [.efficiency, .efficiency, .performance, .performance]
        )
        XCTAssertEqual(
            formattedCPUPerformanceLevels(snapshot.cpuPerformanceLevels),
            "2 Performance · 2 Efficiency"
        )
    }

    func testStatsCPUCoreColourLookupUsesConfiguredTierColours() {
        let colours = StatsCPUCoreColors(
            superCore: "#111111",
            performance: "#222222",
            efficiency: "#333333"
        )

        XCTAssertEqual(statsCPUCoreColorHex(for: .superCore, colors: colours), "#111111")
        XCTAssertEqual(statsCPUCoreColorHex(for: .performance, colors: colours), "#222222")
        XCTAssertEqual(statsCPUCoreColorHex(for: .efficiency, colors: colours), "#333333")
        XCTAssertEqual(statsCPUCoreColorHex(for: .standard, colors: colours), "#222222")
    }

    func testStatsMiniGraphBarsStartAtLeftEdge() {
        let source = NSRect(x: 20, y: 0, width: 62, height: 22)

        let layout = statsMiniGraphBarLayout(in: source, barCount: 18)
        let lastMaxX = layout.firstX
            + layout.barWidth * 18
            + layout.gap * 17

        XCTAssertEqual(layout.firstX, source.minX)
        XCTAssertEqual(layout.barWidth, 2)
        XCTAssertEqual(lastMaxX, source.maxX, accuracy: 0.001)
    }

    func testStatsSideLabelLeavesContentToTheRight() {
        let source = NSRect(x: 12, y: 4, width: 52, height: 22)

        let rects = statsSideLabelRects(in: source)

        XCTAssertEqual(rects.label.minX, 12)
        XCTAssertEqual(rects.label.width, 10)
        XCTAssertGreaterThanOrEqual(statsVerticalLabelFontSize(for: rects.label), 9)
        XCTAssertGreaterThan(rects.content.minX, rects.label.maxX)
        XCTAssertEqual(rects.content.height, 22)
    }

    func testStatsNetworkLinesAreVerticallyStacked() {
        let source = NSRect(x: 0, y: 0, width: 88, height: 22)

        let lines = statsNetworkLineRects(in: source)

        XCTAssertGreaterThan(lines.upload.minY, lines.download.minY)
        XCTAssertEqual(lines.upload.width, 88)
        XCTAssertEqual(lines.download.width, 88)
    }

    func testStatsMemoryPieRectFitsContent() {
        let source = NSRect(x: 12, y: 4, width: 32, height: 22)

        let pie = statsMemoryPieRect(in: source)

        XCTAssertEqual(pie.width, 20)
        XCTAssertEqual(pie.height, 20)
        XCTAssertGreaterThanOrEqual(pie.minY, source.minY)
        XCTAssertLessThanOrEqual(pie.maxY, source.maxY)
    }

    func testStatsPopoverChartLayoutLeavesRoomForAxes() {
        let source = NSRect(x: 18, y: 196, width: 324, height: 116)

        let layout = statsPopoverChartLayout(in: source)

        XCTAssertEqual(layout.panel, source)
        XCTAssertGreaterThan(layout.plot.minX, source.minX + 30)
        XCTAssertLessThanOrEqual(layout.plot.maxX, source.maxX - 8)
        XCTAssertGreaterThan(layout.xAxis.minY, layout.plot.maxY)
        XCTAssertLessThan(layout.yAxis.maxX, layout.plot.minX)
    }

    func testStatsChartPointMapsValuesIntoPlotArea() {
        let plot = NSRect(x: 50, y: 20, width: 200, height: 80)

        let first = statsChartPoint(index: 0, count: 3, value: 0, maxValue: 100, in: plot)
        let middle = statsChartPoint(index: 1, count: 3, value: 50, maxValue: 100, in: plot)
        let last = statsChartPoint(index: 2, count: 3, value: 100, maxValue: 100, in: plot)

        XCTAssertEqual(first.x, plot.minX)
        XCTAssertEqual(first.y, plot.maxY)
        XCTAssertEqual(middle.x, plot.midX)
        XCTAssertEqual(middle.y, plot.midY)
        XCTAssertEqual(last.x, plot.maxX)
        XCTAssertEqual(last.y, plot.minY)
    }

    func testStatsWidgetMetricHitUsesIndividualSlices() {
        let settings = StatsWidgetSettings(
            isEnabled: true,
            showCPU: true,
            showGPU: true,
            showMemory: true,
            showNetwork: true,
            showMiniGraph: true
        )
        let widgetRect = NSRect(x: 20, y: 4, width: 240, height: 22)
        let rects = statsWidgetMetricRects(settings: settings, in: widgetRect)

        for (metric, rect) in rects {
            let point = NSPoint(x: rect.midX, y: widgetRect.minY - 50)

            XCTAssertEqual(statsWidgetMetric(at: point, in: widgetRect, settings: settings), metric)
        }
    }

    func testStatsPopoverLayoutHasGPUSize() {
        let size = StatsPopoverLayout.size(for: .gpu)

        XCTAssertEqual(size.width, 360)
        XCTAssertGreaterThanOrEqual(size.height, 520)
    }

    func testTaskbarInteractionRectUsesFullVerticalSlice() {
        let visual = NSRect(x: 20, y: 4, width: 90, height: 22)
        let bounds = NSRect(x: 0, y: 0, width: 320, height: 30)

        let interaction = taskbarInteractionRect(for: visual, in: bounds)

        XCTAssertTrue(interaction.contains(NSPoint(x: 40, y: 1)))
        XCTAssertTrue(interaction.contains(NSPoint(x: 40, y: 29)))
        XCTAssertFalse(interaction.contains(NSPoint(x: 19, y: 1)))
    }

    func testWidgetSpacingUsesItsIndependentSetting() {
        XCTAssertEqual(taskbarWidgetSpacing(widgetSpacing: 0), 0)
        XCTAssertEqual(taskbarWidgetSpacing(widgetSpacing: 1), 1)
        XCTAssertEqual(taskbarWidgetSpacing(widgetSpacing: 12), 12)
    }

    func testInstalledWidgetsIncludeStatsAndBatteryBeforeDateTime() {
        XCTAssertEqual(installedTaskbarWidgetIDs(), [.stats, .battery, .dateTime])
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

    func testReconciledSidebarSelectionKeepsMonitorByIDWhenScreenGeometryChanges() {
        let original = ScreenInfo(
            id: 7,
            name: "Studio Display",
            appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            quartzFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let resized = ScreenInfo(
            id: 7,
            name: "Studio Display",
            appKitFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            quartzFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440)
        )
        let refreshedItems = taskbarSettingsSidebarItems(screens: [resized], widgets: [.stats])

        XCTAssertEqual(
            reconciledSettingsSidebarSelection(.monitor(original), in: refreshedItems),
            .monitor(resized)
        )
    }
}
