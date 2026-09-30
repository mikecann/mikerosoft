import AppKit
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

/// Which views, and which parts of the lanes, a change redraws.
@MainActor
final class TimelineDamageTests: XCTestCase {
    private func state(_ f: AppFixture, selection: Set<String> = [], scroll: Double = 0, pps: Double = 10) -> TimelineDrawState {
        TimelineDrawState(
            project: f.project, revision: 1, scale: TimelineScale(pixelsPerSecond: pps, scrollSeconds: scroll),
            verticalOffset: 0, trackHeights: [:], showTranscript: true, selection: selection,
            selectedTransitionID: nil, selectedKeyframe: nil, inPoint: nil, outPoint: nil,
            renamingTrackID: nil, artworkRevision: 0
        )
    }

    private func layout(_ f: AppFixture) -> TimelineLayout {
        TimelineLayout.make(project: f.project, showTranscript: true)
    }

    /// A scroll moves the lanes' tiles rather than repainting them.
    func testScrollingMovesTheLanesAndRedrawsTheRulerButNotTheHeaders() throws {
        let f = try AppFixture()
        let damage = TimelineDamage.between(state(f), state(f, scroll: 4), layout: layout(f), layoutChanged: false)
        XCTAssertEqual(damage, TimelineDamage(ruler: true, headers: false, lanesMoved: true))
    }

    func testScrollingDownMovesTheLanesAndRedrawsTheHeadersButNotTheRuler() throws {
        let f = try AppFixture()
        var down = state(f)
        down.verticalOffset = 30
        XCTAssertEqual(TimelineDamage.between(state(f), down, layout: layout(f), layoutChanged: false), TimelineDamage(ruler: false, headers: true, lanesMoved: true))
    }

    func testZoomingRepaintsTheLanesAndRuler() throws {
        let f = try AppFixture()
        XCTAssertEqual(
            TimelineDamage.between(state(f), state(f, pps: 12), layout: layout(f), layoutChanged: false),
            TimelineDamage(ruler: true, headers: false, allLanes: true, lanesReshaped: true)
        )
    }

    /// An edit redraws the ruler (markers) and headers (names), and leaves
    /// the lanes to repaint the clips it changed.
    func testAnEditLeavesTheLanesToFindWhatChanged() throws {
        let f = try AppFixture()
        var edited = state(f)
        edited.revision = 2
        XCTAssertEqual(TimelineDamage.between(state(f), edited, layout: layout(f), layoutChanged: false), TimelineDamage(ruler: true, headers: true, lanesEdited: true))
    }

    /// Lanes that change height (a track's edge dragged) repaint on the
    /// canvas, like a zoom.
    func testNewLanesRepaintEverything() throws {
        let f = try AppFixture()
        XCTAssertEqual(TimelineDamage.between(state(f), state(f), layout: layout(f), layoutChanged: true), TimelineDamage(headers: true, allLanes: true, lanesReshaped: true))
    }

    /// Clicking the screen clip selects it; the camera picture and sound
    /// linked to it get a dashed edge. Those three redraw, nothing else.
    func testSelectingAClipRedrawsItAndTheClipsLinkedToIt() throws {
        let f = try AppFixture()
        let layout = layout(f)
        let screen = f.clip("Screen")
        let damage = TimelineDamage.between(state(f), state(f, selection: [screen.id]), layout: layout, layoutChanged: false)
        XCTAssertFalse(damage.ruler || damage.headers || damage.allLanes)
        let linked = Set(f.project.linkedClipIDs(of: screen.id))
        XCTAssertEqual(linked.count, 3, "screen, camera picture and camera sound")
        XCTAssertEqual(damage.laneRects.count, 3)
        for id in linked {
            let lane = layout.lane(forTrack: f.project.track(containingClip: id)!.id)!
            XCTAssertTrue(damage.laneRects.contains { $0.minY < lane.midY && $0.maxY > lane.midY }, "the lane of \(id)")
        }
        // The take runs 0 to 60 s: 0 to 600 points, and a keyframe's reach
        // either side.
        for rect in damage.laneRects {
            XCTAssertEqual(rect.minX, -TimelineDamage.keyframeReach, accuracy: 0.01)
            XCTAssertEqual(rect.maxX, 600 + TimelineDamage.keyframeReach, accuracy: 0.01)
        }
    }

