import Darwin
import Foundation
import XCTest
@testable import TaskbarApp

private func interfaceMessage(
    index: UInt16,
    flags: Int32,
    upload: UInt64,
    download: UInt64
) -> Data {
    var message = if_msghdr2()
    message.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
    message.ifm_version = UInt8(RTM_VERSION)
    message.ifm_type = UInt8(RTM_IFINFO2)
    message.ifm_flags = flags
    message.ifm_index = index
    message.ifm_data.ifi_obytes = upload
    message.ifm_data.ifi_ibytes = download
    return withUnsafeBytes(of: &message) { Data($0) }
}

private func routeMessage(length: Int, type: UInt8) -> Data {
    precondition(length >= 4 && length <= Int(UInt16.max))
    var data = Data(repeating: 0, count: length)
    var encodedLength = UInt16(length)
    withUnsafeBytes(of: &encodedLength) { bytes in
        data.replaceSubrange(0..<MemoryLayout<UInt16>.size, with: bytes)
    }
    data[2] = UInt8(RTM_VERSION)
    data[3] = type
    return data
}

final class NetworkStatsTests: XCTestCase {
    func testParserReadsNamed64BitCountersFromUpNonLoopbackInterfaces() throws {
        var data = interfaceMessage(
            index: 4,
            flags: Int32(IFF_UP),
            upload: UInt64(UInt32.max) + 123,
            download: UInt64(UInt32.max) + 456
        )
        data.append(interfaceMessage(
            index: 5,
            flags: 0,
            upload: 1_000,
            download: 2_000
        ))
        data.append(interfaceMessage(
            index: 6,
            flags: Int32(IFF_UP | IFF_LOOPBACK),
            upload: 3_000,
            download: 4_000
        ))

        let counters = try XCTUnwrap(parseNetworkInterfaceCounters(
            data,
            interfaceNameAtIndex: { [4: "en0", 5: "en1", 6: "lo0"][$0] }
        ))

        XCTAssertEqual(counters, [
            "en0": NetworkInterfaceCounters(
                upload: UInt64(UInt32.max) + 123,
                download: UInt64(UInt32.max) + 456,
                width: .bits64
            )
        ])
    }

    func testParserRejectsATruncatedRecordInsteadOfReadingPastTheBuffer() {
        let complete = interfaceMessage(
            index: 4,
            flags: Int32(IFF_UP),
            upload: 1_000,
            download: 2_000
        )

        XCTAssertNil(parseNetworkInterfaceCounters(
            Data(complete.dropLast()),
            interfaceNameAtIndex: { _ in "en0" }
        ))
    }

    func testParserRejectsZeroLengthAndShortInterfaceRecords() {
        XCTAssertNil(parseNetworkInterfaceCounters(
            Data(repeating: 0, count: 4),
            interfaceNameAtIndex: { _ in "en0" }
        ))
        XCTAssertNil(parseNetworkInterfaceCounters(
            routeMessage(length: 8, type: UInt8(RTM_IFINFO2)),
            interfaceNameAtIndex: { _ in "en0" }
        ))
    }

    func testParserSkipsOtherVariableLengthRouteMessages() throws {
        var data = routeMessage(length: 12, type: UInt8(RTM_NEWADDR))
        data.append(interfaceMessage(
            index: 4,
            flags: Int32(IFF_UP),
            upload: 123,
            download: 456
        ))

        let counters = try XCTUnwrap(parseNetworkInterfaceCounters(
            data,
            interfaceNameAtIndex: { $0 == 4 ? "en0" : nil }
        ))

        XCTAssertEqual(counters["en0"], NetworkInterfaceCounters(upload: 123, download: 456))
    }
}
