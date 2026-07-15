import Foundation
import XCTest
@testable import TaskbarApp

final class TaskbarStatsSamplerTests: XCTestCase {
    func testCPUPercentUsesOnlySampleDeltasWithoutOverflowing() throws {
        let sinceBootTicks: [UInt32] = [
            2_500_000_000,
            900_000_000,
            3_000_000_000,
            700_000_000
        ]

        XCTAssertNil(cpuPercent(currentTicks: sinceBootTicks, previousTicks: nil))

        let secondSamplePercent = try XCTUnwrap(
            cpuPercent(
                currentTicks: [2_500_000_060, 900_000_020, 3_000_000_120, 700_000_000],
                previousTicks: sinceBootTicks
            )
        )
        XCTAssertEqual(secondSamplePercent, 40, accuracy: 0.001)

        let largeDeltaPercent = try XCTUnwrap(
            cpuPercent(
                currentTicks: sinceBootTicks,
                previousTicks: [0, 0, 0, 0]
            )
        )
        XCTAssertEqual(
            largeDeltaPercent,
            4_100_000_000.0 / 7_100_000_000.0 * 100,
            accuracy: 0.001
        )

        let wrappedCounterPercent = try XCTUnwrap(
            cpuPercent(
                currentTicks: [5, 120, 230, 310],
                previousTicks: [UInt32.max - 10, 100, 200, 300]
            )
        )
        XCTAssertEqual(wrappedCounterPercent, 46.0 / 76.0 * 100, accuracy: 0.001)
    }

    func testCommandOutputDrainsLargeOutputBeforeWaitingForExit() {
        let startedAt = Date()
        let output = runStatsCommandOutput(
            "/bin/sh",
            arguments: ["-c", "yes 1234567890 | head -n 20000"],
            timeout: 3
        )

        XCTAssertNotNil(output)
        XCTAssertGreaterThan(output?.count ?? 0, 100_000)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    func testCommandOutputTimesOutStuckCommands() {
        let startedAt = Date()
        let output = runStatsCommandOutput("/bin/sleep", arguments: ["5"], timeout: 0.1)

        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testSnapshotDoesNotWaitForCommandBackedStatsReaders() {
        let sampler = TaskbarStatsSampler(
            commandOutput: { _, _ in
                Thread.sleep(forTimeInterval: 0.5)
                return nil
            },
            backgroundQueue: DispatchQueue(label: "TaskbarStatsSamplerTests.background")
        )

        let startedAt = Date()
        _ = sampler.snapshot(now: Date(timeIntervalSince1970: 1_000))

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.2)
    }

    func testSnapshotPublishesProcessSamplesAfterBackgroundRefresh() {
        let queue = DispatchQueue(label: "TaskbarStatsSamplerTests.processes")
        let sampler = TaskbarStatsSampler(
            commandOutput: { executable, _ in
                guard executable == "/bin/ps" else { return nil }
                return "987654 45.6 789 /Applications/Foo.app/Contents/MacOS/Foo\n"
            },
            backgroundQueue: queue
        )

        _ = sampler.snapshot(now: Date(timeIntervalSince1970: 1_000))
        queue.sync {}
        let snapshot = sampler.snapshot(now: Date(timeIntervalSince1970: 1_001))

        XCTAssertEqual(snapshot.processes.first?.pid, 987_654)
        XCTAssertEqual(snapshot.processes.first?.cpuPercent, 45.6)
        XCTAssertEqual(snapshot.processes.first?.memoryBytes, 789 * 1024)
    }

    func testUniquePositiveProcessLookupIgnoresInvalidAndDuplicatePIDs() {
        let lookup = uniquePositiveProcessLookup([
            (42, "first"),
            (-1, "transient"),
            (42, "duplicate"),
            (7, "other")
        ])

        XCTAssertEqual(lookup[42], "first")
        XCTAssertEqual(lookup[7], "other")
        XCTAssertNil(lookup[-1])
    }
}
