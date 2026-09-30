import AppKit
import XCTest
@testable import TandemApp

/// Hover from an AppKit view over a SwiftUI one: it hears the pointer come,
/// move and go, and never takes a click.
@MainActor
final class PointerTrackingTests: XCTestCase {
    func testItReportsEnterMoveAndLeave() {
        let view = PointerTrackerView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        var hovers: [Bool] = []
        var moves: [CGPoint?] = []
        view.onHover = { hovers.append($0) }
        view.onMove = { moves.append($0) }
        let window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: 100, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        func event(_ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: x, y: 40 - y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        view.mouseEntered(with: event(10, 5))
        view.mouseMoved(with: event(30, 20))
        view.mouseExited(with: event(150, 20))
        XCTAssertEqual(hovers, [true, false])
        XCTAssertEqual(moves, [CGPoint(x: 10, y: 5), CGPoint(x: 30, y: 20), nil], "top-left points, then nil when it leaves")
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)), "clicks go through")
        // Going away with the pointer on it counts as leaving.
        view.mouseEntered(with: event(10, 5))
        window.contentView = NSView()
        XCTAssertEqual(hovers, [true, false, true, false])
    }
}