    func testMovingTheSelectionRedrawsWhatItLeftAndWhereItWent() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let from = state(f, selection: [f.clip("Screen").id])
        let damage = TimelineDamage.between(from, state(f, selection: [broll.id]), layout: layout(f), layoutChanged: false)
        // The take's three clips, and the B-roll shot and its sound.
        XCTAssertEqual(damage.laneRects.count, 3 + f.project.linkedClipIDs(of: broll.id).count)
        XCTAssertTrue(damage.laneRects.contains { abs($0.minX - (200 - TimelineDamage.keyframeReach)) < 0.01 }, "the shot at 20 s")
    }

    func testNothingRedrawsWhenTheSelectionStaysTheSame() throws {
        let f = try AppFixture()
        let screen = f.clip("Screen").id
        XCTAssertTrue(TimelineDamage.between(state(f, selection: [screen]), state(f, selection: [screen]), layout: layout(f), layoutChanged: false).isEmpty)
    }

    func testChoosingAKeyframeRedrawsItsClip() throws {
        let f = try AppFixture()
        let music = f.clip("Music")
        var chosen = state(f, selection: [music.id])
        chosen.selectedKeyframe = KeyframeRef(clipID: music.id, time: t(2), parameters: ["audio.gainDB"])
        let damage = TimelineDamage.between(state(f, selection: [music.id]), chosen, layout: layout(f), layoutChanged: false)
        XCTAssertEqual(damage.laneRects.count, 1)
        let lane = layout(f).lane(forTrack: f.track("Music").id)!
        XCTAssertEqual(damage.laneRects[0].midY, lane.midY, accuracy: 0.01)
    }

    /// Agent changes arriving, or marked reviewed, redraw the ruler's band
    /// and place the marks over the lanes. The lanes don't repaint for them.
    func testAReviewChangeRedrawsTheRulerAndMarksNotTheLanes() throws {
        let f = try AppFixture()
        let before = f.project
        let revision = try f.coordinator.apply(EditBatch(label: "Whoosh", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(2))])).revision
        var log = ReviewLog()
        log.record(label: "Whoosh", author: "claude", revision: revision, before: before, after: f.project)
        var waiting = state(f)
        waiting.review = TimelineReview.make(log: log, project: f.project)
        XCTAssertFalse(waiting.review.isEmpty)
        XCTAssertEqual(TimelineDamage.between(state(f), waiting, layout: layout(f), layoutChanged: false), TimelineDamage(ruler: true, review: true))
        XCTAssertEqual(TimelineDamage.between(waiting, state(f), layout: layout(f), layoutChanged: false), TimelineDamage(ruler: true, review: true), "marked reviewed")
    }

    func testSelectingATransitionRedrawsItsBand() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let camera = f.track("Camera")
        let transition = Transition(id: "tr_a", type: .dissolve, duration: t(1), fromClipID: camera.clips[0].id, toClipID: camera.clips[1].id)
        try f.coordinator.apply(EditBatch(label: "Dissolve", commands: [.addTransition(trackID: camera.id, transition: transition)]))
        var selected = state(f)
        selected.selectedTransitionID = "tr_a"
        let damage = TimelineDamage.between(state(f), selected, layout: layout(f), layoutChanged: false)
        XCTAssertEqual(damage.laneRects.count, 1)
        // Centred on the cut at 10 s (100 points), half a second each side.
        XCTAssertEqual(damage.laneRects[0].midX, 100, accuracy: 1)
        XCTAssertLessThan(damage.laneRects[0].width, 40)
    }
}

final class TranscriptHighlightTests: XCTestCase {
    private let phrases = [
        TranscriptPhrase(text: "we have evals", start: t(1), end: t(2)),
        TranscriptPhrase(text: "and they run", start: t(2.2), end: t(3)),
        TranscriptPhrase(text: "every night", start: t(6), end: t(7))
    ]

    /// Runs are highlighted from their first phrase's start to their last
    /// one's end, and nothing is in the pauses between.
    func testFindsTheRunUnderThePlayhead() {
        let groups = [0..<2, 2..<3]
        XCTAssertNil(TranscriptPhrase.group(at: t(0.5), in: groups, phrases: phrases), "before the first word")
        XCTAssertEqual(TranscriptPhrase.group(at: t(1), in: groups, phrases: phrases), 0)
        XCTAssertEqual(TranscriptPhrase.group(at: t(2.1), in: groups, phrases: phrases), 0, "between phrases of one run")
        XCTAssertNil(TranscriptPhrase.group(at: t(4), in: groups, phrases: phrases), "the pause between runs")
        XCTAssertEqual(TranscriptPhrase.group(at: t(6.5), in: groups, phrases: phrases), 1)
        XCTAssertNil(TranscriptPhrase.group(at: t(7), in: groups, phrases: phrases), "after the last word")
        XCTAssertNil(TranscriptPhrase.group(at: t(1), in: [], phrases: []))
    }
}

