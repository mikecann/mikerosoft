import XCTest
@testable import PhoneMirrorApp

final class AgentRunnerTests: XCTestCase {
    func testBuildsWhenNothingIsBuiltYet() {
        XCTAssertTrue(AgentRunner.needsBuild(status: 3, output: "ERROR: WebDriverAgent isn't built yet."))
    }

    func testBuildsWhenThePhoneIsNotCoveredBySigning() {
        XCTAssertTrue(AgentRunner.needsBuild(status: 65, output: "error: The provisioning profile doesn't include the device"))
        XCTAssertTrue(AgentRunner.needsBuild(status: 65, output: "The application could not be verified."))
    }

    func testDoesNotRebuildForOrdinaryStops() {
        XCTAssertFalse(AgentRunner.needsBuild(status: 15, output: "Testing cancelled"))
        XCTAssertFalse(AgentRunner.needsBuild(status: 65, output: "Lost connection to the device"))
    }

    func testSummarisesTheLastErrorLine() {
        let output = "Building...\nerror: first problem\nsomething\nerror: the real problem\ndone"
        XCTAssertEqual(AgentRunner.summary(of: output), "error: the real problem")
        XCTAssertEqual(AgentRunner.summary(of: "just this"), "just this")
        XCTAssertEqual(AgentRunner.summary(of: ""), "The phone helper stopped")
    }
}
