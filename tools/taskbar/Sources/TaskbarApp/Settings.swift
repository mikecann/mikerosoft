import Foundation

enum ClockMode: String, Codable, CaseIterable, Equatable {
    case hidden
    case time
    case dateAndTime

    var label: String {
        switch self {
        case .hidden:
            return "Off"
        case .time:
            return "Time"
        case .dateAndTime:
            return "Date and time"
        }
    }
}

enum DateTimeDateDisplay: String, Codable, CaseIterable, Equatable {
    case never
    case whenSpaceAllows
    case always

    var label: String {
        switch self {
        case .never:
            return "Never"
        case .whenSpaceAllows:
            return "When space allows"
        case .always:
            return "Always"
        }
    }
}

struct DateTimeWidgetSettings: Codable, Equatable {
    var isEnabled: Bool
    var dateDisplay: DateTimeDateDisplay
    var showDayOfWeek: Bool
    var showSeconds: Bool
    var use24HourClock: Bool

    static var defaults: DateTimeWidgetSettings {
        DateTimeWidgetSettings(
            isEnabled: true,
            dateDisplay: .whenSpaceAllows,
            showDayOfWeek: true,
            showSeconds: false,
            use24HourClock: true
        )
    }

    static func legacy(clockMode: ClockMode) -> DateTimeWidgetSettings {
        switch clockMode {
        case .hidden:
            var settings = defaults
            settings.isEnabled = false
            settings.dateDisplay = .never
            return settings
        case .time:
            var settings = defaults
            settings.dateDisplay = .never
            return settings
        case .dateAndTime:
            var settings = defaults
            settings.dateDisplay = .always
            return settings
        }
    }

    var legacyClockMode: ClockMode {
        guard isEnabled else { return .hidden }
        return dateDisplay == .never ? .time : .dateAndTime
    }

    mutating func applyLegacyClockMode(_ clockMode: ClockMode) {
        let migrated = Self.legacy(clockMode: clockMode)
        isEnabled = migrated.isEnabled
        dateDisplay = migrated.dateDisplay
    }
}

enum RevealAnimation: String, Codable, CaseIterable, Equatable {
    case instant
    case linear
    case ease

    var label: String {
        switch self {
        case .instant:
            return "Instant"
        case .linear:
            return "Linear"
        case .ease:
            return "Ease"
        }
    }
}

struct PinnedApp: Codable, Equatable {
    var displayName: String
    var bundleID: String
    var appPath: String

    var identity: String {
        if !bundleID.isEmpty {
            return "bundle:\(bundleID)"
        }
        return "path:\(appPath)"
    }
}

struct TaskbarSettingValues: Codable, Equatable {
    static let defaultTaskbarHeight: Double = 54
    static let minimumTaskbarHeight: Double = 24
    static let maximumTaskbarHeight: Double = 96
    static let defaultMinimumItemWidth: Double = 96
    static let defaultMaximumItemWidth: Double = 220
    static let smallestItemWidth: Double = 56
    static let largestItemWidth: Double = 420
    static let defaultItemSpacing: Double = 3
    static let minimumItemSpacing: Double = 0
    static let maximumItemSpacing: Double = 24
    static let defaultBackgroundOpacity: Double = 0.72
    static let minimumBackgroundOpacity: Double = 0.15
    static let maximumBackgroundOpacity: Double = 1
    static let defaultRevealAnimationDuration: Double = 0.18
    static let minimumRevealAnimationDuration: Double = 0
    static let maximumRevealAnimationDuration: Double = 1

    var isVisible: Bool
    var groupByApp: Bool
    var dateTimeWidget: DateTimeWidgetSettings
    var showWindowCounts: Bool
    var taskbarHeight: Double
    var minimumItemWidth: Double
    var maximumItemWidth: Double
    var itemSpacing: Double
    var backgroundOpacity: Double
    var avoidOverlappingWindows: Bool
    var autoHide: Bool
    var revealAnimation: RevealAnimation
    var revealAnimationDuration: Double
    var pinnedApps: [PinnedApp]

    var clockMode: ClockMode {
        get { dateTimeWidget.legacyClockMode }
        set { dateTimeWidget.applyLegacyClockMode(newValue) }
    }

