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
