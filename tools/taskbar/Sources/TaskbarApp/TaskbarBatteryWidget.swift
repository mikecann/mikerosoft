import AppKit
import Foundation
import IOKit.ps

struct BatterySnapshot: Equatable {
    let percentage: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    let timeRemainingMinutes: Int?
    let name: String

    init(
        percentage: Int,
        isCharging: Bool,
        isPluggedIn: Bool,
        timeRemainingMinutes: Int?,
        name: String
    ) {
        self.percentage = min(100, max(0, percentage))
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.timeRemainingMinutes = timeRemainingMinutes.flatMap { $0 >= 0 ? $0 : nil }
        self.name = name
    }

    init?(powerSourceDescription description: [String: Any]) {
        guard batteryBool(description[kIOPSIsPresentKey]) != false,
              let currentCapacity = batteryInt(description[kIOPSCurrentCapacityKey]),
              let maximumCapacity = batteryInt(description[kIOPSMaxCapacityKey]),
              maximumCapacity > 0
        else {
            return nil
        }

        let charging = batteryBool(description[kIOPSIsChargingKey]) ?? false
        let sourceState = description[kIOPSPowerSourceStateKey] as? String
        let pluggedIn = sourceState == kIOPSACPowerValue
        let timeKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        let remaining = batteryInt(description[timeKey]).flatMap { $0 >= 0 ? $0 : nil }
        let percentage = Int((Double(currentCapacity) / Double(maximumCapacity) * 100).rounded())

        self.init(
            percentage: percentage,
            isCharging: charging,
            isPluggedIn: pluggedIn,
            timeRemainingMinutes: remaining,
            name: description[kIOPSNameKey] as? String ?? "Battery"
        )
    }
}

private func batteryInt(_ value: Any?) -> Int? {
    if let value = value as? Int {
        return value
    }
    return (value as? NSNumber)?.intValue
}

private func batteryBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
        return value
    }
    return (value as? NSNumber)?.boolValue
}

func currentMacBatterySnapshot() -> BatterySnapshot? {
    guard let infoReference = IOPSCopyPowerSourcesInfo() else { return nil }
    let info = infoReference.takeRetainedValue()
    guard let sourcesReference = IOPSCopyPowerSourcesList(info) else {
        return nil
    }
    let sources = sourcesReference.takeRetainedValue() as [CFTypeRef]

    for source in sources {
        guard let descriptionReference = IOPSGetPowerSourceDescription(info, source) else { continue }
        let description = descriptionReference.takeUnretainedValue() as NSDictionary
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let values = description as? [String: Any],
              let snapshot = BatterySnapshot(powerSourceDescription: values)
        else {
            continue
        }
        return snapshot
    }
    return nil
}

final class TaskbarBatteryMonitor {
    static let shared = TaskbarBatteryMonitor()

    private let refreshInterval: TimeInterval
    private let loader: () -> BatterySnapshot?
    private let lock = NSLock()
    private var hasRefreshed = false
    private var lastRefresh: Date?
    private var cachedSnapshot: BatterySnapshot?

    init(
        refreshInterval: TimeInterval = 15,
        loader: @escaping () -> BatterySnapshot? = currentMacBatterySnapshot
    ) {
        self.refreshInterval = refreshInterval
        self.loader = loader
    }

    func snapshot(now: Date = Date()) -> BatterySnapshot? {
        lock.lock()
        defer { lock.unlock() }

        if hasRefreshed,
           let lastRefresh,
           now.timeIntervalSince(lastRefresh) < refreshInterval {
            return cachedSnapshot
        }

        cachedSnapshot = loader()
        lastRefresh = now
        hasRefreshed = true
        return cachedSnapshot
    }
}

enum BatteryWidgetMetrics {
    static let horizontalPadding: CGFloat = 1
    static let iconTextGap: CGFloat = 3

    static func fontSize(forHeight height: CGFloat) -> CGFloat {
        min(13, max(10, height - 9))
    }

    static func iconHeight(forHeight height: CGFloat) -> CGFloat {
        min(13, max(9, height - 10))
    }

