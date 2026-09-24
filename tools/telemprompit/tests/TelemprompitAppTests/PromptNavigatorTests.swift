import XCTest
@testable import TelemprompitApp

final class PromptNavigatorTests: XCTestCase {
    private let items: [PromptItem] = [
        .heading("Intro"),
        .line("First"),
        .cue("look at camera"),
        .line("Second", depth: 1),
        PromptItem(kind: .code, text: "x"),
        .line("Third"),
    ]

    func testOnlyReadableLinesAreStops() {
        XCTAssertEqual(PromptNavigator.stops(in: items), [1, 3, 5])
    }

    func testNextSkipsHeadingsCuesAndCodeAndStopsAtTheEnd() {
        XCTAssertEqual(PromptNavigator.next(after: nil, in: items), 1)
        XCTAssertEqual(PromptNavigator.next(after: 1, in: items), 3)
        XCTAssertEqual(PromptNavigator.next(after: 3, in: items), 5)
        XCTAssertEqual(PromptNavigator.next(after: 5, in: items), 5)
        // From a heading or cue, the next stop is the following line.
        XCTAssertEqual(PromptNavigator.next(after: 2, in: items), 3)
    }

    func testPreviousStopsAtTheStart() {
        XCTAssertEqual(PromptNavigator.previous(before: 5, in: items), 3)
        XCTAssertEqual(PromptNavigator.previous(before: 3, in: items), 1)
        XCTAssertEqual(PromptNavigator.previous(before: 1, in: items), 1)
        XCTAssertEqual(PromptNavigator.previous(before: nil, in: items), 1)
    }

    func testEmptyScriptsHaveNoStops() {
        XCTAssertNil(PromptNavigator.next(after: nil, in: []))
        XCTAssertNil(PromptNavigator.previous(before: nil, in: [.heading("Only a heading")]))
        XCTAssertNil(PromptNavigator.first(in: [.cue("x")]))
    }

    func testFirstAndLast() {
        XCTAssertEqual(PromptNavigator.first(in: items), 1)
        XCTAssertEqual(PromptNavigator.last(in: items), 5)
    }

    func testCurrentStopWhileScrollingIsTheLastLineThatReachedTheReadingLine() {
        let tops: [Int: CGFloat] = [0: 0, 1: 40, 2: 120, 3: 160, 4: 240, 5: 300]
        XCTAssertEqual(PromptNavigator.stop(atOffset: 0, tops: tops, in: items), 1)
        XCTAssertEqual(PromptNavigator.stop(atOffset: 41, tops: tops, in: items), 1)
        XCTAssertEqual(PromptNavigator.stop(atOffset: 170, tops: tops, in: items), 3)
        XCTAssertEqual(PromptNavigator.stop(atOffset: 299, tops: tops, in: items), 3)
        XCTAssertEqual(PromptNavigator.stop(atOffset: 900, tops: tops, in: items), 5)
    }

    func testFractionThroughTheScript() {
        XCTAssertEqual(PromptNavigator.progress(of: 1, in: items), 0)
        XCTAssertEqual(PromptNavigator.progress(of: 3, in: items), 0.5)
        XCTAssertEqual(PromptNavigator.progress(of: 5, in: items), 1)
        XCTAssertEqual(PromptNavigator.progress(of: nil, in: items), 0)
    }
}
