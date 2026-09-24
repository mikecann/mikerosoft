import XCTest
@testable import PrompterKit

final class PrompterDisplayTests: XCTestCase {
    func testMatchesFullAndShortenedElgatoPrompterNames() {
        XCTAssertTrue(PrompterDisplay.isPrompterDisplay(named: "Elgato Prompter"))
        XCTAssertTrue(PrompterDisplay.isPrompterDisplay(named: "Elgato Prom."))
        XCTAssertTrue(PrompterDisplay.isPrompterDisplay(named: "ELGATO PROMPTER (2)"))
        XCTAssertFalse(PrompterDisplay.isPrompterDisplay(named: "LG Monitor"))
        XCTAssertFalse(PrompterDisplay.isPrompterDisplay(named: "Elgato Stream Deck"))
    }

    func testFillFrameLeavesRoomForTheTaskbar() {
        let frame = PrompterDisplay.fillFrame(in: CGRect(x: 100, y: 0, width: 1024, height: 600))
        XCTAssertEqual(frame, CGRect(x: 100, y: 32, width: 1024, height: 568))
    }

    func testFillFrameNeverShrinksATinyScreenBelowItsMinimumHeight() {
        let frame = PrompterDisplay.fillFrame(in: CGRect(x: 0, y: 0, width: 400, height: 250))
        XCTAssertEqual(frame.height, 240)
    }
}
