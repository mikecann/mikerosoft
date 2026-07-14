import AppKit

enum TaskbarWidgetID: String, Equatable {
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
    static let compactWidth: CGFloat = 54
    static let compactSecondsWidth: CGFloat = 74
    static let expandedWidth: CGFloat = 124
    static let expandedSecondsWidth: CGFloat = 148
    static let expandedThreshold: CGFloat = 100

    static func compactWidth(for settings: DateTimeWidgetSettings) -> CGFloat {
        settings.showSeconds ? compactSecondsWidth : compactWidth
    }

    static func expandedWidth(for settings: DateTimeWidgetSettings) -> CGFloat {
        settings.showSeconds ? expandedSecondsWidth : expandedWidth
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
        if values.dateTimeWidget.dateDisplay == .always {
            return DateTimeWidgetMetrics.expandedWidth(for: values.dateTimeWidget)
        }
        return DateTimeWidgetMetrics.compactWidth(for: values.dateTimeWidget)
    }

    func preferredWidth(in values: TaskbarSettingValues, height: CGFloat, availableWidth: CGFloat) -> CGFloat {
        guard values.dateTimeWidget.isEnabled else { return 0 }

        let compact = DateTimeWidgetMetrics.compactWidth(for: values.dateTimeWidget)
        let expanded = DateTimeWidgetMetrics.expandedWidth(for: values.dateTimeWidget)
        switch values.dateTimeWidget.dateDisplay {
        case .never:
            return compact
        case .whenSpaceAllows:
            return availableWidth >= DateTimeWidgetMetrics.expandedThreshold ? min(expanded, availableWidth) : compact
        case .always:
            return min(expanded, max(compact, availableWidth))
        }
    }

    func draw(in rect: NSRect, values: TaskbarSettingValues, date: Date = Date()) {
        let text = dateTimeWidgetText(
            settings: values.dateTimeWidget,
            date: date,
            availableWidth: rect.width
        )
        guard !text.isEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail

        let fontSize = min(13, max(10, rect.height - 9))
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
    let widgets: [any TaskbarWidgetPlugin] = [
        DateTimeWidgetPlugin()
    ]
    return widgets.filter { $0.isEnabled(in: values) }
}

func dateTimeWidgetText(
    settings: DateTimeWidgetSettings,
    date: Date,
    availableWidth: CGFloat,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    guard settings.isEnabled else { return "" }

    let timeFormat: String
    if settings.use24HourClock {
        timeFormat = settings.showSeconds ? "HH:mm:ss" : "HH:mm"
    } else {
        timeFormat = settings.showSeconds ? "h:mm:ss a" : "h:mm a"
    }

    let timeText = formattedDate(date, format: timeFormat, locale: locale, timeZone: timeZone)

    let shouldShowDate: Bool
    switch settings.dateDisplay {
    case .never:
        shouldShowDate = false
    case .whenSpaceAllows:
        shouldShowDate = availableWidth >= DateTimeWidgetMetrics.expandedThreshold
    case .always:
        shouldShowDate = true
    }

    guard shouldShowDate else { return timeText }

    let dateFormat = settings.showDayOfWeek ? "EEE MMM d" : "MMM d"
    let dateText = formattedDate(date, format: dateFormat, locale: locale, timeZone: timeZone)
    return "\(dateText) \(timeText)"
}

private func formattedDate(_ date: Date, format: String, locale: Locale, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter.string(from: date)
}
