import AppKit

enum TaskbarWidgetID: String, Equatable {
    case stats
    case battery
    case controlCenterLights
    case dateTime
}

protocol TaskbarWidgetPlugin {
    var id: TaskbarWidgetID { get }
    var title: String { get }
    var symbolName: String { get }

    func isEnabled(in values: TaskbarSettingValues) -> Bool
    func minimumWidth(in values: TaskbarSettingValues, height: CGFloat) -> CGFloat
    func preferredWidth(in values: TaskbarSettingValues, height: CGFloat, availableWidth: CGFloat) -> CGFloat
    func draw(in rect: NSRect, values: TaskbarSettingValues, date: Date)
}

enum DateTimeWidgetMetrics {
    private final class CachedWidths: NSObject {
        let compact: CGFloat
        let expanded: CGFloat

        init(compact: CGFloat, expanded: CGFloat) {
            self.compact = compact
            self.expanded = expanded
        }
    }

    private final class CachedReferenceDates: NSObject {
        let dates: [Date]

        init(dates: [Date]) {
            self.dates = dates
        }
    }

    static let defaultFontSize: CGFloat = 13
    // Widget spacing is controlled by the taskbar setting, so the measured
    // clock width should not add another invisible gap at its leading edge.
    static let horizontalPadding: CGFloat = 0
    private static let widthCache = NSCache<NSString, CachedWidths>()
    private static let referenceDateCache = NSCache<NSString, CachedReferenceDates>()
    private static let referenceTimeZone = TimeZone(secondsFromGMT: 0) ?? .current
    // A 400-day representative cycle covers every weekday plus a full year of
    // localized month and one/two-digit day variants.
    private static let referenceDays: [Date] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = referenceTimeZone
        guard let start = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)) else {
            return []
        }
        return (0..<400).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: dayOffset, to: start)
        }
    }()

    static func fontSize(forHeight height: CGFloat) -> CGFloat {
        min(defaultFontSize, max(10, height - 9))
    }

    static func compactWidth(
        for settings: DateTimeWidgetSettings,
        locale: Locale = .current,
        fontSize: CGFloat = defaultFontSize
    ) -> CGFloat {
        widths(for: settings, locale: locale, fontSize: fontSize).compact
    }

    static func expandedWidth(
        for settings: DateTimeWidgetSettings,
        locale: Locale = .current,
        fontSize: CGFloat = defaultFontSize
    ) -> CGFloat {
        widths(for: settings, locale: locale, fontSize: fontSize).expanded
    }

    private static func widths(
        for settings: DateTimeWidgetSettings,
        locale: Locale,
        fontSize: CGFloat
    ) -> CachedWidths {
        guard settings.isEnabled else {
            return CachedWidths(compact: 0, expanded: 0)
        }

        let cacheKey = [
            settings.showDayOfWeek ? "1" : "0",
            settings.showSeconds ? "1" : "0",
            settings.use24HourClock ? "1" : "0",
            locale.identifier,
            String(Double(fontSize).bitPattern)
        ].joined(separator: "|") as NSString
        if let cached = widthCache.object(forKey: cacheKey) {
            return cached
        }

        var compactSettings = settings
        compactSettings.dateDisplay = .never
        var expandedSettings = settings
        expandedSettings.dateDisplay = .always
        let font = NSFont.menuBarFont(ofSize: fontSize)
        let referenceDateTimes = referenceDateTimes(for: settings, locale: locale, font: font)
        let compact = measuredWidth(
            for: compactSettings,
            referenceDateTimes: referenceDateTimes,
            locale: locale,
            font: font
        )
        let expanded = measuredWidth(
            for: expandedSettings,
            referenceDateTimes: referenceDateTimes,
            locale: locale,
            font: font
        )
        let measured = CachedWidths(compact: compact, expanded: expanded)
        widthCache.setObject(measured, forKey: cacheKey)
        return measured
    }

    private static func measuredWidth(
        for settings: DateTimeWidgetSettings,
        referenceDateTimes: [Date],
        locale: Locale,
        font: NSFont
    ) -> CGFloat {
        let textWidth = referenceDateTimes.map { date in
            let text = dateTimeWidgetText(
                settings: settings,
                date: date,
                availableWidth: .greatestFiniteMagnitude,
                locale: locale,
                timeZone: referenceTimeZone
            )
            return ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }.max() ?? 0
        return textWidth + horizontalPadding
    }

    private static func referenceDateTimes(
        for settings: DateTimeWidgetSettings,
        locale: Locale,
        font: NSFont
    ) -> [Date] {
        widestReferenceDates(for: settings, locale: locale, font: font).flatMap { date in
            // Exercise every numeric hour and both day periods without formatting
            // the full 400-day set through fresh DateFormatter instances.
            (0..<24).map { hour in
                date.addingTimeInterval(TimeInterval(hour * 3_600 + 45 * 60 + 33))
            }
        }
    }

    private static func widestReferenceDates(
        for settings: DateTimeWidgetSettings,
        locale: Locale,
        font: NSFont
    ) -> [Date] {
        let cacheKey = [
            settings.showDayOfWeek ? "1" : "0",
            locale.identifier,
            String(Double(font.pointSize).bitPattern)
        ].joined(separator: "|") as NSString
        if let cached = referenceDateCache.object(forKey: cacheKey) {
            return cached.dates
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = referenceTimeZone
        formatter.dateFormat = dateTimeWidgetDateFormat(for: settings)
        // Keep several widest real dates so final pipeline measurement also
        // covers any small shaping differences at the date/time boundary.
        let dates = referenceDays
            .map { date in
                let text = formatter.string(from: date)
                let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
                return (date: date, width: width)
            }
            .sorted { lhs, rhs in
                if lhs.width == rhs.width {
                    return lhs.date < rhs.date
                }
                return lhs.width > rhs.width
            }
            .prefix(4)
            .map(\.date)
        let measured = CachedReferenceDates(dates: dates)
        referenceDateCache.setObject(measured, forKey: cacheKey)
        return dates
    }
}