    static var defaults: TaskbarSettingValues {
        TaskbarSettingValues(
            isVisible: true,
            groupByApp: true,
            clockMode: .time,
            dateTimeWidget: .defaults,
            showWindowCounts: true,
            taskbarHeight: defaultTaskbarHeight,
            minimumItemWidth: defaultMinimumItemWidth,
            maximumItemWidth: defaultMaximumItemWidth,
            itemSpacing: defaultItemSpacing,
            backgroundOpacity: defaultBackgroundOpacity,
            avoidOverlappingWindows: true,
            autoHide: false,
            revealAnimation: .ease,
            revealAnimationDuration: defaultRevealAnimationDuration,
            pinnedApps: []
        )
    }

    enum CodingKeys: String, CodingKey {
        case isVisible
        case groupByApp
        case showClock
        case clockMode
        case dateTimeWidget
        case showWindowCounts
        case taskbarHeight
        case minimumItemWidth
        case maximumItemWidth
        case itemSpacing
        case backgroundOpacity
        case avoidOverlappingWindows
        case autoHide
        case revealAnimation
        case revealAnimationDuration
        case pinnedApps
    }

    init(
        isVisible: Bool,
        groupByApp: Bool,
        clockMode: ClockMode,
        dateTimeWidget: DateTimeWidgetSettings? = nil,
        showWindowCounts: Bool,
        taskbarHeight: Double,
        minimumItemWidth: Double,
        maximumItemWidth: Double,
        itemSpacing: Double,
        backgroundOpacity: Double,
        avoidOverlappingWindows: Bool,
        autoHide: Bool,
        revealAnimation: RevealAnimation,
        revealAnimationDuration: Double,
        pinnedApps: [PinnedApp]
    ) {
        self.isVisible = isVisible
        self.groupByApp = groupByApp
        self.dateTimeWidget = dateTimeWidget ?? DateTimeWidgetSettings.legacy(clockMode: clockMode)
        self.showWindowCounts = showWindowCounts
        self.taskbarHeight = taskbarHeight
        self.minimumItemWidth = minimumItemWidth
        self.maximumItemWidth = maximumItemWidth
        self.itemSpacing = itemSpacing
        self.backgroundOpacity = backgroundOpacity
        self.avoidOverlappingWindows = avoidOverlappingWindows
        self.autoHide = autoHide
        self.revealAnimation = revealAnimation
        self.revealAnimationDuration = revealAnimationDuration
        self.pinnedApps = pinnedApps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        groupByApp = try container.decodeIfPresent(Bool.self, forKey: .groupByApp) ?? true
        if let dateTimeWidget = try container.decodeIfPresent(DateTimeWidgetSettings.self, forKey: .dateTimeWidget) {
            self.dateTimeWidget = dateTimeWidget
        } else if let clockMode = try container.decodeIfPresent(ClockMode.self, forKey: .clockMode) {
            self.dateTimeWidget = DateTimeWidgetSettings.legacy(clockMode: clockMode)
        } else {
            let oldShowClock = try container.decodeIfPresent(Bool.self, forKey: .showClock) ?? true
            self.dateTimeWidget = DateTimeWidgetSettings.legacy(clockMode: oldShowClock ? .time : .hidden)
        }
        showWindowCounts = try container.decodeIfPresent(Bool.self, forKey: .showWindowCounts) ?? true
        taskbarHeight = try container.decodeIfPresent(Double.self, forKey: .taskbarHeight) ?? Self.defaultTaskbarHeight
        minimumItemWidth = try container.decodeIfPresent(Double.self, forKey: .minimumItemWidth) ?? Self.defaultMinimumItemWidth
        maximumItemWidth = try container.decodeIfPresent(Double.self, forKey: .maximumItemWidth) ?? Self.defaultMaximumItemWidth
        itemSpacing = try container.decodeIfPresent(Double.self, forKey: .itemSpacing) ?? Self.defaultItemSpacing
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? Self.defaultBackgroundOpacity
        avoidOverlappingWindows = try container.decodeIfPresent(Bool.self, forKey: .avoidOverlappingWindows) ?? true
        autoHide = try container.decodeIfPresent(Bool.self, forKey: .autoHide) ?? false
        revealAnimation = try container.decodeIfPresent(RevealAnimation.self, forKey: .revealAnimation) ?? .ease
        revealAnimationDuration = try container.decodeIfPresent(Double.self, forKey: .revealAnimationDuration) ?? Self.defaultRevealAnimationDuration
        pinnedApps = try container.decodeIfPresent([PinnedApp].self, forKey: .pinnedApps) ?? []
        clamp()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(groupByApp, forKey: .groupByApp)
        try container.encode(dateTimeWidget, forKey: .dateTimeWidget)
        try container.encode(showWindowCounts, forKey: .showWindowCounts)
        try container.encode(taskbarHeight, forKey: .taskbarHeight)
        try container.encode(minimumItemWidth, forKey: .minimumItemWidth)
        try container.encode(maximumItemWidth, forKey: .maximumItemWidth)
        try container.encode(itemSpacing, forKey: .itemSpacing)
        try container.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try container.encode(avoidOverlappingWindows, forKey: .avoidOverlappingWindows)
        try container.encode(autoHide, forKey: .autoHide)
        try container.encode(revealAnimation, forKey: .revealAnimation)
        try container.encode(revealAnimationDuration, forKey: .revealAnimationDuration)
        try container.encode(pinnedApps, forKey: .pinnedApps)
    }

