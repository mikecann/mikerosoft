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
}
