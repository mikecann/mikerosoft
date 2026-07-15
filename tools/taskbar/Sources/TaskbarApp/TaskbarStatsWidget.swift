import AppKit
import Darwin
import Foundation

struct StatsProcessSample: Equatable {
    var pid: Int
    var name: String
    var appPath: String
    var cpuPercent: Double
    var memoryBytes: Double
}

struct StatsNetworkProcessSample: Equatable {
    var pid: Int
    var name: String
    var appPath: String
    var uploadBytesPerSecond: Double
    var downloadBytesPerSecond: Double
}

private struct StatsGPUReading {
    var percent: Double
    var renderPercent: Double
    var tilerPercent: Double
    var model: String
    var cores: Int?
}

struct StatsSnapshot: Equatable {
    var cpuPercent: Double
    var cpuUserPercent: Double
    var cpuSystemPercent: Double
    var gpuPercent: Double
    var gpuRenderPercent: Double
    var gpuTilerPercent: Double
    var gpuModel: String
    var gpuCores: Int?
    var memoryPercent: Double
    var memoryUsedBytes: Double
    var memoryAppBytes: Double
    var memoryWiredBytes: Double
    var memoryCompressedBytes: Double
    var memoryTotalBytes: Double
    var networkUploadBytesPerSecond: Double
    var networkDownloadBytesPerSecond: Double
    var cpuHistory: [Double]
    var gpuHistory: [Double]
    var memoryHistory: [Double]
    var networkUploadHistory: [Double]
    var networkDownloadHistory: [Double]
    var processes: [StatsProcessSample]
    var networkProcesses: [StatsNetworkProcessSample]

    static let empty = StatsSnapshot(
        cpuPercent: 0,
        cpuUserPercent: 0,
        cpuSystemPercent: 0,
        gpuPercent: 0,
        gpuRenderPercent: 0,
        gpuTilerPercent: 0,
        gpuModel: "GPU",
        gpuCores: nil,
        memoryPercent: 0,
        memoryUsedBytes: 0,
        memoryAppBytes: 0,
        memoryWiredBytes: 0,
        memoryCompressedBytes: 0,
        memoryTotalBytes: Double(ProcessInfo.processInfo.physicalMemory),
        networkUploadBytesPerSecond: 0,
        networkDownloadBytesPerSecond: 0,
        cpuHistory: Array(repeating: 0, count: 22),
        gpuHistory: Array(repeating: 0, count: 22),
        memoryHistory: Array(repeating: 0, count: 22),
        networkUploadHistory: Array(repeating: 0, count: 22),
        networkDownloadHistory: Array(repeating: 0, count: 22),
        processes: [],
        networkProcesses: []
    )
}

enum StatsWidgetMetric: Equatable {
    case cpu
    case gpu
    case memory
    case network

    var title: String {
        switch self {
        case .cpu:
            return "CPU"
        case .gpu:
            return "GPU"
        case .memory:
            return "RAM"
        case .network:
            return "NET"
        }
    }
}

enum StatsWidgetMetrics {
    static let minimumCPUWidth: CGFloat = 46
    static let preferredCPUWidth: CGFloat = 72
    static let minimumGPUWidth: CGFloat = 42
    static let preferredGPUWidth: CGFloat = 48
    static let minimumMemoryWidth: CGFloat = 38
    static let preferredMemoryWidth: CGFloat = 38
    static let minimumNetworkWidth: CGFloat = 64
    static let preferredNetworkWidth: CGFloat = 82
    static let moduleSpacing: CGFloat = 10
    static let sideLabelWidth: CGFloat = 10
    static let sideLabelGap: CGFloat = 2

    static func metrics(for settings: StatsWidgetSettings) -> [StatsWidgetMetric] {
        var result: [StatsWidgetMetric] = []
        if settings.showCPU {
            result.append(.cpu)
        }
        if settings.showGPU {
            result.append(.gpu)
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
            case .gpu:
                return compact ? minimumGPUWidth : preferredGPUWidth
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
            case .gpu:
                drawGPU(snapshot: snapshot, in: metricRect)
            case .memory:
                drawMemory(snapshot: snapshot, settings: settings, in: metricRect)
            case .network:
                drawNetwork(snapshot: snapshot, in: metricRect)
            }
        }
    }
}

typealias StatsCommandOutput = (_ executable: String, _ arguments: [String]) -> String?

struct CPUUsage: Equatable {
    var activePercent: Double
    var userPercent: Double
    var systemPercent: Double
    var idlePercent: Double
}

struct MemoryBreakdown: Equatable {
    var appBytes: Double
    var wiredBytes: Double
    var compressedBytes: Double

    var usedBytes: Double {
        appBytes + wiredBytes + compressedBytes
    }
}

struct MemoryUsage: Equatable {
    var percent: Double
    var usedBytes: Double
    var totalBytes: Double
    var appBytes: Double
    var wiredBytes: Double
    var compressedBytes: Double
}

func memoryBreakdown(usedBytes: Double, wiredBytes: Double, compressedBytes: Double) -> MemoryBreakdown {
    let usedBytes = max(0, usedBytes)
    let wiredBytes = max(0, wiredBytes)
    let compressedBytes = max(0, compressedBytes)
    return MemoryBreakdown(
        appBytes: max(0, usedBytes - wiredBytes - compressedBytes),
        wiredBytes: wiredBytes,
        compressedBytes: compressedBytes
    )
}

func cpuUsage(currentTicks: [UInt32], previousTicks: [UInt32]?) -> CPUUsage? {
    guard let previousTicks,
          currentTicks.count == Int(CPU_STATE_MAX),
          previousTicks.count == currentTicks.count
    else {
        return nil
    }

    let deltas = zip(currentTicks, previousTicks).map { current, previous in
        UInt64(current &- previous)
    }
    let user = deltas[Int(CPU_STATE_USER)] + deltas[Int(CPU_STATE_NICE)]
    let system = deltas[Int(CPU_STATE_SYSTEM)]
    let idle = deltas[Int(CPU_STATE_IDLE)]
    let total = deltas.reduce(UInt64.zero, +)
    guard total > 0 else { return nil }

    let percentage = { (ticks: UInt64) in
        clampedPercent(Double(ticks) / Double(total) * 100)
    }
    return CPUUsage(
        activePercent: percentage(user + system),
        userPercent: percentage(user),
        systemPercent: percentage(system),
        idlePercent: percentage(idle)
    )
}

func cpuPercent(currentTicks: [UInt32], previousTicks: [UInt32]?) -> Double? {
    cpuUsage(currentTicks: currentTicks, previousTicks: previousTicks)?.activePercent
}

func statsGaugeNeedleEndpoint(percent: Double, center: NSPoint, radius: CGFloat) -> NSPoint {
    let startAngle: CGFloat = 205
    let totalAngle: CGFloat = 130
    let ratio = CGFloat(clampedPercent(percent) / 100)
    let angle = (startAngle - ratio * totalAngle) * .pi / 180
    let length = max(0, radius - 14)
    return NSPoint(
        x: center.x + cos(angle) * length,
        y: center.y + sin(angle) * length
    )
}

final class TaskbarStatsSampler {
    static let shared = TaskbarStatsSampler()

    private let lock = NSLock()
    private let commandOutput: StatsCommandOutput
    private let backgroundQueue: DispatchQueue
    private let cpuTickReader: (() -> [UInt32]?)?
    private let memoryReader: (() -> MemoryUsage?)?
    private let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
    private var cachedSnapshot = StatsSnapshot.empty
    private var lastRefresh = Date.distantPast
    private var lastGPURefresh = Date.distantPast
    private var lastProcessRefresh = Date.distantPast
    private var lastNetworkProcessRefresh = Date.distantPast
    private var isRefreshingGPU = false
    private var isRefreshingProcesses = false
    private var isRefreshingNetworkProcesses = false
    private var previousCPUTicks: [UInt32]?
    private var previousNetwork: (totals: NetworkByteTotals, date: Date)?
    private var cachedGPU = StatsGPUReading(percent: 0, renderPercent: 0, tilerPercent: 0, model: "GPU", cores: nil)
    private var cachedProcesses: [StatsProcessSample] = []
    private var cachedNetworkProcesses: [StatsNetworkProcessSample] = []

