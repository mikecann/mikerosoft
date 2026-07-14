import AppKit
import Darwin
import Foundation

struct StatsSnapshot: Equatable {
    var cpuPercent: Double
    var memoryPercent: Double
    var networkUploadBytesPerSecond: Double
    var networkDownloadBytesPerSecond: Double
    var cpuHistory: [Double]

    static let empty = StatsSnapshot(
        cpuPercent: 0,
        memoryPercent: 0,
        networkUploadBytesPerSecond: 0,
        networkDownloadBytesPerSecond: 0,
        cpuHistory: Array(repeating: 0, count: 18)
    )
}

enum StatsWidgetMetric {
    case cpu
    case memory
    case network
}

enum StatsWidgetMetrics {
    static let minimumCPUWidth: CGFloat = 44
    static let preferredCPUWidth: CGFloat = 88
    static let minimumMemoryWidth: CGFloat = 48
    static let preferredMemoryWidth: CGFloat = 58
    static let minimumNetworkWidth: CGFloat = 66
    static let preferredNetworkWidth: CGFloat = 82
    static let moduleSpacing: CGFloat = 8

    static func metrics(for settings: StatsWidgetSettings) -> [StatsWidgetMetric] {
        var result: [StatsWidgetMetric] = []
        if settings.showCPU {
            result.append(.cpu)
        }
        if settings.showMemory {
            result.append(.memory)
        }
        if settings.showNetwork {
            result.append(.network)
        }
        return result
    }

    static func minimumWidth(for settings: StatsWidgetSettings) -> CGFloat {
        width(for: settings, compact: true)
    }

    static func preferredWidth(for settings: StatsWidgetSettings) -> CGFloat {
        width(for: settings, compact: false)
    }

    private static func width(for settings: StatsWidgetSettings, compact: Bool) -> CGFloat {
        let enabledMetrics = metrics(for: settings)
        guard !enabledMetrics.isEmpty else { return 0 }

        let moduleWidths = enabledMetrics.map { metric -> CGFloat in
            switch metric {
            case .cpu:
                return compact || !settings.showMiniGraph ? minimumCPUWidth : preferredCPUWidth
            case .memory:
                return compact ? minimumMemoryWidth : preferredMemoryWidth
            case .network:
                return compact ? minimumNetworkWidth : preferredNetworkWidth
            }
        }

        return moduleWidths.reduce(0, +) + moduleSpacing * CGFloat(max(0, moduleWidths.count - 1))
    }
}

struct StatsWidgetPlugin: TaskbarWidgetPlugin {
    let id: TaskbarWidgetID = .stats
    let title = "Stats"
    let symbolName = "chart.bar"

    func isEnabled(in values: TaskbarSettingValues) -> Bool {
        values.statsWidget.isEnabled && values.statsWidget.hasVisibleMetrics
    }

    func minimumWidth(in values: TaskbarSettingValues, height: CGFloat) -> CGFloat {
        guard isEnabled(in: values) else { return 0 }
        return StatsWidgetMetrics.minimumWidth(for: values.statsWidget)
    }

    func preferredWidth(in values: TaskbarSettingValues, height: CGFloat, availableWidth: CGFloat) -> CGFloat {
        guard isEnabled(in: values) else { return 0 }
        return min(StatsWidgetMetrics.preferredWidth(for: values.statsWidget), max(0, availableWidth))
    }

    func draw(in rect: NSRect, values: TaskbarSettingValues, date: Date = Date()) {
        let settings = values.statsWidget
        guard settings.isEnabled else { return }

        let snapshot = TaskbarStatsSampler.shared.snapshot(now: date)
        let moduleRects = statsWidgetModuleRects(settings: settings, in: rect)

        for (metric, metricRect) in moduleRects {
            switch metric {
            case .cpu:
                drawCPU(snapshot: snapshot, settings: settings, in: metricRect)
            case .memory:
                drawMetric(
                    label: "RAM",
                    value: formattedStatsPercent(snapshot.memoryPercent),
                    in: metricRect,
                    accent: NSColor.systemPurple
                )
            case .network:
                drawNetwork(snapshot: snapshot, in: metricRect)
            }
        }
    }
}

