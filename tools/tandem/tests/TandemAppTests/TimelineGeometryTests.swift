import XCTest
@testable import TandemApp
@testable import TandemCore

final class TimelineScaleTests: XCTestCase {
    func testTimeAndPixelsRoundTrip() {
        let scale = TimelineScale(pixelsPerSecond: 50, scrollSeconds: 10)
        XCTAssertEqual(scale.x(t(10)), 0)
        XCTAssertEqual(scale.x(t(12)), 100)
        XCTAssertEqual(scale.time(atX: 100, rate: .fps30), t(12))
        XCTAssertEqual(scale.time(atX: -2000, rate: .fps30), .zero, "never before 0")
    }

    func testTimeAtXRoundsToTheNearestFrame() {
        let scale = TimelineScale(pixelsPerSecond: 300)
        // 1/30 s is 10 px; 14 px is 1.4 frames, which rounds to frame 1.
        XCTAssertEqual(scale.time(atX: 14, rate: .fps30), Time.frames(1, at: .fps30))
        XCTAssertEqual(scale.time(atX: 16, rate: .fps30), Time.frames(2, at: .fps30))
    }

    func testZoomKeepsTheAnchorStill() {
        var scale = TimelineScale(pixelsPerSecond: 20, scrollSeconds: 30)
        let anchorX: CGFloat = 400
        let before = scale.seconds(atX: anchorX)
        scale.zoom(by: 2.5, anchorX: anchorX)
        XCTAssertEqual(scale.pixelsPerSecond, 50)
        XCTAssertEqual(scale.seconds(atX: anchorX), before, accuracy: 1e-9)
    }

    func testZoomIsClampedAndScrollNeverGoesNegative() {
        var scale = TimelineScale(pixelsPerSecond: 20, scrollSeconds: 0)
        scale.zoom(by: 1e9, anchorX: 0)
        XCTAssertEqual(scale.pixelsPerSecond, TimelineScale.maximumPixelsPerSecond)
        scale.zoom(by: 1e-12, anchorX: 800)
        XCTAssertEqual(scale.pixelsPerSecond, TimelineScale.minimumPixelsPerSecond)
        XCTAssertGreaterThanOrEqual(scale.scrollSeconds, 0)
    }

    func testFittingShowsTheWholeDuration() {
        let scale = TimelineScale.fitting(t(600), width: 1224)
        XCTAssertEqual(scale.scrollSeconds, 0)
        XCTAssertLessThanOrEqual(scale.x(t(600)), 1224)
        XCTAssertGreaterThan(scale.x(t(600)), 1100)
    }

    func testRevealScrollsOnlyWhenNeeded() {
        var scale = TimelineScale(pixelsPerSecond: 10, scrollSeconds: 0)
        scale.reveal(t(20), width: 1000)
        XCTAssertEqual(scale.scrollSeconds, 0, "20 s is already on screen")
        scale.reveal(t(200), width: 1000)
        XCTAssertEqual(Double(scale.x(t(200))), 960, accuracy: 0.5)
    }

    func testRulerStepReadsWell() {
        XCTAssertEqual(TimelineScale(pixelsPerSecond: 11.6).rulerStep(), 10)
        XCTAssertEqual(TimelineScale(pixelsPerSecond: 1).rulerStep(), 120)
        XCTAssertEqual(TimelineScale(pixelsPerSecond: 3000).rulerStep(), 1.0 / 30, accuracy: 1e-9)
    }
}

final class TimecodeTests: XCTestCase {
    func testMinutesSecondsFrames() {
        let time = t(5 * 60 + 26) + Time.frames(4, at: .fps30)
        XCTAssertEqual(Timecode.string(time, rate: .fps30), "05:26:04")
        XCTAssertEqual(Timecode.string(t(3_600 + 62), rate: .fps30), "1:01:02:00")
        XCTAssertEqual(Timecode.string(.zero, rate: .fps30), "00:00:00")
    }

