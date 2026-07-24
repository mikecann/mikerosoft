import XCTest
@testable import LastWindowQuits

final class QuitDecisionEngineTests: XCTestCase {
    func testAppThatStartsWithoutWindowsIsNotQuit() {
        var engine = QuitDecisionEngine(gracePeriod: 1)

        XCTAssertEqual(engine.update([snapshot(windows: 0)], now: 0), [])
        XCTAssertEqual(engine.update([snapshot(windows: 0)], now: 10), [])
    }

    func testAppIsQuitAfterLastWindowStaysClosedForGracePeriod() {
        var engine = QuitDecisionEngine(gracePeriod: 1)

        XCTAssertEqual(engine.update([snapshot(windows: 1)], now: 0), [])
        XCTAssertEqual(engine.update([snapshot(windows: 0)], now: 1), [])
        XCTAssertEqual(engine.update([snapshot(windows: 0)], now: 1.9), [])
        XCTAssertEqual(engine.update([snapshot(windows: 0)], now: 2), [42])
    }

    func testNewWindowCancelsPendingQuit() {
        var engine = QuitDecisionEngine(gracePeriod: 1)

        _ = engine.update([snapshot(windows: 1)], now: 0)
        _ = engine.update([snapshot(windows: 0)], now: 1)
        XCTAssertEqual(engine.update([snapshot(windows: 1)], now: 1.5), [])
        XCTAssertEqual(engine.update([snapshot(windows: 0)], now: 2), [])
        XCTAssertEqual(engine.update([snapshot(windows: 0)], now: 3), [42])
    }

    func testQuitIsRequestedOnlyOnceUntilAnotherWindowAppears() {
        var engine = QuitDecisionEngine(gracePeriod: 1)

        _ = engine.update([snapshot(windows: 1)], now: 0)
        _ = engine.update([snapshot(windows: 0)], now: 1)
        XCTAssertEqual(engine.update([snapshot(windows: 0)], now: 2), [42])
        XCTAssertEqual(engine.update([snapshot(windows: 0)], now: 3), [])
    }

    func testIneligibleAppIsNeverQuit() {
        var engine = QuitDecisionEngine(gracePeriod: 1)

        _ = engine.update([snapshot(windows: 1, eligible: false)], now: 0)
        XCTAssertEqual(engine.update([snapshot(windows: 0, eligible: false)], now: 10), [])
    }

    func testMissingProcessStateIsDiscarded() {
        var engine = QuitDecisionEngine(gracePeriod: 1)

        _ = engine.update([snapshot(windows: 1)], now: 0)
        _ = engine.update([], now: 1)
        XCTAssertEqual(engine.update([snapshot(windows: 0)], now: 10), [])
    }

    private func snapshot(windows: Int, eligible: Bool = true) -> AppSnapshot {
        AppSnapshot(processIdentifier: 42, windowCount: windows, isEligible: eligible)
    }
}
