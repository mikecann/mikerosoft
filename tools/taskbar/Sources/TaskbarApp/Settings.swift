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

enum StatsMemoryDisplay: String, Codable, CaseIterable, Equatable {
    case percent
    case pie

    var label: String {
        switch self {
        case .percent:
            return "Percentage"
        case .pie:
            return "Pie chart"
        }
    }
}

enum StatsCPUDisplay: String, Codable, CaseIterable, Equatable {
    case percentage
    case history
    case perCPU

    var label: String {
        switch self {
        case .percentage:
            return "Percentage"
        case .history:
            return "History"
        case .perCPU:
            return "Per CPU"
        }
    }
}

struct StatsCPUCoreColors: Codable, Equatable {
    var superCore: String
    var performance: String
    var efficiency: String

    static var defaults: StatsCPUCoreColors {
        StatsCPUCoreColors(
            superCore: "#FF9230",
            performance: "#0091FF",
            efficiency: "#00D2E0"
        )
    }

    enum CodingKeys: String, CodingKey {
        case superCore
        case performance
        case efficiency
    }

    init(superCore: String, performance: String, efficiency: String) {
        self.superCore = superCore
        self.performance = performance
        self.efficiency = efficiency
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.defaults
        let container = try decoder.container(keyedBy: CodingKeys.self)
        superCore = try container.decodeIfPresent(String.self, forKey: .superCore) ?? defaults.superCore
        performance = try container.decodeIfPresent(String.self, forKey: .performance) ?? defaults.performance
        efficiency = try container.decodeIfPresent(String.self, forKey: .efficiency) ?? defaults.efficiency
    }
}

struct StatsWidgetSettings: Codable, Equatable {
    var isEnabled: Bool
    var showCPU: Bool
    var showGPU: Bool
    var showMemory: Bool
    var showNetwork: Bool
    var cpuDisplay: StatsCPUDisplay
    var memoryDisplay: StatsMemoryDisplay
    var cpuCoreColors: StatsCPUCoreColors

    // Keep the old API and JSON field working so existing settings migrate
    // cleanly. A graph is now either the aggregate history or live per-CPU bars.
    var showMiniGraph: Bool {
        get { cpuDisplay != .percentage }
        set {
            if newValue {
                if cpuDisplay == .percentage {
                    cpuDisplay = .perCPU
                }
            } else {
                cpuDisplay = .percentage
            }
        }
    }

    static var defaults: StatsWidgetSettings {
        StatsWidgetSettings(
            isEnabled: true,
            showCPU: true,
            showGPU: true,
            showMemory: true,
            showNetwork: true,
            showMiniGraph: true,
            memoryDisplay: .percent,
            cpuDisplay: .perCPU
        )
    }

    var hasVisibleMetrics: Bool {
        showCPU || showGPU || showMemory || showNetwork
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case showCPU
        case showGPU
        case showMemory
        case showNetwork
        case showMiniGraph
        case cpuDisplay
        case memoryDisplay
        case cpuCoreColors
    }