    init(
        commandOutput: @escaping StatsCommandOutput = { executable, arguments in
            runStatsCommandOutput(executable, arguments: arguments)
        },
        backgroundQueue: DispatchQueue = DispatchQueue.global(qos: .utility),
        cpuTickReader: (() -> [UInt32]?)? = nil,
        memoryReader: (() -> MemoryUsage?)? = nil
    ) {
        self.commandOutput = commandOutput
        self.backgroundQueue = backgroundQueue
        self.cpuTickReader = cpuTickReader
        self.memoryReader = memoryReader
    }

    func snapshot(now: Date = Date()) -> StatsSnapshot {
        lock.lock()
        if now.timeIntervalSince(lastRefresh) < 0.75 {
            let snapshot = cachedSnapshot
            lock.unlock()
            return snapshot
        }

        let cpu = readCPUUsage() ?? CPUUsage(
            activePercent: cachedSnapshot.cpuPercent,
            userPercent: cachedSnapshot.cpuUserPercent,
            systemPercent: cachedSnapshot.cpuSystemPercent,
            idlePercent: max(0, 100 - cachedSnapshot.cpuPercent)
        )
        let memory = readMemory() ?? MemoryUsage(
            percent: cachedSnapshot.memoryPercent,
            usedBytes: cachedSnapshot.memoryUsedBytes,
            totalBytes: cachedSnapshot.memoryTotalBytes,
            appBytes: cachedSnapshot.memoryAppBytes,
            wiredBytes: cachedSnapshot.memoryWiredBytes,
            compressedBytes: cachedSnapshot.memoryCompressedBytes
        )
        let gpu = cachedGPU
        let network = readNetworkSpeed(now: now)
        let processes = cachedProcesses
        let networkProcesses = readNetworkProcesses(now: now)
        let shouldRefreshGPU = now.timeIntervalSince(lastGPURefresh) >= 2.0 && !isRefreshingGPU
        let shouldRefreshProcesses = now.timeIntervalSince(lastProcessRefresh) >= 3.0 && !isRefreshingProcesses

        if shouldRefreshGPU {
            isRefreshingGPU = true
            lastGPURefresh = now
        }
        if shouldRefreshProcesses {
            isRefreshingProcesses = true
            lastProcessRefresh = now
        }

        let cpuHistory = appendedHistory(cachedSnapshot.cpuHistory, value: cpu.activePercent)
        let gpuHistory = appendedHistory(cachedSnapshot.gpuHistory, value: gpu.percent)
        let memoryHistory = appendedHistory(cachedSnapshot.memoryHistory, value: memory.percent)
        let uploadHistory = appendedHistory(cachedSnapshot.networkUploadHistory, value: network.upload)
        let downloadHistory = appendedHistory(cachedSnapshot.networkDownloadHistory, value: network.download)

        cachedSnapshot = StatsSnapshot(
            cpuPercent: cpu.activePercent,
            cpuUserPercent: cpu.userPercent,
            cpuSystemPercent: cpu.systemPercent,
            gpuPercent: gpu.percent,
            gpuRenderPercent: gpu.renderPercent,
            gpuTilerPercent: gpu.tilerPercent,
            gpuModel: gpu.model,
            gpuCores: gpu.cores,
            memoryPercent: memory.percent,
            memoryUsedBytes: memory.usedBytes,
            memoryAppBytes: memory.appBytes,
            memoryWiredBytes: memory.wiredBytes,
            memoryCompressedBytes: memory.compressedBytes,
            memoryTotalBytes: memory.totalBytes,
            networkUploadBytesPerSecond: network.upload,
            networkDownloadBytesPerSecond: network.download,
            cpuHistory: cpuHistory,
            gpuHistory: gpuHistory,
            memoryHistory: memoryHistory,
            networkUploadHistory: uploadHistory,
            networkDownloadHistory: downloadHistory,
            processes: processes,
            networkProcesses: networkProcesses
        )
        lastRefresh = now
        let snapshot = cachedSnapshot
        let gpuFallback = cachedGPU
        lock.unlock()

        if shouldRefreshGPU {
            refreshGPUInBackground(fallback: gpuFallback)
        }
        if shouldRefreshProcesses {
            refreshProcessesInBackground()
        }

        return snapshot
    }