/// A real timeline in a window: what redraws, measured with `DrawTiming`.
@MainActor
final class TimelineRedrawTests: XCTestCase {
    private var model: EditorModel!
    private var window: NSWindow!

    /// The fixture's take, B-roll and music in a project session, shown by
    /// a timeline in a window at 10 points a second. (Made in the test, not
    /// an async setUp: from there the run loop can't hand observation over.)
    private func showTimeline() throws {
        guard NSScreen.screens.first != nil else { throw XCTSkip("no screen") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-redraw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Redraw.tandem"), name: "Redraw", owner: .app)
        let model = EditorModel(session: session)
        self.model = model
        addTeardownBlock { @MainActor in
            self.window?.orderOut(nil)
            model.tearDown()
            _ = model.session.close()
            try? FileManager.default.removeItem(at: folder)
        }
        let fixture = try AppFixture()
        model.apply(EditBatch(label: "Media", commands: fixture.project.media.map { .addMedia(item: $0) }))
        model.apply(EditBatch(label: "Build", commands: [
            .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(60)),
            .placeMedia(mediaIDs: ["med_broll"], at: t(20), sourceStart: t(1), duration: t(5)),
            .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(60))
        ]))
        model.timeline.fitPending = false
        model.timeline.scale = TimelineScale(pixelsPerSecond: 10, scrollSeconds: 0)
        settle()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = TimelineContainerView(model: model)
        window.orderBack(nil)
        settle()
        XCTAssertEqual(model.project.track(named: "B-roll")?.clips.count, 1)
        DrawTiming.reset()
    }

    /// Lets observation hand changes over and the window draw them, until
    /// nothing more draws.
    private func settle() {
        var quiet = 0
        for _ in 0..<40 where quiet < 3 {
            let before = ["lanes", "ruler", "headers"].map(draws).reduce(0, +)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            CATransaction.flush()
            quiet = ["lanes", "ruler", "headers"].map(draws).reduce(0, +) == before ? quiet + 1 : 0
        }
    }

    private func draws(_ name: String) -> Int { DrawTiming.samples(name).count }

    func testThePlayheadMovingRedrawsNothing() throws {
        try showTimeline()
        for second in stride(from: 1.0, through: 3, by: 0.25) {
            model.playback.seek(to: t(second))
            settle()
        }
        // Without a transcript there's no phrase to highlight; the playhead
        // is a layer that moves. It used to redraw the lanes every frame.
        XCTAssertEqual(draws("lanes"), 0)
        XCTAssertEqual(draws("ruler"), 0)
        XCTAssertEqual(draws("headers"), 0)
    }

    func testClickingAClipRedrawsItAndItsLinksNotTheLanes() throws {
        try showTimeline()
        model.selection = [model.project.track(named: "B-roll")!.clips[0].id]
        settle()
        XCTAssertEqual(draws("ruler"), 0)
        XCTAssertEqual(draws("headers"), 0)
        XCTAssertGreaterThan(draws("lanes"), 0)
        let area = DrawTiming.samples("lanes area").reduce(0, +)
        XCTAssertLessThan(area, 0.25, "the 5 s shot and its sound, not all of the lanes")
    }

    /// Scrolling moves the lanes' tiles: the strip along the left edge
    /// (where the transcript lane's note stays in view) paints again, and
    /// so does what scrolls into view. It used to repaint all the lanes and
    /// the headers.
    func testScrollingPaintsOnlyTheLeftEdgeAndWhatComesIntoView() throws {
        try showTimeline()
        model.timeline.scale.scrollSeconds = 12
        settle()
        XCTAssertEqual(draws("headers"), 0)
        XCTAssertEqual(draws("ruler"), 1)
        XCTAssertGreaterThan(draws("lanes"), 0, "the strip")
        XCTAssertLessThan(paintedArea(), 0.5)
    }

    /// Moving a clip repaints where it was and where it went.
    func testAnEditRepaintsTheClipsItChanged() throws {
        try showTimeline()
        let shot = model.project.track(named: "B-roll")!.clips[0]
        model.apply(EditBatch(label: "Move", commands: [.moveClips(clipIDs: [shot.id], delta: t(20), includeLinked: false)]))
        settle()
        XCTAssertGreaterThan(draws("lanes"), 0)
        XCTAssertLessThan(paintedArea(), 0.2, "two 5 s shots, not the lanes")
    }

    /// Dragging a clip previews it on the tiles, repainting only what each
    /// move changes; the snap line and label are layers of their own.
    func testDraggingAClipRepaintsOnlyWhatMoves() throws {
        try showTimeline()
        let lanes = try XCTUnwrap(timeline?.lanes)
        let lane = try XCTUnwrap(timeline?.layoutCache.lane(forTrack: model.project.track(named: "B-roll")!.id))
        // The shot runs 20 to 25 s: 200 to 250 points.
        let press = CGPoint(x: 225, y: lane.midY)
        mouse(.leftMouseDown, at: press, in: lanes)
        settle()
        DrawTiming.reset()
        for step in 1...10 {
            mouse(.leftMouseDragged, at: CGPoint(x: press.x + CGFloat(step) * 8, y: press.y), in: lanes)
            settle()
        }
        XCTAssertEqual(draws("headers"), 0)
        XCTAssertEqual(draws("ruler"), 0)
        XCTAssertGreaterThan(draws("lanes"), 0)
        XCTAssertLessThan(paintedArea() / Double(draws("lanes")), 0.1, "each paint a few clips' worth")
        mouse(.leftMouseUp, at: CGPoint(x: press.x + 80, y: press.y), in: lanes)
        settle()
        XCTAssertEqual(model.project.track(named: "B-roll")?.clips[0].start, t(28))
    }

    /// Zooming paints one full-size canvas a step, not every tile; the
    /// tiles come back when the zoom rests.
    func testZoomingPaintsTheCanvasThenTheTiles() throws {
        try showTimeline()
        model.timeline.scale.pixelsPerSecond = 12
        settle()
        XCTAssertEqual(draws("lanes"), 1, "the canvas")
        XCTAssertEqual(paintedArea(), 1, accuracy: 0.01)
        DrawTiming.reset()
        RunLoop.main.run(until: Date().addingTimeInterval(TimelineLanesView.reshapeRest + 0.05))
        settle()
        XCTAssertGreaterThanOrEqual(draws("lanes"), 3, "the tiles in view")
    }

    // MARK: - Agent changes waiting for review

    /// An agent's edit through the API, and the review log catching up.
    private func agentPlacesAShot(at seconds: Double) throws {
        try model.session.coordinator.apply(EditBatch(label: "Whoosh", author: "claude", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(seconds), duration: t(2))]))
        for _ in 0..<50 {
            let log = model.session.review.log
            settle()
            if model.reviewLog == log && !log.isEmpty { return }
        }
    }

    /// The edit repaints the shot it added, like any edit; the review adds
    /// the ruler's band and one placing of the marks, not lane paints.
    func testAnAgentsEditRedrawsTheRulerAndPlacesItsMarksOnce() throws {
        try showTimeline()
        try agentPlacesAShot(at: 40)
        XCTAssertEqual(model.review.editCount, 1)
        XCTAssertGreaterThan(draws("ruler"), 0)
        XCTAssertLessThan(paintedArea(), 0.1, "the 2 s shot, not the lanes")
        XCTAssertEqual(DrawTiming.samples("review marks").count, 1)
        let marks = try XCTUnwrap(timeline?.reviewOverlay.shownFrames)
        XCTAssertEqual(marks.boxes.count, 1)
        // The shot runs 40 to 42 s: 400 to 420 points, the mark just inside.
        XCTAssertEqual(marks.boxes[0].minX, 403, accuracy: 1)
        XCTAssertEqual(marks.boxes[0].maxX, 417, accuracy: 1)
    }

    /// Scrolling moves the marks with the lanes without placing them again.
    func testScrollingMovesTheMarksWithoutPlacingThemAgain() throws {
        try showTimeline()
        try agentPlacesAShot(at: 40)
        let before = try XCTUnwrap(timeline?.reviewOverlay.shownFrames.boxes.first)
        DrawTiming.reset()
        model.timeline.scale.scrollSeconds = 12
        settle()
        XCTAssertEqual(DrawTiming.samples("review marks").count, 0)
        XCTAssertEqual(draws("headers"), 0)
        XCTAssertEqual(draws("ruler"), 1)
        XCTAssertLessThan(paintedArea(), 0.5)
        let after = try XCTUnwrap(timeline?.reviewOverlay.shownFrames.boxes.first)
        XCTAssertEqual(after.minX, before.minX - 120, accuracy: 0.5)
    }

    /// Mark reviewed redraws the ruler and hides the marks; the lanes and
    /// headers don't draw.
    func testMarkingReviewedRedrawsOnlyTheRuler() throws {
        try showTimeline()
        try agentPlacesAShot(at: 40)
        DrawTiming.reset()
        XCTAssertTrue(model.markAgentChangesReviewed())
        settle()
        XCTAssertEqual(draws("ruler"), 1)
        XCTAssertEqual(draws("lanes"), 0)
        XCTAssertEqual(draws("headers"), 0)
        XCTAssertEqual(timeline?.reviewOverlay.isHidden, true)
    }

    /// Stepping to a change that's in view moves the playhead, a layer,
    /// and draws nothing.
    func testSteppingToAChangeInViewMovesOnlyThePlayhead() throws {
        try showTimeline()
        try agentPlacesAShot(at: 40)
        DrawTiming.reset()
        XCTAssertTrue(model.goToAgentChange(forward: true))
        settle()
        XCTAssertEqual(model.playhead, t(40))
        XCTAssertEqual(draws("lanes"), 0)
        XCTAssertEqual(draws("ruler"), 0)
        XCTAssertEqual(draws("headers"), 0)
        XCTAssertEqual(DrawTiming.samples("review marks").count, 0)
    }

    /// Resting on the ruler's band says who changed what there, as a tip
    /// like the rest of the app's; moving off it puts the tip away.
    func testHoveringTheReviewBandSaysWhoChangedWhat() throws {
        try showTimeline()
        try agentPlacesAShot(at: 40)
        let ruler = try XCTUnwrap(timeline?.ruler)
        TipCenter.shared.hide()
        defer { TipCenter.shared.hide() }
        // 40.5 s at 10 points a second.
        hover(at: CGPoint(x: 405, y: 5), in: ruler)
        RunLoop.main.run(until: Date().addingTimeInterval(TipCenter.delay + 0.2))
        let shown = try XCTUnwrap(TipCenter.shared.shown)
        XCTAssertTrue(shown.text.hasPrefix("Claude · Whoosh · "), shown.text)
        hover(at: CGPoint(x: 100, y: 5), in: ruler)
        XCTAssertNil(TipCenter.shared.shown)
    }

    /// Sends a mouse move to `view` at `point` in its coordinates.
    private func hover(at point: CGPoint, in view: NSView) {
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ) else { return }
        view.mouseMoved(with: event)
    }

    private var timeline: TimelineContainerView? { window?.contentView as? TimelineContainerView }

    /// The share of the lanes painted since the timings were reset.
    private func paintedArea() -> Double {
        DrawTiming.samples("lanes area").reduce(0, +)
    }

    /// Sends a mouse event to `view` at `point` in its coordinates.
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
}

