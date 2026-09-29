import XCTest
@testable import MikeyMouse

final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MikeyMouseTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsMatchMacMouseFixSetup() {
        let settings = SettingsStore(defaults: defaults).current

        XCTAssertTrue(settings.backForwardEnabled)
        XCTAssertTrue(settings.smoothScrollingEnabled)
        XCTAssertEqual(settings.scrollSpeed, .medium)
        XCTAssertEqual(settings.smoothness, .high)
    }

    func testChangesPersistAcrossLaunches() {
        SettingsStore(defaults: defaults).update {
            $0.backForwardEnabled = false
            $0.smoothScrollingEnabled = false
            $0.scrollSpeed = .fast
            $0.smoothness = .low
        }

        let reloaded = SettingsStore(defaults: defaults).current

        XCTAssertFalse(reloaded.backForwardEnabled)
        XCTAssertFalse(reloaded.smoothScrollingEnabled)
        XCTAssertEqual(reloaded.scrollSpeed, .fast)
        XCTAssertEqual(reloaded.smoothness, .low)
    }

    func testUnknownStoredValuesFallBackToDefaults() {
        defaults.set("warp", forKey: "scrollSpeed")
        defaults.set("silky", forKey: "smoothness")

        let settings = SettingsStore(defaults: defaults).current

        XCTAssertEqual(settings.scrollSpeed, .medium)
        XCTAssertEqual(settings.smoothness, .high)
    }

    func testFasterSpeedsTravelFurtherPerTick() {
        XCTAssertLessThan(ScrollSpeed.slow.pixelsPerTick, ScrollSpeed.medium.pixelsPerTick)
        XCTAssertLessThan(ScrollSpeed.medium.pixelsPerTick, ScrollSpeed.fast.pixelsPerTick)
    }

    func testSmootherSettingsGlideLonger() {
        XCTAssertLessThan(Smoothness.low.timeConstant, Smoothness.medium.timeConstant)
        XCTAssertLessThan(Smoothness.medium.timeConstant, Smoothness.high.timeConstant)
    }
}