final class TaskbarStatsSampler {
    static let shared = TaskbarStatsSampler()

    private let lock = NSLock()
    private let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
    private var cachedSnapshot = StatsSnapshot.empty
    private var lastRefresh = Date.distantPast
    private var previousCPU: host_cpu_load_info?
    private var previousNetwork: (totals: NetworkByteTotals, date: Date)?

    func snapshot(now: Date = Date()) -> StatsSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard now.timeIntervalSince(lastRefresh) >= 0.75 else {
            return cachedSnapshot
        }

        let cpuPercent = readCPUPercent() ?? cachedSnapshot.cpuPercent
        let memoryPercent = readMemoryPercent() ?? cachedSnapshot.memoryPercent
        let network = readNetworkSpeed(now: now)

        var history = cachedSnapshot.cpuHistory
        history.append(cpuPercent)
        if history.count > 22 {
            history.removeFirst(history.count - 22)
        }

        cachedSnapshot = StatsSnapshot(
            cpuPercent: cpuPercent,
            memoryPercent: memoryPercent,
            networkUploadBytesPerSecond: network.upload,
            networkDownloadBytesPerSecond: network.download,
            cpuHistory: history
        )
        lastRefresh = now
        return cachedSnapshot
    }

    private func readCPUPercent() -> Double? {
        guard let info = readCPULoadInfo() else { return nil }
        defer { previousCPU = info }

        let current = cpuTicks(from: info)
        let previous = previousCPU.map(cpuTicks(from:))
        let deltas: [UInt32]

        if let previous {
            deltas = zip(current, previous).map { current, previous in
                current >= previous ? current - previous : current
            }
        } else {
            deltas = current
        }

        let idle = Double(deltas[2])
        let total = Double(deltas.reduce(0, +))
        guard total > 0 else { return nil }
        return clampedPercent((total - idle) / total * 100)
    }

    private func readCPULoadInfo() -> host_cpu_load_info? {
        let count = MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        var size = mach_msg_type_number_t(count)
        var info = host_cpu_load_info()

        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: count) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return info
    }

    private func cpuTicks(from info: host_cpu_load_info) -> [UInt32] {
        [
            info.cpu_ticks.0,
            info.cpu_ticks.1,
            info.cpu_ticks.2,
            info.cpu_ticks.3
        ]
    }

    private func readMemoryPercent() -> Double? {
        guard totalMemory > 0 else { return nil }

        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        let pageSize = Double(vm_page_size)
        let active = Double(stats.active_count) * pageSize
        let speculative = Double(stats.speculative_count) * pageSize
        let inactive = Double(stats.inactive_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let purgeable = Double(stats.purgeable_count) * pageSize
        let external = Double(stats.external_page_count) * pageSize
        let used = max(0, active + inactive + speculative + wired + compressed - purgeable - external)

        return clampedPercent(used / totalMemory * 100)
    }

    private func readNetworkSpeed(now: Date) -> (upload: Double, download: Double) {
        guard let totals = readNetworkTotals() else {
            return (cachedSnapshot.networkUploadBytesPerSecond, cachedSnapshot.networkDownloadBytesPerSecond)
        }

        defer { previousNetwork = (totals, now) }
        guard let previousNetwork else {
            return (0, 0)
        }

        let elapsed = now.timeIntervalSince(previousNetwork.date)
        guard elapsed > 0 else {
            return (cachedSnapshot.networkUploadBytesPerSecond, cachedSnapshot.networkDownloadBytesPerSecond)
        }

        return (
            upload: bytesPerSecond(current: totals.upload, previous: previousNetwork.totals.upload, elapsed: elapsed),
            download: bytesPerSecond(current: totals.download, previous: previousNetwork.totals.download, elapsed: elapsed)
        )
    }

    private func readNetworkTotals() -> NetworkByteTotals? {
        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceAddresses) == 0, let firstAddress = interfaceAddresses else {
            return nil
        }
        defer { freeifaddrs(interfaceAddresses) }

        var totals = NetworkByteTotals()
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            let flags = current.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0,
                  let address = current.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_LINK,
                  let data = current.pointee.ifa_data
            else {
                continue
            }

            let interfaceData = data.assumingMemoryBound(to: if_data.self).pointee
            totals.upload += UInt64(interfaceData.ifi_obytes)
            totals.download += UInt64(interfaceData.ifi_ibytes)
        }

        return totals
    }

    private func bytesPerSecond(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double {
        guard current >= previous else { return 0 }
        return Double(current - previous) / elapsed
    }
}