/// What a drag or drop's preview, or an edit, repaints in the lanes.
@MainActor
final class PreviewDamageTests: XCTestCase {
    private let scale = TimelineScale(pixelsPerSecond: 10)

    private func rects(_ from: Project, _ to: Project, previewed: (Set<String>, Set<String>) = ([], []), drop: (String?, String?) = (nil, nil)) -> [CGRect]? {
        TimelineDamage.previewRects(
            from: PreviewState(project: from, previewed: previewed.0, dropLaneID: drop.0),
            to: PreviewState(project: to, previewed: previewed.1, dropLaneID: drop.1),
            layout: TimelineLayout.make(project: from, showTranscript: true), scale: scale, offsetY: 0, width: 1_000
        )
    }

    /// Moving the B-roll shot from 20 s to 40 s repaints where it was and
    /// where it went, and nothing else.
    func testAMovedClipRepaintsWhereItWasAndWhereItIs() throws {
        let f = try AppFixture()
        let before = f.project
        let shot = f.clip("B-roll")
        try f.coordinator.apply(EditBatch(label: "Move", commands: [.moveClips(clipIDs: [shot.id], delta: t(20), includeLinked: false)]))
        let found = try XCTUnwrap(rects(before, f.project))
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map { ($0.minX + TimelineDamage.keyframeReach).rounded() }), [200, 400])
        XCTAssertTrue(found.allSatisfy { $0.width < 70 }, "a 5 s shot is 50 points")
    }

    func testNothingRepaintsWhenNothingChanged() throws {
        let f = try AppFixture()
        XCTAssertEqual(rects(f.project, f.project), [])
    }

    func testOutliningAClipRepaintsIt() throws {
        let f = try AppFixture()
        let shot = f.clip("B-roll").id
        let found = try XCTUnwrap(rects(f.project, f.project, previewed: ([], [shot])))
        XCTAssertEqual(found.count, 1)
    }

    func testTheDropTargetsLaneRepaintsWhenItMoves() throws {
        let f = try AppFixture()
        let broll = f.track("B-roll").id
        let music = f.track("Music").id
        let found = try XCTUnwrap(rects(f.project, f.project, drop: (broll, music)))
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.allSatisfy { $0.width == 1_000 }, "whole lanes")
    }

    /// Muting a track dims all of it, and changes which words the
    /// transcript shows.
    func testMutingATrackRepaintsItAndTheTranscript() throws {
        let f = try AppFixture()
        let before = f.project
        var after = before
        let index = after.audioTracks.firstIndex { $0.name == "Voice" }!
        after.audioTracks[index].muted = true
        let found = try XCTUnwrap(rects(before, after))
        XCTAssertEqual(found.count, 2, "the track and the transcript")
    }

    func testANewTrackRepaintsEverything() throws {
        let f = try AppFixture()
        var after = f.project
        after.audioTracks.append(Track(kind: .audio, name: "SFX 2", rippleMode: .follow))
        XCTAssertNil(rects(f.project, after))
    }
}

