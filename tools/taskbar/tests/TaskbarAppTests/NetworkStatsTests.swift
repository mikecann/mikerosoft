import Darwin
import Foundation
import XCTest
@testable import TaskbarApp

private func interfaceRecord(
    name: String,
    flags: UInt32,
    upload: UInt64,
    download: UInt64
) -> Data {
    var record = ifmibdata()
    withUnsafeMutableBytes(of: &record.ifmd_name) { nameBytes in
        let encodedName = Array(name.utf8.prefix(nameBytes.count - 1))
        nameBytes.copyBytes(from: encodedName)
        nameBytes[encodedName.count] = 0
    }
    record.ifmd_flags = flags
    record.ifmd_data.ifi_obytes = upload
    record.ifmd_data.ifi_ibytes = download
    return withUnsafeBytes(of: &record) { Data($0) }
}

final class NetworkStatsTests: XCTestCase {
    func testParserReadsNamed64BitCountersFromUpNonLoopbackInterfaces() throws {
        var data = interfaceRecord(
            name: "en0",
            flags: UInt32(IFF_UP),
            upload: UInt64(UInt32.max) + 123,
            download: UInt64(UInt32.max) + 456
        )
        data.append(interfaceRecord(
            name: "en1",
            flags: 0,
            upload: 1_000,
            download: 2_000
        ))
        data.append(interfaceRecord(
            name: "lo0",
            flags: UInt32(IFF_UP | IFF_LOOPBACK),
            upload: 3_000,
            download: 4_000
        ))

        let counters = try XCTUnwrap(parseNetworkInterfaceCounters(data))

        XCTAssertEqual(counters, [
            "en0": NetworkInterfaceCounters(
                upload: UInt64(UInt32.max) + 123,
                download: UInt64(UInt32.max) + 456,
                width: .bits64
            )
        ])
    }

    func testParserRejectsDataWhoseLengthIsNotAWholeRecord() {
        let complete = interfaceRecord(
            name: "en0",
            flags: UInt32(IFF_UP),
            upload: 1_000,
            download: 2_000
        )

        XCTAssertNil(parseNetworkInterfaceCounters(Data(complete.dropLast())))
        XCTAssertNil(parseNetworkInterfaceCounters(Data([0])))
    }

    func testParserSkipsARecordWithoutATerminatedInterfaceName() throws {
        var record = ifmibdata()
        _ = withUnsafeMutableBytes(of: &record.ifmd_name) { nameBytes in
            nameBytes.initializeMemory(as: UInt8.self, repeating: 0x61)
        }
        record.ifmd_flags = UInt32(IFF_UP)
        record.ifmd_data.ifi_obytes = 123
        record.ifmd_data.ifi_ibytes = 456
        let data = withUnsafeBytes(of: &record) { Data($0) }

        let counters = try XCTUnwrap(parseNetworkInterfaceCounters(data))

        XCTAssertTrue(counters.isEmpty)
    }
}