    private func readCPUUsage() -> CPUUsage? {
        let currentTicks: [UInt32]
        if let cpuTickReader {
            guard let ticks = cpuTickReader() else { return nil }
            currentTicks = ticks
        } else {
            guard let info = readCPULoadInfo() else { return nil }
            currentTicks = cpuTicks(from: info)
        }

        defer { previousCPUTicks = currentTicks }
        return cpuUsage(currentTicks: currentTicks, previousTicks: previousCPUTicks)
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

    private func readMemory() -> MemoryUsage? {
        if let memoryReader {
            return memoryReader()
        }
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
        let measuredUsed = active + inactive + speculative + wired + compressed - purgeable - external
        let breakdown = memoryBreakdown(
            usedBytes: measuredUsed,
            wiredBytes: wired,
            compressedBytes: compressed
        )
        let used = breakdown.usedBytes

        return MemoryUsage(
            percent: clampedPercent(used / totalMemory * 100),
            usedBytes: used,
            totalBytes: totalMemory,
            appBytes: breakdown.appBytes,
            wiredBytes: breakdown.wiredBytes,
            compressedBytes: breakdown.compressedBytes
        )
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

    private func readNetworkProcesses(now: Date) -> [StatsNetworkProcessSample] {
        guard now.timeIntervalSince(lastNetworkProcessRefresh) >= 15, !isRefreshingNetworkProcesses else {
            return cachedNetworkProcesses
        }

        isRefreshingNetworkProcesses = true
        lastNetworkProcessRefresh = now
        backgroundQueue.async { [weak self] in
            guard let self else { return }
            let samples = Self.captureNetworkProcesses(commandOutput: self.commandOutput)

            self.lock.lock()
            self.cachedNetworkProcesses = samples
            self.isRefreshingNetworkProcesses = false
            self.lock.unlock()
        }
        return cachedNetworkProcesses
    }

    private func refreshGPUInBackground(fallback: StatsGPUReading) {
        backgroundQueue.async { [weak self] in
            guard let self else { return }
            let gpu = Self.captureGPU(commandOutput: self.commandOutput, fallback: fallback)

            self.lock.lock()
            self.cachedGPU = gpu
            self.isRefreshingGPU = false
            self.lock.unlock()
        }
    }

    private static func captureGPU(commandOutput: StatsCommandOutput, fallback: StatsGPUReading) -> StatsGPUReading {
        guard let output = commandOutput("/usr/sbin/ioreg", ["-r", "-c", "IOAccelerator", "-d", "1"]) else {
            return fallback
        }

        let model = quotedValue(for: "model", in: output) ?? fallback.model
        let percent = numericValue(for: "Device Utilization %", in: output)
            ?? numericValue(for: "GPU Activity(%)", in: output)
            ?? fallback.percent
        let render = numericValue(for: "Renderer Utilization %", in: output) ?? fallback.renderPercent
        let tiler = numericValue(for: "Tiler Utilization %", in: output) ?? fallback.tilerPercent

        return StatsGPUReading(
            percent: clampedPercent(percent),
            renderPercent: clampedPercent(render),
            tilerPercent: clampedPercent(tiler),
            model: model,
            cores: gpuCoreCount(model: model)
        )
    }

    private func refreshProcessesInBackground() {
        backgroundQueue.async { [weak self] in
            guard let self else { return }
            let processes = Self.captureProcesses(commandOutput: self.commandOutput)

            self.lock.lock()
            self.cachedProcesses = processes
            self.isRefreshingProcesses = false
            self.lock.unlock()
        }
    }

    private static func captureProcesses(commandOutput: StatsCommandOutput) -> [StatsProcessSample] {
        guard let output = commandOutput("/bin/ps", ["-axo", "pid=,pcpu=,rss=,comm=", "-r"]) else {
            return []
        }

        let runningApps = uniquePositiveProcessLookup(
            NSWorkspace.shared.runningApplications.map { (Int($0.processIdentifier), $0) }
        )

        return output
            .split(separator: "\n")
            .compactMap { line -> StatsProcessSample? in
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4,
                      let pid = Int(parts[0]),
                      let cpu = Double(String(parts[1])),
                      let rssKilobytes = Double(String(parts[2]))
                else {
                    return nil
                }

                let rawPath = String(parts[3])
                let app = runningApps[pid]
                let appPath = app?.bundleURL?.path ?? rawPath
                let name = app?.localizedName
                    ?? URL(fileURLWithPath: rawPath).deletingPathExtension().lastPathComponent
                return StatsProcessSample(
                    pid: pid,
                    name: name,
                    appPath: appPath,
                    cpuPercent: max(0, cpu),
                    memoryBytes: max(0, rssKilobytes * 1024)
                )
            }
    }

    private static func captureNetworkProcesses(commandOutput: StatsCommandOutput) -> [StatsNetworkProcessSample] {
        guard let output = commandOutput(
            "/usr/bin/nettop",
            ["-P", "-x", "-d", "-s", "1", "-L", "2", "-J", "bytes_in,bytes_out"]
        ) else {
            return []
        }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerIndex = lines.lastIndex(where: { $0 == ",bytes_in,bytes_out," }) else {
            return []
        }

        let runningApps = uniquePositiveProcessLookup(
            NSWorkspace.shared.runningApplications.map { (Int($0.processIdentifier), $0) }
        )

        return lines
            .dropFirst(headerIndex + 1)
            .compactMap { line -> StatsNetworkProcessSample? in
                let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 3 else { return nil }

                let identity = String(fields[0])
                guard let dotIndex = identity.lastIndex(of: ".") else { return nil }
                let rawName = String(identity[..<dotIndex])
                guard let pid = Int(identity[identity.index(after: dotIndex)...]),
                      let download = Double(String(fields[1])),
                      let upload = Double(String(fields[2]))
                else {
                    return nil
                }

                let total = upload + download
                guard total > 0 else { return nil }

                let app = runningApps[pid]
                let appPath = app?.bundleURL?.path ?? ""
                let name = app?.localizedName ?? rawName
                return StatsNetworkProcessSample(
                    pid: pid,
                    name: name,
                    appPath: appPath,
                    uploadBytesPerSecond: max(0, upload),
                    downloadBytesPerSecond: max(0, download)
                )
            }
            .sorted {
                ($0.uploadBytesPerSecond + $0.downloadBytesPerSecond) >
                    ($1.uploadBytesPerSecond + $1.downloadBytesPerSecond)
            }
            .prefix(8)
            .map { $0 }
    }

    private static func numericValue(for key: String, in text: String) -> Double? {
        guard let keyRange = text.range(of: "\"\(key)\"=") else { return nil }
        let suffix = text[keyRange.upperBound...].drop { $0 == " " }
        let token = suffix.prefix { character in
            character.isNumber || character == "."
        }
        return Double(String(token))
    }

    private static func quotedValue(for key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\" = \"") else { return nil }
        let suffix = text[keyRange.upperBound...]
        guard let end = suffix.firstIndex(of: "\"") else { return nil }
        let value = String(suffix[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func gpuCoreCount(model: String) -> Int? {
        let normalized = model.lowercased()
        if normalized.contains("m1 ultra") { return 64 }
        if normalized.contains("m1 max") { return 32 }
        if normalized.contains("m1 pro") { return 16 }
        if normalized.contains("m1") { return 8 }
        if normalized.contains("m2 ultra") { return 76 }
        if normalized.contains("m2 max") { return 38 }
        if normalized.contains("m2 pro") { return 19 }
        if normalized.contains("m2") { return 10 }
        if normalized.contains("m3 ultra") { return 80 }
        if normalized.contains("m3 max") { return 40 }
        if normalized.contains("m3 pro") { return 18 }
        if normalized.contains("m3") { return 10 }
        if normalized.contains("m4 max") { return 40 }
        if normalized.contains("m4 pro") { return 20 }
        if normalized.contains("m4") { return 10 }
        return nil
    }

    private func appendedHistory(_ values: [Double], value: Double, limit: Int = 22) -> [Double] {
        var history = values
        history.append(value)
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
        return history
    }
}

func runStatsCommandOutput(_ executable: String, arguments: [String], timeout: TimeInterval = 6) -> String? {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let outputHandle = outputPipe.fileHandleForReading
    let errorHandle = errorPipe.fileHandleForReading
    let lock = NSLock()
    let terminated = DispatchSemaphore(value: 0)
    var outputData = Data()

    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.terminationHandler = { _ in
        terminated.signal()
    }

    outputHandle.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        lock.lock()
        outputData.append(data)
        lock.unlock()
    }
    errorHandle.readabilityHandler = { handle in
        _ = handle.availableData
    }

    do {
        try process.run()
    } catch {
        outputHandle.readabilityHandler = nil
        errorHandle.readabilityHandler = nil
        return nil
    }

    let waitResult = terminated.wait(timeout: .now() + timeout)
    if waitResult == .timedOut {
        if process.isRunning {
            process.terminate()
        }
        if terminated.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = terminated.wait(timeout: .now() + 0.5)
        }
        outputHandle.readabilityHandler = nil
        errorHandle.readabilityHandler = nil
        return nil
    }

    outputHandle.readabilityHandler = nil
    errorHandle.readabilityHandler = nil
    lock.lock()
    outputData.append(outputHandle.readDataToEndOfFile())
    lock.unlock()
    _ = errorHandle.readDataToEndOfFile()

    guard process.terminationStatus == 0 else {
        return nil
    }
    return String(data: outputData, encoding: .utf8)
}

func uniquePositiveProcessLookup<Value>(_ values: [(Int, Value)]) -> [Int: Value] {
    values.reduce(into: [Int: Value]()) { result, entry in
        let (pid, value) = entry
        guard pid > 0, result[pid] == nil else { return }
        result[pid] = value
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

func formattedStatsMemoryBytes(_ bytes: Double) -> String {
    let value = max(0, bytes)
    let units = ["B", "KB", "MB", "GB", "TB"]
    var scaled = value
    var unitIndex = 0

    while scaled >= 1024, unitIndex < units.count - 1 {
        scaled /= 1024
        unitIndex += 1
    }

    if unitIndex <= 2 || scaled >= 10 {
        return "\(Int(round(scaled))) \(units[unitIndex])"
    }
    return String(format: "%.1f %@", scaled, units[unitIndex])
}

enum StatsCPUTaskbarRenderContent: Equatable {
    case miniGraph(width: CGFloat)
    case percent
}

func statsCPUTaskbarRenderContent(in rect: NSRect, showMiniGraph: Bool) -> StatsCPUTaskbarRenderContent {
    let contentRect = statsSideLabelRects(in: rect).content
    let graphWidth = statsMiniGraphWidth(in: contentRect, isEnabled: showMiniGraph)
    return graphWidth > 0 ? .miniGraph(width: graphWidth) : .percent
}

func statsWidgetModuleRects(settings: StatsWidgetSettings, in rect: NSRect) -> [(StatsWidgetMetric, NSRect)] {
    let metrics = StatsWidgetMetrics.metrics(for: settings)
    guard !metrics.isEmpty else { return [] }

    let preferredWidths = metrics.map { metric -> CGFloat in
        switch metric {
        case .cpu:
            return settings.showMiniGraph ? StatsWidgetMetrics.preferredCPUWidth : StatsWidgetMetrics.minimumCPUWidth
        case .gpu:
            return StatsWidgetMetrics.preferredGPUWidth
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
        case .gpu:
            return StatsWidgetMetrics.minimumGPUWidth
        case .memory:
            return StatsWidgetMetrics.minimumMemoryWidth
        case .network:
            return StatsWidgetMetrics.minimumNetworkWidth
        }
    }

    let gapCount = max(0, metrics.count - 1)
    let totalSpacing = min(
        max(0, rect.width),
        StatsWidgetMetrics.moduleSpacing * CGFloat(gapCount)
    )
    let moduleSpacing = gapCount > 0 ? totalSpacing / CGFloat(gapCount) : 0
    let available = max(0, rect.width - totalSpacing)
    let widths = fittedTaskbarItemWidths(
        preferredWidths: preferredWidths,
        minimumWidths: minimumWidths,
        availableWidth: available
    )

    var x = rect.minX
    return zip(metrics, widths).map { metric, width in
        defer { x += width + moduleSpacing }
        return (metric, NSRect(x: x, y: rect.minY, width: width, height: rect.height))
    }
}

func statsWidgetMetricRects(settings: StatsWidgetSettings, in rect: NSRect) -> [(StatsWidgetMetric, NSRect)] {
    statsWidgetModuleRects(settings: settings, in: rect)
}

func statsWidgetMetric(at point: NSPoint, in rect: NSRect, settings: StatsWidgetSettings) -> StatsWidgetMetric? {
    statsWidgetMetricRects(settings: settings, in: rect)
        .first { _, metricRect in point.x >= metricRect.minX && point.x <= metricRect.maxX }?
        .0
}

func statsWidgetMetricRect(_ metric: StatsWidgetMetric, in rect: NSRect, settings: StatsWidgetSettings) -> NSRect? {
    statsWidgetMetricRects(settings: settings, in: rect)
        .first { $0.0 == metric }?
        .1
}

private func drawCPU(snapshot: StatsSnapshot, settings: StatsWidgetSettings, in rect: NSRect) {
    switch statsCPUTaskbarRenderContent(in: rect, showMiniGraph: settings.showMiniGraph) {
    case let .miniGraph(graphWidth):
        let layout = statsSideLabelRects(in: rect)
        drawVerticalStatsLabel("CPU", in: layout.label)
        drawMiniGraph(
            snapshot.cpuHistory,
            in: statsMiniGraphRect(in: layout.content, width: graphWidth)
        )
    case .percent:
        drawLabeledStatText(
            label: "CPU",
            value: formattedStatsPercent(snapshot.cpuPercent),
            in: rect,
            accent: .systemBlue
        )
    }
}

private func drawGPU(snapshot: StatsSnapshot, in rect: NSRect) {
    drawLabeledStatText(label: "GPU", value: formattedStatsPercent(snapshot.gpuPercent), in: rect, accent: .systemBlue)
}

private func drawMemory(snapshot: StatsSnapshot, settings: StatsWidgetSettings, in rect: NSRect) {
    guard rect.width > 2, rect.height > 10 else { return }

    switch settings.memoryDisplay {
    case .percent:
        drawLabeledStatText(label: "RAM", value: formattedStatsPercent(snapshot.memoryPercent), in: rect, accent: .systemPurple)
    case .pie:
        let layout = statsSideLabelRects(in: rect)
        drawVerticalStatsLabel("RAM", in: layout.label)
        drawMemoryPie(percent: snapshot.memoryPercent, in: statsMemoryPieRect(in: layout.content))
    }
}

private func drawLabeledStatText(label: String, value: String, in rect: NSRect, accent: NSColor) {
    guard rect.width > 2, rect.height > 10 else { return }

    let layout = statsSideLabelRects(in: rect)
    drawVerticalStatsLabel(label, in: layout.label)
    drawStatsText(
        value,
        in: NSRect(x: layout.content.minX, y: rect.midY - 7, width: layout.content.width, height: 14),
        size: min(12, max(9, rect.height - 10)),
        weight: .semibold,
        color: accent.blended(withFraction: 0.2, of: .white) ?? accent
    )
}

func statsMemoryPieRect(in rect: NSRect) -> NSRect {
    let diameter = min(max(0, rect.width), max(0, rect.height - 2))
    return NSRect(
        x: rect.minX,
        y: rect.midY - diameter / 2,
        width: diameter,
        height: diameter
    )
}

private func drawMemoryPie(percent: Double, in rect: NSRect) {
    guard rect.width > 3, rect.height > 3 else { return }

    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) / 2

    NSColor(calibratedWhite: 1, alpha: 0.16).setFill()
    NSBezierPath(ovalIn: rect).fill()

    let valuePath = NSBezierPath()
    valuePath.move(to: center)
    valuePath.appendArc(
        withCenter: center,
        radius: radius,
        startAngle: 90,
        endAngle: 90 - CGFloat(clampedPercent(percent) / 100 * 360),
        clockwise: true
    )
    valuePath.close()
    NSColor.systemPurple.withAlphaComponent(0.9).setFill()
    valuePath.fill()

    NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
    NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
}

private func drawNetwork(snapshot: StatsSnapshot, in rect: NSRect) {
    guard rect.width > 2 else { return }

    let upload = formattedStatsBytesPerSecond(snapshot.networkUploadBytesPerSecond)
    let download = formattedStatsBytesPerSecond(snapshot.networkDownloadBytesPerSecond)
    let sideLayout = statsSideLabelRects(in: rect)
    drawVerticalStatsLabel("NET", in: sideLayout.label)

    let layout = statsNetworkLineRects(in: sideLayout.content)
    let compactSize = min(10, max(8, rect.height / 2 - 2))

    drawStatsText(
        "↑ \(upload)",
        in: layout.upload,
        size: compactSize,
        weight: .semibold,
        color: NSColor.systemRed.blended(withFraction: 0.18, of: .white) ?? NSColor.systemRed
    )
    drawStatsText(
        "↓ \(download)",
        in: layout.download,
        size: compactSize,
        weight: .semibold,
        color: NSColor.systemGreen.blended(withFraction: 0.18, of: .white) ?? NSColor.systemGreen
    )
}

func statsMiniGraphWidth(in rect: NSRect, isEnabled: Bool) -> CGFloat {
    guard isEnabled, rect.width >= 18 else { return 0 }
    return min(62, rect.width)
}

func statsMiniGraphRect(in rect: NSRect, width: CGFloat) -> NSRect {
    NSRect(
        x: rect.minX,
        y: rect.minY + 1,
        width: width,
        height: max(1, rect.height - 2)
    )
}

func statsSideLabelRects(in rect: NSRect) -> (label: NSRect, content: NSRect) {
    let labelWidth = min(StatsWidgetMetrics.sideLabelWidth, max(0, rect.width))
    let gap = rect.width > labelWidth ? min(StatsWidgetMetrics.sideLabelGap, rect.width - labelWidth) : 0
    let contentX = rect.minX + labelWidth + gap
    return (
        label: NSRect(x: rect.minX, y: rect.minY, width: labelWidth, height: rect.height),
        content: NSRect(
            x: contentX,
            y: rect.minY,
            width: max(0, rect.maxX - contentX),
            height: rect.height
        )
    )
}

func statsNetworkLineRects(in rect: NSRect) -> (upload: NSRect, download: NSRect) {
    let rowHeight = max(1, floor((rect.height - 1) / 2))
    return (
        upload: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rowHeight),
        download: NSRect(x: rect.minX, y: rect.midY - rowHeight, width: rect.width, height: rowHeight)
    )
}

struct StatsChartLayout: Equatable {
    var panel: NSRect
    var plot: NSRect
    var yAxis: NSRect
    var xAxis: NSRect
}

func statsPopoverChartLayout(in rect: NSRect) -> StatsChartLayout {
    let axisWidth = min(42, max(34, rect.width * 0.13))
    let bottomAxisHeight: CGFloat = 17
    let plot = NSRect(
        x: rect.minX + axisWidth,
        y: rect.minY + 8,
        width: max(1, rect.width - axisWidth - 8),
        height: max(1, rect.height - bottomAxisHeight - 14)
    )

    return StatsChartLayout(
        panel: rect,
        plot: plot,
        yAxis: NSRect(
            x: rect.minX + 4,
            y: plot.minY,
            width: max(1, axisWidth - 10),
            height: plot.height
        ),
        xAxis: NSRect(
            x: plot.minX,
            y: plot.maxY + 3,
            width: plot.width,
            height: max(1, bottomAxisHeight - 4)
        )
    )
}

func statsChartPoint(index: Int, count: Int, value: Double, maxValue: Double, in plot: NSRect) -> NSPoint {
    let xRatio = count <= 1 ? 1 : CGFloat(index) / CGFloat(count - 1)
    let yRatio = maxValue <= 0 ? 0 : CGFloat(min(max(value / maxValue, 0), 1))
    return NSPoint(
        x: plot.minX + xRatio * plot.width,
        y: plot.maxY - yRatio * plot.height
    )
}

func statsMiniGraphBarLayout(in rect: NSRect, barCount: Int) -> (barWidth: CGFloat, gap: CGFloat, firstX: CGFloat) {
    guard barCount > 0 else { return (0, 0, rect.minX) }
    guard barCount > 1 else { return (max(1, rect.width), 0, rect.minX) }

    let minimumGap: CGFloat = 1
    let barWidth = max(1, floor((rect.width - minimumGap * CGFloat(barCount - 1)) / CGFloat(barCount)))
    let gap = max(minimumGap, (rect.width - barWidth * CGFloat(barCount)) / CGFloat(barCount - 1))
    return (barWidth, gap, rect.minX)
}

private func drawMiniGraph(_ values: [Double], in rect: NSRect) {
    guard !values.isEmpty, rect.width > 2, rect.height > 2 else { return }

    NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()

    let barCount = min(values.count, 18)
    let visibleValues = Array(values.suffix(barCount))
    let layout = statsMiniGraphBarLayout(in: rect, barCount: barCount)
    var x = layout.firstX

    for value in visibleValues {
        let percent = clampedPercent(value) / 100
        let height = max(1, rect.height * CGFloat(percent))
        let barRect = NSRect(
            x: x,
            y: rect.minY,
            width: layout.barWidth,
            height: height
        )
        NSColor.systemBlue.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1).fill()
        x += layout.barWidth + layout.gap
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

private func drawVerticalStatsLabel(_ value: String, in rect: NSRect) {
    guard rect.width > 0, rect.height > 0, let context = NSGraphicsContext.current else { return }

    context.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: rect.midX, yBy: rect.midY)
    transform.rotate(byDegrees: 90)
    transform.translateX(by: -rect.height / 2, yBy: -rect.width / 2)
    transform.concat()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: statsVerticalLabelFontSize(for: rect), weight: .bold),
        .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1.0),
        .paragraphStyle: paragraph
    ]
    (value as NSString).draw(
        in: NSRect(x: 0, y: 0, width: rect.height, height: rect.width),
        withAttributes: attributes
    )
    context.restoreGraphicsState()
}

