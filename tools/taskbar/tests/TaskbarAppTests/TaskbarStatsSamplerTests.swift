import Foundation
import XCTest
@testable import TaskbarApp

final class TaskbarStatsSamplerTests: XCTestCase {
    func testStatsSnapshotEqualityIncludesMeasuredBreakdowns() {
        var changed = StatsSnapshot.empty
        changed.cpuUserPercent = 1
        XCTAssertNotEqual(changed, .empty)

        changed = .empty
        changed.memoryCompressedBytes = 1
        XCTAssertNotEqual(changed, .empty)
    }

    func testCPUUsageSplitsRealTickDeltasAndFoldsNiceIntoUser() throws {
        let usage = try XCTUnwrap(
            cpuUsage(
                currentTicks: [130, 220, 350, 410],
                previousTicks: [100, 200, 300, 400]
            )
        )

        XCTAssertEqual(usage.userPercent, 40.0 / 110.0 * 100, accuracy: 0.001)
        XCTAssertEqual(usage.systemPercent, 20.0 / 110.0 * 100, accuracy: 0.001)
        XCTAssertEqual(usage.idlePercent, 50.0 / 110.0 * 100, accuracy: 0.001)
        XCTAssertEqual(usage.activePercent, 60.0 / 110.0 * 100, accuracy: 0.001)
        XCTAssertEqual(usage.userPercent + usage.systemPercent, usage.activePercent, accuracy: 0.001)
    }

    func testCPUUsageRejectsSamplesWithoutAnInterval() {
        let ticks: [UInt32] = [100, 200, 300, 400]

        XCTAssertNil(cpuUsage(currentTicks: ticks, previousTicks: nil))
        XCTAssertNil(cpuUsage(currentTicks: ticks, previousTicks: ticks))
    }

    func testSnapshotPublishesAndPreservesRealCPUSplit() {
        var readings: [[UInt32]?] = [
            [100, 200, 300, 400],
            [140, 220, 330, 410],
            nil
        ]
        let sampler = TaskbarStatsSampler(
            commandOutput: { _, _ in nil },
            backgroundQueue: DispatchQueue(label: "TaskbarStatsSamplerTests.cpu"),
            cpuTickReader: { readings.removeFirst() }
        )

        _ = sampler.snapshot(now: Date(timeIntervalSince1970: 1_000))
        let measured = sampler.snapshot(now: Date(timeIntervalSince1970: 1_001))
        let cached = sampler.snapshot(now: Date(timeIntervalSince1970: 1_002))

        XCTAssertEqual(measured.cpuPercent, 70, accuracy: 0.001)
        XCTAssertEqual(measured.cpuUserPercent, 50, accuracy: 0.001)
        XCTAssertEqual(measured.cpuSystemPercent, 20, accuracy: 0.001)
        XCTAssertEqual(cached.cpuPercent, measured.cpuPercent, accuracy: 0.001)
        XCTAssertEqual(cached.cpuUserPercent, measured.cpuUserPercent, accuracy: 0.001)
        XCTAssertEqual(cached.cpuSystemPercent, measured.cpuSystemPercent, accuracy: 0.001)
    }

    func testMemoryBreakdownUsesMeasuredComponentsAndAccountsForUsedBytes() {
        let breakdown = memoryBreakdown(
            usedBytes: 16_000,
            wiredBytes: 3_000,
            compressedBytes: 2_000
        )

        XCTAssertEqual(breakdown.appBytes, 11_000, accuracy: 0.001)
        XCTAssertEqual(breakdown.wiredBytes, 3_000, accuracy: 0.001)
        XCTAssertEqual(breakdown.compressedBytes, 2_000, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(breakdown.appBytes, 0)
        XCTAssertGreaterThanOrEqual(breakdown.wiredBytes, 0)
        XCTAssertGreaterThanOrEqual(breakdown.compressedBytes, 0)
        XCTAssertEqual(
            breakdown.appBytes + breakdown.wiredBytes + breakdown.compressedBytes,
            16_000,
            accuracy: 0.001
        )
    }

    func testMemoryBreakdownClampsOnlyAppAndPreservesMeasuredComponents() {
        let breakdown = memoryBreakdown(
            usedBytes: 10_000,
            wiredBytes: 8_000,
            compressedBytes: 4_000
        )

        XCTAssertEqual(breakdown.appBytes, 0, accuracy: 0.001)
        XCTAssertEqual(breakdown.wiredBytes, 8_000, accuracy: 0.001)
        XCTAssertEqual(breakdown.compressedBytes, 4_000, accuracy: 0.001)
        XCTAssertEqual(breakdown.usedBytes, 12_000, accuracy: 0.001)
    }

    func testSnapshotPublishesAndPreservesMeasuredMemoryBreakdown() {
        let measuredUsage = MemoryUsage(
            percent: 60,
            usedBytes: 6_000,
            totalBytes: 10_000,
            appBytes: 3_000,
            wiredBytes: 2_000,
            compressedBytes: 1_000
        )
        var readings: [MemoryUsage?] = [measuredUsage, nil]
        let sampler = TaskbarStatsSampler(
            commandOutput: { _, _ in nil },
            backgroundQueue: DispatchQueue(label: "TaskbarStatsSamplerTests.memory"),
            memoryReader: { readings.removeFirst() }
        )

        let measured = sampler.snapshot(now: Date(timeIntervalSince1970: 1_000))
        let cached = sampler.snapshot(now: Date(timeIntervalSince1970: 1_001))

        XCTAssertEqual(measured.memoryAppBytes, 3_000, accuracy: 0.001)
        XCTAssertEqual(measured.memoryWiredBytes, 2_000, accuracy: 0.001)
        XCTAssertEqual(measured.memoryCompressedBytes, 1_000, accuracy: 0.001)
        XCTAssertEqual(cached.memoryUsedBytes, measured.memoryUsedBytes, accuracy: 0.001)
        XCTAssertEqual(cached.memoryAppBytes, measured.memoryAppBytes, accuracy: 0.001)
        XCTAssertEqual(cached.memoryWiredBytes, measured.memoryWiredBytes, accuracy: 0.001)
        XCTAssertEqual(cached.memoryCompressedBytes, measured.memoryCompressedBytes, accuracy: 0.001)
    }

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

        let allCountersWrapped = try XCTUnwrap(
            cpuUsage(
                currentTicks: [4, 5, 6, 7],
                previousTicks: [UInt32.max - 5, UInt32.max - 4, UInt32.max - 3, UInt32.max - 2]
            )
        )
        XCTAssertEqual(allCountersWrapped.activePercent, 75, accuracy: 0.001)
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