    static func clampedTaskbarHeight(_ value: Double) -> Double {
        min(max(value, minimumTaskbarHeight), maximumTaskbarHeight)
    }

    static func clampedMinimumItemWidth(_ value: Double) -> Double {
        min(max(value, smallestItemWidth), largestItemWidth)
    }

    static func clampedMaximumItemWidth(_ value: Double) -> Double {
        min(max(value, smallestItemWidth), largestItemWidth)
    }

    static func clampedBackgroundOpacity(_ value: Double) -> Double {
        min(max(value, minimumBackgroundOpacity), maximumBackgroundOpacity)
    }

    static func clampedItemSpacing(_ value: Double) -> Double {
        min(max(value, minimumItemSpacing), maximumItemSpacing)
    }

    static func clampedRevealAnimationDuration(_ value: Double) -> Double {
        min(max(value, minimumRevealAnimationDuration), maximumRevealAnimationDuration)
    }

    mutating func clamp() {
        taskbarHeight = Self.clampedTaskbarHeight(taskbarHeight)
        minimumItemWidth = Self.clampedMinimumItemWidth(minimumItemWidth)
        maximumItemWidth = Self.clampedMaximumItemWidth(maximumItemWidth)
        if maximumItemWidth < minimumItemWidth {
            maximumItemWidth = minimumItemWidth
        }
        itemSpacing = Self.clampedItemSpacing(itemSpacing)
        backgroundOpacity = Self.clampedBackgroundOpacity(backgroundOpacity)
        revealAnimationDuration = Self.clampedRevealAnimationDuration(revealAnimationDuration)
    }
}

struct TaskbarMonitorOverrides: Codable, Equatable {
    var isVisible: Bool?
    var groupByApp: Bool?
    var clockMode: ClockMode?
    var dateTimeWidget: DateTimeWidgetSettings?
    var showWindowCounts: Bool?
    var taskbarHeight: Double?
    var minimumItemWidth: Double?
    var maximumItemWidth: Double?
    var itemSpacing: Double?
    var backgroundOpacity: Double?
    var avoidOverlappingWindows: Bool?
    var autoHide: Bool?
    var revealAnimation: RevealAnimation?
    var revealAnimationDuration: Double?
    var pinnedApps: [PinnedApp]?

    var hasAnyOverride: Bool {
        isVisible != nil
            || groupByApp != nil
            || clockMode != nil
            || dateTimeWidget != nil
            || showWindowCounts != nil
            || taskbarHeight != nil
            || minimumItemWidth != nil
            || maximumItemWidth != nil
            || itemSpacing != nil
            || backgroundOpacity != nil
            || avoidOverlappingWindows != nil
            || autoHide != nil
            || revealAnimation != nil
            || revealAnimationDuration != nil
            || pinnedApps != nil
    }

    enum CodingKeys: String, CodingKey {
        case isVisible
        case groupByApp
        case showClock
        case clockMode
        case dateTimeWidget
        case showWindowCounts
        case taskbarHeight
        case minimumItemWidth
        case maximumItemWidth
        case itemSpacing
        case backgroundOpacity
        case avoidOverlappingWindows
        case autoHide
        case revealAnimation
        case revealAnimationDuration
        case pinnedApps
    }

