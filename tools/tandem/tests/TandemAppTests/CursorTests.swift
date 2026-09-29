import AppKit
import XCTest
@testable import TandemApp
@testable import TandemCore

/// The cursor says what a press would do: scale from a viewer handle, move
/// the selected layer, trim, roll, slip, cut, move a marker, set a height.
final class CursorTests: XCTestCase {
    // MARK: Viewer

    /// A selection box from (100, 50) to (300, 150), y down as in the view.
    let box = CGRect(x: 100, y: 50, width: 200, height: 100)

    func testHandlesSitOnTheCornersOfTheBox() {
        let handles = ViewerHandles.rects(for: box)
        XCTAssertEqual(handles.map(\.corner), [.topLeft, .topRight, .bottomLeft, .bottomRight])
        XCTAssertEqual(handles.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }, [
            CGPoint(x: 100, y: 50), CGPoint(x: 300, y: 50), CGPoint(x: 100, y: 150), CGPoint(x: 300, y: 150)
        ])
    }

    func testEachCornerHandleShowsItsDiagonal() {
        XCTAssertEqual(ViewerHandles.cursor(at: CGPoint(x: 100, y: 50), box: box, zoomKeyHeld: false), .scaleCorner(.topLeft))
        XCTAssertEqual(ViewerHandles.cursor(at: CGPoint(x: 300, y: 50), box: box, zoomKeyHeld: false), .scaleCorner(.topRight))
        XCTAssertEqual(ViewerHandles.cursor(at: CGPoint(x: 100, y: 150), box: box, zoomKeyHeld: false), .scaleCorner(.bottomLeft))
        XCTAssertEqual(ViewerHandles.cursor(at: CGPoint(x: 300, y: 150), box: box, zoomKeyHeld: false), .scaleCorner(.bottomRight))
        // A few points off the handle still grab it, as a press does.
        XCTAssertEqual(ViewerHandles.cursor(at: CGPoint(x: 93, y: 43), box: box, zoomKeyHeld: false), .scaleCorner(.topLeft))
        XCTAssertEqual(ViewerHandles.corner(at: CGPoint(x: 93, y: 43), box: box), .topLeft)
        XCTAssertNil(ViewerHandles.corner(at: CGPoint(x: 90, y: 40), box: box))
    }

    func testInsideTheSelectedBoxGrabsAndOutsideIsTheArrow() {
        XCTAssertEqual(ViewerHandles.cursor(at: CGPoint(x: 200, y: 100), box: box, zoomKeyHeld: false), .grab)
        XCTAssertEqual(ViewerHandles.cursor(at: CGPoint(x: 50, y: 100), box: box, zoomKeyHeld: false), .arrow)
        XCTAssertEqual(ViewerHandles.cursor(at: CGPoint(x: 200, y: 100), box: nil, zoomKeyHeld: false), .arrow)
    }

    func testTheZoomKeyShowsZoomAnywhere() {
        XCTAssertEqual(ViewerHandles.cursor(at: CGPoint(x: 100, y: 50), box: box, zoomKeyHeld: true), .zoomIn)
        XCTAssertEqual(ViewerHandles.cursor(at: CGPoint(x: 10, y: 10), box: nil, zoomKeyHeld: true), .zoomIn)
    }

    // MARK: Timeline

    func press(_ f: AppFixture, _ hit: TimelineHit, _ tool: TimelineTool, command: Bool = false) -> DragKind? {
        DragKind.forPress(on: hit, tool: tool, project: f.project, selection: [], rippleByDefault: false, command: command, option: false)
    }

    func cursor(_ f: AppFixture, _ hit: TimelineHit, _ tool: TimelineTool, keyframe: Bool = false) -> CursorKind {
        CursorKind.timeline(hit: hit, tool: tool, overKeyframe: keyframe, press: press(f, hit, tool), project: f.project)
    }

    func testTimelineCursorFollowsWhatAPressWouldDo() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let trackID = f.track("B-roll").id
        let body = TimelineHit.clip(clipID: broll.id, trackID: trackID, part: .body)
        let head = TimelineHit.clip(clipID: broll.id, trackID: trackID, part: .head)
        let tail = TimelineHit.clip(clipID: broll.id, trackID: trackID, part: .tail)
        let empty = TimelineHit.emptyTrack(trackID: trackID, time: t(40))

        XCTAssertEqual(cursor(f, body, .select), .arrow, "clips move with the arrow, as in other editors")
        XCTAssertEqual(cursor(f, head, .select), .trim)
        XCTAssertEqual(cursor(f, tail, .rippleTrim), .trim)
        XCTAssertEqual(cursor(f, body, .rippleTrim), .arrow)
        XCTAssertEqual(cursor(f, body, .slip), .grab)
        XCTAssertEqual(cursor(f, body, .slide), .grab)
        XCTAssertEqual(cursor(f, body, .blade), .blade)
        XCTAssertEqual(cursor(f, empty, .blade), .arrow)
        XCTAssertEqual(cursor(f, empty, .select), .arrow)
        XCTAssertEqual(cursor(f, body, .select, keyframe: true), .pointer)
        XCTAssertEqual(cursor(f, body, .blade, keyframe: true), .blade, "the blade cuts through keyframes")
    }

    func testRollShowsOnlyOnACutBetweenTwoClips() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let camera = f.track("Camera")
        let left = camera.clips[0], right = camera.clips[1]
        XCTAssertEqual(cursor(f, .clip(clipID: left.id, trackID: camera.id, part: .tail), .roll), .roll)
        XCTAssertEqual(cursor(f, .clip(clipID: right.id, trackID: camera.id, part: .head), .roll), .roll)
        // The take's first edge has nothing to roll against, so it trims.
        XCTAssertEqual(cursor(f, .clip(clipID: left.id, trackID: camera.id, part: .head), .roll), .trim)
    }

    func testALockedTrackShowsTheArrow() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let track = f.track("B-roll")
        try f.apply(EditBatch(label: "Lock", commands: [.updateTrack(trackID: track.id, patch: .object(["locked": .bool(true)]))]))
        for part in [ClipPart.head, .body, .tail] {
            let hit = TimelineHit.clip(clipID: broll.id, trackID: track.id, part: part)
            for tool in TimelineTool.allCases {
                XCTAssertEqual(cursor(f, hit, tool), .arrow, "\(tool) on the \(part)")
            }
        }
    }

    func testDragsKeepTheirCursor() {
        XCTAssertEqual(CursorKind.dragging(.trim(clipID: "a", edge: .start, ripple: true, includeLinked: true)), .trim)
        XCTAssertEqual(CursorKind.dragging(.roll(leftClipID: "a", rightClipID: "b")), .roll)
        XCTAssertEqual(CursorKind.dragging(.slip(clipID: "a", includeLinked: true)), .grabbing)
        XCTAssertEqual(CursorKind.dragging(.slide(clipID: "a")), .grabbing)
        XCTAssertEqual(CursorKind.dragging(.move(clipIDs: ["a"], anchorClipID: "a")), .arrow)
    }

    // MARK: The cursors themselves

    func image(_ kind: CursorKind) -> Data? { kind.nsCursor.image.tiffRepresentation }

    func testCornerCursorsPointAlongTheirDiagonal() {
        XCTAssertEqual(image(.scaleCorner(.topLeft)), image(.scaleCorner(.bottomRight)))
        XCTAssertEqual(image(.scaleCorner(.topRight)), image(.scaleCorner(.bottomLeft)))
        XCTAssertNotEqual(image(.scaleCorner(.topLeft)), image(.scaleCorner(.topRight)))
    }

    func testEveryKindButTheArrowLooksDifferent() {
        let kinds: [CursorKind] = [.grab, .grabbing, .scaleCorner(.topLeft), .scaleCorner(.topRight), .trim, .roll, .blade, .rowResize, .pointer, .zoomIn]
        let images = kinds.map(image)
        XCTAssertEqual(Set(images.compactMap { $0 }).count, kinds.count, "each kind has its own cursor")
        XCTAssertFalse(images.contains(image(.arrow)))
    }

    func testTheDebugDumpNamesTheCursor() {
        XCTAssertEqual(CursorKind.describe(CursorKind.blade.nsCursor), "blade")
        XCTAssertEqual(CursorKind.describe(NSCursor.frameResize(position: .bottomRight, directions: .all)), "scaleCorner(TandemApp.ViewerCorner.topLeft)")
        let dot = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        XCTAssertEqual(CursorKind.describe(NSCursor(image: dot, hotSpot: .zero)), "other")
    }

    func testTheBladeCutsAtItsHotSpot() {
        let cursor = CursorKind.blade.nsCursor
        let size = cursor.image.size
        XCTAssertGreaterThan(size.width, 10)
        XCTAssertGreaterThan(size.height, 10)
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(cursor.hotSpot))
        XCTAssertIdentical(CursorKind.blade.nsCursor, cursor, "made once")
    }
}