private struct NetworkByteTotals {
    var upload: UInt64 = 0
    var download: UInt64 = 0
}

func formattedStatsPercent(_ value: Double) -> String {
    "\(Int(round(clampedPercent(value))))%"
}

func formattedStatsBytesPerSecond(_ bytesPerSecond: Double) -> String {
    let value = max(0, bytesPerSecond)
    let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
    var scaled = value
    var unitIndex = 0

    while scaled >= 1024, unitIndex < units.count - 1 {
        scaled /= 1024
        unitIndex += 1
    }

    if unitIndex == 0 {
        return "\(Int(round(scaled))) \(units[unitIndex])"
    }
    if scaled >= 10 {
        return "\(Int(round(scaled))) \(units[unitIndex])"
    }
    return String(format: "%.1f %@", scaled, units[unitIndex])
}

func statsWidgetModuleRects(settings: StatsWidgetSettings, in rect: NSRect) -> [(StatsWidgetMetric, NSRect)] {
    let metrics = StatsWidgetMetrics.metrics(for: settings)
    guard !metrics.isEmpty else { return [] }

    let preferredWidths = metrics.map { metric -> CGFloat in
        switch metric {
        case .cpu:
            return settings.showMiniGraph ? StatsWidgetMetrics.preferredCPUWidth : StatsWidgetMetrics.minimumCPUWidth
        case .memory:
            return StatsWidgetMetrics.preferredMemoryWidth
        case .network:
            return StatsWidgetMetrics.preferredNetworkWidth
        }
    }
    let minimumWidths = metrics.map { metric -> CGFloat in
        switch metric {
        case .cpu:
            return StatsWidgetMetrics.minimumCPUWidth
        case .memory:
            return StatsWidgetMetrics.minimumMemoryWidth
        case .network:
            return StatsWidgetMetrics.minimumNetworkWidth
        }
    }

    let totalSpacing = StatsWidgetMetrics.moduleSpacing * CGFloat(max(0, metrics.count - 1))
    let available = max(0, rect.width - totalSpacing)
    let widths = fittedTaskbarItemWidths(
        preferredWidths: preferredWidths,
        softMinimumWidth: minimumWidths.min() ?? 0,
        availableWidth: available
    )

    var x = rect.minX
    return zip(metrics, widths).map { metric, width in
        defer { x += width + StatsWidgetMetrics.moduleSpacing }
        return (metric, NSRect(x: x, y: rect.minY, width: width, height: rect.height))
    }
}

private func drawCPU(snapshot: StatsSnapshot, settings: StatsWidgetSettings, in rect: NSRect) {
    let graphWidth: CGFloat = settings.showMiniGraph && rect.width >= 70 ? min(34, rect.width * 0.42) : 0
    if graphWidth > 0 {
        drawMiniGraph(
            snapshot.cpuHistory,
            in: NSRect(
                x: rect.minX,
                y: rect.minY + max(2, rect.height * 0.18),
                width: graphWidth,
                height: max(8, rect.height * 0.64)
            )
        )
    }

    let textRect = NSRect(
        x: graphWidth > 0 ? rect.minX + graphWidth + 4 : rect.minX,
        y: rect.minY,
        width: max(0, rect.width - graphWidth - (graphWidth > 0 ? 4 : 0)),
        height: rect.height
    )
    drawMetric(label: "CPU", value: formattedStatsPercent(snapshot.cpuPercent), in: textRect, accent: NSColor.systemBlue)
}