    static func iconWidth(forHeight height: CGFloat) -> CGFloat {
        iconHeight(forHeight: height) * 1.85
    }

    static func width(forHeight height: CGFloat) -> CGFloat {
        let font = NSFont.menuBarFont(ofSize: fontSize(forHeight: height))
        let textWidth = ceil(("100%" as NSString).size(withAttributes: [.font: font]).width)
        return horizontalPadding + iconWidth(forHeight: height) + iconTextGap + textWidth + horizontalPadding
    }
}

struct BatteryIconGeometry: Equatable {
    let bodyRect: NSRect
    let terminalRect: NSRect
    let interiorRect: NSRect
    let fillRect: NSRect
}

func batteryIconGeometry(in bounds: NSRect, percentage: Int) -> BatteryIconGeometry {
    let terminalWidth = max(1.5, bounds.height * 0.14)
    let terminalGap = max(0.75, bounds.height * 0.07)
    let bodyWidth = max(0, bounds.width - terminalWidth - terminalGap)
    let bodyHeight = min(bounds.height, bodyWidth / 1.7)
    let bodyRect = NSRect(
        x: bounds.minX,
        y: bounds.midY - bodyHeight / 2,
        width: bodyWidth,
        height: bodyHeight
    )
    let terminalHeight = bodyHeight * 0.42
    let terminalRect = NSRect(
        x: bodyRect.maxX + terminalGap,
        y: bodyRect.midY - terminalHeight / 2,
        width: terminalWidth,
        height: terminalHeight
    )
    let interiorInset = max(1.75, bodyHeight * 0.18)
    let interiorRect = bodyRect.insetBy(dx: interiorInset, dy: interiorInset)
    let level = CGFloat(min(100, max(0, percentage))) / 100
    let fillRect = NSRect(
        x: interiorRect.minX,
        y: interiorRect.minY,
        width: interiorRect.width * level,
        height: interiorRect.height
    )
    return BatteryIconGeometry(
        bodyRect: bodyRect,
        terminalRect: terminalRect,
        interiorRect: interiorRect,
        fillRect: fillRect
    )
}

struct BatteryWidgetPlugin: TaskbarWidgetPlugin {
    let id: TaskbarWidgetID = .battery
    let title = "Battery"
    let symbolName = "battery.100"

    func isEnabled(in values: TaskbarSettingValues) -> Bool {
        values.batteryWidget.isEnabled
    }

    func minimumWidth(in values: TaskbarSettingValues, height: CGFloat) -> CGFloat {
        guard isEnabled(in: values) else { return 0 }
        return BatteryWidgetMetrics.width(forHeight: height)
    }

    func preferredWidth(in values: TaskbarSettingValues, height: CGFloat, availableWidth: CGFloat) -> CGFloat {
        min(minimumWidth(in: values, height: height), max(0, availableWidth))
    }

