import XCTest
@testable import TandemApp

final class RevisionMemoTests: XCTestCase {
    func testAsksOncePerKeyUntilTheRevisionChanges() {
        var memo = RevisionMemo<Bool>()
        var asked = 0
        func lookup(_ key: String, _ revision: Int, answer: Bool) -> Bool {
            memo.value(for: key, revision: revision) {
                asked += 1
                return answer
            }
        }
        XCTAssertFalse(lookup("take1", 3, answer: false))
        XCTAssertFalse(lookup("take1", 3, answer: true), "remembered, not asked again")
        XCTAssertTrue(lookup("take2", 3, answer: true))
        XCTAssertEqual(asked, 2)
        // A transcript landed: the revision went up, so it looks again.
        XCTAssertTrue(lookup("take1", 4, answer: true))
        XCTAssertEqual(asked, 3)
    }
}