struct DateTimeWidgetPlugin: TaskbarWidgetPlugin {
    let id: TaskbarWidgetID = .dateTime
    let title = "Date & Time"
    let symbolName = "clock"

    func isEnabled(in values: TaskbarSettingValues) -> Bool {
        values.dateTimeWidget.isEnabled
    }

    func minimumWidth(in values: TaskbarSettingValues, height: CGFloat) -> CGFloat {
        guard values.dateTimeWidget.isEnabled else { return 0 }
        let fontSize = DateTimeWidgetMetrics.fontSize(forHeight: height)
        if values.dateTimeWidget.dateDisplay == .always {
            return DateTimeWidgetMetrics.expandedWidth(
                for: values.dateTimeWidget,
                fontSize: fontSize
            )
        }
        return DateTimeWidgetMetrics.compactWidth(
            for: values.dateTimeWidget,
            fontSize: fontSize
        )
    }

    func preferredWidth(in values: TaskbarSettingValues, height: CGFloat, availableWidth: CGFloat) -> CGFloat {
        guard values.dateTimeWidget.isEnabled else { return 0 }

        let fontSize = DateTimeWidgetMetrics.fontSize(forHeight: height)
        let compact = DateTimeWidgetMetrics.compactWidth(
            for: values.dateTimeWidget,
            fontSize: fontSize
        )
        let expanded = DateTimeWidgetMetrics.expandedWidth(
            for: values.dateTimeWidget,
            fontSize: fontSize
        )
        switch values.dateTimeWidget.dateDisplay {
        case .never:
            return compact
        case .whenSpaceAllows:
            return availableWidth >= expanded ? expanded : compact
        case .always:
            return min(expanded, max(compact, availableWidth))
        }
    }

