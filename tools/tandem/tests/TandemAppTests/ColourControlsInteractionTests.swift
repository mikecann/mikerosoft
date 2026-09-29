import AppKit
import SwiftUI
import XCTest
@testable import TandemApp
@testable import TandemCore

/// The colour controls driven with the mouse events AppKit sends, in a
/// window that's never shown: sliders, scrubbable numbers, the wheel and a
/// section's header.
@MainActor
final class ColourControlsInteractionTests: XCTestCase {
    /// Collects what the controls commit.
    final class Log {
        var values: [Double] = []
        var colours: [(hue: Double, amount: Double)] = []
        var events: [String] = []
    }

    /// A SwiftUI view in an offscreen window. Points are in the view,
    /// measured from the top left.
    final class Host {
        let window: NSWindow
        let view: NSView

        init(_ content: some View, size: CGSize) {
            _ = NSApplication.shared
            window = NSWindow(
                contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height, alignment: .topLeading))
            hosting.frame = CGRect(origin: .zero, size: size)
            window.contentView = hosting
            view = hosting
            // Far off every screen and see-through, but in the window list,
            // which SwiftUI needs before it handles the mouse. A window
            // that could become key would take the first click to do that
            // (the test process is never active), so it stays borderless.
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.display()
            settle()
        }

        func close() {
            window.orderOut(nil)
            window.close()
        }

        /// Types into whatever has the keyboard; a newline presses Return.
        func type(_ text: String) {
            guard let responder = window.firstResponder else { return }
            for (index, part) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { responder.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
                if !part.isEmpty { responder.insertText(String(part)) }
            }
            settle()
        }

        var isTyping: Bool { window.firstResponder is NSTextView }

        func settle() {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        private func windowPoint(_ p: CGPoint) -> NSPoint {
            NSPoint(x: p.x, y: view.bounds.height - p.y)
        }

        private func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: windowPoint(p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            )!
        }

        func click(_ p: CGPoint, count: Int = 1) {
            for number in 1...count {
                window.sendEvent(event(.leftMouseDown, p, clicks: number))
                settle()
                window.sendEvent(event(.leftMouseUp, p, clicks: number))
                settle()
            }
        }