    func testParseRoundTrips() {
        let time = t(629) + Time.frames(4, at: .fps30)
        XCTAssertEqual(Timecode.parse("10:29:04", rate: .fps30), time)
        XCTAssertEqual(Timecode.parse("1:00:00:00", rate: .fps30), t(3_600))
        XCTAssertEqual(Timecode.parse("12.5", rate: .fps30), t(12.5))
        XCTAssertEqual(Timecode.parse("02:05", rate: .fps30), t(125))
        XCTAssertNil(Timecode.parse("nonsense", rate: .fps30))
    }

    func testDurations() {
        XCTAssertEqual(Timecode.duration(5), "0:05")
        XCTAssertEqual(Timecode.duration(124), "2:04")
        XCTAssertEqual(Timecode.duration(3_723), "1:02:03")
        XCTAssertEqual(Timecode.clock(320), "05:20")
    }
}

final class TimelineLayoutTests: XCTestCase {
    func testLanesRunTranscriptThenTopVideoDownThenAudio() throws {
        let f = try AppFixture()
        let layout = TimelineLayout.make(project: f.project, showTranscript: true)
        let names = layout.lanes.map { $0.trackID.flatMap { f.project.track($0)?.name } ?? "transcript" }
        XCTAssertEqual(names, ["transcript", "Text", "Graphics", "B-roll", "Camera", "Screen", "Voice", "Music", "SFX"])
        XCTAssertEqual(layout.lanes.map(\.height), [18, 24, 32, 40, 48, 48, 40, 30, 20])
        XCTAssertEqual(layout.lanes[0].y, 3)
        XCTAssertEqual(layout.lanes[1].y, 3 + 18 + 3)
        XCTAssertEqual(layout.contentHeight, layout.lanes.last!.maxY + 3)
    }

    func testTranscriptLaneCanBeHidden() throws {
        let f = try AppFixture()
        let layout = TimelineLayout.make(project: f.project, showTranscript: false)
        XCTAssertNil(layout.lanes.first { $0.isTranscript })
        XCTAssertEqual(layout.lanes.first?.y, 3)
    }

    func testNearestTrackLaneStaysWithinTheKind() throws {
        let f = try AppFixture()
        let layout = TimelineLayout.make(project: f.project, showTranscript: true)
        let voice = layout.lane(forTrack: f.track("Voice").id)!
        // Dragging a video clip down over the audio lanes stops at the
        // bottom video track.
        XCTAssertEqual(layout.nearestTrackLane(toY: voice.midY, kind: .video)?.trackID, f.track("Screen").id)
        XCTAssertEqual(layout.nearestTrackLane(toY: -50, kind: .audio)?.trackID, f.track("Voice").id)
        XCTAssertEqual(layout.track(f.track("Camera").id, offsetBy: -1), f.track("B-roll").id)
        XCTAssertEqual(layout.track(f.track("Camera").id, offsetBy: 10), f.track("Screen").id)
    }

    func testStylesFollowTrackNames() {
        XCTAssertEqual(LaneStyle.of(Track(kind: .video, name: "Captions")), .text)
        XCTAssertEqual(LaneStyle.of(Track(kind: .video, name: "V4")), .video)
        XCTAssertEqual(LaneStyle.of(Track(kind: .audio, name: "Sound FX")), .sfx)
        XCTAssertEqual(LaneStyle.of(Track(kind: .audio, name: "A5")), .audio)
    }
}

final class SnappingTests: XCTestCase {
    func testNearestTargetWithinTolerance() {
        let targets = SnapTargets([t(10), t(5), t(20), t(5)])
        XCTAssertEqual(targets.times, [t(5), t(10), t(20)])
        XCTAssertEqual(targets.nearest(to: t(10.2), within: t(0.25)), t(10))
        XCTAssertNil(targets.nearest(to: t(10.3), within: t(0.25)))
        XCTAssertEqual(targets.nearest(to: t(7.6), within: t(3)), t(10), "the closer of two in reach")
        XCTAssertEqual(targets.nearest(to: t(0), within: t(5)), t(5))
        XCTAssertEqual(targets.nearest(to: t(99), within: t(80)), t(20))
    }

