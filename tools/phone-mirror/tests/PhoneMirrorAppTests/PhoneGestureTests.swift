import XCTest
@testable import PhoneMirrorApp

final class GestureClassifierTests: XCTestCase {
    private let screen = CGSize(width: 414, height: 896)

    private func sample(_ x: CGFloat, _ y: CGFloat, _ time: TimeInterval) -> TouchSample {
        TouchSample(point: CGPoint(x: x, y: y), time: time)
    }

    func testAQuickClickIsATapInPhonePoints() {
        let gesture = GestureClassifier.gesture(from: [sample(0.5, 0.25, 10), sample(0.501, 0.25, 10.1)], screen: screen)
        XCTAssertEqual(gesture, .tap(CGPoint(x: 207, y: 224)))
    }

    func testAHeldClickIsALongPress() {
        let gesture = GestureClassifier.gesture(from: [sample(0.5, 0.5, 0), sample(0.5, 0.5, 0.8)], screen: screen)
        XCTAssertEqual(gesture, .longPress(CGPoint(x: 207, y: 448), duration: 0.8))
    }

    func testMovingPastTheSlopIsADragThatKeepsItsTiming() {
        let gesture = GestureClassifier.gesture(
            from: [sample(0.5, 0.8, 1), sample(0.5, 0.6, 1.1), sample(0.5, 0.3, 1.25)],
            screen: screen
        )
        XCTAssertEqual(gesture, .drag([
            TimedPoint(point: CGPoint(x: 207, y: 717), time: 0),
            TimedPoint(point: CGPoint(x: 207, y: 538), time: 0.1),
            TimedPoint(point: CGPoint(x: 207, y: 269), time: 0.25),
        ]))
    }

    func testDragsKeepAtMostOneSamplePer16Milliseconds() {
        let samples = (0...100).map { sample(0.5, 0.2 + CGFloat($0) * 0.005, TimeInterval($0) * 0.004) }
        guard case .drag(let path) = GestureClassifier.gesture(from: samples, screen: screen) else {
            return XCTFail("expected a drag")
        }
        XCTAssertLessThanOrEqual(path.count, 27)
        XCTAssertEqual(path.first?.point.y, 179)
        XCTAssertEqual(path.last?.point.y, 627)
        XCTAssertEqual(path.last?.time ?? 0, 0.4, accuracy: 0.0001)
    }

    func testClampsPointsToTheScreen() {
        XCTAssertEqual(GestureClassifier.gesture(from: [sample(-0.2, 1.3, 0)], screen: screen), .tap(CGPoint(x: 0, y: 896)))
        XCTAssertNil(GestureClassifier.gesture(from: [], screen: screen))
        XCTAssertNil(GestureClassifier.gesture(from: [sample(0.5, 0.5, 0)], screen: .zero))
    }
}

final class TouchActionsTests: XCTestCase {
    func testReplaysADragWithItsTimingAndHoldsBeforeLifting() throws {
        let payload = TouchActions.drag([
            TimedPoint(point: CGPoint(x: 10, y: 500), time: 0),
            TimedPoint(point: CGPoint(x: 10, y: 300), time: 0.12),
        ], holdAtEnd: 0.1)
        let pointer = try XCTUnwrap((payload["actions"] as? [[String: Any]])?.first)
        XCTAssertEqual(pointer["type"] as? String, "pointer")
        XCTAssertEqual((pointer["parameters"] as? [String: String])?["pointerType"], "touch")
        let steps = try XCTUnwrap(pointer["actions"] as? [[String: Any]])
        XCTAssertEqual(steps.map { $0["type"] as? String }, ["pointerMove", "pointerDown", "pointerMove", "pause", "pointerUp"])
        XCTAssertEqual(steps[0]["x"] as? Int, 10)
        XCTAssertEqual(steps[0]["y"] as? Int, 500)
        XCTAssertEqual(steps[2]["duration"] as? Int, 120)
        XCTAssertEqual(steps[2]["y"] as? Int, 300)
        XCTAssertEqual(steps[3]["duration"] as? Int, 100)
    }
}

final class ScrollSwipeTests: XCTestCase {
    private let screen = CGSize(width: 414, height: 896)

    func testDragsTheFingerTheWayTheContentMoves() {
        let path = ScrollSwipe.path(anchor: CGPoint(x: 200, y: 400), delta: CGVector(dx: 0, dy: -150), screen: screen)
        XCTAssertEqual(path.first?.point, CGPoint(x: 200, y: 400))
        XCTAssertEqual(path.last?.point, CGPoint(x: 200, y: 250))
    }

    func testShiftsTheStartSoTheEndStaysOnScreen() {
        let path = ScrollSwipe.path(anchor: CGPoint(x: 200, y: 100), delta: CGVector(dx: 0, dy: -200), screen: screen)
        XCTAssertEqual(path.last?.point.y, ScrollSwipe.margin)
        XCTAssertEqual(path.first?.point.y, ScrollSwipe.margin + 200)
    }

    func testCapsASwipeLongerThanTheScreen() {
        let path = ScrollSwipe.path(anchor: CGPoint(x: 200, y: 400), delta: CGVector(dx: 0, dy: 5000), screen: screen)
        XCTAssertEqual(path.first?.point.y, ScrollSwipe.margin)
        XCTAssertEqual(path.last?.point.y, screen.height - ScrollSwipe.margin)
    }
}

final class PhoneKeysTests: XCTestCase {
    func testMapsEditingKeysToXCTestKeys() {
        XCTAssertEqual(PhoneKeys.text(keyCode: 0x33, characters: "\u{7F}"), "\u{8}") // Delete
        XCTAssertEqual(PhoneKeys.text(keyCode: 0x75, characters: "\u{F728}"), "\u{7F}") // Forward delete
        XCTAssertEqual(PhoneKeys.text(keyCode: 0x24, characters: "\r"), "\n") // Return
        XCTAssertEqual(PhoneKeys.text(keyCode: 0x7E, characters: "\u{F700}"), "\u{F700}") // Up arrow
    }

    func testPassesTypedCharactersThrough() {
        XCTAssertEqual(PhoneKeys.text(keyCode: 0x00, characters: "A"), "A")
        XCTAssertEqual(PhoneKeys.text(keyCode: 0x31, characters: " "), " ")
        XCTAssertEqual(PhoneKeys.text(keyCode: 0x2B, characters: "é"), "é")
    }

    func testIgnoresFunctionKeysAndControlCharacters() {
        XCTAssertNil(PhoneKeys.text(keyCode: 0x7A, characters: "\u{F704}")) // F1
        XCTAssertNil(PhoneKeys.text(keyCode: 0x00, characters: "\u{1}"))
        XCTAssertNil(PhoneKeys.text(keyCode: 0x00, characters: nil))
    }
}
