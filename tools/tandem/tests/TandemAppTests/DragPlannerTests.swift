import XCTest
@testable import TandemApp
@testable import TandemCore

/// Each tool's drag, from pointer movement to the batch committed on mouse
/// up, checked by applying it to the fixture.
final class DragPlannerTests: XCTestCase {
    /// 10 px a second, so 1 px is 0.1 s and snapping reaches 0.8 s.
    func context(_ f: AppFixture, snapping: Bool = true, playhead: Time = t(45)) -> DragContext {
        DragContext(
            project: f.project,
            scale: TimelineScale(pixelsPerSecond: 10),
            layout: TimelineLayout.make(project: f.project, showTranscript: true),
            snapping: snapping,
            playhead: playhead
        )
    }

    func lane(_ f: AppFixture, _ name: String) -> TimelineLane {
        TimelineLayout.make(project: f.project, showTranscript: true).lane(forTrack: f.track(name).id)!
    }

    // MARK: Press

    func testPressPicksTheDragForEachTool() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let trackID = f.track("B-roll").id
        let body = TimelineHit.clip(clipID: broll.id, trackID: trackID, part: .body)
        let head = TimelineHit.clip(clipID: broll.id, trackID: trackID, part: .head)
        func press(_ hit: TimelineHit, _ tool: TimelineTool, ripple: Bool = false, command: Bool = false, option: Bool = false) -> DragKind? {
            DragKind.forPress(on: hit, tool: tool, project: f.project, selection: [], rippleByDefault: ripple, command: command, option: option)
        }
        XCTAssertEqual(press(body, .select), .move(clipIDs: [broll.id], anchorClipID: broll.id))
        XCTAssertEqual(press(head, .select), .trim(clipID: broll.id, edge: .start, ripple: false, includeLinked: true))
        XCTAssertEqual(press(head, .select, command: true), .trim(clipID: broll.id, edge: .start, ripple: true, includeLinked: true))
        XCTAssertEqual(press(head, .select, ripple: true), .trim(clipID: broll.id, edge: .start, ripple: true, includeLinked: true))
        XCTAssertEqual(press(head, .select, option: true), .trim(clipID: broll.id, edge: .start, ripple: false, includeLinked: false))
        XCTAssertEqual(press(head, .rippleTrim), .trim(clipID: broll.id, edge: .start, ripple: true, includeLinked: true))
        XCTAssertNil(press(body, .rippleTrim))
        XCTAssertEqual(press(body, .slip), .slip(clipID: broll.id, includeLinked: true))
        XCTAssertEqual(press(body, .slide), .slide(clipID: broll.id))
        XCTAssertNil(press(body, .blade), "the blade cuts on click, it doesn't drag")
        XCTAssertNil(press(.emptyTrack(trackID: trackID, time: t(3)), .select))
    }

    func testRollNeedsTouchingClips() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let trackID = f.track("Camera").id
        let left = f.clip("Camera", 0)
        let right = f.clip("Camera", 1)
        let kind = DragKind.forPress(on: .clip(clipID: right.id, trackID: trackID, part: .head), tool: .roll, project: f.project, selection: [], rippleByDefault: false, command: false, option: false)
        XCTAssertEqual(kind, .roll(leftClipID: left.id, rightClipID: right.id))
        let lone = DragKind.forPress(on: .clip(clipID: left.id, trackID: trackID, part: .head), tool: .roll, project: f.project, selection: [], rippleByDefault: false, command: false, option: false)
        XCTAssertEqual(lone, .trim(clipID: left.id, edge: .start, ripple: false, includeLinked: true), "no neighbour to roll with, so it trims")
    }

    func testPressingASelectedClipDragsTheWholeSelection() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let music = f.clip("Music")
        let kind = DragKind.forPress(on: .clip(clipID: broll.id, trackID: f.track("B-roll").id, part: .body), tool: .select, project: f.project, selection: [broll.id, music.id], rippleByDefault: false, command: false, option: false)
        XCTAssertEqual(kind, .move(clipIDs: [broll.id, music.id], anchorClipID: broll.id))
    }

    // MARK: Move

    func testMoveSnapsToAMarker() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll") // 20 to 25; the marker is at 30
        // 47 px is 4.7 s: the end lands at 29.7, within reach of 30.
        let plan = DragPlanner.plan(.move(clipIDs: [broll.id], anchorClipID: broll.id), pointer: DragPointer(deltaX: 47, y: lane(f, "B-roll").midY), context: context(f))
        XCTAssertEqual(plan.delta, t(5))
        XCTAssertEqual(plan.snappedTo, t(30))
        try f.apply(plan.batch)
        XCTAssertEqual(f.clip("B-roll").range, TimeRange(start: t(25), end: t(30)))
    }

    func testShiftTurnsSnappingOffForOneDrag() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let plan = DragPlanner.plan(.move(clipIDs: [broll.id], anchorClipID: broll.id), pointer: DragPointer(deltaX: 47, y: lane(f, "B-roll").midY, invertSnap: true), context: context(f))
        XCTAssertEqual(plan.delta, t(4.7))
        XCTAssertNil(plan.snappedTo)
    }

    func testMoveStopsAtZero() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let plan = DragPlanner.plan(.move(clipIDs: [broll.id], anchorClipID: broll.id), pointer: DragPointer(deltaX: -900, y: lane(f, "B-roll").midY), context: context(f, snapping: false))
        XCTAssertEqual(plan.delta, t(-20))
    }

    func testDraggingDownALaneChangesTrack() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let plan = DragPlanner.plan(.move(clipIDs: [broll.id], anchorClipID: broll.id), pointer: DragPointer(deltaX: 0, y: lane(f, "Graphics").midY), context: context(f))
        XCTAssertEqual(plan.destinationTrackID, f.track("Graphics").id)
        try f.apply(plan.batch)
        XCTAssertEqual(f.clip("Graphics").range, TimeRange(start: t(20), end: t(25)))
    }

    func testVideoClipsDontLandOnAudioLanes() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let plan = DragPlanner.plan(.move(clipIDs: [broll.id], anchorClipID: broll.id), pointer: DragPointer(deltaX: 0, y: lane(f, "Music").midY), context: context(f))
        XCTAssertEqual(plan.destinationTrackID, f.track("Screen").id, "the nearest video track")
    }

    func testCommandDragInserts() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let plan = DragPlanner.plan(.move(clipIDs: [broll.id], anchorClipID: broll.id), pointer: DragPointer(deltaX: 0, y: lane(f, "Graphics").midY, insert: true), context: context(f))
        XCTAssertEqual(plan.batch?.label, "Insert clip")
        try f.apply(plan.batch)
        XCTAssertEqual(f.clip("Graphics").range, TimeRange(start: t(20), end: t(25)))
    }

    // MARK: Trim

    func testTrimSnapsToThePlayhead() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll") // tail at 25
        let plan = DragPlanner.plan(.trim(clipID: broll.id, edge: .end, ripple: false, includeLinked: true), pointer: DragPointer(deltaX: -8, y: 0), context: context(f, playhead: t(24)))
        XCTAssertEqual(plan.snappedTo, t(24))
        try f.apply(plan.batch)
        XCTAssertEqual(f.clip("B-roll").end, t(24))
    }

    func testTrimStopsWhereTheMediaRunsOut() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll") // shows 1 to 6 of a 10 s file
        let tail = DragPlanner.plan(.trim(clipID: broll.id, edge: .end, ripple: false, includeLinked: true), pointer: DragPointer(deltaX: 200, y: 0), context: context(f, snapping: false))
        XCTAssertEqual(tail.delta, t(4))
        let head = DragPlanner.plan(.trim(clipID: broll.id, edge: .start, ripple: false, includeLinked: true), pointer: DragPointer(deltaX: -200, y: 0), context: context(f, snapping: false))
        XCTAssertEqual(head.delta, t(-1))
        try f.apply(head.batch)
        XCTAssertEqual(f.clip("B-roll").sourceStart, .zero)
    }

    func testTrimStopsAtTheNeighbour() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let left = f.clip("Camera", 0)
        // Can't grow into the next clip without rippling.
        let plan = DragPlanner.plan(.trim(clipID: left.id, edge: .end, ripple: false, includeLinked: true), pointer: DragPointer(deltaX: 50, y: 0), context: context(f, snapping: false))
        XCTAssertNil(plan.batch)
        // Shrinking is fine and never below a frame.
        let shrink = DragPlanner.plan(.trim(clipID: left.id, edge: .end, ripple: false, includeLinked: true), pointer: DragPointer(deltaX: -500, y: 0), context: context(f, snapping: false))
        XCTAssertEqual(shrink.delta, -(t(10) - Time.frames(1, at: .fps30)))
    }

    func testRippleTrimMovesEverythingAfter() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let left = f.clip("Camera", 0)
        let plan = DragPlanner.plan(.trim(clipID: left.id, edge: .end, ripple: true, includeLinked: true), pointer: DragPointer(deltaX: -20, y: 0), context: context(f, snapping: false))
        try f.apply(plan.batch)
        XCTAssertEqual(f.clip("Camera", 0).range, TimeRange(start: t(0), end: t(8)))
        XCTAssertEqual(f.clip("Camera", 1).start, t(8))
        XCTAssertEqual(f.clip("B-roll").start, t(18))
    }

    func testOptionTrimLeavesTheLinkedSideAlone() throws {
        let f = try AppFixture()
        let camera = f.clip("Camera")
        let plan = DragPlanner.plan(.trim(clipID: camera.id, edge: .end, ripple: false, includeLinked: false), pointer: DragPointer(deltaX: -30, y: 0), context: context(f, snapping: false))
        try f.apply(plan.batch)
        XCTAssertEqual(f.clip("Camera").end, t(57))
        XCTAssertEqual(f.clip("Voice").end, t(60))
    }

    // MARK: Roll, slip, slide

    func testRollMovesTheCutWithinTheMedia() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let left = f.clip("Camera", 0)
        let right = f.clip("Camera", 1)
        let plan = DragPlanner.plan(.roll(leftClipID: left.id, rightClipID: right.id), pointer: DragPointer(deltaX: 25, y: 0), context: context(f, snapping: false))
        XCTAssertEqual(plan.delta, t(2.5))
        try f.apply(plan.batch)
        XCTAssertEqual(f.clip("Camera", 0).end, t(12.5))
        XCTAssertEqual(f.clip("Voice", 0).end, t(12.5), "linked cuts roll together")
        XCTAssertEqual(f.clip("Camera", 1).sourceStart, t(12.5))
    }

    func testSlipIsLimitedByTheMedia() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll") // 1 s of head, 4 s of tail
        let right = DragPlanner.plan(.slip(clipID: broll.id, includeLinked: true), pointer: DragPointer(deltaX: 50, y: 0), context: context(f))
        XCTAssertEqual(right.delta, t(1))
        let left = DragPlanner.plan(.slip(clipID: broll.id, includeLinked: true), pointer: DragPointer(deltaX: -80, y: 0), context: context(f))
        XCTAssertEqual(left.delta, t(-4))
        try f.apply(left.batch)
        XCTAssertEqual(f.clip("B-roll").sourceStart, t(5))
        XCTAssertEqual(f.clip("B-roll").sourceEnd, t(10))
    }

    func testSlideTrimsTheNeighbours() throws {
        let f = try AppFixture()
        try f.blade(at: [10, 20])
        let middle = f.clip("Camera", 1)
        let plan = DragPlanner.plan(.slide(clipID: middle.id), pointer: DragPointer(deltaX: 30, y: 0), context: context(f, snapping: false))
        try f.apply(plan.batch)
        XCTAssertEqual(f.clips("Camera").map(\.range), [
            TimeRange(start: t(0), end: t(13)),
            TimeRange(start: t(13), end: t(23)),
            TimeRange(start: t(23), end: t(60))
        ])
        XCTAssertEqual(f.clip("Camera", 1).sourceStart, t(10), "sliding keeps the clip's own media")
        assertValid(f.project)
    }

    // MARK: Session

    func testSessionKeepsTheLastGoodPreviewAndCommitsOnce() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let left = f.clip("Camera", 0)
        var session = DragSession(kind: .trim(clipID: left.id, edge: .end, ripple: false, includeLinked: true), context: context(f, snapping: false))
        session.update(DragPointer(deltaX: -20, y: 0), travelled: 20)
        XCTAssertEqual(session.preview?.clip(left.id)?.end, t(8))
        session.update(DragPointer(deltaX: 60, y: 0), travelled: 60)
        XCTAssertNil(session.preview, "growing into the neighbour isn't an edit, so there's nothing to preview")
        session.update(DragPointer(deltaX: -30, y: 0), travelled: 60)
        let batch = try XCTUnwrap(session.finish())
        XCTAssertEqual(f.coordinator.revision, 2, "nothing was committed while dragging")
        try f.apply(batch)
        XCTAssertEqual(f.clip("Camera", 0).end, t(7))
        XCTAssertEqual(f.coordinator.revision, 3)
    }

    func testAClickIsNotADrag() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        var session = DragSession(kind: .move(clipIDs: [broll.id], anchorClipID: broll.id), context: context(f, snapping: false))
        session.update(DragPointer(deltaX: 1, y: lane(f, "B-roll").midY), travelled: 1)
        XCTAssertNil(session.finish())
    }
}