    func testMovingRangeSnapsWhicheverEdgeIsCloser() {
        let targets = SnapTargets([t(30)])
        // A clip from 10 to 20 moved by 9.9 has its end at 29.9: snap it.
        let tail = targets.snappedDelta(t(9.9), edges: [t(10), t(20)], within: t(0.2))
        XCTAssertEqual(tail?.delta, t(10))
        XCTAssertEqual(tail?.target, t(30))
        // Moved by 19.95 its start is at 29.95: snap the start.
        let head = targets.snappedDelta(t(19.95), edges: [t(10), t(20)], within: t(0.2))
        XCTAssertEqual(head?.delta, t(20))
        XCTAssertNil(targets.snappedDelta(t(5), edges: [t(10), t(20)], within: t(0.2)))
    }

    func testCollectLeavesOutTheDraggedClips() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let targets = SnapTargets.collect(in: f.project, excluding: [broll.id], playhead: t(12), inPoint: t(3))
        XCTAssertFalse(targets.times.contains(t(20)), "the B-roll's own start")
        XCTAssertTrue(targets.times.contains(t(60)))
        XCTAssertTrue(targets.times.contains(t(30)), "marker")
        XCTAssertTrue(targets.times.contains(t(12)), "playhead")
        XCTAssertTrue(targets.times.contains(t(3)), "in point")
    }
}

final class HitTestingTests: XCTestCase {
    func makeTester(_ f: AppFixture, pps: Double = 10) -> TimelineHitTester {
        TimelineHitTester(
            project: f.project,
            layout: TimelineLayout.make(project: f.project, showTranscript: true),
            scale: TimelineScale(pixelsPerSecond: pps)
        )
    }

    func testBodyHeadAndTail() throws {
        let f = try AppFixture()
        let tester = makeTester(f)
        let lane = tester.layout.lane(forTrack: f.track("B-roll").id)!
        let broll = f.clip("B-roll") // 20 to 25 s, so 200 to 250 px
        XCTAssertEqual(tester.hit(CGPoint(x: 225, y: lane.midY)), .clip(clipID: broll.id, trackID: lane.trackID!, part: .body))
        XCTAssertEqual(tester.hit(CGPoint(x: 202, y: lane.midY)), .clip(clipID: broll.id, trackID: lane.trackID!, part: .head))
        XCTAssertEqual(tester.hit(CGPoint(x: 249, y: lane.midY)), .clip(clipID: broll.id, trackID: lane.trackID!, part: .tail))
        XCTAssertEqual(tester.hit(CGPoint(x: 253, y: lane.midY)), .clip(clipID: broll.id, trackID: lane.trackID!, part: .tail), "just outside the tail still grabs it")
        XCTAssertEqual(tester.hit(CGPoint(x: 400, y: lane.midY)), .emptyTrack(trackID: lane.trackID!, time: t(40)))
    }