    init(
        isVisible: Bool? = nil,
        groupByApp: Bool? = nil,
        clockMode: ClockMode? = nil,
        dateTimeWidget: DateTimeWidgetSettings? = nil,
        showWindowCounts: Bool? = nil,
        taskbarHeight: Double? = nil,
        minimumItemWidth: Double? = nil,
        maximumItemWidth: Double? = nil,
        itemSpacing: Double? = nil,
        backgroundOpacity: Double? = nil,
        avoidOverlappingWindows: Bool? = nil,
        autoHide: Bool? = nil,
        revealAnimation: RevealAnimation? = nil,
        revealAnimationDuration: Double? = nil,
        pinnedApps: [PinnedApp]? = nil
    ) {
        self.isVisible = isVisible
        self.groupByApp = groupByApp
        self.clockMode = clockMode
        self.dateTimeWidget = dateTimeWidget
        self.showWindowCounts = showWindowCounts
        self.taskbarHeight = taskbarHeight
        self.minimumItemWidth = minimumItemWidth
        self.maximumItemWidth = maximumItemWidth
        self.itemSpacing = itemSpacing
        self.backgroundOpacity = backgroundOpacity
        self.avoidOverlappingWindows = avoidOverlappingWindows
        self.autoHide = autoHide
        self.revealAnimation = revealAnimation
        self.revealAnimationDuration = revealAnimationDuration
        self.pinnedApps = pinnedApps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible)
        groupByApp = try container.decodeIfPresent(Bool.self, forKey: .groupByApp)
        if let clockMode = try container.decodeIfPresent(ClockMode.self, forKey: .clockMode) {
            self.clockMode = clockMode
        } else if let oldShowClock = try container.decodeIfPresent(Bool.self, forKey: .showClock) {
            self.clockMode = oldShowClock ? .time : .hidden
        } else {
            self.clockMode = nil
        }
        dateTimeWidget = try container.decodeIfPresent(DateTimeWidgetSettings.self, forKey: .dateTimeWidget)
        showWindowCounts = try container.decodeIfPresent(Bool.self, forKey: .showWindowCounts)
        taskbarHeight = try container.decodeIfPresent(Double.self, forKey: .taskbarHeight)
        minimumItemWidth = try container.decodeIfPresent(Double.self, forKey: .minimumItemWidth)
        maximumItemWidth = try container.decodeIfPresent(Double.self, forKey: .maximumItemWidth)
        itemSpacing = try container.decodeIfPresent(Double.self, forKey: .itemSpacing)
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity)
        avoidOverlappingWindows = try container.decodeIfPresent(Bool.self, forKey: .avoidOverlappingWindows)
        autoHide = try container.decodeIfPresent(Bool.self, forKey: .autoHide)
        revealAnimation = try container.decodeIfPresent(RevealAnimation.self, forKey: .revealAnimation)
        revealAnimationDuration = try container.decodeIfPresent(Double.self, forKey: .revealAnimationDuration)
        pinnedApps = try container.decodeIfPresent([PinnedApp].self, forKey: .pinnedApps)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(isVisible, forKey: .isVisible)
        try container.encodeIfPresent(groupByApp, forKey: .groupByApp)
        try container.encodeIfPresent(clockMode, forKey: .clockMode)
        try container.encodeIfPresent(dateTimeWidget, forKey: .dateTimeWidget)
        try container.encodeIfPresent(showWindowCounts, forKey: .showWindowCounts)
        try container.encodeIfPresent(taskbarHeight, forKey: .taskbarHeight)
        try container.encodeIfPresent(minimumItemWidth, forKey: .minimumItemWidth)
        try container.encodeIfPresent(maximumItemWidth, forKey: .maximumItemWidth)
        try container.encodeIfPresent(itemSpacing, forKey: .itemSpacing)
        try container.encodeIfPresent(backgroundOpacity, forKey: .backgroundOpacity)
        try container.encodeIfPresent(avoidOverlappingWindows, forKey: .avoidOverlappingWindows)
        try container.encodeIfPresent(autoHide, forKey: .autoHide)
        try container.encodeIfPresent(revealAnimation, forKey: .revealAnimation)
        try container.encodeIfPresent(revealAnimationDuration, forKey: .revealAnimationDuration)
        try container.encodeIfPresent(pinnedApps, forKey: .pinnedApps)
    }
}

