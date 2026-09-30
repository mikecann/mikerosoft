import AppKit
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

/// A transition on the timeline: a box as long as it plays, its label, what
/// a press on it does, dragging its edges and what that repaints.
@MainActor
final class TransitionTimelineTests: XCTestCase {
    let swoosh = MediaItem(id: "med_swoosh", path: "assets/sfx/a-quick-light-swoosh-sweeping-from-left--rgm8r7d7.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)

    /// The take cut at 30 s with a 0.8 s push on the camera's cut (24
    /// frames, 12 either side), playing the swoosh.
    func fixture(sound: Bool = true) throws -> AppFixture {
        let f = try AppFixture()
        try f.blade(at: [30])
        try f.coordinator.apply(EditBatch(label: "Push", commands: [
            .addMedia(item: swoosh),
            .addTransition(
                trackID: f.track("Camera").id,
                transition: Transition(id: "tr_p", type: .push, duration: t(0.8), fromClipID: f.clip("Camera", 0).id, toClipID: f.clip("Camera", 1).id),
                sound: sound ? TransitionSound(mediaID: swoosh.id, gainDB: -23.3, offset: t(-0.39)) : nil
            )
        ]))
        return f
    }

    func push(_ f: AppFixture) -> Transition { f.track("Camera").transitions.first { $0.id == "tr_p" }! }

    func lane(_ f: AppFixture) -> TimelineLane {
        TimelineLayout.make(project: f.project, showTranscript: true).lane(forTrack: f.track("Camera").id)!
    }

    // MARK: - Drawing

    /// The box is the transition's length at the zoom, centred on the cut,
    /// so a longer transition is a wider box.
    func testTheBoxIsAsWideAsTheTransitionAtEveryZoom() throws {
        let f = try fixture()
        let lane = lane(f)
        func box(_ pps: Double) -> CGRect? {
            TransitionGeometry.boxRect(push(f), on: f.track("Camera"), lane: lane, scale: TimelineScale(pixelsPerSecond: pps))
        }
        XCTAssertEqual(box(10), CGRect(x: 296, y: lane.y + 1, width: 8, height: lane.height - 2))
        XCTAssertEqual(box(100), CGRect(x: 2960, y: lane.y + 1, width: 80, height: lane.height - 2))
        XCTAssertEqual(box(1)?.width, TransitionGeometry.minimumWidth, "zoomed out it still shows")
        XCTAssertEqual(box(1)?.midX, 30)
        try f.apply(EditBatch(label: "Longer", commands: [.updateTransition(transitionID: "tr_p", patch: .object(["duration": .number(1.6)]))]))
        XCTAssertEqual(box(100), CGRect(x: 2920, y: lane.y + 1, width: 160, height: lane.height - 2), "twice as long, twice as wide, still on the cut")
        // A fade at a clip's head covers the start of it.
        try f.apply(EditBatch(label: "Fade", commands: [.addTransition(trackID: f.track("Camera").id, transition: Transition(id: "tr_in", type: .fadeFromBlack, duration: t(1), fromClipID: nil, toClipID: f.clip("Camera", 0).id))]))
        let fade = f.track("Camera").transitions.first { $0.id == "tr_in" }!
        XCTAssertEqual(TransitionGeometry.boxRect(fade, on: f.track("Camera"), lane: lane, scale: TimelineScale(pixelsPerSecond: 100))?.minX, 0)
        XCTAssertEqual(TransitionGeometry.boxRect(fade, on: f.track("Camera"), lane: lane, scale: TimelineScale(pixelsPerSecond: 100))?.width, 100)
    }

    /// The label holds the icon, and the name when the box has room for
    /// it. Between two clips the icon stays on the cut when the box is
    /// narrower, as long as the clips are wide enough; a fade's stays in
    /// its box.
    func testTheLabelShowsTheNameWhenItFits() throws {
        let f = try fixture()
        let lane = lane(f)
        func label(_ pps: Double, name: CGFloat = 30, _ transition: Transition? = nil) -> TransitionGeometry.Label? {
            TransitionGeometry.label(transition ?? push(f), on: f.track("Camera"), lane: lane, scale: TimelineScale(pixelsPerSecond: pps), nameWidth: name)
        }
        let wide = try XCTUnwrap(label(100))
        XCTAssertEqual(wide.rect.width, 18 + 2 + 30 + TransitionGeometry.labelPadding)
        XCTAssertEqual(wide.rect.midX, 3000, accuracy: 1)
        XCTAssertEqual(wide.icon.minX, wide.rect.minX)
        XCTAssertEqual(wide.nameX, wide.rect.minX + 19)
        XCTAssertEqual(wide.rect.minY, lane.y + 20, "under the clips' name badges")
        let narrow = try XCTUnwrap(label(10))
        XCTAssertNil(narrow.nameX, "an 8 point box has no room for a name")
        XCTAssertEqual(narrow.rect, CGRect(x: 291, y: lane.y + 20, width: 18, height: 18))
        XCTAssertNil(label(0.5), "15 point clips: nothing but the box")

        try f.apply(EditBatch(label: "Fade", commands: [.addTransition(trackID: f.track("Camera").id, transition: Transition(id: "tr_out", type: .fadeToBlack, duration: t(1), fromClipID: f.clip("Camera", 1).id, toClipID: nil))]))
        let fade = f.track("Camera").transitions.first { $0.id == "tr_out" }!
        XCTAssertNil(label(10, fade), "a 10 point fade has no room for its icon")
        XCTAssertEqual(label(30, name: 0, fade)?.rect.maxX, 1800 - 6, "inside its box, at the end of the take")
    }

    /// A press on the box picks the transition, on its edges drags its
    /// length, and near the cut above and below the label still trims.
    func testPressesPickTheEdgeTheBodyOrTheCut() throws {
        let f = try fixture()
        let camera = f.track("Camera")
        let layout = TimelineLayout.make(project: f.project, showTranscript: true)
        let lane = layout.lane(forTrack: camera.id)!
        let tester = TimelineHitTester(project: f.project, layout: layout, scale: TimelineScale(pixelsPerSecond: 100))
        let top = lane.y + 4
        // The box runs 2960 to 3040, the cut is at 3000.
        XCTAssertEqual(tester.hit(CGPoint(x: 2962, y: top)), .transitionEdge(transitionID: "tr_p", trackID: camera.id, edge: .start))
        XCTAssertEqual(tester.hit(CGPoint(x: 3043, y: lane.midY)), .transitionEdge(transitionID: "tr_p", trackID: camera.id, edge: .end), "just outside still grabs it")
        XCTAssertEqual(tester.hit(CGPoint(x: 3020, y: top)), .transition(transitionID: "tr_p", trackID: camera.id))
        XCTAssertEqual(tester.hit(CGPoint(x: 3002, y: top)), .clip(clipID: f.clip("Camera", 1).id, trackID: camera.id, part: .head), "the cut above the label trims")
        XCTAssertEqual(tester.hit(CGPoint(x: 3002, y: lane.midY)), .transition(transitionID: "tr_p", trackID: camera.id), "the label picks it")
        XCTAssertEqual(tester.hit(CGPoint(x: 3002, y: lane.midY), transitions: false), .clip(clipID: f.clip("Camera", 1).id, trackID: camera.id, part: .head), "what's under it, for drops")

        // Zoomed out the box is too narrow to grab its edges apart.
        let far = TimelineHitTester(project: f.project, layout: layout, scale: TimelineScale(pixelsPerSecond: 10))
        XCTAssertEqual(far.hit(CGPoint(x: 296, y: lane.midY)), .transition(transitionID: "tr_p", trackID: camera.id), "the icon on the cut")
        XCTAssertEqual(far.hit(CGPoint(x: 297, y: top)), .clip(clipID: f.clip("Camera", 0).id, trackID: camera.id, part: .tail))

        // A locked track shows its transitions but they don't drag.
        try f.apply(EditBatch(label: "Lock", commands: [.updateTrack(trackID: camera.id, patch: .object(["locked": .bool(true)]))]))
        let locked = TimelineHitTester(project: f.project, layout: layout, scale: TimelineScale(pixelsPerSecond: 100))
        XCTAssertEqual(locked.hit(CGPoint(x: 2962, y: top)), .transition(transitionID: "tr_p", trackID: camera.id))
    }

    // MARK: - The length drag

    func testDraggingAnEdgeMovesBothSidesAWholeFrameAtATime() throws {
        let f = try fixture()
        let track = f.track("Camera")
        let transition = push(f)
        let rate = FrameRate.fps30
        XCTAssertEqual(TransitionLength.draggableEdges(transition), [.start, .end])
        XCTAssertEqual(TransitionLength.length(transition, on: track, edge: .end, at: t(31), rate: rate), t(2))
        XCTAssertEqual(TransitionLength.length(transition, on: track, edge: .start, at: t(29), rate: rate), t(2), "either edge")
        XCTAssertEqual(TransitionLength.length(transition, on: track, edge: .end, at: t(30.51), rate: rate), t(1), "15.3 frames each side is 15")
        // At least a tenth of a second (two frames each side), and at most
        // half of each 30 s clip.
        XCTAssertEqual(TransitionLength.limits(transition, on: track, rate: rate), Time.frames(4, at: rate)...t(30))
        XCTAssertEqual(TransitionLength.length(transition, on: track, edge: .end, at: t(30), rate: rate), Time.frames(4, at: rate))
        XCTAssertEqual(TransitionLength.length(transition, on: track, edge: .end, at: t(80), rate: rate), t(30))
    }

    /// A fade at a clip's head or tail keeps its clip-edge side, and grows
    /// to half its clip.
    func testAFadeMovesItsInsideEdge() throws {
        let f = try AppFixture()
        try f.blade(at: [30])
        try f.apply(EditBatch(label: "Fades", commands: [
            .addTransition(trackID: f.track("Camera").id, transition: Transition(id: "tr_in", type: .fadeFromBlack, duration: t(1), fromClipID: nil, toClipID: f.clip("Camera", 1).id)),
            .addTransition(trackID: f.track("Camera").id, transition: Transition(id: "tr_out", type: .fadeToBlack, duration: t(1), fromClipID: f.clip("Camera", 0).id, toClipID: nil))
        ]))
        let track = f.track("Camera")
        let fadeIn = track.transitions.first { $0.id == "tr_in" }!
        let fadeOut = track.transitions.first { $0.id == "tr_out" }!
        XCTAssertEqual(TransitionLength.draggableEdges(fadeIn), [.end])
        XCTAssertEqual(TransitionLength.draggableEdges(fadeOut), [.start])
        XCTAssertEqual(TransitionLength.length(fadeIn, on: track, edge: .end, at: t(31.5), rate: .fps30), t(1.5))
        XCTAssertEqual(TransitionLength.length(fadeIn, on: track, edge: .end, at: t(59), rate: .fps30), t(15), "half its clip")
        XCTAssertNil(TransitionLength.length(fadeIn, on: track, edge: .start, at: t(29), rate: .fps30), "its clip-edge side stays")
        XCTAssertEqual(TransitionLength.length(fadeOut, on: track, edge: .start, at: t(29), rate: .fps30), t(1))
    }

    /// A transition already longer than half its short clip (the
    /// inspector's slider allows it) can keep its length.
    func testALongTransitionKeepsItsLengthAsItsLimit() throws {
        let f = try AppFixture()
        try f.blade(at: [29, 30])
        try f.coordinator.apply(EditBatch(label: "Push", commands: [
            .addTransition(trackID: f.track("Camera").id, transition: Transition(id: "tr_p", type: .push, duration: t(1.5), fromClipID: f.clip("Camera", 1).id, toClipID: f.clip("Camera", 2).id))
        ]))
        XCTAssertEqual(TransitionLength.limits(push(f), on: f.track("Camera"), rate: .fps30)?.upperBound, t(1.5), "the 1 s clip allows 1 s; it keeps its 1.5")
    }

    func context(_ f: AppFixture, playhead: Time = t(45)) -> DragContext {
        DragContext(project: f.project, scale: TimelineScale(pixelsPerSecond: 100), layout: TimelineLayout.make(project: f.project, showTranscript: true), snapping: true, playhead: playhead)
    }

    /// The drag previews the new length and commits it as one
    /// `updateTransition`, one undo step.
    func testALengthDragCommitsOneUpdate() throws {
        let f = try fixture()
        var session = DragSession(kind: .transitionLength(transitionID: "tr_p", edge: .end), context: context(f))
        for step in 1...6 {
            session.update(DragPointer(deltaX: CGFloat(step * 10), y: 0), travelled: CGFloat(step * 10))
        }
        // 60 points at 100 a second: the end from 30.4 to 31.0 s.
        XCTAssertEqual(session.plan.length, t(2))
        XCTAssertEqual(session.plan.delta, t(1.2))
        XCTAssertEqual(session.preview.map { push(AppFixtureView(project: $0)) }?.duration, t(2), "the preview is the longer box")
        let batch = try XCTUnwrap(session.finish())
        XCTAssertEqual(batch.commands, [.updateTransition(transitionID: "tr_p", patch: .object(["duration": .number(2)]))])
        let revision = f.coordinator.revision
        try f.apply(batch)
        XCTAssertEqual(push(f).duration, t(2))
        XCTAssertEqual(f.coordinator.revision, revision + 1)
        XCTAssertEqual(f.coordinator.undoLabel, "Transition length")

        // Past the cut it stops at its shortest.
        var shrink = DragSession(kind: .transitionLength(transitionID: "tr_p", edge: .start), context: context(f))
        shrink.update(DragPointer(deltaX: 500, y: 0), travelled: 500)
        XCTAssertEqual(shrink.plan.length, Time.frames(4, at: .fps30))
    }

    func testTheEdgeSnapsToThePlayhead() throws {
        let f = try fixture()
        // The end dragged to 30.97 s, 3 points from the playhead at 31.
        let plan = DragPlanner.plan(.transitionLength(transitionID: "tr_p", edge: .end), pointer: DragPointer(deltaX: 57, y: 0), context: context(f, playhead: t(31)))
        XCTAssertEqual(plan.snappedTo, t(31))
        XCTAssertEqual(plan.length, t(2))
        let loose = DragPlanner.plan(.transitionLength(transitionID: "tr_p", edge: .end), pointer: DragPointer(deltaX: 57, y: 0, invertSnap: true), context: context(f, playhead: t(31)))
        XCTAssertNil(loose.snappedTo)
        XCTAssertEqual(loose.length, Time.frames(58, at: .fps30), "17 frames further: 29 either side")
    }

    func testAnEdgeStartsALengthDragWithTheTrimCursor() throws {
        let f = try fixture()
        let camera = f.track("Camera").id
        let edge = TimelineHit.transitionEdge(transitionID: "tr_p", trackID: camera, edge: .end)
        func press(_ tool: TimelineTool) -> DragKind? {
            DragKind.forPress(on: edge, tool: tool, project: f.project, selection: [], rippleByDefault: false, command: false, option: false)
        }
        XCTAssertEqual(press(.select), .transitionLength(transitionID: "tr_p", edge: .end))
        XCTAssertEqual(press(.roll), .transitionLength(transitionID: "tr_p", edge: .end))
        XCTAssertNil(press(.blade))
        XCTAssertEqual(CursorKind.timeline(hit: edge, tool: .select, overKeyframe: false, press: press(.select), project: f.project), .trim)
        XCTAssertEqual(CursorKind.dragging(.transitionLength(transitionID: "tr_p", edge: .start)), .trim)
        XCTAssertEqual(DragKind.transitionLength(transitionID: "tr_p", edge: .end).movingClipIDs(in: f.project), [f.clip("Camera", 0).id, f.clip("Camera", 1).id], "its cut isn't a snap target")
    }

    func testItsTipAndDragLabelSayWhatItIsAndDoes() throws {
        let f = try fixture()
        let body = try XCTUnwrap(TransitionTips.body("tr_p", in: f.project))
        XCTAssertEqual(body, "Push · 0.80 s · with A quick light swoosh sweeping from left\nDrag either edge to make it longer or shorter; both sides move together")
        XCTAssertTrue(try XCTUnwrap(TransitionTips.edge("tr_p", in: f.project)).hasSuffix("both sides move together, up to half of each clip"))
        XCTAssertEqual(TransitionTips.dragLabel("tr_p", length: t(1.2), in: f.project), "Push · 1.20 s")
        let silent = try fixture(sound: false)
        XCTAssertEqual(TransitionTips.body("tr_p", in: silent.project)?.components(separatedBy: "\n").first, "Push · 0.80 s")
    }

    // MARK: - Redrawing

    /// Picking a transition outlines its box and dashes its sound's edge,
    /// so those two repaint and nothing else.
    func testPickingATransitionRepaintsItsBoxAndItsSound() throws {
        let f = try fixture()
        let layout = TimelineLayout.make(project: f.project, showTranscript: true)
        func state(_ id: String?) -> TimelineDrawState {
            TimelineDrawState(
                project: f.project, revision: 1, scale: TimelineScale(pixelsPerSecond: 100), verticalOffset: 0, trackHeights: [:],
                showTranscript: true, selection: [], selectedTransitionID: id, selectedKeyframe: nil, inPoint: nil, outPoint: nil,
                renamingTrackID: nil, artworkRevision: 0
            )
        }
        let damage = TimelineDamage.between(state(nil), state("tr_p"), layout: layout, layoutChanged: false)
        XCTAssertFalse(damage.allLanes)
        XCTAssertEqual(damage.laneRects.count, 2)
        let camera = layout.lane(forTrack: f.track("Camera").id)!
        let sfx = layout.lane(forTrack: f.track("SFX").id)!
        XCTAssertTrue(damage.laneRects.contains { $0.midY > camera.y && $0.midY < camera.maxY && abs($0.midX - 3000) < 2 }, "its box")
        XCTAssertTrue(damage.laneRects.contains { $0.midY > sfx.y && $0.midY < sfx.maxY && abs($0.minX + TimelineDamage.keyframeReach - 2961) < 1 }, "its swoosh, 29.61 to 30.61 s")
    }

    /// A longer transition repaints its old box and its new one, and the
    /// sound it moved (none, for a centred one), nothing else.
    func testALongerTransitionRepaintsItsOldAndNewBoxes() throws {
        let f = try fixture()
        let before = f.project
        try f.apply(EditBatch(label: "Longer", commands: [.updateTransition(transitionID: "tr_p", patch: .object(["duration": .number(2)]))]))
        let rects = try XCTUnwrap(TimelineDamage.previewRects(
            from: PreviewState(project: before, previewed: []), to: PreviewState(project: f.project, previewed: []),
            layout: TimelineLayout.make(project: before, showTranscript: true), scale: TimelineScale(pixelsPerSecond: 100), offsetY: 0, width: 5_000
        ))
        let lane = lane(f)
        XCTAssertFalse(rects.isEmpty)
        XCTAssertTrue(rects.allSatisfy { $0.minY >= lane.y - 2 && $0.maxY <= lane.maxY + 2 }, "the camera lane only: the swoosh stays on the cut")
        let covered = rects.reduce(rects[0]) { $0.union($1) }
        XCTAssertLessThanOrEqual(covered.minX, 2960 - 2, "the old box")
        XCTAssertLessThanOrEqual(covered.minX, 2900 - 2, "the new box")
        XCTAssertGreaterThanOrEqual(covered.maxX, 3100 + 2)
        XCTAssertLessThan(covered.width, 220)
    }

    /// Rolling the cut moves the box with it, and the sound on SFX.
    func testRollingTheCutRepaintsTheTransitionAndItsSound() throws {
        let f = try fixture()
        let before = f.project
        try f.apply(EditBatch(label: "Roll", commands: [.roll(leftClipID: f.clip("Camera", 0).id, rightClipID: f.clip("Camera", 1).id, delta: t(1))]))
        let layout = TimelineLayout.make(project: before, showTranscript: true)
        let rects = try XCTUnwrap(TimelineDamage.previewRects(
            from: PreviewState(project: before, previewed: []), to: PreviewState(project: f.project, previewed: []),
            layout: layout, scale: TimelineScale(pixelsPerSecond: 100), offsetY: 0, width: 5_000
        ))
        let sfx = layout.lane(forTrack: f.track("SFX").id)!
        XCTAssertTrue(rects.contains { $0.midY > sfx.y && $0.midY < sfx.maxY && $0.minX <= 3061 + TimelineDamage.keyframeReach }, "the swoosh, from 29.61 to 30.61 s")
        XCTAssertTrue(rects.contains { abs($0.midX - 3100) < 2 && $0.minY < lane(f).midY && $0.maxY > lane(f).midY }, "the push's new box, on the new cut")
    }
}

/// Reads a transition from a project without a coordinator.
private struct AppFixtureView {
    let project: Project
}

private extension TransitionTimelineTests {
    func push(_ view: AppFixtureView) -> Transition {
        view.project.track(named: "Camera")!.transitions.first { $0.id == "tr_p" }!
    }
}

/// Dragging a transition's edge in a real timeline: the box grows as the
/// pointer moves, repainting only around it, and mouse up is one edit.
@MainActor
final class TransitionDragWindowTests: XCTestCase {
    private var model: EditorModel!
    private var window: NSWindow!