private func drawMetric(label: String, value: String, in rect: NSRect, accent: NSColor) {
    guard rect.width > 2, rect.height > 10 else { return }

    if rect.height < 30 || rect.width < 42 {
        drawStatsText(
            "\(label) \(value)",
            in: NSRect(x: rect.minX, y: rect.midY - 7, width: rect.width, height: 14),
            size: min(11, max(9, rect.height - 10)),
            weight: .semibold,
            color: NSColor(calibratedWhite: 0.92, alpha: 1.0)
        )
        return
    }

    drawStatsText(
        label,
        in: NSRect(x: rect.minX, y: rect.midY + 1, width: rect.width, height: 12),
        size: 10,
        weight: .medium,
        color: NSColor(calibratedWhite: 0.86, alpha: 1.0)
    )
    drawStatsText(
        value,
        in: NSRect(x: rect.minX, y: rect.midY - 14, width: rect.width, height: 15),
        size: 13,
        weight: .semibold,
        color: accent.blended(withFraction: 0.2, of: .white) ?? accent
    )
}

private func drawNetwork(snapshot: StatsSnapshot, in rect: NSRect) {
    guard rect.width > 2 else { return }

    let upload = formattedStatsBytesPerSecond(snapshot.networkUploadBytesPerSecond)
    let download = formattedStatsBytesPerSecond(snapshot.networkDownloadBytesPerSecond)

    if rect.height < 30 {
        drawStatsText(
            "↓ \(download)",
            in: NSRect(x: rect.minX, y: rect.midY - 7, width: rect.width, height: 14),
            size: min(11, max(9, rect.height - 10)),
            weight: .semibold,
            color: NSColor(calibratedWhite: 0.92, alpha: 1.0)
        )
        return
    }

    let dotSize: CGFloat = 5
    let textX = rect.minX + dotSize + 5
    let textWidth = max(0, rect.width - dotSize - 5)
    drawDot(color: NSColor.systemRed, rect: NSRect(x: rect.minX, y: rect.midY + 5, width: dotSize, height: dotSize))
    drawDot(color: NSColor.systemBlue, rect: NSRect(x: rect.minX, y: rect.midY - 8, width: dotSize, height: dotSize))
    drawStatsText(
        upload,
        in: NSRect(x: textX, y: rect.midY + 1, width: textWidth, height: 12),
        size: 10,
        weight: .medium,
        color: NSColor(calibratedWhite: 0.92, alpha: 1.0)
    )
    drawStatsText(
        download,
        in: NSRect(x: textX, y: rect.midY - 13, width: textWidth, height: 12),
        size: 10,
        weight: .medium,
        color: NSColor(calibratedWhite: 0.92, alpha: 1.0)
    )
}

private func drawMiniGraph(_ values: [Double], in rect: NSRect) {
    guard !values.isEmpty, rect.width > 2, rect.height > 2 else { return }

    NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()

    let barCount = min(values.count, 18)
    let visibleValues = Array(values.suffix(barCount))
    let gap: CGFloat = 1
    let barWidth = max(1, floor((rect.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)))
    var x = rect.maxX - CGFloat(barCount) * barWidth - CGFloat(barCount - 1) * gap

    for value in visibleValues {
        let percent = clampedPercent(value) / 100
        let height = max(1, rect.height * CGFloat(percent))
        let barRect = NSRect(
            x: x,
            y: rect.minY,
            width: barWidth,
            height: height
        )
        NSColor.systemBlue.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1).fill()
        x += barWidth + gap
    }
}

private func drawStatsText(_ value: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    paragraph.alignment = .left

    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    (value as NSString).draw(in: rect, withAttributes: attributes)
}

private func drawDot(color: NSColor, rect: NSRect) {
    color.withAlphaComponent(0.88).setFill()
    NSBezierPath(ovalIn: rect).fill()
}

private func clampedPercent(_ value: Double) -> Double {
    min(max(value, 0), 100)
}