struct TaskbarPreferences: Codable, Equatable {
    var startAtLogin: Bool
    var general: TaskbarSettingValues
    var monitorOverrides: [String: TaskbarMonitorOverrides]

    static var defaults: TaskbarPreferences {
        TaskbarPreferences(general: .defaults, monitorOverrides: [:], startAtLogin: true)
    }

    enum CodingKeys: String, CodingKey {
        case startAtLogin
        case general
        case monitorOverrides
    }

    init(general: TaskbarSettingValues, monitorOverrides: [String: TaskbarMonitorOverrides], startAtLogin: Bool = true) {
        self.startAtLogin = startAtLogin
        self.general = general
        self.monitorOverrides = monitorOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startAtLogin = try container.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? true
        general = try container.decodeIfPresent(TaskbarSettingValues.self, forKey: .general) ?? .defaults
        monitorOverrides = try container.decodeIfPresent([String: TaskbarMonitorOverrides].self, forKey: .monitorOverrides) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startAtLogin, forKey: .startAtLogin)
        try container.encode(general, forKey: .general)
        try container.encode(monitorOverrides, forKey: .monitorOverrides)
    }

    func resolvedValues(for screenID: UInt32) -> TaskbarSettingValues {
        guard let override = monitorOverrides[String(screenID)] else {
            return clamped(general)
        }

        var values = general
        if let isVisible = override.isVisible {
            values.isVisible = isVisible
        }
        if let groupByApp = override.groupByApp {
            values.groupByApp = groupByApp
        }
        if let dateTimeWidget = override.dateTimeWidget {
            values.dateTimeWidget = dateTimeWidget
        } else if let clockMode = override.clockMode {
            values.clockMode = clockMode
        }
        if let showWindowCounts = override.showWindowCounts {
            values.showWindowCounts = showWindowCounts
        }
        if let taskbarHeight = override.taskbarHeight {
            values.taskbarHeight = taskbarHeight
        }
        if let minimumItemWidth = override.minimumItemWidth {
            values.minimumItemWidth = minimumItemWidth
        }
        if let maximumItemWidth = override.maximumItemWidth {
            values.maximumItemWidth = maximumItemWidth
        }
        if let itemSpacing = override.itemSpacing {
            values.itemSpacing = itemSpacing
        }
        if let backgroundOpacity = override.backgroundOpacity {
            values.backgroundOpacity = backgroundOpacity
        }
        if let avoidOverlappingWindows = override.avoidOverlappingWindows {
            values.avoidOverlappingWindows = avoidOverlappingWindows
        }
        if let autoHide = override.autoHide {
            values.autoHide = autoHide
        }
        if let revealAnimation = override.revealAnimation {
            values.revealAnimation = revealAnimation
        }
        if let revealAnimationDuration = override.revealAnimationDuration {
            values.revealAnimationDuration = revealAnimationDuration
        }
        if let pinnedApps = override.pinnedApps {
            values.pinnedApps = pinnedApps
        }
        return clamped(values)
    }

    private func clamped(_ values: TaskbarSettingValues) -> TaskbarSettingValues {
        var copy = values
        copy.clamp()
        return copy
    }
}

final class TaskbarSettings {
    private let defaults: UserDefaults
    private let key = "taskbarPreferences.v1"

