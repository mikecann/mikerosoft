import XCTest
@testable import PhoneMirrorApp

final class KeepAwakeTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    func testNudgesAReadyPhoneStraightAway() {
        XCTAssertTrue(KeepAwake.shouldNudge(isOn: true, isReady: true, lastNudge: nil, now: now))
    }

    func testWaitsTheIntervalBetweenNudges() {
        XCTAssertFalse(KeepAwake.shouldNudge(isOn: true, isReady: true, lastNudge: now.addingTimeInterval(-10), now: now))
        XCTAssertTrue(KeepAwake.shouldNudge(isOn: true, isReady: true, lastNudge: now.addingTimeInterval(-KeepAwake.interval), now: now))
    }

    func testLeavesLockedPhonesAndTheOffSwitchAlone() {
        XCTAssertFalse(KeepAwake.shouldNudge(isOn: true, isReady: false, lastNudge: nil, now: now))
        XCTAssertFalse(KeepAwake.shouldNudge(isOn: false, isReady: true, lastNudge: nil, now: now))
    }
}
