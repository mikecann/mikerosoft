import XCTest
@testable import TandemApp

final class SaveProblemTextTests: XCTestCase {
    func testSaveProblemsReadAsSentences() {
        XCTAssertEqual(
            SaveProblem.message(file: "Video.tandem", reason: "You don't have permission to save the file in the folder droptest"),
            "Couldn't save Video.tandem. You don't have permission to save the file in the folder droptest. Tandem keeps trying."
        )
        XCTAssertEqual(SaveProblem.sentence("The disk is full."), "The disk is full.")
        XCTAssertEqual(SaveProblem.sentence("  "), "The file couldn't be written.")
        let alert = SaveProblem.closeAlert(files: ["A.tandem", "B.tandem"], reason: "The disk is full", quitting: true)
        XCTAssertEqual(alert.title, "Tandem couldn't save 2 projects")
        XCTAssertTrue(alert.detail.hasPrefix("The disk is full.\n\nQuitting now loses"))
    }
}
