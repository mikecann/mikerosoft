import AppKit
import SwiftUI
import XCTest
@testable import TandemApp

/// Tooltips ride on a see-through AppKit view over each control: macOS
/// shows its tooltip, and clicks go through it to the control.
@MainActor
final class TipTests: XCTestCase {
    func testTheAnchorCarriesTheTipAndLetsClicksThrough() {
        let view = TipAnchorView(frame: CGRect(x: 0, y: 0, width: 28, height: 24))
        view.toolTip = "Select tool (V)"
        XCTAssertEqual(view.toolTip, "Select tool (V)")
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)), "never the target of a click")
        XCTAssertFalse(view.acceptsFirstResponder)
    }

    /// A button with a tip still gets its click through the anchor.
    func testAButtonUnderATipStillClicks() {
        _ = NSApplication.shared
        var clicks = 0
        let size = CGSize(width: 120, height: 40)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = Button { clicks += 1 } label: { Color.red.frame(width: 28, height: 24) }
            .buttonStyle(.plain)
            .tip("Select tool (V)")
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        func send(_ type: NSEvent.EventType) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 12, y: size.height - 12), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        send(.leftMouseDown)
        send(.leftMouseUp)
        XCTAssertEqual(clicks, 1)
        // The anchor is in the window, with its tooltip.
        func anchors(in view: NSView) -> [TipAnchorView] {
            (view as? TipAnchorView).map { [$0] } ?? view.subviews.flatMap(anchors)
        }
        XCTAssertEqual(anchors(in: hosting).map(\.toolTip), ["Select tool (V)"])
        window.orderOut(nil)
    }
}
