import CoreGraphics
import XCTest
@testable import TaskbarApp

final class WindowProviderTests: XCTestCase {
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
