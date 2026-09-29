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

    /// Tandem got a new icon while the taskbar ran, and the taskbar kept
    /// showing the blank one it loaded first. A relaunched app (a new pid)
    /// has its icon loaded again; the old one shows until it arrives.
    func testRelaunchedAppLoadsItsIconAgain() {
        let queue = DispatchQueue(label: "TaskbarIconCacheTests.loader")
        let blank = Self.image(gray: 0.8)
        let amber = Self.image(gray: 0.3)
        var loads = 0
        let cache = TaskbarIconCache(
            retryInterval: 10,
            queue: queue,
            iconLoader: { _ in
                loads += 1
                return loads == 1 ? blank : amber
            }
        )
        func item(pid: pid_t?) -> TaskbarItem {
            TaskbarItem(
                owner: "Tandem",
                pid: pid,
                title: "Decision Models v14",
                windowCount: 1,
                windowIDs: [],
                windowBounds: nil,
                accessibilitySignature: "",
                isFrontmost: false,
                isMinimized: false,
                bundleID: "com.mikerosoft.tandem",
                appPath: "/Users/mike/Applications/Tandem.app",
                isPinned: pid == nil,
                pinOrder: nil
            )
        }

        XCTAssertNil(cache.icon(for: item(pid: 101)))
        queue.sync {}
        XCTAssertTrue(cache.icon(for: item(pid: 101)) === blank)
        XCTAssertEqual(loads, 1, "the same process keeps its icon")

        XCTAssertTrue(cache.icon(for: item(pid: 202)) === blank, "the old icon shows while the new one loads")
        queue.sync {}
        XCTAssertEqual(loads, 2)
        XCTAssertTrue(cache.icon(for: item(pid: 202)) === amber)

        XCTAssertTrue(cache.icon(for: item(pid: 101)) === amber, "a process already seen doesn't load again")
        XCTAssertTrue(cache.icon(for: item(pid: nil)) === amber, "nor does a closed pinned app")
        queue.sync {}
        XCTAssertEqual(loads, 2)
    }

    private static func image(gray: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
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
