import AppKit
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

final class WindowPlacementTests: XCTestCase {
    private let laptop = NSRect(x: 0, y: 0, width: 1_512, height: 950)
    private let monitor = NSRect(x: -2_560, y: -269, width: 2_560, height: 1_440)

    private func store() -> UserDefaults {
        let name = "tandem-placement-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { store.removePersistentDomain(forName: name) }
        return store
    }

    /// The editor goes back to the monitor it was on, even when another
    /// screen is the active one at launch.
    func testRestoresTheFrameOnTheScreenItWasOn() {
        let defaults = store()
        let frame = NSRect(x: -2_560, y: -237, width: 2_560, height: 1_408)
        WindowPlacement.save(frame, to: defaults)
        XCTAssertEqual(WindowPlacement.restored(screens: [laptop, monitor], occupied: [], store: defaults), frame)
    }

    func testForgetsAFrameWhoseScreenHasGone() {
        let defaults = store()
        WindowPlacement.save(NSRect(x: -2_560, y: -237, width: 2_560, height: 1_408), to: defaults)
        XCTAssertNil(WindowPlacement.restored(screens: [laptop], occupied: [], store: defaults), "the monitor is unplugged")
        XCTAssertNil(WindowPlacement.restored(screens: [laptop], occupied: [], store: store()), "nothing saved")
    }

    func testNeedsTheTitleBarOnScreenToGrab() {
        // Hanging off the top of the laptop screen: can't be dragged back.
        XCTAssertFalse(WindowPlacement.isOnScreen(NSRect(x: 100, y: 400, width: 1_200, height: 700), screens: [laptop]))
        XCTAssertTrue(WindowPlacement.isOnScreen(NSRect(x: 100, y: 200, width: 1_200, height: 700), screens: [laptop]))
        // Mostly off the right edge.
        XCTAssertFalse(WindowPlacement.isOnScreen(NSRect(x: 1_300, y: 100, width: 1_200, height: 700), screens: [laptop]))
    }

    /// Two projects open side by side each come back where they were; a
    /// project with no frame of its own opens where the last window was.
    func testEachProjectKeepsItsOwnFrame() {
        let defaults = store()
        let decisions = URL(fileURLWithPath: "/videos/decision-models/v14.tandem")
        let workbench = URL(fileURLWithPath: "/videos/workbench/Workbench.tandem")
        let left = NSRect(x: -2_560, y: -237, width: 1_280, height: 1_408)
        let right = NSRect(x: -1_280, y: -237, width: 1_280, height: 1_408)
        WindowPlacement.save(left, for: decisions, to: defaults)
        WindowPlacement.save(right, for: workbench, to: defaults)
        XCTAssertEqual(WindowPlacement.restored(screens: [laptop, monitor], occupied: [], for: decisions, store: defaults), left)
        XCTAssertEqual(WindowPlacement.restored(screens: [laptop, monitor], occupied: [], for: workbench, store: defaults), right)
        let other = URL(fileURLWithPath: "/videos/new/New.tandem")
        XCTAssertEqual(WindowPlacement.restored(screens: [laptop, monitor], occupied: [], for: other, store: defaults), right, "the last window's frame")
    }

    func testSteppedPastAWindowAlreadyThere() {
        let defaults = store()
        let frame = NSRect(x: 100, y: 200, width: 1_200, height: 700)
        WindowPlacement.save(frame, to: defaults)
        XCTAssertEqual(WindowPlacement.restored(screens: [laptop], occupied: [frame], store: defaults), frame.offsetBy(dx: 24, dy: -24))
    }
}

@MainActor
final class ProjectWindowFrameTests: XCTestCase {
    /// A restart to install a build put the editor back at the default size.
    func testTheWindowOpensWhereTheLastOneWas() throws {
        guard let screen = NSScreen.screens.first?.visibleFrame else { throw XCTSkip("no screen") }
        let saved = UserDefaults.standard.string(forKey: WindowPlacement.key)
        defer { UserDefaults.standard.set(saved, forKey: WindowPlacement.key) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-frame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Frame.tandem")

        func open() throws -> ProjectWindowController {
            let session = FileManager.default.fileExists(atPath: url.path)
                ? try ProjectSession.open(url, owner: .app)
                : try ProjectSession.create(at: url, name: "Frame", owner: .app)
            return ProjectWindowController(model: EditorModel(session: session), keymap: Keymap(name: "Test", bindings: [:]))
        }
        func close(_ controller: ProjectWindowController) {
            controller.model.tearDown()
            _ = controller.model.session.close()
        }

        let first = try open()
        let placed = NSRect(x: screen.minX + 40, y: screen.minY + 60, width: 1_100, height: 700)
        first.window?.setFrame(placed, display: false)
        XCTAssertEqual(WindowPlacement.saved(), placed, "moving the window remembers it")
        close(first)

        let second = try open()
        XCTAssertEqual(second.window?.frame, placed)
        close(second)
    }
}

/// A project's timeline comes back where it was: the playhead, the zoom
/// and the scroll, so a restart to install a build doesn't lose the place.
final class TimelinePlacementTests: XCTestCase {
    private func store() -> UserDefaults {
        let name = "tandem-timeline-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { store.removePersistentDomain(forName: name) }
        return store
    }

    func testEachProjectKeepsItsPlace() {
        let defaults = store()
        let talk = URL(fileURLWithPath: "/videos/talk/Talk.tandem")
        let short = URL(fileURLWithPath: "/videos/short/Short.tandem")
        let place = TimelinePlacement.Saved(playhead: 312.4, pixelsPerSecond: 48, scrollSeconds: 290, verticalOffset: 36)
        TimelinePlacement.save(place, for: talk, to: defaults)
        TimelinePlacement.save(TimelinePlacement.Saved(playhead: 5, pixelsPerSecond: 200, scrollSeconds: 0, verticalOffset: 0), for: short, to: defaults)
        XCTAssertEqual(TimelinePlacement.saved(for: talk, in: defaults), place)
        XCTAssertEqual(TimelinePlacement.saved(for: short, in: defaults)?.playhead, 5)
        XCTAssertEqual(TimelinePlacement.saved(for: URL(fileURLWithPath: "/videos/talk/../talk/Talk.tandem"), in: defaults), place, "the same file however it's spelled")
        XCTAssertNil(TimelinePlacement.saved(for: URL(fileURLWithPath: "/videos/new/New.tandem"), in: defaults), "a new project fits")
    }

    func testNonsenseIsIgnored() {
        let defaults = store()
        let talk = URL(fileURLWithPath: "/videos/talk/Talk.tandem")
        TimelinePlacement.save(TimelinePlacement.Saved(playhead: 10, pixelsPerSecond: 0, scrollSeconds: 0, verticalOffset: 0), for: talk, to: defaults)
        XCTAssertNil(TimelinePlacement.saved(for: talk, in: defaults), "no zoom")
        TimelinePlacement.save(TimelinePlacement.Saved(playhead: -4, pixelsPerSecond: 20, scrollSeconds: -1, verticalOffset: .nan), for: talk, to: defaults)
        XCTAssertEqual(TimelinePlacement.saved(for: talk, in: defaults), TimelinePlacement.Saved(playhead: 0, pixelsPerSecond: 20, scrollSeconds: 0, verticalOffset: 0))
    }
}