    init(
        isEnabled: Bool,
        showCPU: Bool,
        showGPU: Bool = true,
        showMemory: Bool,
        showNetwork: Bool,
        showMiniGraph: Bool,
        memoryDisplay: StatsMemoryDisplay = .percent,
        cpuDisplay: StatsCPUDisplay? = nil,
        cpuCoreColors: StatsCPUCoreColors = .defaults
    ) {
        self.isEnabled = isEnabled
        self.showCPU = showCPU
        self.showGPU = showGPU
        self.showMemory = showMemory
        self.showNetwork = showNetwork
        self.memoryDisplay = memoryDisplay
        self.cpuDisplay = cpuDisplay ?? (showMiniGraph ? .perCPU : .percentage)
        self.cpuCoreColors = cpuCoreColors
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.defaults
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        showCPU = try container.decodeIfPresent(Bool.self, forKey: .showCPU) ?? defaults.showCPU
        showGPU = try container.decodeIfPresent(Bool.self, forKey: .showGPU) ?? defaults.showGPU
        showMemory = try container.decodeIfPresent(Bool.self, forKey: .showMemory) ?? defaults.showMemory
        showNetwork = try container.decodeIfPresent(Bool.self, forKey: .showNetwork) ?? defaults.showNetwork
        let legacyShowMiniGraph = try container.decodeIfPresent(Bool.self, forKey: .showMiniGraph) ?? defaults.showMiniGraph
        cpuDisplay = try container.decodeIfPresent(StatsCPUDisplay.self, forKey: .cpuDisplay)
            ?? (legacyShowMiniGraph ? .perCPU : .percentage)
        memoryDisplay = try container.decodeIfPresent(StatsMemoryDisplay.self, forKey: .memoryDisplay) ?? defaults.memoryDisplay
        cpuCoreColors = try container.decodeIfPresent(StatsCPUCoreColors.self, forKey: .cpuCoreColors)
            ?? defaults.cpuCoreColors
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(showCPU, forKey: .showCPU)
        try container.encode(showGPU, forKey: .showGPU)
        try container.encode(showMemory, forKey: .showMemory)
        try container.encode(showNetwork, forKey: .showNetwork)
        try container.encode(showMiniGraph, forKey: .showMiniGraph)
        try container.encode(cpuDisplay, forKey: .cpuDisplay)
        try container.encode(memoryDisplay, forKey: .memoryDisplay)
        try container.encode(cpuCoreColors, forKey: .cpuCoreColors)
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
    var dateTimeWidget: DateTimeWidgetSettings
    var statsWidget: StatsWidgetSettings
    var taskbarHeight: Double
    var minimumItemWidth: Double
    var maximumItemWidth: Double
    var itemSpacing: Double
    var backgroundOpacity: Double
    var avoidOverlappingWindows: Bool
    var showMinimizedWindows: Bool
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
            clockMode: .time,
            dateTimeWidget: .defaults,
            statsWidget: .defaults,
            taskbarHeight: defaultTaskbarHeight,
            minimumItemWidth: defaultMinimumItemWidth,
            maximumItemWidth: defaultMaximumItemWidth,
            itemSpacing: defaultItemSpacing,
            backgroundOpacity: defaultBackgroundOpacity,
            avoidOverlappingWindows: true,
            showMinimizedWindows: true,
            autoHide: false,
            revealAnimation: .ease,
            revealAnimationDuration: defaultRevealAnimationDuration,
            pinnedApps: []
        )
    }

    enum CodingKeys: String, CodingKey {
        case isVisible
        case showClock
        case clockMode
        case dateTimeWidget
        case statsWidget
        case taskbarHeight
        case minimumItemWidth
        case maximumItemWidth
        case itemSpacing
        case backgroundOpacity
        case avoidOverlappingWindows
        case showMinimizedWindows
        case autoHide
        case revealAnimation
        case revealAnimationDuration
        case pinnedApps
    }

    init(
        isVisible: Bool,
        clockMode: ClockMode,
        dateTimeWidget: DateTimeWidgetSettings? = nil,
        statsWidget: StatsWidgetSettings? = nil,
        taskbarHeight: Double,
        minimumItemWidth: Double,
        maximumItemWidth: Double,
        itemSpacing: Double,
        backgroundOpacity: Double,
        avoidOverlappingWindows: Bool,
        showMinimizedWindows: Bool = true,
        autoHide: Bool,
        revealAnimation: RevealAnimation,
        revealAnimationDuration: Double,
        pinnedApps: [PinnedApp]
    ) {
        self.isVisible = isVisible
        self.dateTimeWidget = dateTimeWidget ?? DateTimeWidgetSettings.legacy(clockMode: clockMode)
        self.statsWidget = statsWidget ?? .defaults
        self.taskbarHeight = taskbarHeight
        self.minimumItemWidth = minimumItemWidth
        self.maximumItemWidth = maximumItemWidth
        self.itemSpacing = itemSpacing
        self.backgroundOpacity = backgroundOpacity
        self.avoidOverlappingWindows = avoidOverlappingWindows
        self.showMinimizedWindows = showMinimizedWindows
        self.autoHide = autoHide
        self.revealAnimation = revealAnimation
        self.revealAnimationDuration = revealAnimationDuration
        self.pinnedApps = pinnedApps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        if let dateTimeWidget = try container.decodeIfPresent(DateTimeWidgetSettings.self, forKey: .dateTimeWidget) {
            self.dateTimeWidget = dateTimeWidget
        } else if let clockMode = try container.decodeIfPresent(ClockMode.self, forKey: .clockMode) {
            self.dateTimeWidget = DateTimeWidgetSettings.legacy(clockMode: clockMode)
        } else {
            let oldShowClock = try container.decodeIfPresent(Bool.self, forKey: .showClock) ?? true
            self.dateTimeWidget = DateTimeWidgetSettings.legacy(clockMode: oldShowClock ? .time : .hidden)
        }
        statsWidget = try container.decodeIfPresent(StatsWidgetSettings.self, forKey: .statsWidget) ?? .defaults
        taskbarHeight = try container.decodeIfPresent(Double.self, forKey: .taskbarHeight) ?? Self.defaultTaskbarHeight
        minimumItemWidth = try container.decodeIfPresent(Double.self, forKey: .minimumItemWidth) ?? Self.defaultMinimumItemWidth
        maximumItemWidth = try container.decodeIfPresent(Double.self, forKey: .maximumItemWidth) ?? Self.defaultMaximumItemWidth
        itemSpacing = try container.decodeIfPresent(Double.self, forKey: .itemSpacing) ?? Self.defaultItemSpacing
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? Self.defaultBackgroundOpacity
        avoidOverlappingWindows = try container.decodeIfPresent(Bool.self, forKey: .avoidOverlappingWindows) ?? true
        showMinimizedWindows = try container.decodeIfPresent(Bool.self, forKey: .showMinimizedWindows) ?? true
        autoHide = try container.decodeIfPresent(Bool.self, forKey: .autoHide) ?? false
        revealAnimation = try container.decodeIfPresent(RevealAnimation.self, forKey: .revealAnimation) ?? .ease
        revealAnimationDuration = try container.decodeIfPresent(Double.self, forKey: .revealAnimationDuration) ?? Self.defaultRevealAnimationDuration
        pinnedApps = try container.decodeIfPresent([PinnedApp].self, forKey: .pinnedApps) ?? []
        clamp()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(dateTimeWidget, forKey: .dateTimeWidget)
        try container.encode(statsWidget, forKey: .statsWidget)
        try container.encode(taskbarHeight, forKey: .taskbarHeight)
        try container.encode(minimumItemWidth, forKey: .minimumItemWidth)
        try container.encode(maximumItemWidth, forKey: .maximumItemWidth)
        try container.encode(itemSpacing, forKey: .itemSpacing)
        try container.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try container.encode(avoidOverlappingWindows, forKey: .avoidOverlappingWindows)
        try container.encode(showMinimizedWindows, forKey: .showMinimizedWindows)
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
    var clockMode: ClockMode?
    var dateTimeWidget: DateTimeWidgetSettings?
    var statsWidget: StatsWidgetSettings?
    var taskbarHeight: Double?
    var minimumItemWidth: Double?
    var maximumItemWidth: Double?
    var itemSpacing: Double?
    var backgroundOpacity: Double?
    var avoidOverlappingWindows: Bool?
    var showMinimizedWindows: Bool?
    var autoHide: Bool?
    var revealAnimation: RevealAnimation?
    var revealAnimationDuration: Double?
    var pinnedApps: [PinnedApp]?

    var hasAnyOverride: Bool {
        isVisible != nil
            || clockMode != nil
            || dateTimeWidget != nil
            || statsWidget != nil
            || taskbarHeight != nil
            || minimumItemWidth != nil
            || maximumItemWidth != nil
            || itemSpacing != nil
            || backgroundOpacity != nil
            || avoidOverlappingWindows != nil
            || showMinimizedWindows != nil
            || autoHide != nil
            || revealAnimation != nil
            || revealAnimationDuration != nil
            || pinnedApps != nil
    }

    enum CodingKeys: String, CodingKey {
        case isVisible
        case showClock
        case clockMode
        case dateTimeWidget
        case statsWidget
        case taskbarHeight
        case minimumItemWidth
        case maximumItemWidth
        case itemSpacing
        case backgroundOpacity
        case avoidOverlappingWindows
        case showMinimizedWindows
        case autoHide
        case revealAnimation
        case revealAnimationDuration
        case pinnedApps
    }

    init(
        isVisible: Bool? = nil,
        clockMode: ClockMode? = nil,
        dateTimeWidget: DateTimeWidgetSettings? = nil,
        statsWidget: StatsWidgetSettings? = nil,
        taskbarHeight: Double? = nil,
        minimumItemWidth: Double? = nil,
        maximumItemWidth: Double? = nil,
        itemSpacing: Double? = nil,
        backgroundOpacity: Double? = nil,
        avoidOverlappingWindows: Bool? = nil,
        showMinimizedWindows: Bool? = nil,
        autoHide: Bool? = nil,
        revealAnimation: RevealAnimation? = nil,
        revealAnimationDuration: Double? = nil,
        pinnedApps: [PinnedApp]? = nil
    ) {
        self.isVisible = isVisible
        self.clockMode = clockMode
        self.dateTimeWidget = dateTimeWidget
        self.statsWidget = statsWidget
        self.taskbarHeight = taskbarHeight
        self.minimumItemWidth = minimumItemWidth
        self.maximumItemWidth = maximumItemWidth
        self.itemSpacing = itemSpacing
        self.backgroundOpacity = backgroundOpacity
        self.avoidOverlappingWindows = avoidOverlappingWindows
        self.showMinimizedWindows = showMinimizedWindows
        self.autoHide = autoHide
        self.revealAnimation = revealAnimation
        self.revealAnimationDuration = revealAnimationDuration
        self.pinnedApps = pinnedApps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible)
        if let clockMode = try container.decodeIfPresent(ClockMode.self, forKey: .clockMode) {
            self.clockMode = clockMode
        } else if let oldShowClock = try container.decodeIfPresent(Bool.self, forKey: .showClock) {
            self.clockMode = oldShowClock ? .time : .hidden
        } else {
            self.clockMode = nil
        }
        dateTimeWidget = try container.decodeIfPresent(DateTimeWidgetSettings.self, forKey: .dateTimeWidget)
        statsWidget = try container.decodeIfPresent(StatsWidgetSettings.self, forKey: .statsWidget)
        taskbarHeight = try container.decodeIfPresent(Double.self, forKey: .taskbarHeight)
        minimumItemWidth = try container.decodeIfPresent(Double.self, forKey: .minimumItemWidth)
        maximumItemWidth = try container.decodeIfPresent(Double.self, forKey: .maximumItemWidth)
        itemSpacing = try container.decodeIfPresent(Double.self, forKey: .itemSpacing)
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity)
        avoidOverlappingWindows = try container.decodeIfPresent(Bool.self, forKey: .avoidOverlappingWindows)
        showMinimizedWindows = try container.decodeIfPresent(Bool.self, forKey: .showMinimizedWindows)
        autoHide = try container.decodeIfPresent(Bool.self, forKey: .autoHide)
        revealAnimation = try container.decodeIfPresent(RevealAnimation.self, forKey: .revealAnimation)
        revealAnimationDuration = try container.decodeIfPresent(Double.self, forKey: .revealAnimationDuration)
        pinnedApps = try container.decodeIfPresent([PinnedApp].self, forKey: .pinnedApps)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(isVisible, forKey: .isVisible)
        try container.encodeIfPresent(clockMode, forKey: .clockMode)
        try container.encodeIfPresent(dateTimeWidget, forKey: .dateTimeWidget)
        try container.encodeIfPresent(statsWidget, forKey: .statsWidget)
        try container.encodeIfPresent(taskbarHeight, forKey: .taskbarHeight)
        try container.encodeIfPresent(minimumItemWidth, forKey: .minimumItemWidth)
        try container.encodeIfPresent(maximumItemWidth, forKey: .maximumItemWidth)
        try container.encodeIfPresent(itemSpacing, forKey: .itemSpacing)
        try container.encodeIfPresent(backgroundOpacity, forKey: .backgroundOpacity)
        try container.encodeIfPresent(avoidOverlappingWindows, forKey: .avoidOverlappingWindows)
        try container.encodeIfPresent(showMinimizedWindows, forKey: .showMinimizedWindows)
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
        if let dateTimeWidget = override.dateTimeWidget {
            values.dateTimeWidget = dateTimeWidget
        } else if let clockMode = override.clockMode {
            values.clockMode = clockMode
        }
        if let statsWidget = override.statsWidget {
            values.statsWidget = statsWidget
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
        if let showMinimizedWindows = override.showMinimizedWindows {
            values.showMinimizedWindows = showMinimizedWindows
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

protocol TaskbarSettingsStoring {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
}

struct UserDefaultsTaskbarSettingsStore: TaskbarSettingsStoring {
    let defaults: UserDefaults

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ data: Data, forKey key: String) {
        defaults.set(data, forKey: key)
    }
}

final class TaskbarSettingsChangeObservation {
    fileprivate let id: UUID
    private weak var settings: TaskbarSettings?

    fileprivate init(id: UUID, settings: TaskbarSettings) {
        self.id = id
        self.settings = settings
    }

    func cancel() {
        settings?.removeChangeObserver(id: id)
        settings = nil
    }

    deinit {
        cancel()
    }
}

final class TaskbarSettings {
    private let store: TaskbarSettingsStoring
    private let persistenceDelay: TimeInterval
    private let key = "taskbarPreferences.v1"
    private var pendingPersistenceWorkItem: DispatchWorkItem?
    private var persistenceGeneration = 0
    private var changeObservers: [UUID: () -> Void] = [:]
    private var suppressedChangeObservers: [UUID: Int] = [:]

    var onStartAtLoginChange: ((Bool) -> Void)?
    private(set) var preferences: TaskbarPreferences

    convenience init(defaults: UserDefaults = .standard) {
        self.init(store: UserDefaultsTaskbarSettingsStore(defaults: defaults))
    }

    init(store: TaskbarSettingsStoring, persistenceDelay: TimeInterval = 0.25) {
        self.store = store
        self.persistenceDelay = persistenceDelay
        self.preferences = Self.load(from: store, key: key)
    }

    func observeChanges(_ observer: @escaping () -> Void) -> TaskbarSettingsChangeObservation {
        let id = UUID()
        changeObservers[id] = observer
        return TaskbarSettingsChangeObservation(id: id, settings: self)
    }

    func performChanges(
        suppressing observer: TaskbarSettingsChangeObservation,
        _ changes: () -> Void
    ) {
        suppressedChangeObservers[observer.id, default: 0] += 1
        defer {
            let remaining = (suppressedChangeObservers[observer.id] ?? 1) - 1
            if remaining == 0 {
                suppressedChangeObservers.removeValue(forKey: observer.id)
            } else {
                suppressedChangeObservers[observer.id] = remaining
            }
        }
        changes()
    }

    fileprivate func removeChangeObserver(id: UUID) {
        changeObservers.removeValue(forKey: id)
    }

    func values(for screenID: UInt32) -> TaskbarSettingValues {
        preferences.resolvedValues(for: screenID)
    }

    func overrides(for screenID: UInt32) -> TaskbarMonitorOverrides {
        preferences.monitorOverrides[String(screenID)] ?? TaskbarMonitorOverrides()
    }

    func updateGeneral(_ transform: (inout TaskbarSettingValues) -> Void) {
        var general = preferences.general
        transform(&general)
        general.clamp()
        guard general != preferences.general else { return }
        preferences.general = general
        settingsDidChange()
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

        var monitorOverrides = preferences.monitorOverrides
        if override.hasAnyOverride {
            monitorOverrides[key] = override
        } else {
            monitorOverrides.removeValue(forKey: key)
        }
        guard monitorOverrides != preferences.monitorOverrides else { return }
        preferences.monitorOverrides = monitorOverrides
        settingsDidChange()
    }

    func updateDateTimeWidget(for screenID: UInt32, _ transform: (inout DateTimeWidgetSettings) -> Void) {
        let override = overrides(for: screenID)
        if override.dateTimeWidget != nil || override.clockMode != nil {
            var value = values(for: screenID).dateTimeWidget
            transform(&value)
            updateOverrides(for: screenID) { override in
                override.dateTimeWidget = value
                override.clockMode = nil
            }
        } else {
            updateGeneral { values in
                transform(&values.dateTimeWidget)
            }
        }
    }

    func updateStatsWidget(for screenID: UInt32, _ transform: (inout StatsWidgetSettings) -> Void) {
        if overrides(for: screenID).statsWidget != nil {
            updateOverrides(for: screenID) { override in
                var value = override.statsWidget ?? .defaults
                transform(&value)
                override.statsWidget = value
            }
        } else {
            updateGeneral { values in
                transform(&values.statsWidget)
            }
        }
    }

    func pin(_ app: PinnedApp, for screenID: UInt32? = nil) {
        updatePinnedApps(for: screenID) { apps in
            guard !apps.contains(where: { $0.identity == app.identity }) else { return }
            apps.append(app)
        }
    }

    func unpin(_ app: PinnedApp, for screenID: UInt32? = nil) {
        updatePinnedApps(for: screenID) { apps in
            apps.removeAll { $0.identity == app.identity }
        }
    }

    func movePinnedApp(movingIdentity: String, beforeIdentity: String?, for screenID: UInt32? = nil) {
        updatePinnedApps(for: screenID) { apps in
            apps = movedPinnedApps(apps, movingIdentity: movingIdentity, beforeIdentity: beforeIdentity)
        }
    }

    private func updatePinnedApps(for screenID: UInt32?, _ transform: (inout [PinnedApp]) -> Void) {
        if let screenID, overrides(for: screenID).pinnedApps != nil {
            updateOverrides(for: screenID) { override in
                var apps = override.pinnedApps ?? []
                transform(&apps)
                override.pinnedApps = apps
            }
        } else {
            updateGeneral { values in
                transform(&values.pinnedApps)
            }
        }
    }

    func setStartAtLogin(_ enabled: Bool) {
        guard preferences.startAtLogin != enabled else { return }
        preferences.startAtLogin = enabled
        schedulePersistence()
        onStartAtLoginChange?(enabled)
    }

    func flushPendingPersistence() {
        guard let pendingPersistenceWorkItem else { return }
        pendingPersistenceWorkItem.cancel()
        self.pendingPersistenceWorkItem = nil
        persistenceGeneration += 1
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(preferences)
            store.set(data, forKey: key)
        } catch {
            log("failed to save settings: \(error)")
        }
    }

    private func schedulePersistence() {
        pendingPersistenceWorkItem?.cancel()
        persistenceGeneration += 1
        let generation = persistenceGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.persistenceGeneration == generation else { return }
            self.pendingPersistenceWorkItem = nil
            self.persist()
        }
        pendingPersistenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + persistenceDelay, execute: workItem)
    }

    private func settingsDidChange() {
        schedulePersistence()
        changeObservers
            .filter { suppressedChangeObservers[$0.key] == nil }
            .map(\.value)
            .forEach { $0() }
    }

    private static func load(from store: TaskbarSettingsStoring, key: String) -> TaskbarPreferences {
        guard let data = store.data(forKey: key) else {
            return .defaults
        }

        do {
            var preferences = try JSONDecoder().decode(TaskbarPreferences.self, from: data)
            preferences.general.clamp()
            return preferences
        } catch {
            log("failed to load settings: \(error)")
            let backupKey = "\(key).corruptBackup"
            store.set(data, forKey: backupKey)
            log("backed up corrupt settings to \(backupKey)")
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