    func draw(in rect: NSRect, values: TaskbarSettingValues, date: Date = Date()) {
        let fontSize = DateTimeWidgetMetrics.fontSize(forHeight: rect.height)
        let text = dateTimeWidgetText(
            settings: values.dateTimeWidget,
            date: date,
            availableWidth: rect.width,
            fontSize: fontSize
        )
        guard !text.isEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail

        let font = NSFont.menuBarFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1.0),
            .paragraphStyle: paragraph
        ]
        let textHeight = ceil(font.ascender - font.descender)
        let textRect = NSRect(
            x: rect.minX,
            y: rect.midY - textHeight / 2 - 1,
            width: rect.width,
            height: textHeight + 2
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }
}

func activeTaskbarWidgets(for values: TaskbarSettingValues) -> [any TaskbarWidgetPlugin] {
    installedTaskbarWidgetPlugins().filter { $0.isEnabled(in: values) }
}

func installedTaskbarWidgetPlugins() -> [any TaskbarWidgetPlugin] {
    [
        StatsWidgetPlugin(),
        BatteryWidgetPlugin(),
        ControlCenterLightsWidgetPlugin(),
        DateTimeWidgetPlugin()
    ]
}

func installedTaskbarWidgetIDs() -> [TaskbarWidgetID] {
    installedTaskbarWidgetPlugins().map(\.id)
}

func taskbarWidgetPlugin(id: TaskbarWidgetID) -> (any TaskbarWidgetPlugin)? {
    installedTaskbarWidgetPlugins().first { $0.id == id }
}

func dateTimeWidgetText(
    settings: DateTimeWidgetSettings,
    date: Date,
    availableWidth: CGFloat,
    fontSize: CGFloat = DateTimeWidgetMetrics.defaultFontSize,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    guard settings.isEnabled else { return "" }

    let timeFormat = dateTimeWidgetTimeFormat(for: settings)
    let timeText = formattedDate(date, format: timeFormat, locale: locale, timeZone: timeZone)

    let shouldShowDate: Bool
    switch settings.dateDisplay {
    case .never:
        shouldShowDate = false
    case .whenSpaceAllows:
        shouldShowDate = availableWidth >= DateTimeWidgetMetrics.expandedWidth(
            for: settings,
            locale: locale,
            fontSize: fontSize
        )
    case .always:
        shouldShowDate = true
    }

    guard shouldShowDate else { return timeText }

    let dateFormat = dateTimeWidgetDateFormat(for: settings)
    let dateText = formattedDate(date, format: dateFormat, locale: locale, timeZone: timeZone)
    return "\(dateText) \(timeText)"
}

private func dateTimeWidgetTimeFormat(for settings: DateTimeWidgetSettings) -> String {
    if settings.use24HourClock {
        return settings.showSeconds ? "HH:mm:ss" : "HH:mm"
    }
    return settings.showSeconds ? "h:mm:ss a" : "h:mm a"
}

private func dateTimeWidgetDateFormat(for settings: DateTimeWidgetSettings) -> String {
    settings.showDayOfWeek ? "EEE MMM d" : "MMM d"
}

final class TaskbarDateFormatterCache {
    private struct Key: Hashable {
        let format: String
        let localeIdentifier: String
        let timeZoneIdentifier: String
    }

    private let lock = NSLock()
    private let makeFormatter: () -> DateFormatter
    private var formatters: [Key: DateFormatter] = [:]

    init(makeFormatter: @escaping () -> DateFormatter = { DateFormatter() }) {
        self.makeFormatter = makeFormatter
    }

    func string(from date: Date, format: String, locale: Locale, timeZone: TimeZone) -> String {
        let key = Key(
            format: format,
            localeIdentifier: locale.identifier,
            timeZoneIdentifier: timeZone.identifier
        )
        lock.lock()
        defer { lock.unlock() }

        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            let created = makeFormatter()
            created.locale = locale
            created.timeZone = timeZone
            created.dateFormat = format
            formatters[key] = created
            formatter = created
        }
        return formatter.string(from: date)
    }
}

private let taskbarDateFormatterCache = TaskbarDateFormatterCache()

private func formattedDate(_ date: Date, format: String, locale: Locale, timeZone: TimeZone) -> String {
    taskbarDateFormatterCache.string(from: date, format: format, locale: locale, timeZone: timeZone)
}