    /// The take cut at 30 s with a 0.8 s push playing a swoosh, at 100
    /// points a second scrolled to 25 s: the cut is at 500 points.
    private func showTimeline() throws {
        guard NSScreen.screens.first != nil else { throw XCTSkip("no screen") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-transition-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Drag.tandem"), name: "Drag", owner: .app)
        let model = EditorModel(session: session)
        self.model = model
        addTeardownBlock { @MainActor in
            self.window?.orderOut(nil)
            model.tearDown()
            _ = model.session.close()
            try? FileManager.default.removeItem(at: folder)
        }
        let fixture = try AppFixture()
        let swoosh = MediaItem(id: "med_swoosh", path: "assets/sfx/swoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)
        model.apply(EditBatch(label: "Media", commands: (fixture.project.media + [swoosh]).map { .addMedia(item: $0) }))
        model.apply(EditBatch(label: "Take", commands: [.placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(60))]))
        let camera = model.project.track(named: "Camera")!
        model.apply(EditBatch(label: "Cut", commands: [.blade(at: t(30), clipIDs: [camera.clips[0].id])]))
        let pieces = model.project.track(named: "Camera")!.clips
        model.apply(EditBatch(label: "Push", commands: [.addTransition(
            trackID: camera.id,
            transition: Transition(id: "tr_p", type: .push, duration: t(0.8), fromClipID: pieces[0].id, toClipID: pieces[1].id),
            sound: TransitionSound(mediaID: "med_swoosh", gainDB: -23.3, offset: t(-0.39))
        )]))
        model.timeline.fitPending = false
        model.timeline.scale = TimelineScale(pixelsPerSecond: 100, scrollSeconds: 25)
        settle()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = TimelineContainerView(model: model)
        window.orderBack(nil)
        settle()
        DrawTiming.reset()
    }

    private func settle() {
        var quiet = 0
        for _ in 0..<40 where quiet < 3 {
            let before = ["lanes", "ruler", "headers"].map { DrawTiming.samples($0).count }.reduce(0, +)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            CATransaction.flush()
            quiet = ["lanes", "ruler", "headers"].map { DrawTiming.samples($0).count }.reduce(0, +) == before ? quiet + 1 : 0
        }
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }

    func testDraggingTheEdgeLengthensItInOneEdit() throws {
        try showTimeline()
        let timeline = try XCTUnwrap(window.contentView as? TimelineContainerView)
        let lane = try XCTUnwrap(timeline.layoutCache.lane(forTrack: model.project.track(named: "Camera")!.id))
        let undoBefore = model.undoLabel
        // The push runs 29.6 to 30.4 s: 460 to 540 points. Its right edge,
        // above the label.
        let press = CGPoint(x: 539, y: lane.y + 5 - timeline.contentOrigin.y)
        mouse(.leftMouseDown, at: press, in: timeline.lanes)
        settle()
        XCTAssertEqual(model.selectedTransitionID, "tr_p", "the press picks it")
        DrawTiming.reset()
        for step in 1...6 {
            mouse(.leftMouseDragged, at: CGPoint(x: press.x + CGFloat(step * 10), y: press.y), in: timeline.lanes)
            settle()
        }
        XCTAssertEqual(DrawTiming.samples("headers").count, 0)
        XCTAssertEqual(DrawTiming.samples("ruler").count, 0)
        XCTAssertGreaterThan(DrawTiming.samples("lanes").count, 0, "the box grows as it's dragged")
        XCTAssertLessThan(DrawTiming.samples("lanes area").reduce(0, +) / Double(DrawTiming.samples("lanes").count), 0.1, "each paint a box's worth")
        XCTAssertEqual(model.project.track(named: "Camera")?.transitions.first?.duration, t(0.8), "nothing's committed while dragging")
        mouse(.leftMouseUp, at: CGPoint(x: press.x + 60, y: press.y), in: timeline.lanes)
        settle()
        let transition = try XCTUnwrap(model.project.track(named: "Camera")?.transitions.first)
        XCTAssertEqual(transition.duration, t(2), "60 points is 0.6 s more each side")
        XCTAssertEqual(model.undoLabel, "Transition length")
        XCTAssertNotEqual(model.undoLabel, undoBefore)
        XCTAssertEqual(transition.soundClipID.flatMap { model.project.clip($0) }?.start, t(29.61), "the swoosh stays on the cut")
        model.undo()
        XCTAssertEqual(model.project.track(named: "Camera")?.transitions.first?.duration, t(0.8), "one undo puts it back")
    }
}
