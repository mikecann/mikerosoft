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

    func testScrollingRedrawsTheRulerAndLanesButNotTheHeaders() throws {
        let f = try AppFixture()
        let damage = TimelineDamage.between(state(f), state(f, scroll: 4), layout: layout(f), layoutChanged: false)
        XCTAssertEqual(damage, TimelineDamage(ruler: true, headers: false, allLanes: true))
    }

    func testScrollingDownRedrawsTheHeadersAndLanesButNotTheRuler() throws {
        let f = try AppFixture()
        var down = state(f)
        down.verticalOffset = 30
        XCTAssertEqual(TimelineDamage.between(state(f), down, layout: layout(f), layoutChanged: false), TimelineDamage(ruler: false, headers: true, allLanes: true))
    }

    func testAnEditRedrawsEverything() throws {
        let f = try AppFixture()
        var edited = state(f)
        edited.revision = 2
        XCTAssertEqual(TimelineDamage.between(state(f), edited, layout: layout(f), layoutChanged: false), TimelineDamage(ruler: true, headers: true, allLanes: true))
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

    func testScrollingLeavesTheHeadersAlone() throws {
        try showTimeline()
        model.timeline.scale.scrollSeconds = 12
        settle()
        XCTAssertEqual(draws("headers"), 0)
        XCTAssertEqual(draws("ruler"), 1)
        XCTAssertGreaterThan(draws("lanes"), 0)
    }
}
