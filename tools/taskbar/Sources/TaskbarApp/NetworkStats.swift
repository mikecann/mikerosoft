import Darwin
import Foundation

// 100 gigabits per second divided by 8 bits per byte.
let maximumPlausibleNetworkBytesPerSecond: UInt64 = 12_500_000_000

enum NetworkCounterWidth: Equatable {
    case bits32
    case bits64
}

struct NetworkInterfaceCounters: Equatable {
    let upload: UInt64
    let download: UInt64
    let width: NetworkCounterWidth

    init(upload: UInt64, download: UInt64, width: NetworkCounterWidth = .bits64) {
        self.upload = upload
        self.download = download
        self.width = width
    }
}

struct NetworkTransferRates: Equatable {
    var upload: Double
    var download: Double

    static let zero = NetworkTransferRates(upload: 0, download: 0)
}

func readNetworkInterfaceCounters64() -> [String: NetworkInterfaceCounters]? {
    var mib = [
        Int32(CTL_NET),
        Int32(PF_LINK),
        Int32(NETLINK_GENERIC),
        Int32(IFMIB_IFALLDATA),
        0,
        Int32(IFDATA_GENERAL)
    ]

    // The interface table can grow between the size query and the read.
    for _ in 0..<3 {
        var requiredLength = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer { mibBuffer in
            sysctl(
                mibBuffer.baseAddress,
                UInt32(mibBuffer.count),
                nil,
                &requiredLength,
                nil,
                0
            )
        }
        guard sizeResult == 0 else { return nil }
        guard requiredLength > 0 else { return [:] }

        var data = Data(count: requiredLength)
        var actualLength = requiredLength
        let readResult = data.withUnsafeMutableBytes { dataBuffer in
            mib.withUnsafeMutableBufferPointer { mibBuffer in
                sysctl(
                    mibBuffer.baseAddress,
                    UInt32(mibBuffer.count),
                    dataBuffer.baseAddress,
                    &actualLength,
                    nil,
                    0
                )
            }
        }

        if readResult == 0 {
            guard actualLength <= data.count else { return nil }
            data.removeSubrange(actualLength..<data.count)
            return parseNetworkInterfaceCounters(data)
        }

        guard errno == ENOMEM else { return nil }
    }

    return nil
}

func parseNetworkInterfaceCounters(_ data: Data) -> [String: NetworkInterfaceCounters]? {
    let recordSize = MemoryLayout<ifmibdata>.stride
    guard data.count.isMultiple(of: recordSize) else { return nil }

    return data.withUnsafeBytes { bytes in
        var counters: [String: NetworkInterfaceCounters] = [:]

        for offset in stride(from: 0, to: bytes.count, by: recordSize) {
            let record = bytes.loadUnaligned(fromByteOffset: offset, as: ifmibdata.self)
            let flags = record.ifmd_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0,
                  let name = networkInterfaceName(from: record)
            else {
                continue
            }

            counters[name] = NetworkInterfaceCounters(
                upload: record.ifmd_data.ifi_obytes,
                download: record.ifmd_data.ifi_ibytes,
                width: .bits64
            )
        }

        return counters
    }
}

private func networkInterfaceName(from record: ifmibdata) -> String? {
    var nameBytes = record.ifmd_name
    return withUnsafeBytes(of: &nameBytes) { bytes in
        guard let terminator = bytes.firstIndex(of: 0), terminator > 0 else { return nil }
        return String(bytes: bytes[..<terminator], encoding: .utf8)
    }
}

func networkTransferRates(
    previous: [String: NetworkInterfaceCounters],
    current: [String: NetworkInterfaceCounters],
    elapsed: TimeInterval
) -> NetworkTransferRates {
    guard elapsed > 0, elapsed.isFinite else { return .zero }

    var rates = NetworkTransferRates.zero

    for (name, counters) in current {
        guard let oldCounters = previous[name], oldCounters.width == counters.width else { continue }

        if let delta = networkCounterDelta(
            current: counters.upload,
            previous: oldCounters.upload,
            width: counters.width
        ) {
            rates.upload += plausibleNetworkRate(delta: delta, elapsed: elapsed)
        }
        if let delta = networkCounterDelta(
            current: counters.download,
            previous: oldCounters.download,
            width: counters.width
        ) {
            rates.download += plausibleNetworkRate(delta: delta, elapsed: elapsed)
        }
    }

    let maximumRate = Double(maximumPlausibleNetworkBytesPerSecond)
    if rates.upload > maximumRate {
        rates.upload = 0
    }
    if rates.download > maximumRate {
        rates.download = 0
    }
    return rates
}

private func plausibleNetworkRate(delta: UInt64, elapsed: TimeInterval) -> Double {
    let rate = Double(delta) / elapsed
    guard rate <= Double(maximumPlausibleNetworkBytesPerSecond) else { return 0 }
    return rate
}

private func networkCounterDelta(
    current: UInt64,
    previous: UInt64,
    width: NetworkCounterWidth
) -> UInt64? {
    if current >= previous {
        return current - previous
    }

    // A value regression is ambiguous between a wrap and a reset. The
    // if_data64 source never wraps in this process lifetime, so modulo math is
    // reserved for readers that explicitly identify their counters as 32-bit.
    guard width == .bits32 else { return nil }

    let maximum32BitCounter = UInt64(UInt32.max)
    guard current <= maximum32BitCounter, previous <= maximum32BitCounter else {
        return nil
    }

    return maximum32BitCounter - previous + 1 + current
}