/// The strip along the lanes' left edge is as wide as what's pinned there.
@MainActor
final class PinnedReachTests: XCTestCase {
    private func painter(_ f: AppFixture, pinX: CGFloat) -> LanesPainter {
        LanesPainter(
            project: f.project, state: TimelineDrawState(
                project: f.project, revision: 1, scale: TimelineScale(pixelsPerSecond: 10), verticalOffset: 0, trackHeights: [:],
                showTranscript: false, selection: [], selectedTransitionID: nil, selectedKeyframe: nil, inPoint: nil, outPoint: nil,
                renamingTrackID: nil, artworkRevision: 0
            ),
            layout: TimelineLayout.make(project: f.project, showTranscript: false), artwork: nil, pinX: pinX, viewMaxX: pinX + 1_000
        )
    }

    /// Scrolled to 22 s, the take (0 to 60 s) and the B-roll shot (20 to
    /// 25 s) start off the left edge: their name badges stay at the edge,
    /// and the strip covers the longest.
    func testLabelsPinnedAtTheEdgeWidenTheStrip() throws {
        let f = try AppFixture()
        let reach = painter(f, pinX: 220).pinnedReach()
        XCTAssertGreaterThan(reach, 220 + 40, "a name badge past the edge")
        XCTAssertLessThan(reach, 220 + 200)
        // Pinned labels move with the edge.
        XCTAssertEqual(painter(f, pinX: 230).pinnedReach(), reach + 10, accuracy: 0.01)
    }

