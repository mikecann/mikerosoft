import AppKit
import XCTest
@testable import TelemprompitApp

@MainActor
final class PrompterModelTests: XCTestCase {
    private func makeModel() -> PrompterModel {
        let model = PrompterModel(defaults: UserDefaults(suiteName: "telemprompit-model-\(UUID().uuidString)")!)
        model.load("# Intro\n- One\n- Two\n    - Two point one\n- Three")
        // Items: heading, One, Two, Two point one, Three.
        model.updateLayout(tops: [0: 0, 1: 50, 2: 150, 3: 250, 4: 350], contentHeight: 420)
        return model
    }

    func testLoadingStartsOnTheFirstLineAtTheReadingLine() {
        let model = makeModel()
        XCTAssertEqual(model.current, 1)
        XCTAssertEqual(model.offset, model.targetOffset(for: 1))
        XCTAssertEqual(model.position, 1)
        XCTAssertEqual(model.stopCount, 4)
    }

    func testStepsForwardAndBackThroughLines() {
        let model = makeModel()
        model.next()
        XCTAssertEqual(model.current, 2)
        XCTAssertEqual(model.offset, model.targetOffset(for: 2))
        model.next()
        model.next()
        model.next()
        XCTAssertEqual(model.current, 4)
        model.previous()
        XCTAssertEqual(model.current, 3)
        model.restart()
        XCTAssertEqual(model.current, 1)
        model.end()
        XCTAssertEqual(model.current, 4)
    }

    func testTargetPutsTheFirstLineMiddleOnTheReadingLine() {
        let model = makeModel()
        XCTAssertEqual(model.targetOffset(for: 2), 150 + CGFloat(model.settings.fontSize) * 0.6)
    }

    func testManualScrollingMovesTheCurrentLineAndStaysInBounds() {
        let model = makeModel()
        model.nudge(by: 200)
        XCTAssertEqual(model.current, 3)
        model.nudge(by: -10_000)
        XCTAssertEqual(model.offset, 0)
        XCTAssertEqual(model.current, 1)
        model.nudge(by: 10_000)
        XCTAssertEqual(model.offset, 420)
        XCTAssertEqual(model.current, 4)
    }

    func testRelayoutKeepsTheCurrentLineOnTheReadingLine() {
        let model = makeModel()
        model.next()
        model.updateLayout(tops: [0: 0, 1: 80, 2: 240, 3: 400, 4: 560], contentHeight: 640)
        XCTAssertEqual(model.current, 2)
        XCTAssertEqual(model.offset, model.targetOffset(for: 2))
    }

    func testPixelRoundingNoiseDoesNotReanchorTheScroll() {
        let model = makeModel()
        model.nudge(by: 30)
        let scrolled = model.offset
        model.updateLayout(tops: [0: 0.3, 1: 50.25, 2: 150, 3: 249.75, 4: 350], contentHeight: 420.5)
        XCTAssertEqual(model.offset, scrolled)
    }

    func testEditingTheScriptKeepsYourPlaceWhenTheLineStillExists() {
        let model = makeModel()
        model.next()
        model.scriptText += "\n- Four"
        XCTAssertEqual(model.current, 2)
        XCTAssertEqual(model.stopCount, 5)
    }

    func testPasteReplacesTheScriptAndIgnoresAnEmptyClipboard() {
        let model = makeModel()
        model.next()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("telemprompit-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("  \n", forType: .string)
        XCTAssertFalse(model.pasteFromClipboard(pasteboard))
        XCTAssertEqual(model.stopCount, 4)

        pasteboard.clearContents()
        pasteboard.setString("- New one\n- New two", forType: .string)
        XCTAssertTrue(model.pasteFromClipboard(pasteboard))
        XCTAssertEqual(model.items, [.line("New one"), .line("New two")])
        XCTAssertEqual(model.current, 0)
    }

    func testInsertingALineAboveKeepsTheSameLineCurrent() {
        let model = makeModel()
        model.next() // "Two"
        model.scriptText = "# Intro\n- Zero\n- One\n- Two\n    - Two point one\n- Three"
        XCTAssertEqual(model.items[model.current!].text, "Two")
    }

    func testDeletingTheCurrentLineMovesToTheLineNowInItsPlace() {
        let model = makeModel()
        model.next() // "Two" at index 2
        model.scriptText = "# Intro\n- One\n    - Two point one\n- Three"
        XCTAssertEqual(model.items[model.current!].text, "Two point one")
    }

    func testClearingTheScriptLeavesNoCurrentLine() {
        let model = makeModel()
        model.load("")
        XCTAssertNil(model.current)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testSettingsArePersistedAndClamped() {
        let defaults = UserDefaults(suiteName: "telemprompit-model-\(UUID().uuidString)")!
        let model = PrompterModel(defaults: defaults)
        model.settings.fontSize = 999
        XCTAssertEqual(model.settings.fontSize, PrompterSettings.fontSizeRange.upperBound)
        XCTAssertEqual(PrompterSettings.load(from: defaults).fontSize, PrompterSettings.fontSizeRange.upperBound)
    }

    func testSpeedChangesAreMultiplicative() {
        let model = makeModel()
        model.settings.scrollSpeed = 100
        model.changeSpeed(by: 1.2)
        XCTAssertEqual(model.settings.scrollSpeed, 120)
    }

    func testRemoteCommandsMapToActions() {
        XCTAssertEqual(RemoteCommand(url: URL(string: "telemprompit://next")!), .next)
        XCTAssertEqual(RemoteCommand(url: URL(string: "telemprompit://previous")!), .previous)
        XCTAssertEqual(RemoteCommand(url: URL(string: "telemprompit:toggle")!), .toggleScrolling)
        XCTAssertEqual(RemoteCommand(url: URL(string: "telemprompit://PLAY")!), .play)
        XCTAssertNil(RemoteCommand(url: URL(string: "telemprompit://nope")!))
        XCTAssertNil(RemoteCommand(url: URL(string: "https://next")!))
    }
}
