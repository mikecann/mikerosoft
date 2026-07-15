import AppKit
import XCTest
@testable import TaskbarApp

final class TaskbarIconCacheTests: XCTestCase {
    func testFailedLoadRetriesOnlyAfterBackoffExpires() {
        let queue = DispatchQueue(label: "TaskbarIconCacheTests.loader")
        var now = Date(timeIntervalSince1970: 1_000)
        var loadCount = 0
        let cache = TaskbarIconCache(
            retryInterval: 10,
            now: { now },
            queue: queue,
            iconLoader: { _ in
                loadCount += 1
                return nil
            }
        )
        let item = TaskbarItem(
            owner: "Missing",
            pid: nil,
            title: "Missing",
            windowCount: 0,
            windowIDs: [],
            windowBounds: nil,
            accessibilitySignature: "",
            isFrontmost: false,
            isMinimized: false,
            bundleID: "com.example.missing",
            appPath: "/Applications/Missing.app",
            isPinned: true,
            pinOrder: 0
        )

        XCTAssertNil(cache.icon(for: item))
        queue.sync {}
        XCTAssertEqual(loadCount, 1)

        now.addTimeInterval(9.9)
        XCTAssertNil(cache.icon(for: item))
        queue.sync {}
        XCTAssertEqual(loadCount, 1)

        now.addTimeInterval(0.1)
        XCTAssertNil(cache.icon(for: item))
        queue.sync {}
        XCTAssertEqual(loadCount, 2)
    }

    func testRetryCheckPurgesExpiredFailuresButKeepsBlockedFailures() {
        let queue = DispatchQueue(label: "TaskbarIconCacheTests.loader")
        var now = Date(timeIntervalSince1970: 1_000)
        var loadCount = 0
        let cache = TaskbarIconCache(
            retryInterval: 10,
            now: { now },
            queue: queue,
            iconLoader: { _ in
                loadCount += 1
                return nil
            }
        )

        func item(pid: pid_t) -> TaskbarItem {
            TaskbarItem(
                owner: "Missing",
                pid: pid,
                title: "Missing",
                windowCount: 0,
                windowIDs: [],
                windowBounds: nil,
                accessibilitySignature: "",
                isFrontmost: false,
                isMinimized: false,
                bundleID: "com.example.missing",
                appPath: "/Applications/Missing.app",
                isPinned: false,
                pinOrder: nil
            )
        }

        XCTAssertNil(cache.icon(for: item(pid: 101)))
        queue.sync {}

        now.addTimeInterval(5)
        XCTAssertNil(cache.icon(for: item(pid: 202)))
        queue.sync {}
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(failedRequestCount(in: cache), 2)

        now.addTimeInterval(5)
        XCTAssertNil(cache.icon(for: item(pid: 202)))
        queue.sync {}

        XCTAssertEqual(loadCount, 2, "The unexpired failure should still block a reload")
        XCTAssertEqual(failedRequestCount(in: cache), 1, "The expired failure should be purged")
    }

    private func failedRequestCount(in cache: TaskbarIconCache) -> Int {
        guard let failedAt = Mirror(reflecting: cache).children.first(where: { $0.label == "failedAt" })?.value
            as? [String: Date]
        else {
            XCTFail("TaskbarIconCache failedAt storage was not found")
            return -1
        }
        return failedAt.count
    }
}