    func draw(in rect: NSRect, values: TaskbarSettingValues, date: Date = Date()) {
        guard values.batteryWidget.isEnabled else { return }

        let snapshot = TaskbarBatteryMonitor.shared.snapshot(now: date)
        let text = snapshot.map(batteryWidgetText) ?? "--%"
        let color = batteryWidgetColor(snapshot: snapshot)
        let iconHeight = min(BatteryWidgetMetrics.iconHeight(forHeight: rect.height), rect.height)
        let iconWidth = BatteryWidgetMetrics.iconWidth(forHeight: rect.height)
        let iconRect = NSRect(
            x: rect.minX + BatteryWidgetMetrics.horizontalPadding,
            y: rect.midY - iconHeight / 2,
            width: iconWidth,
            height: iconHeight
        )
        drawBatteryIcon(snapshot: snapshot, color: color, in: iconRect)

        let font = NSFont.menuBarFont(ofSize: BatteryWidgetMetrics.fontSize(forHeight: rect.height))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byClipping
        let textHeight = ceil(font.ascender - font.descender)
        let textRect = NSRect(
            x: iconRect.maxX + BatteryWidgetMetrics.iconTextGap,
            y: rect.midY - textHeight / 2 - 1,
            width: max(0, rect.maxX - BatteryWidgetMetrics.horizontalPadding - iconRect.maxX - BatteryWidgetMetrics.iconTextGap),
            height: textHeight + 2
        )
        (text as NSString).draw(in: textRect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}

func batteryWidgetText(snapshot: BatterySnapshot) -> String {
    "\(snapshot.percentage)%"
}

private func drawBatteryIcon(snapshot: BatterySnapshot?, color: NSColor, in rect: NSRect) {
    let geometry = batteryIconGeometry(in: rect, percentage: snapshot?.percentage ?? 0)
    let lineWidth: CGFloat = 1.25

    let bodyPath = NSBezierPath(
        roundedRect: geometry.bodyRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
        xRadius: geometry.bodyRect.height * 0.22,
        yRadius: geometry.bodyRect.height * 0.22
    )
    bodyPath.lineWidth = lineWidth
    color.setStroke()
    bodyPath.stroke()

    let terminalPath = NSBezierPath(
        roundedRect: geometry.terminalRect,
        xRadius: geometry.terminalRect.width * 0.35,
        yRadius: geometry.terminalRect.width * 0.35
    )
    color.setFill()
    terminalPath.fill()

    if geometry.fillRect.width > 0 {
        let radius = min(geometry.interiorRect.height * 0.24, geometry.fillRect.width / 2)
        let fillPath = NSBezierPath(roundedRect: geometry.fillRect, xRadius: radius, yRadius: radius)
        color.setFill()
        fillPath.fill()
    }

    if snapshot?.isCharging == true {
        drawBatteryChargingBolt(in: geometry.bodyRect)
    }
}

private func drawBatteryChargingBolt(in bodyRect: NSRect) {
    let width = bodyRect.width * 0.28
    let height = bodyRect.height * 0.72
    let rect = NSRect(
        x: bodyRect.midX - width / 2,
        y: bodyRect.midY - height / 2,
        width: width,
        height: height
    )
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.midX + rect.width * 0.12, y: rect.maxY))
    path.line(to: NSPoint(x: rect.minX, y: rect.midY - rect.height * 0.02))
    path.line(to: NSPoint(x: rect.midX - rect.width * 0.02, y: rect.midY - rect.height * 0.02))
    path.line(to: NSPoint(x: rect.midX - rect.width * 0.12, y: rect.minY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.midY + rect.height * 0.08))
    path.line(to: NSPoint(x: rect.midX + rect.width * 0.02, y: rect.midY + rect.height * 0.08))
    path.close()
    path.lineWidth = 0.65
    NSColor(calibratedWhite: 1, alpha: 0.65).setStroke()
    NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
    path.fill()
    path.stroke()
}

func batteryWidgetColor(snapshot: BatterySnapshot?) -> NSColor {
    guard let snapshot else { return .secondaryLabelColor }
    if snapshot.isCharging || (snapshot.isPluggedIn && snapshot.percentage == 100) {
        return NSColor(calibratedRed: 0.28, green: 0.84, blue: 0.39, alpha: 1)
    }
    if snapshot.percentage <= 20 {
        return NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.26, alpha: 1)
    }
    return NSColor(calibratedWhite: 0.92, alpha: 1)
}

func batteryWidgetStatusText(snapshot: BatterySnapshot?) -> String {
    guard let snapshot else { return "No internal battery detected" }

    let state: String
    if snapshot.isCharging {
        state = "charging"
    } else if snapshot.isPluggedIn {
        state = "connected to power"
    } else {
        state = "on battery"
    }
    guard let minutes = snapshot.timeRemainingMinutes, minutes > 0 else {
        return "\(snapshot.percentage)% - \(state)"
    }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    let duration = hours > 0 ? "\(hours)h \(remainingMinutes)m" : "\(remainingMinutes)m"
    let suffix = snapshot.isCharging ? "until full" : "remaining"
    return "\(snapshot.percentage)% - \(state), \(duration) \(suffix)"
}