func statsVerticalLabelFontSize(for rect: NSRect) -> CGFloat {
    min(9.5, max(8.0, rect.width - 0.75))
}

private func clampedPercent(_ value: Double) -> Double {
    min(max(value, 0), 100)
}

enum StatsPopoverLayout {
    static func size(for metric: StatsWidgetMetric) -> NSSize {
        switch metric {
        case .cpu:
            return NSSize(width: 360, height: 860)
        case .gpu:
            return NSSize(width: 360, height: 560)
        case .memory:
            return NSSize(width: 360, height: 860)
        case .network:
            return NSSize(width: 360, height: 780)
        }
    }
}

final class StatsPopoverViewController: NSViewController {
    private let metric: StatsWidgetMetric
    private let size: NSSize
    private var refreshTimer: Timer?

    init(metric: StatsWidgetMetric, size: NSSize? = nil) {
        self.metric = metric
        self.size = size ?? StatsPopoverLayout.size(for: metric)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        metric = .cpu
        size = StatsPopoverLayout.size(for: .cpu)
        super.init(coder: coder)
    }

    override func loadView() {
        view = StatsPopoverView(
            frame: NSRect(origin: .zero, size: size),
            metric: metric
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.view.needsDisplay = true
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

private final class StatsPopoverView: NSView {
    private let metric: StatsWidgetMetric

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect, metric: StatsWidgetMetric) {
        self.metric = metric
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        metric = .cpu
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        let snapshot = TaskbarStatsSampler.shared.snapshot()
        let bounds = self.bounds

        NSColor(calibratedWhite: 0.18, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18).fill()

        drawHeader(title: metric.title, in: bounds)
        switch metric {
        case .cpu:
            drawCPUPopup(snapshot: snapshot, in: bounds)
        case .gpu:
            drawGPUPopup(snapshot: snapshot, in: bounds)
        case .memory:
            drawMemoryPopup(snapshot: snapshot, in: bounds)
        case .network:
            drawNetworkPopup(snapshot: snapshot, in: bounds)
        }
    }

    private func drawCPUPopup(snapshot: StatsSnapshot, in bounds: NSRect) {
        drawRing(
            percent: snapshot.cpuPercent,
            title: formattedStatsPercent(snapshot.cpuPercent),
            subtitle: "CPU",
            center: NSPoint(x: 110, y: 116),
            radius: 50,
            color: .systemBlue
        )
        drawRing(
            percent: 100 - snapshot.cpuPercent,
            title: formattedStatsPercent(100 - snapshot.cpuPercent),
            subtitle: "IDLE",
            center: NSPoint(x: bounds.width - 110, y: 116),
            radius: 50,
            color: .systemGray
        )

        drawSectionTitle("USAGE HISTORY", y: 188, in: bounds)
        drawPercentHistory(snapshot.cpuHistory, in: NSRect(x: 18, y: 216, width: bounds.width - 36, height: 112), color: .systemBlue)
        drawCoreSampleBars(snapshot.cpuHistory, in: NSRect(x: 18, y: 336, width: bounds.width - 36, height: 52))

        drawSectionTitle("DETAILS", y: 410, in: bounds)
        drawDetailRow(label: "System:", value: formattedStatsPercent(snapshot.cpuSystemPercent), color: .systemRed, y: 438, in: bounds)
        drawDetailRow(label: "User:", value: formattedStatsPercent(snapshot.cpuUserPercent), color: .systemBlue, y: 468, in: bounds)
        drawDetailRow(label: "Idle:", value: formattedStatsPercent(100 - snapshot.cpuPercent), color: .systemGray, y: 498, in: bounds)
        drawPlainDetailRow(label: "Uptime:", value: formattedUptime(ProcessInfo.processInfo.systemUptime), y: 528, in: bounds)

        drawSectionTitle("TOP PROCESSES", y: 584, in: bounds)
        drawProcessTable(processes: topCPUProcesses(snapshot), value: { formattedStatsPercent($0.cpuPercent) }, y: 618, in: bounds)
    }

    private func drawMemoryPopup(snapshot: StatsSnapshot, in bounds: NSRect) {
        drawGauge(
            percent: snapshot.memoryPercent,
            title: memoryPressureLabel(snapshot.memoryPercent),
            center: NSPoint(x: 100, y: 124),
            radius: 54
        )
        drawRing(
            percent: snapshot.memoryPercent,
            title: formattedStatsPercent(snapshot.memoryPercent),
            subtitle: "RAM",
            center: NSPoint(x: bounds.width - 112, y: 116),
            radius: 56,
            color: .systemPurple
        )

        drawSectionTitle("USAGE HISTORY", y: 202, in: bounds)
        drawPercentHistory(snapshot.memoryHistory, in: NSRect(x: 18, y: 230, width: bounds.width - 36, height: 112), color: .systemBlue)

        let total = max(0, snapshot.memoryTotalBytes)
        let used = max(0, snapshot.memoryUsedBytes)
        let app = max(0, snapshot.memoryAppBytes)
        let wired = max(0, snapshot.memoryWiredBytes)
        let compressed = max(0, snapshot.memoryCompressedBytes)
        let free = max(0, total - used)

        drawSectionTitle("DETAILS", y: 368, in: bounds)
        drawPlainDetailRow(label: "Used:", value: formattedStatsMemoryBytes(used), y: 398, in: bounds)
        drawMemoryBreakdownBar(
            app: app,
            wired: wired,
            compressed: compressed,
            free: free,
            in: NSRect(x: 24, y: 432, width: bounds.width - 48, height: 13)
        )
        drawDetailRow(label: "App:", value: formattedStatsMemoryBytes(app), color: .systemBlue, y: 462, in: bounds)
        drawDetailRow(label: "Wired:", value: formattedStatsMemoryBytes(wired), color: .systemOrange, y: 492, in: bounds)
        drawDetailRow(label: "Compressed:", value: formattedStatsMemoryBytes(compressed), color: .systemPink, y: 522, in: bounds)
        drawDetailRow(label: "Free:", value: formattedStatsMemoryBytes(free), color: .systemGray, y: 552, in: bounds)

        drawSectionTitle("TOP PROCESSES", y: 602, in: bounds)
        drawProcessTable(processes: topMemoryProcesses(snapshot), value: { formattedStatsMemoryBytes($0.memoryBytes) }, y: 636, in: bounds)
    }

    private func drawGPUPopup(snapshot: StatsSnapshot, in bounds: NSRect) {
        drawRing(
            percent: snapshot.gpuPercent,
            title: formattedStatsPercent(snapshot.gpuPercent),
            subtitle: "GPU",
            center: NSPoint(x: bounds.midX, y: 116),
            radius: 54,
            color: .systemBlue
        )
        drawRing(
            percent: snapshot.gpuRenderPercent,
            title: formattedStatsPercent(snapshot.gpuRenderPercent),
            subtitle: "RENDER",
            center: NSPoint(x: 88, y: 116),
            radius: 38,
            color: .systemBlue
        )
        drawRing(
            percent: snapshot.gpuTilerPercent,
            title: formattedStatsPercent(snapshot.gpuTilerPercent),
            subtitle: "TILER",
            center: NSPoint(x: bounds.width - 88, y: 116),
            radius: 38,
            color: .systemTeal
        )

        drawSectionTitle("USAGE HISTORY", y: 188, in: bounds)
        drawPercentHistory(snapshot.gpuHistory, in: NSRect(x: 18, y: 216, width: bounds.width - 36, height: 112), color: .systemBlue)

        drawSectionTitle("DETAILS", y: 356, in: bounds)
        drawPlainDetailRow(label: "Model:", value: snapshot.gpuModel, y: 386, in: bounds)
        drawPlainDetailRow(label: "Cores:", value: snapshot.gpuCores.map(String.init) ?? "Unknown", y: 416, in: bounds)
        drawPlainDetailRow(label: "Utilisation:", value: formattedStatsPercent(snapshot.gpuPercent), y: 446, in: bounds)
        drawPlainDetailRow(label: "Render utilisation:", value: formattedStatsPercent(snapshot.gpuRenderPercent), y: 476, in: bounds)
        drawPlainDetailRow(label: "Tiler utilisation:", value: formattedStatsPercent(snapshot.gpuTilerPercent), y: 506, in: bounds)
    }

    private func drawNetworkPopup(snapshot: StatsSnapshot, in bounds: NSRect) {
        drawTopValue(
            title: "Download",
            value: formattedStatsBytesPerSecond(snapshot.networkDownloadBytesPerSecond),
            color: .systemBlue,
            in: NSRect(x: 56, y: 86, width: 110, height: 62)
        )
        drawTopValue(
            title: "Upload",
            value: formattedStatsBytesPerSecond(snapshot.networkUploadBytesPerSecond),
            color: .systemRed,
            in: NSRect(x: bounds.width - 166, y: 86, width: 110, height: 62)
        )

        drawSectionTitle("USAGE HISTORY", y: 186, in: bounds)
        drawNetworkHistory(
            upload: snapshot.networkUploadHistory,
            download: snapshot.networkDownloadHistory,
            in: NSRect(x: 18, y: 214, width: bounds.width - 36, height: 124)
        )

        drawSectionTitle("CURRENT RATES", y: 366, in: bounds)
        drawDetailRow(label: "Upload:", value: formattedStatsBytesPerSecond(snapshot.networkUploadBytesPerSecond), color: .systemRed, y: 394, in: bounds)
        drawDetailRow(label: "Download:", value: formattedStatsBytesPerSecond(snapshot.networkDownloadBytesPerSecond), color: .systemBlue, y: 424, in: bounds)

        drawSectionTitle("TOP PROCESSES", y: 480, in: bounds)
        drawNetworkProcessTable(snapshot.networkProcesses, y: 514, in: bounds)
    }

    private func topCPUProcesses(_ snapshot: StatsSnapshot) -> [StatsProcessSample] {
        Array(snapshot.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(8))
    }

    private func topMemoryProcesses(_ snapshot: StatsSnapshot) -> [StatsProcessSample] {
        Array(snapshot.processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(8))
    }

    private func drawHeader(title: String, in bounds: NSRect) {
        drawMiniBarsIcon(in: NSRect(x: 22, y: 24, width: 24, height: 22))
        drawCenteredText(
            title,
            in: NSRect(x: 0, y: 18, width: bounds.width, height: 32),
            size: 24,
            weight: .semibold,
            color: .white
        )
        drawCenteredText(
            "⌘",
            in: NSRect(x: bounds.width - 54, y: 17, width: 32, height: 32),
            size: 27,
            weight: .regular,
            color: NSColor(calibratedWhite: 0.78, alpha: 0.9)
        )
    }

    private func drawTopValue(title: String, value: String, color: NSColor, in rect: NSRect) {
        drawStatsText(
            value,
            in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 34),
            size: 28,
            weight: .light,
            color: .white
        )

        let dotRect = NSRect(x: rect.minX, y: rect.minY + 42, width: 14, height: 14)
        color.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: dotRect, xRadius: 3, yRadius: 3).fill()
        drawStatsText(
            title,
            in: NSRect(x: rect.minX + 20, y: rect.minY + 38, width: rect.width - 20, height: 20),
            size: 14,
            weight: .semibold,
            color: NSColor(calibratedWhite: 0.86, alpha: 1)
        )
    }

