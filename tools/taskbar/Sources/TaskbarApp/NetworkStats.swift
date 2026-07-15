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
        Int32(PF_ROUTE),
        0,
        Int32(AF_UNSPEC),
        Int32(NET_RT_IFLIST2),
        0
    ]

    // The routing table can grow between the size query and the read.
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
            return parseNetworkInterfaceCounters(
                data,
                interfaceNameAtIndex: networkInterfaceName(at:)
            )
        }

        guard errno == ENOMEM else { return nil }
    }

    return nil
}

private func networkInterfaceName(at index: UInt32) -> String? {
    guard index > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))

    return buffer.withUnsafeMutableBufferPointer { nameBuffer in
        guard let baseAddress = nameBuffer.baseAddress,
              if_indextoname(index, baseAddress) != nil
        else {
            return nil
        }
        return String(cString: baseAddress)
    }
}

func parseNetworkInterfaceCounters(
    _ data: Data,
    interfaceNameAtIndex: (UInt32) -> String?
) -> [String: NetworkInterfaceCounters]? {
    data.withUnsafeBytes { bytes -> [String: NetworkInterfaceCounters]? in
        var counters: [String: NetworkInterfaceCounters] = [:]
        var offset = 0

        while offset < bytes.count {
            let remaining = bytes.count - offset
            guard remaining >= 4 else { return nil }

            let messageLength = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard messageLength >= 4, messageLength <= remaining else { return nil }

            let messageType = bytes.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self)
            if messageType == UInt8(RTM_IFINFO2) {
                guard messageLength >= MemoryLayout<if_msghdr2>.size else { return nil }
                let message = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let flags = message.ifm_flags

                if (flags & Int32(IFF_UP)) != 0,
                   (flags & Int32(IFF_LOOPBACK)) == 0,
                   let name = interfaceNameAtIndex(UInt32(message.ifm_index)),
                   !name.isEmpty {
                    counters[name] = NetworkInterfaceCounters(
                        upload: message.ifm_data.ifi_obytes,
                        download: message.ifm_data.ifi_ibytes,
                        width: .bits64
                    )
                }
            }

            offset += messageLength
        }

        return counters
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