    func testTouchingClipsSplitTheCutBetweenThem() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let tester = makeTester(f)
        let lane = tester.layout.lane(forTrack: f.track("Camera").id)!
        let left = f.clip("Camera", 0)
        let right = f.clip("Camera", 1)
        XCTAssertEqual(tester.hit(CGPoint(x: 98, y: lane.midY)), .clip(clipID: left.id, trackID: lane.trackID!, part: .tail))
        XCTAssertEqual(tester.hit(CGPoint(x: 100, y: lane.midY)), .clip(clipID: right.id, trackID: lane.trackID!, part: .head))
        XCTAssertEqual(tester.hit(CGPoint(x: 103, y: lane.midY)), .clip(clipID: right.id, trackID: lane.trackID!, part: .head))
    }

    func testShortClipsKeepABodyToGrab() throws {
        let f = try AppFixture()
        let tester = makeTester(f, pps: 2) // the 5 s B-roll is 10 px wide
        let lane = tester.layout.lane(forTrack: f.track("B-roll").id)!
        let broll = f.clip("B-roll") // 40 to 50 px
        XCTAssertEqual(tester.hit(CGPoint(x: 45, y: lane.midY)), .clip(clipID: broll.id, trackID: lane.trackID!, part: .body))
        XCTAssertEqual(tester.hit(CGPoint(x: 41, y: lane.midY)), .clip(clipID: broll.id, trackID: lane.trackID!, part: .head))
    }

    func testTransitionsAndTheTranscriptLane() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let camera = f.track("Camera")
        try f.coordinator.apply(EditBatch(label: "Dissolve", commands: [
            .addTransition(trackID: camera.id, transition: Transition(id: "tr_a", type: .dissolve, duration: t(0.5), fromClipID: f.clip("Camera", 0).id, toClipID: f.clip("Camera", 1).id))
        ]))
        let tester = makeTester(f)
        let lane = tester.layout.lane(forTrack: camera.id)!
        XCTAssertEqual(tester.hit(CGPoint(x: 100, y: lane.midY)), .transition(transitionID: "tr_a", trackID: camera.id))
        XCTAssertEqual(tester.hit(CGPoint(x: 100, y: 10)), .transcript(time: t(10)))
        XCTAssertEqual(tester.hit(CGPoint(x: 100, y: 9_999)), .nothing)
    }

    func testTransitionChipsShrinkWithTheirClipsAndFadesUseTheirBand() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let camera = f.track("Camera")
        try f.coordinator.apply(EditBatch(label: "Transitions", commands: [
            .addTransition(trackID: camera.id, transition: Transition(id: "tr_cut", type: .dissolve, duration: t(0.5), fromClipID: f.clip("Camera", 0).id, toClipID: f.clip("Camera", 1).id)),
            .addTransition(trackID: camera.id, transition: Transition(id: "tr_in", type: .fadeFromBlack, duration: t(2), fromClipID: nil, toClipID: f.clip("Camera", 0).id))
        ]))
        let layout = TimelineLayout.make(project: f.project, showTranscript: true)
        let lane = layout.lane(forTrack: camera.id)!
        let track = f.track("Camera")
        let cut = track.transitions.first { $0.id == "tr_cut" }!
        let fade = track.transitions.first { $0.id == "tr_in" }!
        XCTAssertEqual(TransitionGeometry.chipRect(cut, on: track, lane: lane, scale: TimelineScale(pixelsPerSecond: 10))?.width, 24)
        XCTAssertEqual(TransitionGeometry.chipRect(cut, on: track, lane: lane, scale: TimelineScale(pixelsPerSecond: 2))?.width, 12, "10 s of clip is 20 px, so a 12 px chip")
        XCTAssertNil(TransitionGeometry.chipRect(cut, on: track, lane: lane, scale: TimelineScale(pixelsPerSecond: 1)), "too small to draw")
        XCTAssertNil(TransitionGeometry.chipRect(fade, on: track, lane: lane, scale: TimelineScale(pixelsPerSecond: 10)), "fades draw as a ramp")
        let tester = TimelineHitTester(project: f.project, layout: layout, scale: TimelineScale(pixelsPerSecond: 10))
        XCTAssertEqual(tester.hit(CGPoint(x: 10, y: lane.midY)), .transition(transitionID: "tr_in", trackID: camera.id))
    }

    func testMarqueeFindsIntersectingClips() throws {
        let f = try AppFixture()
        let tester = makeTester(f)
        let broll = tester.layout.lane(forTrack: f.track("B-roll").id)!
        let camera = tester.layout.lane(forTrack: f.track("Camera").id)!
        let ids = tester.clips(in: CGRect(x: 210, y: broll.midY, width: 5, height: camera.midY - broll.midY))
        XCTAssertEqual(ids, [f.clip("B-roll").id, f.clip("Camera").id])
    }
}
