import Foundation
import XCTest
@testable import TaskbarApp

final class TaskbarStatsSamplerTests: XCTestCase {
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
