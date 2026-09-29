import XCTest
@testable import TandemApp
@testable import TandemCore

final class MarqueeTests: XCTestCase {
    private func tester(_ f: AppFixture, pps: Double = 10) -> TimelineHitTester {
        TimelineHitTester(
            project: f.project,
            layout: TimelineLayout.make(project: f.project, showTranscript: true),
            scale: TimelineScale(pixelsPerSecond: pps)
        )
    }

    /// The box works out its selection on every move, but only reports a
    /// change (and a redraw) when it takes in or lets go of a clip.
    func testSelectionChangesOnlyWhenTheBoxTakesInAnotherClip() throws {
        let f = try AppFixture()
        let tester = tester(f)
        let broll = tester.layout.lane(forTrack: f.track("B-roll").id)!
        // The B-roll shot runs 20 to 25 s: 200 to 250 px at 10 px a second.
        var box = Marquee(at: CGPoint(x: 150, y: broll.midY), scale: tester.scale, base: [], modifiers: .init())
        XCTAssertFalse(box.move(to: CGPoint(x: 180, y: broll.midY + 2), tester: tester, linkedSelection: false), "still short of the shot")
        XCTAssertEqual(box.selection, [])
        XCTAssertTrue(box.move(to: CGPoint(x: 210, y: broll.midY + 2), tester: tester, linkedSelection: false))
        XCTAssertEqual(box.selection, [f.clip("B-roll").id])
        XCTAssertFalse(box.move(to: CGPoint(x: 230, y: broll.midY + 3), tester: tester, linkedSelection: false), "same shot, nothing to redraw")
        XCTAssertTrue(box.move(to: CGPoint(x: 160, y: broll.midY), tester: tester, linkedSelection: false), "backing off lets it go")
        XCTAssertEqual(box.selection, [])
    }

    func testShiftAddsToWhatWasSelected() throws {
        let f = try AppFixture()
        let tester = tester(f)
        let broll = tester.layout.lane(forTrack: f.track("B-roll").id)!
        let music = f.clip("Music").id
        var box = Marquee(at: CGPoint(x: 150, y: broll.midY), scale: tester.scale, base: [music], modifiers: .init(shift: true))
        XCTAssertEqual(box.selection, [music], "an empty box keeps what was selected")
        XCTAssertTrue(box.move(to: CGPoint(x: 210, y: broll.midY + 2), tester: tester, linkedSelection: false))
        XCTAssertEqual(box.selection, [music, f.clip("B-roll").id])
    }

    /// Dragging past the edge scrolls the timeline; the corner the drag
    /// started from stays on its time rather than on its spot on screen.
    func testTheStartStaysOnItsTimeWhileTheTimelineScrolls() {
        var scale = TimelineScale(pixelsPerSecond: 10, scrollSeconds: 0)
        var box = Marquee(at: CGPoint(x: 300, y: 40), scale: scale, base: [], modifiers: .init())
        box.end = CGPoint(x: 400, y: 90)
        XCTAssertEqual(box.rect(scale: scale), CGRect(x: 300, y: 40, width: 100, height: 50))
        scale.scrollSeconds = 10
        XCTAssertEqual(box.rect(scale: scale), CGRect(x: 200, y: 40, width: 200, height: 50), "30 s is now at 200 px")
        XCTAssertEqual(box.startTime(rate: .fps30), t(30))
    }
}

final class TimelinePanTests: XCTestCase {
    func testWhatsUnderThePointerStaysUnderIt() {
        let pan = TimelinePan(start: CGPoint(x: 400, y: 100), scrollSeconds: 30, verticalOffset: 40)
        let next = pan.offsets(at: CGPoint(x: 600, y: 80), pixelsPerSecond: 20, maxScrollSeconds: 500, maxVerticalOffset: 300)
        XCTAssertEqual(next.scrollSeconds, 20, accuracy: 1e-9, "200 px right at 20 px a second shows 10 s earlier")
        XCTAssertEqual(next.verticalOffset, 60, "20 px up moves the tracks up")
    }

    func testStopsAtTheEnds() {
        let pan = TimelinePan(start: .zero, scrollSeconds: 5, verticalOffset: 10)
        let start = pan.offsets(at: CGPoint(x: 10_000, y: 10_000), pixelsPerSecond: 20, maxScrollSeconds: 500, maxVerticalOffset: 300)
        XCTAssertEqual(start.scrollSeconds, 0)
        XCTAssertEqual(start.verticalOffset, 0)
        let end = pan.offsets(at: CGPoint(x: -100_000, y: -10_000), pixelsPerSecond: 20, maxScrollSeconds: 500, maxVerticalOffset: 300)
        XCTAssertEqual(end.scrollSeconds, 500)
        XCTAssertEqual(end.verticalOffset, 300)
    }

    /// Zoomed out past the end, a pan mustn't snap back on the first move.
    func testDoesNotJumpWhenAlreadyPastTheEnd() {
        let pan = TimelinePan(start: .zero, scrollSeconds: 600, verticalOffset: 0)
        let next = pan.offsets(at: CGPoint(x: 1, y: 0), pixelsPerSecond: 20, maxScrollSeconds: 500, maxVerticalOffset: 0)
        XCTAssertEqual(next.scrollSeconds, 599.95, accuracy: 1e-9)
    }
}

final class SimulatedGestureTests: XCTestCase {
    func testParsesMiddleButtonAndPacedDrags() {
        XCTAssertEqual(
            AppURLCommand.parse(URL(string: "tandem://simulate?drag=600,700,400,650&button=middle")!),
            .simulate(InputSimulator.Gesture(kind: .drag(to: CGPoint(x: 400, y: 650), steps: 12), at: CGPoint(x: 600, y: 700), modifiers: [], button: .middle))
        )
        XCTAssertEqual(
            AppURLCommand.parse(URL(string: "tandem://simulate?drag=600,700,400,650&steps=90&interval=8")!),
            .simulate(InputSimulator.Gesture(kind: .drag(to: CGPoint(x: 400, y: 650), steps: 90), at: CGPoint(x: 600, y: 700), modifiers: [], interval: 0.008))
        )
        XCTAssertEqual(InputSimulator.parse(["drag": "1,2,3,4", "button": "left"])?.button, .left)
        XCTAssertNil(InputSimulator.parse(["drag": "1,2,3,4", "button": "fifth"]), "unknown buttons are refused")
        XCTAssertNil(InputSimulator.parse(["drag": "1,2,3,4", "interval": "5000"]), "a step can't wait more than a second")
    }
}