    private func drawCoreSampleBars(_ values: [Double], in rect: NSRect) {
        NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let barCount = 10
        let gap: CGFloat = 4
        let barWidth = max(2, floor((rect.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)))
        let samples = Array(values.suffix(barCount))
        for index in 0..<barCount {
            let value = samples.indices.contains(index) ? clampedPercent(samples[index]) / 100 : 0
            let height = max(4, rect.height * CGFloat(value))
            let barRect = NSRect(
                x: rect.minX + CGFloat(index) * (barWidth + gap),
                y: rect.maxY - height,
                width: barWidth,
                height: height
            )
            let color = index < 2 ? NSColor.systemTeal : NSColor.systemIndigo
            color.withAlphaComponent(0.78).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 3, yRadius: 3).fill()
        }
    }

    private func drawGauge(percent: Double, title: String, center: NSPoint, radius: CGFloat) {
        let startAngle: CGFloat = 205
        let totalAngle: CGFloat = 130
        let segments: [(CGFloat, CGFloat, NSColor)] = [
            (0, 0.46, .systemGreen),
            (0.46, 0.74, .systemYellow),
            (0.74, 1, .systemRed)
        ]

        for segment in segments {
            let path = NSBezierPath()
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: startAngle - segment.0 * totalAngle,
                endAngle: startAngle - segment.1 * totalAngle,
                clockwise: true
            )
            path.lineWidth = 8
            segment.2.withAlphaComponent(0.95).setStroke()
            path.stroke()
        }

        let needleEnd = statsGaugeNeedleEndpoint(percent: percent, center: center, radius: radius)
        let needle = NSBezierPath()
        needle.move(to: center)
        needle.line(to: needleEnd)
        needle.lineWidth = 2
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
        needle.stroke()

        NSColor.systemBlue.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
        drawCenteredText(
            title,
            in: NSRect(x: center.x - radius, y: center.y + 22, width: radius * 2, height: 18),
            size: 14,
            weight: .semibold,
            color: .white
        )
    }

    private func drawMemoryBreakdownBar(
        app: Double,
        wired: Double,
        compressed: Double,
        free: Double,
        in rect: NSRect
    ) {
        let total = max(app + wired + compressed + free, 1)
        let segments: [(Double, NSColor)] = [
            (app, .systemBlue),
            (wired, .systemOrange),
            (compressed, .systemPink),
            (free, .systemGray)
        ]

        NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()

        if let context = NSGraphicsContext.current {
            context.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            var x = rect.minX
            for segment in segments {
                let width = rect.width * CGFloat(max(0, segment.0) / total)
                guard width > 0.5 else { continue }
                segment.1.withAlphaComponent(0.9).setFill()
                NSRect(x: x, y: rect.minY, width: width, height: rect.height).fill()
                x += width
            }
            context.restoreGraphicsState()
        }
    }

    private func drawPercentHistory(_ values: [Double], in rect: NSRect, color: NSColor) {
        drawChart(
            series: [(values: values, color: color, fillAlpha: 0.26)],
            in: rect,
            maxValue: 100,
            yTicks: [0, 50, 100],
            yLabel: formattedStatsPercent
        )
    }

    private func drawNetworkHistory(upload: [Double], download: [Double], in rect: NSRect) {
        let maxValue = roundedChartMax(max(upload.max() ?? 0, download.max() ?? 0, 1))
        drawChart(
            series: [
                (values: download, color: .systemGreen, fillAlpha: 0.22),
                (values: upload, color: .systemRed, fillAlpha: 0.18)
            ],
            in: rect,
            maxValue: maxValue,
            yTicks: [0, maxValue / 2, maxValue],
            yLabel: formattedStatsBytesPerSecond
        )
    }

    private func drawChart(
        series: [(values: [Double], color: NSColor, fillAlpha: CGFloat)],
        in rect: NSRect,
        maxValue: Double,
        yTicks: [Double],
        yLabel: (Double) -> String
    ) {
        let layout = statsPopoverChartLayout(in: rect)
        drawChartFrame(layout: layout, maxValue: maxValue, yTicks: yTicks, yLabel: yLabel)

        guard maxValue > 0 else { return }

        if let context = NSGraphicsContext.current {
            context.saveGraphicsState()
            NSBezierPath(roundedRect: layout.plot, xRadius: 5, yRadius: 5).addClip()
            for item in series where item.values.count > 1 {
                drawChartSeries(item.values, in: layout.plot, maxValue: maxValue, color: item.color, fillAlpha: item.fillAlpha)
            }
            context.restoreGraphicsState()
        }
    }

    private func drawChartFrame(
        layout: StatsChartLayout,
        maxValue: Double,
        yTicks: [Double],
        yLabel: (Double) -> String
    ) {
        NSColor(calibratedWhite: 1, alpha: 0.09).setFill()
        NSBezierPath(roundedRect: layout.panel, xRadius: 7, yRadius: 7).fill()

        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        let border = NSBezierPath(roundedRect: layout.plot, xRadius: 5, yRadius: 5)
        border.lineWidth = 1
        border.stroke()

        drawChartGrid(layout: layout, maxValue: maxValue, yTicks: yTicks)
        drawChartLabels(layout: layout, maxValue: maxValue, yTicks: yTicks, yLabel: yLabel)
    }

    private func drawChartGrid(layout: StatsChartLayout, maxValue: Double, yTicks: [Double]) {
        let grid = NSBezierPath()
        for tick in yTicks where maxValue > 0 {
            let ratio = CGFloat(min(max(tick / maxValue, 0), 1))
            let y = layout.plot.maxY - ratio * layout.plot.height
            grid.move(to: NSPoint(x: layout.plot.minX, y: y))
            grid.line(to: NSPoint(x: layout.plot.maxX, y: y))
        }

        for index in 0...4 {
            let ratio = CGFloat(index) / 4
            let x = layout.plot.minX + ratio * layout.plot.width
            grid.move(to: NSPoint(x: x, y: layout.plot.minY))
            grid.line(to: NSPoint(x: x, y: layout.plot.maxY))
        }

        grid.lineWidth = 0.75
        NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
        grid.stroke()

        let axes = NSBezierPath()
        axes.move(to: NSPoint(x: layout.plot.minX, y: layout.plot.minY))
        axes.line(to: NSPoint(x: layout.plot.minX, y: layout.plot.maxY))
        axes.line(to: NSPoint(x: layout.plot.maxX, y: layout.plot.maxY))
        axes.lineWidth = 1
        NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
        axes.stroke()
    }

    private func drawChartLabels(
        layout: StatsChartLayout,
        maxValue: Double,
        yTicks: [Double],
        yLabel: (Double) -> String
    ) {
        for tick in yTicks where maxValue > 0 {
            let ratio = CGFloat(min(max(tick / maxValue, 0), 1))
            let y = layout.plot.maxY - ratio * layout.plot.height
            drawRightAlignedText(
                yLabel(tick),
                in: NSRect(x: layout.yAxis.minX, y: y - 6, width: layout.yAxis.width, height: 12),
                size: 8.5,
                weight: .medium,
                color: NSColor(calibratedWhite: 0.64, alpha: 1)
            )
        }

        drawStatsText(
            "older",
            in: NSRect(x: layout.xAxis.minX, y: layout.xAxis.minY, width: 60, height: layout.xAxis.height),
            size: 8.5,
            weight: .medium,
            color: NSColor(calibratedWhite: 0.56, alpha: 1)
        )
        drawRightAlignedText(
            "now",
            in: NSRect(x: layout.xAxis.maxX - 60, y: layout.xAxis.minY, width: 60, height: layout.xAxis.height),
            size: 8.5,
            weight: .medium,
            color: NSColor(calibratedWhite: 0.64, alpha: 1)
        )
    }

    private func drawChartSeries(_ values: [Double], in plot: NSRect, maxValue: Double, color: NSColor, fillAlpha: CGFloat) {
        guard values.count > 1, maxValue > 0 else { return }

        let points = values.enumerated().map { index, value in
            statsChartPoint(index: index, count: values.count, value: value, maxValue: maxValue, in: plot)
        }

        let fillPath = NSBezierPath()
        fillPath.move(to: NSPoint(x: plot.minX, y: plot.maxY))
        points.forEach { fillPath.line(to: $0) }
        fillPath.line(to: NSPoint(x: plot.maxX, y: plot.maxY))
        fillPath.close()
        color.withAlphaComponent(fillAlpha).setFill()
        fillPath.fill()

        let linePath = NSBezierPath()
        linePath.move(to: points[0])
        points.dropFirst().forEach { linePath.line(to: $0) }
        linePath.lineJoinStyle = .round
        linePath.lineCapStyle = .round
        linePath.lineWidth = 2
        color.withAlphaComponent(0.96).setStroke()
        linePath.stroke()
    }

    private func roundedChartMax(_ value: Double) -> Double {
        let value = max(value, 1)
        let magnitude = pow(10, floor(log10(value)))
        let normalized = value / magnitude
        let niceValue: Double
        if normalized <= 1 {
            niceValue = 1
        } else if normalized <= 2 {
            niceValue = 2
        } else if normalized <= 5 {
            niceValue = 5
        } else {
            niceValue = 10
        }
        return niceValue * magnitude
    }

    private func drawProcessTable(
        processes: [StatsProcessSample],
        valueTitle: String = "Usage",
        value: (StatsProcessSample) -> String,
        y: CGFloat,
        in bounds: NSRect
    ) {
        drawStatsText(
            "Process",
            in: NSRect(x: 60, y: y, width: 160, height: 18),
            size: 12,
            weight: .semibold,
            color: NSColor(calibratedWhite: 0.56, alpha: 1)
        )
        drawRightAlignedText(
            valueTitle,
            in: NSRect(x: bounds.width - 116, y: y, width: 92, height: 18),
            size: 12,
            weight: .semibold,
            color: NSColor(calibratedWhite: 0.56, alpha: 1)
        )

        if processes.isEmpty {
            drawStatsText(
                "Sampling processes...",
                in: NSRect(x: 60, y: y + 32, width: bounds.width - 84, height: 20),
                size: 14,
                weight: .medium,
                color: NSColor(calibratedWhite: 0.72, alpha: 1)
            )
            return
        }

        let maxRows = max(0, min(8, Int((bounds.height - y - 56) / 26)))
        for (index, process) in processes.prefix(maxRows).enumerated() {
            let rowY = y + 32 + CGFloat(index) * 26
            drawProcessIcon(path: process.appPath, in: NSRect(x: 24, y: rowY + 3, width: 15, height: 15))
            drawStatsText(
                process.name,
                in: NSRect(x: 52, y: rowY, width: bounds.width - 174, height: 20),
                size: 14,
                weight: .semibold,
                color: NSColor(calibratedWhite: 0.86, alpha: 1)
            )
            drawRightAlignedText(
                value(process),
                in: NSRect(x: bounds.width - 124, y: rowY, width: 100, height: 20),
                size: 14,
                weight: .semibold,
                color: .white
            )
        }
    }

    private func drawNetworkProcessTable(_ processes: [StatsNetworkProcessSample], y: CGFloat, in bounds: NSRect) {
        drawStatsText(
            "Process",
            in: NSRect(x: 60, y: y, width: 160, height: 18),
            size: 12,
            weight: .semibold,
            color: NSColor(calibratedWhite: 0.56, alpha: 1)
        )

        NSColor.systemBlue.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.width - 112, y: y + 2, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
        NSColor.systemRed.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.width - 42, y: y + 2, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()

        if processes.isEmpty {
            drawStatsText(
                "Sampling network processes...",
                in: NSRect(x: 60, y: y + 32, width: bounds.width - 84, height: 20),
                size: 14,
                weight: .medium,
                color: NSColor(calibratedWhite: 0.72, alpha: 1)
            )
            return
        }

        let maxRows = max(0, min(8, Int((bounds.height - y - 56) / 26)))
        for (index, process) in processes.prefix(maxRows).enumerated() {
            let rowY = y + 32 + CGFloat(index) * 26
            drawProcessIcon(path: process.appPath, in: NSRect(x: 24, y: rowY + 3, width: 15, height: 15))
            drawStatsText(
                process.name,
                in: NSRect(x: 52, y: rowY, width: bounds.width - 190, height: 20),
                size: 14,
                weight: .semibold,
                color: NSColor(calibratedWhite: 0.86, alpha: 1)
            )
            drawRightAlignedText(
                formattedStatsBytesPerSecond(process.downloadBytesPerSecond),
                in: NSRect(x: bounds.width - 150, y: rowY, width: 74, height: 20),
                size: 12.5,
                weight: .semibold,
                color: .white
            )
            drawRightAlignedText(
                formattedStatsBytesPerSecond(process.uploadBytesPerSecond),
                in: NSRect(x: bounds.width - 74, y: rowY, width: 50, height: 20),
                size: 12.5,
                weight: .semibold,
                color: .white
            )
        }
    }

    private func drawProcessIcon(path: String, in rect: NSRect) {
        if !path.isEmpty {
            NSWorkspace.shared.icon(forFile: path).draw(in: rect)
            return
        }

        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        NSColor.systemGreen.withAlphaComponent(0.35).setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
    }

    private func drawPlainDetailRow(label: String, value: String, y: CGFloat, in bounds: NSRect) {
        drawStatsText(
            label,
            in: NSRect(x: 24, y: y, width: 176, height: 20),
            size: 14,
            weight: .medium,
            color: NSColor(calibratedWhite: 0.86, alpha: 1)
        )
        drawRightAlignedText(
            value,
            in: NSRect(x: bounds.width - 194, y: y, width: 170, height: 20),
            size: 14,
            weight: .semibold,
            color: .white
        )
    }

    private func drawDetailRow(label: String, value: String, color: NSColor, y: CGFloat, in bounds: NSRect) {
        let dotRect = NSRect(x: 24, y: y + 6, width: 9, height: 9)
        color.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: dotRect, xRadius: 2, yRadius: 2).fill()

        drawStatsText(
            label,
            in: NSRect(x: 44, y: y, width: 180, height: 20),
            size: 14,
            weight: .medium,
            color: NSColor(calibratedWhite: 0.86, alpha: 1)
        )
        drawRightAlignedText(
            value,
            in: NSRect(x: bounds.width - 162, y: y, width: 138, height: 20),
            size: 14,
            weight: .semibold,
            color: .white
        )
    }

    private func drawRing(percent: Double, title: String, subtitle: String, center: NSPoint, radius: CGFloat, color: NSColor) {
        let basePath = NSBezierPath()
        basePath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        basePath.lineWidth = 9
        NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
        basePath.stroke()

        let valuePath = NSBezierPath()
        valuePath.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - CGFloat(clampedPercent(percent) / 100 * 360),
            clockwise: true
        )
        valuePath.lineWidth = 9
        color.withAlphaComponent(0.95).setStroke()
        valuePath.stroke()

        drawCenteredText(
            title,
            in: NSRect(x: center.x - radius + 4, y: center.y - 12, width: radius * 2 - 8, height: 18),
            size: radius > 38 ? 20 : 15,
            weight: .semibold,
            color: .white
        )
        drawCenteredText(
            subtitle,
            in: NSRect(x: center.x - radius, y: center.y + 8, width: radius * 2, height: 14),
            size: 10,
            weight: .medium,
            color: NSColor(calibratedWhite: 0.72, alpha: 1)
        )
    }

    private func drawSectionTitle(_ title: String, y: CGFloat, in bounds: NSRect) {
        let lineY = y + 9
        let titleWidth = min(bounds.width - 120, max(92, CGFloat(title.count) * 9.5))
        let titleMinX = (bounds.width - titleWidth) / 2
        let leftLineMaxX = max(18, titleMinX - 16)
        let rightLineMinX = min(bounds.width - 18, titleMinX + titleWidth + 16)

        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: 18, y: lineY), to: NSPoint(x: leftLineMaxX, y: lineY))
        NSBezierPath.strokeLine(from: NSPoint(x: rightLineMinX, y: lineY), to: NSPoint(x: bounds.width - 18, y: lineY))
        drawCenteredText(
            title,
            in: NSRect(x: titleMinX, y: y, width: titleWidth, height: 20),
            size: 12,
            weight: .semibold,
            color: NSColor(calibratedWhite: 0.56, alpha: 1)
        )
    }

    private func drawMiniBarsIcon(in rect: NSRect) {
        let values: [CGFloat] = [0.45, 0.72, 0.95]
        let width = rect.width / 4
        for (index, value) in values.enumerated() {
            let height = rect.height * value
            let barRect = NSRect(
                x: rect.minX + CGFloat(index) * (width + 2),
                y: rect.maxY - height,
                width: width,
                height: height
            )
            NSColor(calibratedWhite: 0.86, alpha: 1).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawCenteredText(_ value: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (value as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func drawRightAlignedText(_ value: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (value as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func memoryPressureLabel(_ percent: Double) -> String {
        switch clampedPercent(percent) {
        case 0..<70:
            return "Normal"
        case 70..<88:
            return "High"
        default:
            return "Critical"
        }
    }

    private func formattedUptime(_ uptime: TimeInterval) -> String {
        let totalMinutes = max(0, Int(uptime / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days) day, \(hours) hours" : "\(days) day, \(minutes) minutes"
        }
        if hours > 0 {
            return "\(hours) hours, \(minutes) minutes"
        }
        return "\(minutes) minutes"
    }
}
