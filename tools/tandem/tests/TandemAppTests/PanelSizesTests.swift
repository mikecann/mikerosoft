import XCTest
@testable import TandemApp

final class PanelSizesTests: XCTestCase {
    private func store() -> UserDefaults {
        let name = "tandem-panels-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { store.removePersistentDomain(forName: name) }
        return store
    }

    func testStandardSizesFitTheSmallestWindow() {
        let fitted = PanelSizes.standard.fitted(windowWidth: 1_080)
        XCTAssertEqual(fitted.library, 300)
        XCTAssertEqual(fitted.inspector, 330)
    }

    /// Wide panels in a narrow window give up room, each in proportion to
    /// how far it's over its minimum, so the viewer keeps its 420 points.
    func testWidePanelsShrinkToLeaveTheViewerItsRoom() {
        let sizes = PanelSizes(libraryWidth: 440, inspectorWidth: 400, workspaceHeight: nil)
        let fitted = sizes.fitted(windowWidth: 1_200)
        // Over by 440 + 400 + 420 + 2 - 1200 = 62; spare is 200 and 100.
        XCTAssertEqual(fitted.library, 440 - 62 * 200 / 300, accuracy: 0.001)
        XCTAssertEqual(fitted.inspector, 400 - 62 * 100 / 300, accuracy: 0.001)
        XCTAssertEqual(fitted.library + fitted.inspector + 420 + 2, 1_200, accuracy: 0.001)
        let roomy = sizes.fitted(windowWidth: 2_560)
        XCTAssertEqual(roomy.library, 440, "the saved widths come back in a wider window")
        XCTAssertEqual(roomy.inspector, 400)
    }

    func testDragsStayInRangeAndLeaveTheViewerItsRoom() {
        let sizes = PanelSizes.standard
        XCTAssertEqual(sizes.library(dragged: 100, windowWidth: 2_560), 240)
        XCTAssertEqual(sizes.library(dragged: 900, windowWidth: 2_560), 560)
        XCTAssertEqual(sizes.library(dragged: 400, windowWidth: 2_560), 400)
        // 1200 wide: 1200 - 330 - 420 - 2 leaves the library 448.
        XCTAssertEqual(sizes.library(dragged: 520, windowWidth: 1_200), 448)
        XCTAssertEqual(sizes.inspector(dragged: 250, windowWidth: 2_560), 300)
        XCTAssertEqual(sizes.inspector(dragged: 520, windowWidth: 1_200), 478)
    }

    func testSurvivesARestart() {
        let defaults = store()
        XCTAssertEqual(PanelSizes.load(from: defaults), .standard, "nothing saved yet")
        PanelSizes(libraryWidth: 360, inspectorWidth: 420, workspaceHeight: 610).save(to: defaults)
        XCTAssertEqual(PanelSizes.load(from: defaults), PanelSizes(libraryWidth: 360, inspectorWidth: 420, workspaceHeight: 610))
        PanelSizes(libraryWidth: 360, inspectorWidth: 420, workspaceHeight: nil).save(to: defaults)
        XCTAssertNil(PanelSizes.load(from: defaults).workspaceHeight, "back to following the window")
        defaults.set(5_000.0, forKey: "panelLibraryWidth")
        XCTAssertEqual(PanelSizes.load(from: defaults).libraryWidth, 560, "out of range is clamped")
    }
}