    func testNothingPinnedLeavesNoStrip() throws {
        let f = try AppFixture()
        // At 70 s the take and the music (0 to 60 s) are behind the edge.
        XCTAssertEqual(painter(f, pinX: 700).pinnedReach(), 700)
    }
}

final class FittedThumbnailTests: XCTestCase {
    /// Thumbnails are redrawn once at the pixels they cover, in the screen's
    /// colour space, so drawing them is a copy.
    func testFitsToThePixelsAndColourSpace() throws {
        let source = try XCTUnwrap(CGContext(
            data: nil, width: 240, height: 135, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let fitted = try XCTUnwrap(MediaArtwork.fit(source, width: 128, height: 72, colorSpace: displayP3))
        XCTAssertEqual(fitted.width, 128)
        XCTAssertEqual(fitted.height, 72)
        XCTAssertEqual(fitted.colorSpace?.name, CGColorSpace.displayP3)
    }
}

@MainActor
final class FramePacerTests: XCTestCase {
    /// Changes arriving together run once; more within a frame wait for the
    /// next one.
    func testRunsAtMostOncePerFrame() {
        var runs: [CFTimeInterval] = []
        let pacer = FramePacer(view: NSView()) { runs.append(CACurrentMediaTime()) }
        pacer.request()
        pacer.request()
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        XCTAssertEqual(runs.count, 1, "two requests in one turn run once")
        pacer.request()
        RunLoop.main.run(until: Date().addingTimeInterval(0.004))
        XCTAssertEqual(runs.count, 1, "the next waits for a frame to pass")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(runs.count, 2)
        XCTAssertGreaterThanOrEqual(runs[1] - runs[0], 1.0 / 60 * 0.9)
    }
}
