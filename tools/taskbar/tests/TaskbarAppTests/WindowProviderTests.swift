import CoreGraphics
import XCTest
@testable import TaskbarApp

final class WindowProviderTests: XCTestCase {
    func testMetadataSamplerReturnsInitialSnapshotSynchronously() {
        let pid = pid_t(123)
        var collectedPIDs: [Set<pid_t>] = []
        let sampler = RunningApplicationMetadataSampler(collect: { pids in
            collectedPIDs.append(pids)
            return [
                pid: RunningApplicationMetadata(
                    bundleID: "com.example.Editor",
                    appPath: "/Applications/Editor.app"
                )
            ]
        })

        let metadata = sampler.metadata(for: [pid], now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(metadata[pid]?.bundleID, "com.example.Editor")
        XCTAssertEqual(metadata[pid]?.appPath, "/Applications/Editor.app")
        XCTAssertEqual(collectedPIDs, [[pid]])
    }

    func testMetadataSamplerRefreshesUnknownPIDWithoutWaitingForTheTwoSecondGate() {
        let editorPID = pid_t(123)
        let browserPID = pid_t(456)
        var collectedPIDs: [Set<pid_t>] = []
        let sampler = RunningApplicationMetadataSampler(collect: { pids in
            collectedPIDs.append(pids)
            return Dictionary(uniqueKeysWithValues: pids.map { pid in
                let name = pid == editorPID ? "Editor" : "Browser"
                return (
                    pid,
                    RunningApplicationMetadata(
                        bundleID: "com.example.\(name)",
                        appPath: "/Applications/\(name).app"
                    )
                )
            })
        })

        _ = sampler.metadata(for: [editorPID], now: Date(timeIntervalSince1970: 100))
        let metadata = sampler.metadata(
            for: [editorPID, browserPID],
            now: Date(timeIntervalSince1970: 100.5)
        )

        XCTAssertEqual(metadata[browserPID]?.bundleID, "com.example.Browser")
        XCTAssertEqual(collectedPIDs, [[editorPID], [editorPID, browserPID]])
    }

    func testMetadataSamplerDoesNotRescanPermanentlyMissingPIDBeforePeriodicGate() {
        let editorPID = pid_t(123)
        let windowServerPID = pid_t(415)
        var collectionCount = 0
        let sampler = RunningApplicationMetadataSampler(collect: { _ in
            collectionCount += 1
            return [
                editorPID: RunningApplicationMetadata(
                    bundleID: "com.example.Editor",
                    appPath: "/Applications/Editor.app"
                )
            ]
        })

        _ = sampler.metadata(for: [editorPID], now: Date(timeIntervalSince1970: 100))
        _ = sampler.metadata(for: [editorPID, windowServerPID], now: Date(timeIntervalSince1970: 100.1))
        let nextTick = sampler.metadata(
            for: [editorPID, windowServerPID],
            now: Date(timeIntervalSince1970: 101.1)
        )

        XCTAssertNil(nextTick[windowServerPID])
        XCTAssertEqual(collectionCount, 2)
    }

    func testMetadataSamplerQueuesUnknownPIDWhilePeriodicRefreshIsInFlight() throws {
        let editorPID = pid_t(123)
        let browserPID = pid_t(456)
        var collectedPIDs: [Set<pid_t>] = []
        var scheduledRefreshes: [() -> Void] = []
        let sampler = RunningApplicationMetadataSampler(
            collect: { pids in
                collectedPIDs.append(pids)
                return Dictionary(uniqueKeysWithValues: pids.map { pid in
                    let name = pid == editorPID ? "Editor" : "Browser"
                    return (
                        pid,
                        RunningApplicationMetadata(
                            bundleID: "com.example.\(name)",
                            appPath: "/Applications/\(name).app"
                        )
                    )
                })
            },
            schedule: { scheduledRefreshes.append($0) }
        )

        _ = sampler.metadata(for: [editorPID], now: Date(timeIntervalSince1970: 100))
        _ = sampler.metadata(for: [editorPID], now: Date(timeIntervalSince1970: 102.1))
        let whileRefreshing = sampler.metadata(
            for: [editorPID, browserPID],
            now: Date(timeIntervalSince1970: 102.2)
        )

        XCTAssertNil(whileRefreshing[browserPID])
        try XCTUnwrap(scheduledRefreshes.first)()
        scheduledRefreshes.removeFirst()

        _ = sampler.metadata(
            for: [editorPID, browserPID],
            now: Date(timeIntervalSince1970: 102.3)
        )

        try XCTUnwrap(scheduledRefreshes.first)()
        scheduledRefreshes.removeFirst()

        let nextTick = sampler.metadata(
            for: [editorPID, browserPID],
            now: Date(timeIntervalSince1970: 103.1)
        )

        XCTAssertEqual(nextTick[browserPID]?.bundleID, "com.example.Browser")
        XCTAssertEqual(collectedPIDs, [[editorPID], [editorPID], [editorPID, browserPID]])
        XCTAssertTrue(scheduledRefreshes.isEmpty)
    }

    func testAccessibilitySamplerReturnsInitialSnapshotSynchronously() {
        let pid = pid_t(321)
        let expected = AccessibilityWindowSurface(
            pid: pid,
            windowID: 987,
            title: "First document",
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            signature: ""
        )
        var collectedPIDs: [Set<pid_t>] = []
        let sampler = AccessibilitySurfaceSampler { pids in
            collectedPIDs.append(pids)
            return [expected]
        }

        let surfaces = sampler.surfaces(for: [pid], now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(surfaces, [expected])
        XCTAssertEqual(collectedPIDs, [[pid]])
    }

    func testMinimizedSamplerReturnsInitialSnapshotSynchronously() {
        let record = WindowRecord(
            owner: "Editor",
            title: "Draft",
            pid: 321,
            windowID: 987,
            accessibilityWindowID: 987,
            layer: 0,
            isOnScreen: false,
            isMinimized: true,
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            screenID: 1,
            bundleID: "com.example.Editor",
            appPath: "/Applications/Editor.app",
            accessibilityTitle: "Draft",
            accessibilitySignature: ""
        )
        var collectionCount = 0
        let sampler = MinimizedWindowSampler(collect: { _ in
            collectionCount += 1
            return [record]
        })

        let records = sampler.records(
            screens: [],
            excluding: [],
            visibleWindowIDs: [],
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(records, [record])
        XCTAssertEqual(collectionCount, 1)
    }

    func testMinimizedSamplerInvalidatesWindowAfterTaskbarRestoresIt() {
        let record = WindowRecord(
            owner: "Editor",
            title: "Draft",
            pid: 321,
            windowID: 987,
            accessibilityWindowID: 987,
            layer: 0,
            isOnScreen: false,
            isMinimized: true,
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            screenID: 1,
            bundleID: "com.example.Editor",
            appPath: "/Applications/Editor.app",
            accessibilityTitle: "Draft",
            accessibilitySignature: ""
        )
        let sampler = MinimizedWindowSampler(collect: { _ in [record] })
        _ = sampler.records(
            screens: [],
            excluding: [],
            visibleWindowIDs: [],
            now: Date(timeIntervalSince1970: 100)
        )

        sampler.invalidate(pid: record.pid, windowID: record.windowID, title: record.title)

        XCTAssertEqual(
            sampler.records(
                screens: [],
                excluding: [],
                visibleWindowIDs: [],
                now: Date(timeIntervalSince1970: 100.5)
            ),
            []
        )
    }

    func testMinimizedSamplerDoesNotRestoreInvalidatedWindowFromInFlightRefresh() throws {
        let record = WindowRecord(
            owner: "Editor",
            title: "Draft",
            pid: 321,
            windowID: 987,
            accessibilityWindowID: 987,
            layer: 0,
            isOnScreen: false,
            isMinimized: true,
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            screenID: 1,
            bundleID: "com.example.Editor",
            appPath: "/Applications/Editor.app",
            accessibilityTitle: "Draft",
            accessibilitySignature: ""
        )
        var scheduledRefresh: (() -> Void)?
        let sampler = MinimizedWindowSampler(
            collect: { _ in [record] },
            schedule: { scheduledRefresh = $0 }
        )
        _ = sampler.records(
            screens: [],
            excluding: [],
            visibleWindowIDs: [],
            now: Date(timeIntervalSince1970: 100)
        )
        _ = sampler.records(
            screens: [],
            excluding: [],
            visibleWindowIDs: [],
            now: Date(timeIntervalSince1970: 102.1)
        )

        sampler.invalidate(pid: record.pid, windowID: record.windowID, title: record.title)
        try XCTUnwrap(scheduledRefresh)()

        XCTAssertEqual(
            sampler.records(
                screens: [],
                excluding: [],
                visibleWindowIDs: [],
                now: Date(timeIntervalSince1970: 102.5)
            ),
            []
        )
    }

    func testResolvedWindowTitleUsesAccessibilityTitleWhenCGTitleIsOwner() {
        XCTAssertEqual(
            resolvedWindowTitle(
                cgTitle: "Discord",
                owner: "Discord",
                accessibilityTitle: "general - Discord"
            ),
            "general - Discord"
        )
    }

    func testResolvedWindowTitleKeepsDescriptiveCGTitle() {
        XCTAssertEqual(
            resolvedWindowTitle(
                cgTitle: "Downloads",
                owner: "Finder",
                accessibilityTitle: "Finder"
            ),
            "Downloads"
        )
    }

    func testMatchingAccessibilitySurfaceCanMatchWhenCGTitleIsBlank() {
        let bounds = CGRect(x: 20, y: 30, width: 900, height: 700)
        let surface = AccessibilityWindowSurface(
            pid: 123,
            title: "Downloads",
            bounds: bounds,
            signature: "child-a"
        )

        XCTAssertEqual(
            matchingAccessibilitySurface(
                pid: 123,
                cgTitle: "",
                bounds: bounds,
                in: [surface]
            ),
            surface
        )
    }

    func testMatchingAccessibilitySurfacesDisambiguatesChromeProfileWindowsWithSameBounds() {
        let bounds = CGRect(x: 0, y: 30, width: 2560, height: 1378)
        let requests = [
            AccessibilityWindowMatchRequest(
                pid: 739,
                cgTitle: "Type-Safe Environment Variables in Convex",
                bounds: bounds
            ),
            AccessibilityWindowMatchRequest(
                pid: 739,
                cgTitle: "New tab",
                bounds: bounds
            )
        ]
        let surfaces = [
            AccessibilityWindowSurface(
                pid: 739,
                title: "Type-Safe Environment Variables in Convex - Google Chrome - Michael",
                bounds: bounds,
                signature: "profile-a-window"
            ),
            AccessibilityWindowSurface(
                pid: 739,
                title: "New tab - Google Chrome - Michael (convex.dev)",
                bounds: bounds,
                signature: "profile-b-window"
            )
        ]

        let matches = matchingAccessibilitySurfaces(requests: requests, in: surfaces)

        XCTAssertEqual(matches.map { $0?.signature }, ["profile-a-window", "profile-b-window"])
    }

    func testMatchingAccessibilitySurfacesUsesWindowIDBeforeSurfaceOrder() {
        let bounds = CGRect(x: 0, y: 30, width: 2560, height: 1378)
        let requests = [
            AccessibilityWindowMatchRequest(
                pid: 739,
                windowID: 578,
                cgTitle: "",
                bounds: bounds
            ),
            AccessibilityWindowMatchRequest(
                pid: 739,
                windowID: 16416,
                cgTitle: "",
                bounds: bounds
            )
        ]
        let surfaces = [
            AccessibilityWindowSurface(
                pid: 739,
                windowID: 16416,
                title: "New tab - Google Chrome - Michael (convex.dev)",
                bounds: bounds,
                signature: "profile-b-window"
            ),
            AccessibilityWindowSurface(
                pid: 739,
                windowID: 578,
                title: "Inbox (11) - mike.cann@gmail.com - Gmail - Google Chrome - Michael",
                bounds: bounds,
                signature: "profile-a-window"
            )
        ]

        let matches = matchingAccessibilitySurfaces(requests: requests, in: surfaces)

        XCTAssertEqual(matches.map { $0?.windowID }, [578, 16416])
    }

    func testMatchingAccessibilitySurfacesRefusesKnownWindowIDMismatchInHeuristicPass() {
        let bounds = CGRect(x: 20, y: 30, width: 900, height: 700)
        let requests = [
            AccessibilityWindowMatchRequest(
                pid: 123,
                windowID: 101,
                cgTitle: "",
                bounds: bounds
            )
        ]
        let surfaces = [
            AccessibilityWindowSurface(
                pid: 123,
                windowID: 202,
                title: "Downloads",
                bounds: bounds,
                signature: "child-a"
            )
        ]

        let matches = matchingAccessibilitySurfaces(requests: requests, in: surfaces)

        XCTAssertNil(matches[0])
    }

    func testExactApplicationWindowMatchUsesWindowIDInsteadOfCandidateOrder() {
        XCTAssertEqual(
            exactApplicationWindowMatchIndex(
                itemWindowIDs: [16416],
                candidateWindowIDs: [578, 16416]
            ),
            1
        )
    }

    func testApplicationWindowHeuristicRefusesKnownWindowIDMismatch() {
        let itemWindowIDs = [101]
        let staleCandidateWindowIDs = [202, 303]

        XCTAssertNil(
            exactApplicationWindowMatchIndex(
                itemWindowIDs: itemWindowIDs,
                candidateWindowIDs: staleCandidateWindowIDs
            )
        )
        XCTAssertTrue(
            staleCandidateWindowIDs.allSatisfy {
                !canHeuristicallyMatchApplicationWindow(
                    itemWindowIDs: itemWindowIDs,
                    candidateWindowID: $0
                )
            }
        )
        XCTAssertTrue(
            canHeuristicallyMatchApplicationWindow(
                itemWindowIDs: itemWindowIDs,
                candidateWindowID: 0
            )
        )
    }

    func testAccessibilitySignatureSkipsAddressFallbackWhenWindowIDBridgeIsAvailable() {
        var fallbackWasRead = false

        let bridgedSignature = resolvedAccessibilitySignature(windowIDBridgeAvailable: true) {
            fallbackWasRead = true
            return "address-based-signature"
        }

        XCTAssertEqual(bridgedSignature, "")
        XCTAssertFalse(fallbackWasRead)
        XCTAssertEqual(
            resolvedAccessibilitySignature(windowIDBridgeAvailable: false) {
                "address-based-signature"
            },
            "address-based-signature"
        )
    }

    func testMinimizedWindowIdentityUsesRealIDAndRejectsStaleVisibleCacheMatch() {
        var syntheticIDWasRead = false
        let realWindowID = resolvedMinimizedWindowID(1234) {
            syntheticIDWasRead = true
            return -99
        }

        XCTAssertEqual(realWindowID, 1234)
        XCTAssertFalse(syntheticIDWasRead)
        XCTAssertEqual(resolvedMinimizedWindowID(0) { -99 }, -99)
        XCTAssertTrue(isStaleCachedMinimizedWindow(windowID: 1234, visibleWindowIDs: [1234]))
        XCTAssertFalse(isStaleCachedMinimizedWindow(windowID: -99, visibleWindowIDs: [1234]))
    }

    func testApplicationWindowMatchScorePrefersMatchingSignatureAndBounds() {
        let bounds = CGRect(x: 0, y: 30, width: 2560, height: 1378)

        let matching = applicationWindowMatchScore(
            itemTitle: "New tab",
            itemBounds: bounds,
            itemAccessibilitySignature: "profile-b-window",
            candidateTitle: "New tab - Google Chrome - Michael (convex.dev)",
            candidateBounds: bounds,
            candidateAccessibilitySignature: "profile-b-window"
        )
        let otherChromeWindow = applicationWindowMatchScore(
            itemTitle: "New tab",
            itemBounds: bounds,
            itemAccessibilitySignature: "profile-b-window",
            candidateTitle: "Inbox (11) - mike.cann@gmail.com - Gmail - Google Chrome - Michael",
            candidateBounds: bounds,
            candidateAccessibilitySignature: "profile-a-window"
        )

        XCTAssertGreaterThan(matching, otherChromeWindow)
        XCTAssertGreaterThan(matching, 0)
    }
}
