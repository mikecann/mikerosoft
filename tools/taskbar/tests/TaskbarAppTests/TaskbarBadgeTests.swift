import AppKit
import XCTest
@testable import TaskbarApp

final class TaskbarBadgeTests: XCTestCase {
    func testBadgeDisplayHandlesCountsDotsAndEmptyValues() {
        XCTAssertNil(taskbarBadgeText(nil))
        XCTAssertNil(taskbarBadgeText("  "))
        XCTAssertNil(taskbarBadgeText("0"))
        XCTAssertEqual(taskbarBadgeText("3"), "3")
        XCTAssertEqual(taskbarBadgeText("1000"), "99+")
        XCTAssertEqual(taskbarBadgeText("•"), "")
        XCTAssertEqual(taskbarBadgeText("unread"), "")
    }

    func testBadgesMatchApplicationPathsAndInvalidateItemEqualityWhenCleared() {
        let items = buildTaskbarItems(windows: [], frontmostPID: nil, pinnedApps: [
            PinnedApp(displayName: "ChatGPT", bundleID: "com.example.chat", appPath: "/Applications/ChatGPT.app/"),
            PinnedApp(displayName: "ChatGPT", bundleID: "com.example.other", appPath: "/Applications/Other.app")
        ])
        let badged = applyingTaskbarBadges(["/Applications/ChatGPT.app": "3"], to: items)
        XCTAssertEqual(badged[0].badgeLabel, "3")
        XCTAssertNil(badged[1].badgeLabel)
        XCTAssertNotEqual(items, badged)
        XCTAssertEqual(applyingTaskbarBadges([:], to: badged), items)
    }

    func testSamplerCachesWithoutBlockingAndClearsRemovedBadges() {
        var pending: [() -> Void] = []
        var source = ["/Applications/Slack.app": "•"]
        let sampler = TaskbarBadgeSampler(collect: { source }, schedule: { pending.append($0) })
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(sampler.snapshot(now: now).isEmpty)
        XCTAssertEqual(pending.count, 1)
        _ = sampler.snapshot(now: now)
        XCTAssertEqual(pending.count, 1)
        pending.removeFirst()()
        XCTAssertEqual(sampler.snapshot(now: now), source)
        XCTAssertTrue(pending.isEmpty)
        source = [:]
        _ = sampler.snapshot(now: now.addingTimeInterval(3))
        pending.removeFirst()()
        XCTAssertTrue(sampler.snapshot(now: now.addingTimeInterval(3)).isEmpty)
    }
}