    var onChange: (() -> Void)?
    private(set) var preferences: TaskbarPreferences {
        didSet {
            persist()
            onChange?()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferences = Self.load(from: defaults, key: key)
    }

    func values(for screenID: UInt32) -> TaskbarSettingValues {
        preferences.resolvedValues(for: screenID)
    }

    func overrides(for screenID: UInt32) -> TaskbarMonitorOverrides {
        preferences.monitorOverrides[String(screenID)] ?? TaskbarMonitorOverrides()
    }

    func updateGeneral(_ transform: (inout TaskbarSettingValues) -> Void) {
        transform(&preferences.general)
        preferences.general.clamp()
    }

    func updateOverrides(for screenID: UInt32, _ transform: (inout TaskbarMonitorOverrides) -> Void) {
        let key = String(screenID)
        var override = preferences.monitorOverrides[key] ?? TaskbarMonitorOverrides()
        transform(&override)
        if let height = override.taskbarHeight {
            override.taskbarHeight = TaskbarSettingValues.clampedTaskbarHeight(height)
        }
        if let width = override.minimumItemWidth {
            override.minimumItemWidth = TaskbarSettingValues.clampedMinimumItemWidth(width)
        }
        if let width = override.maximumItemWidth {
            override.maximumItemWidth = TaskbarSettingValues.clampedMaximumItemWidth(width)
        }
        if let minWidth = override.minimumItemWidth, let maxWidth = override.maximumItemWidth, maxWidth < minWidth {
            override.maximumItemWidth = minWidth
        }
        if let itemSpacing = override.itemSpacing {
            override.itemSpacing = TaskbarSettingValues.clampedItemSpacing(itemSpacing)
        }
        if let opacity = override.backgroundOpacity {
            override.backgroundOpacity = TaskbarSettingValues.clampedBackgroundOpacity(opacity)
        }
        if let duration = override.revealAnimationDuration {
            override.revealAnimationDuration = TaskbarSettingValues.clampedRevealAnimationDuration(duration)
        }

        if override.hasAnyOverride {
            preferences.monitorOverrides[key] = override
        } else {
            preferences.monitorOverrides.removeValue(forKey: key)
        }
    }

    func isPinned(_ app: PinnedApp, for screenID: UInt32? = nil) -> Bool {
        let apps = screenID.map { values(for: $0).pinnedApps } ?? preferences.general.pinnedApps
        return apps.contains(where: { $0.identity == app.identity })
    }

    func pin(_ app: PinnedApp, for screenID: UInt32? = nil) {
        if let screenID {
            updateOverrides(for: screenID) { override in
                var apps = override.pinnedApps ?? values(for: screenID).pinnedApps
                guard !apps.contains(where: { $0.identity == app.identity }) else { return }
                apps.append(app)
                override.pinnedApps = apps
            }
        } else {
            updateGeneral { values in
                guard !values.pinnedApps.contains(where: { $0.identity == app.identity }) else { return }
                values.pinnedApps.append(app)
            }
        }
    }

    func unpin(_ app: PinnedApp, for screenID: UInt32? = nil) {
        if let screenID {
            updateOverrides(for: screenID) { override in
                var apps = override.pinnedApps ?? values(for: screenID).pinnedApps
                apps.removeAll { $0.identity == app.identity }
                override.pinnedApps = apps
            }
        } else {
            updateGeneral { values in
                values.pinnedApps.removeAll { $0.identity == app.identity }
            }
        }
    }

    func movePinnedApp(movingIdentity: String, beforeIdentity: String?, for screenID: UInt32? = nil) {
        if let screenID {
            updateOverrides(for: screenID) { override in
                let apps = override.pinnedApps ?? values(for: screenID).pinnedApps
                override.pinnedApps = movedPinnedApps(apps, movingIdentity: movingIdentity, beforeIdentity: beforeIdentity)
            }
        } else {
            updateGeneral { values in
                values.pinnedApps = movedPinnedApps(values.pinnedApps, movingIdentity: movingIdentity, beforeIdentity: beforeIdentity)
            }
        }
    }

    func setStartAtLogin(_ enabled: Bool) {
        preferences.startAtLogin = enabled
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(preferences)
            defaults.set(data, forKey: key)
        } catch {
            log("failed to save settings: \(error)")
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> TaskbarPreferences {
        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }

        do {
            var preferences = try JSONDecoder().decode(TaskbarPreferences.self, from: data)
            preferences.general.clamp()
            return preferences
        } catch {
            log("failed to load settings: \(error)")
            return .defaults
        }
    }
}

func movedPinnedApps(_ apps: [PinnedApp], movingIdentity: String, beforeIdentity: String?) -> [PinnedApp] {
    guard let movingIndex = apps.firstIndex(where: { $0.identity == movingIdentity }) else {
        return apps
    }

    var result = apps
    let moving = result.remove(at: movingIndex)
    guard let beforeIdentity,
          let destinationIndex = result.firstIndex(where: { $0.identity == beforeIdentity })
    else {
        result.append(moving)
        return result
    }

    result.insert(moving, at: destinationIndex)
    return result
}