        func drag(from start: CGPoint, to end: CGPoint, steps: Int = 8) {
            window.sendEvent(event(.leftMouseDown, start))
            settle()
            for step in 1...steps {
                let f = CGFloat(step) / CGFloat(steps)
                window.sendEvent(event(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f)))
                settle()
            }
            window.sendEvent(event(.leftMouseUp, end))
            settle()
        }
    }

    private var hosts: [Host] = []

    override func tearDown() async throws {
        for host in hosts { host.close() }
        hosts = []
        settleMainThread()
    }

    private func host(_ content: some View, size: CGSize) -> Host {
        let host = Host(content, size: size)
        hosts.append(host)
        return host
    }

    // A slider row 330 wide: label to 86, slider from 96 to 330 - 10 - 58
    // = 262 (its knob's centre runs from 101.5 to 256.5), value after it.
    private let rowSize = CGSize(width: 330, height: 20)
    private let knobLeft: CGFloat = 96 + GraphiteSlider.knob / 2
    private let knobRight: CGFloat = 262 - GraphiteSlider.knob / 2

    private func knobX(_ value: Double, in range: ClosedRange<Double>) -> CGFloat {
        knobLeft + CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * (knobRight - knobLeft)
    }

    private func sliderRow(_ value: Double, log: Log) -> some View {
        SliderRow(
            label: "Contrast", value: value, range: -100...100, bipolar: true, valueWidth: 58,
            format: { String(format: "%.0f", $0) }, defaultValue: 0, step: 1,
            onCommit: { log.values.append($0) }
        )
    }

    func testDraggingTheKnobMovesItFromWhereItIs() {
        let log = Log()
        let host = self.host(sliderRow(20, log: log), size: rowSize)
        // Grab the knob a little off centre: it mustn't jump to the pointer.
        let start = CGPoint(x: knobX(20, in: -100...100) + 3, y: 10)
        host.drag(from: start, to: CGPoint(x: start.x + 31, y: 10))
        XCTAssertEqual(log.values.count, 1, "one commit when the drag ends")
        // 31 points of a 155 point track is 40 of 200.
        XCTAssertEqual(log.values.first ?? 0, 60, accuracy: 1)
    }

    func testPressingTheTrackJumpsThere() {
        let log = Log()
        let host = self.host(sliderRow(0, log: log), size: rowSize)
        host.click(CGPoint(x: knobX(50, in: -100...100), y: 10))
        XCTAssertEqual(log.values, [50])
    }

    func testDoubleClickingTheKnobResets() {
        let log = Log()
        let host = self.host(sliderRow(35, log: log), size: rowSize)
        host.click(CGPoint(x: knobX(35, in: -100...100), y: 10), count: 2)
        XCTAssertEqual(log.values, [0], "one step back to the default, nothing else")
    }

    func testDoubleClickingTheLabelResets() {
        let log = Log()
        let host = self.host(sliderRow(35, log: log), size: rowSize)
        host.click(CGPoint(x: 20, y: 10), count: 2)
        XCTAssertEqual(log.values, [0])
    }

    func testDraggingTheValueScrubsIt() {
        let log = Log()
        let host = self.host(sliderRow(10, log: log), size: rowSize)
        // The value sits right-aligned in its 58 points, 272 to 330.
        host.drag(from: CGPoint(x: 322, y: 10), to: CGPoint(x: 342, y: 10))
        XCTAssertEqual(log.values.count, 1)
        // A point is 1 of 200; the first 2 points only start the drag.
        XCTAssertEqual(log.values.first ?? 0, 28, accuracy: 3)
    }

    func testClickingTheValueTypesIntoIt() {
        let log = Log()
        let host = self.host(sliderRow(10, log: log), size: rowSize)
        host.click(CGPoint(x: 322, y: 10))
        XCTAssertTrue(host.isTyping, "a click opens the value for typing")
        // Select what's there, then type over it.
        (host.window.firstResponder as? NSTextView)?.selectAll(nil)
        host.type("−42\n")
        XCTAssertEqual(log.values, [-42])
        XCTAssertFalse(host.isTyping)
    }

    func testDraggingTheWheelMovesThePuckAndCommitsOnce() {
        let log = Log()
        let host = self.host(
            ColourWheelView(hue: 0, amount: 0, help: "") { log.colours.append(($0, $1)) },
            size: CGSize(width: 96, height: 96)
        )
        // Right is towards 0 degrees on the wheel: between blue and
        // magenta. The puck moves at half the pointer's speed.
        let reach = ColourWheelView.reach(96)
        host.drag(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 30 + reach, y: 60))
        XCTAssertEqual(log.colours.count, 1)
        let expected = ColourWheels.hue(wheelAngle: 0)
        XCTAssertEqual(log.colours.first?.hue ?? -1, expected.rounded(), accuracy: 1.5)
        XCTAssertEqual(log.colours.first?.amount ?? -1, 50, accuracy: 1.5)
    }

    func testDoubleClickingTheWheelResetsIt() {
        let log = Log()
        let host = self.host(
            ColourWheelView(hue: 200, amount: 20, help: "") { log.colours.append(($0, $1)) },
            size: CGSize(width: 96, height: 96)
        )
        host.click(CGPoint(x: 48, y: 48), count: 2)
        XCTAssertEqual(log.colours.count, 1)
        XCTAssertEqual(log.colours.first?.hue, 0)
        XCTAssertEqual(log.colours.first?.amount, 0)
        // A single click changes nothing.
        host.click(CGPoint(x: 30, y: 30))
        XCTAssertEqual(log.colours.count, 1)
    }

    func testTheSectionHeadersButtonsDoTheirOwnThing() {
        let log = Log()
        let block = ColourSectionBlock(
            section: .light, hasEffect: true, isOn: true, isChanged: true, canToggle: true, summary: "",
            expanded: true,
            toggleExpanded: { log.events.append("expand") },
            toggle: { log.events.append("toggle") },
            reset: { log.events.append("reset") }
        ) { Color.clear.frame(height: 10) }
        let host = self.host(block, size: CGSize(width: 330, height: 60))
        // Right to left from the edge's 16 point margin: chevron 14, switch 28, reset 18, 6 apart.
        host.click(CGPoint(x: 330 - 16 - 7, y: 21))
        host.click(CGPoint(x: 330 - 16 - 14 - 6 - 14, y: 21))
        host.click(CGPoint(x: 330 - 16 - 14 - 6 - 28 - 6 - 9, y: 21))
        host.click(CGPoint(x: 60, y: 21))
        XCTAssertEqual(log.events, ["expand", "toggle", "reset", "expand"])
    }
}
