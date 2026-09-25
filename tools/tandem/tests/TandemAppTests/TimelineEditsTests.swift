import XCTest
@testable import TandemApp
@testable import TandemCore

final class MoveEditTests: XCTestCase {
    func testMoveOverwritesWhatItLandsOn() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let batch = TimelineEdits.move(f.project, clipIDs: [broll.id], delta: t(-5))
        XCTAssertEqual(batch?.commands, [.moveClips(clipIDs: [broll.id], delta: t(-5), toTrackID: nil, includeLinked: false, mode: .overwrite)])
        try f.apply(batch)
        XCTAssertEqual(f.clip("B-roll").range, TimeRange(start: t(15), end: t(20)))
    }

    func testMoveToAnotherTrack() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        try f.apply(TimelineEdits.move(f.project, clipIDs: [broll.id], delta: t(1), toTrackID: f.track("Graphics").id))
        XCTAssertTrue(f.clips("B-roll").isEmpty)
        XCTAssertEqual(f.clip("Graphics").range, TimeRange(start: t(21), end: t(26)))
        XCTAssertEqual(f.clip("Graphics").id, broll.id)
    }

    func testAGroupAcrossTracksOnlyMovesInTime() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let group = f.project.linkedClipIDs(of: f.clip("Camera", 1).id)
        let batch = TimelineEdits.move(f.project, clipIDs: group, delta: t(2), toTrackID: f.track("B-roll").id)
        guard case .moveClips(_, _, let toTrack, _, _)? = batch?.commands.first else { return XCTFail("expected a move") }
        XCTAssertNil(toTrack)
    }

    func testNoMoveNoBatch() throws {
        let f = try AppFixture()
        XCTAssertNil(TimelineEdits.move(f.project, clipIDs: [f.clip("B-roll").id], delta: .zero))
        XCTAssertNil(TimelineEdits.move(f.project, clipIDs: ["clip_missing"], delta: t(1)))
    }

    func testCommandDragInsertsAndLeavesAGap() throws {
        let f = try AppFixture()
        try f.blade(at: [10, 20])
        // Move the middle part of the take (10 to 20) to 40 as an insert.
        let group = f.project.linkedClipIDs(of: f.clip("Camera", 1).id)
        let batch = TimelineEdits.move(f.project, clipIDs: group, delta: t(30), insert: true)
        XCTAssertEqual(batch?.label, "Insert 3 clips")
        try f.apply(batch)
        let camera = f.clips("Camera").map(\.range)
        XCTAssertEqual(camera, [
            TimeRange(start: t(0), end: t(10)),
            TimeRange(start: t(20), end: t(40)),
            TimeRange(start: t(40), end: t(50)),
            TimeRange(start: t(50), end: t(70))
        ])
        XCTAssertEqual(f.clips("Camera")[2].sourceStart, t(10), "the moved clip keeps its media")
        XCTAssertEqual(f.clips("Voice").map(\.range), camera, "the take moved together")
        XCTAssertEqual(f.project.markers[0].time, t(30), "the marker is before the insert point")
        assertValid(f.project)
    }

    func testNudgeMovesByFramesAndStopsAtZero() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let batch = TimelineEdits.nudge(f.project, clipIDs: [broll.id], frames: -5)
        XCTAssertEqual(batch?.commands, [.moveClips(clipIDs: [broll.id], delta: Time.frames(-5, at: .fps30), toTrackID: nil, includeLinked: false, mode: .overwrite)])
        let camera = f.clip("Camera")
        let atZero = TimelineEdits.nudge(f.project, clipIDs: [camera.id], frames: -1)
        XCTAssertNil(atZero, "already at 0")
    }
}

final class RemoveEditTests: XCTestCase {
    func testDeleteLiftsAndShiftDeleteRipples() throws {
        let f = try AppFixture()
        try f.blade(at: [10, 20])
        let middle = Set(f.project.linkedClipIDs(of: f.clip("Camera", 1).id))
        let lift = TimelineEdits.remove(f.project, clipIDs: middle, ripple: false)
        XCTAssertEqual(lift?.label, "Delete 3 clips")
        let ripple = try XCTUnwrap(TimelineEdits.remove(f.project, clipIDs: middle, ripple: true))
        try f.apply(ripple)
        XCTAssertEqual(f.clips("Camera").map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(10), end: t(50))])
        XCTAssertEqual(f.clip("B-roll").start, t(10), "follow tracks moved with the take")
    }

    func testOptionSelectedSideRemovesOnlyThatSide() throws {
        let f = try AppFixture()
        let voice = f.clip("Voice")
        try f.apply(TimelineEdits.remove(f.project, clipIDs: [voice.id], ripple: false))
        XCTAssertTrue(f.clips("Voice").isEmpty)
        XCTAssertEqual(f.clips("Camera").count, 1)
    }

    func testLiftRangeLeavesAGapOnEveryUnlockedTrack() throws {
        let f = try AppFixture()
        let batch = try XCTUnwrap(TimelineEdits.liftRange(f.project, range: TimeRange(start: t(10), end: t(22))))
        XCTAssertEqual(batch.label, "Lift in to out")
        try f.apply(batch)
        for name in ["Camera", "Screen", "Voice", "Music"] {
            XCTAssertEqual(f.clips(name).map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(22), end: t(60))], name)
        }
        XCTAssertEqual(f.clip("Camera", 1).sourceStart, t(22), "the right part still shows the same media")
        XCTAssertEqual(f.clip("B-roll").range, TimeRange(start: t(22), end: t(25)))
        XCTAssertEqual(f.clip("B-roll").sourceStart, t(3))
        XCTAssertEqual(f.project.markers[0].time, t(30), "markers stay put")
        assertValid(f.project)
    }

    func testLiftRangeKeepsMarkersInsideTheRange() throws {
        let f = try AppFixture()
        try f.coordinator.apply(EditBatch(label: "Marker", commands: [.addMarker(marker: Marker(id: "mk_in", time: t(15), name: "Inside"))]))
        try f.apply(TimelineEdits.liftRange(f.project, range: TimeRange(start: t(10), end: t(20))))
        XCTAssertEqual(f.project.markers.first { $0.id == "mk_in" }?.time, t(15))
    }

    func testLiftRangeSkipsLockedTracks() throws {
        let f = try AppFixture()
        try f.coordinator.apply(EditBatch(label: "Lock", commands: [.updateTrack(trackID: f.track("Music").id, patch: .object(["locked": .bool(true)]))]))
        try f.apply(TimelineEdits.liftRange(f.project, range: TimeRange(start: t(10), end: t(20))))
        XCTAssertEqual(f.clips("Music").map(\.range), [TimeRange(start: t(0), end: t(60))])
        XCTAssertEqual(f.clips("Camera").count, 2)
    }

    func testExtractRangeClosesTheGap() throws {
        let f = try AppFixture()
        try f.apply(TimelineEdits.extractRange(f.project, range: TimeRange(start: t(10), end: t(12))))
        XCTAssertEqual(f.clips("Camera").map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(10), end: t(58))])
        XCTAssertEqual(f.clips("Music").map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(10), end: t(58))], "named tracks are cut, not followed")
        XCTAssertEqual(f.project.duration, t(58))
    }

    func testEmptyRangesDoNothing() throws {
        let f = try AppFixture()
        XCTAssertNil(TimelineEdits.liftRange(f.project, range: TimeRange(start: t(5), end: t(5))))
        XCTAssertNil(TimelineEdits.liftRange(f.project, range: TimeRange(start: t(100), end: t(110))))
        XCTAssertNil(TimelineEdits.extractRange(f.project, range: TimeRange(start: t(5), end: t(4))))
    }
}

final class CutEditTests: XCTestCase {
    func testBladeAtPlayheadCutsTargetedTracks() throws {
        let f = try AppFixture()
        let batch = TimelineEdits.bladeAtPlayhead(f.project, playhead: t(22), selection: [])
        XCTAssertEqual(batch?.commands, [.blade(at: t(22))])
        XCTAssertNil(TimelineEdits.bladeAtPlayhead(f.project, playhead: t(99), selection: []))
    }

    func testBladeAtPlayheadPrefersTheSelection() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let batch = TimelineEdits.bladeAtPlayhead(f.project, playhead: t(22), selection: [broll.id, f.clip("Camera").id])
        XCTAssertEqual(batch?.commands, [.blade(at: t(22), clipIDs: [f.clip("Camera").id, broll.id])], "timeline order: V2 before V3")
    }

    func testBladeToolClick() throws {
        let f = try AppFixture()
        let camera = f.clip("Camera")
        XCTAssertEqual(TimelineEdits.blade(f.project, clipID: camera.id, at: t(5), allTracks: false)?.commands, [.blade(at: t(5), clipIDs: [camera.id])])
        XCTAssertEqual(TimelineEdits.blade(f.project, clipID: camera.id, at: t(5), allTracks: true)?.commands, [.blade(at: t(5))])
        XCTAssertNil(TimelineEdits.blade(f.project, clipID: camera.id, at: .zero, allTracks: false), "on the edge there's nothing to cut")
    }

    func testQRippleTrimsTheStartAndMovesThePlayheadToTheEdit() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let result = try XCTUnwrap(TimelineEdits.rippleTrimToPlayhead(f.project, playhead: t(14), edge: .start, selection: []))
        XCTAssertEqual(result.playhead, t(10))
        try f.apply(result.batch)
        XCTAssertEqual(f.clip("Camera", 1).range, TimeRange(start: t(10), end: t(56)))
        XCTAssertEqual(f.clip("Camera", 1).sourceStart, t(14))
        XCTAssertEqual(f.clip("Voice", 1).sourceStart, t(14), "the linked sound went with it")
        XCTAssertEqual(f.clip("B-roll").start, t(16), "later clips closed up")
        assertValid(f.project)
    }

    func testWRippleTrimsTheEnd() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        let result = try XCTUnwrap(TimelineEdits.rippleTrimToPlayhead(f.project, playhead: t(4), edge: .end, selection: []))
        XCTAssertEqual(result.playhead, t(4))
        try f.apply(result.batch)
        XCTAssertEqual(f.clip("Camera", 0).range, TimeRange(start: t(0), end: t(4)))
        XCTAssertEqual(f.clip("Camera", 1).range, TimeRange(start: t(4), end: t(54)))
    }

    func testQOnTheEditPointDoesNothing() throws {
        let f = try AppFixture()
        try f.blade(at: [10])
        XCTAssertNil(TimelineEdits.rippleTrimToPlayhead(f.project, playhead: t(10), edge: .start, selection: []))
    }

    func testSlipConvertsTimelineDistanceToMedia() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll") // source starts at 1 s
        let batch = TimelineEdits.slip(f.project, clipID: broll.id, timelineDelta: t(0.5), includeLinked: true)
        XCTAssertEqual(batch?.commands, [.slip(clipID: broll.id, delta: t(-0.5), includeLinked: true)])
        try f.apply(batch)
        XCTAssertEqual(f.clip("B-roll").sourceStart, t(0.5))
        XCTAssertEqual(f.clip("B-roll").start, t(20), "slipping never moves the clip")
    }
}

final class LayoutAndLinkEditTests: XCTestCase {
    func testLayoutKeysPreferSelectedVideoClips() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll")
        let targets = TimelineEdits.layoutTargets(f.project, playhead: t(22), selection: [broll.id, f.clip("Voice").id])
        XCTAssertEqual(targets, [broll.id])
    }

    func testLayoutKeysFallBackToTheCameraUnderThePlayhead() throws {
        let f = try AppFixture()
        XCTAssertEqual(TimelineEdits.layoutTargets(f.project, playhead: t(22), selection: []), [f.clip("Camera").id])
        let batch = try XCTUnwrap(TimelineEdits.applyLayout(f.project, preset: .pipRight, playhead: t(22), selection: []))
        XCTAssertEqual(batch.label, "Layout: PiP right")
        try f.apply(batch)
        XCTAssertEqual(f.clip("Camera").video?.transform.scale, 0.5)
        XCTAssertEqual(f.clip("Camera").video?.cutout?.enabled, true)
        XCTAssertNil(TimelineEdits.applyLayout(f.project, preset: .full, playhead: t(99), selection: []))
    }

    func testLinkToggles() throws {
        let f = try AppFixture()
        let group = Set(f.project.linkedClipIDs(of: f.clip("Camera").id))
        let unlink = try XCTUnwrap(TimelineEdits.toggleLink(f.project, selection: group))
        XCTAssertEqual(unlink.label, "Unlink 3 clips")
        try f.apply(unlink)
        XCTAssertNil(f.clip("Camera").linkGroup)
        let link = try XCTUnwrap(TimelineEdits.toggleLink(f.project, selection: [f.clip("Camera").id, f.clip("B-roll").id]))
        try f.apply(link)
        XCTAssertNotNil(f.clip("Camera").linkGroup)
        XCTAssertEqual(f.clip("Camera").linkGroup, f.clip("B-roll").linkGroup)
        XCTAssertNil(TimelineEdits.toggleLink(f.project, selection: [f.clip("Music").id]), "one unlinked clip has nothing to link to")
    }

    func testMarkersAndDefaultTransition() throws {
        let f = try AppFixture()
        try f.apply(TimelineEdits.addMarker(f.project, at: t(12), id: "mk_new"))
        XCTAssertEqual(f.project.markers.map(\.id), ["mk_new", "mk_s2"])
        XCTAssertNil(TimelineEdits.addDefaultTransition(f.project, playhead: t(12), selection: []), "no cut in reach")
        try f.blade(at: [12])
        let batch = try XCTUnwrap(TimelineEdits.addDefaultTransition(f.project, playhead: t(12.5), selection: [], id: "tr_d"))
        try f.apply(batch)
        let transition = try XCTUnwrap(f.track("Camera").transitions.first)
        XCTAssertEqual(transition.id, "tr_d")
        XCTAssertEqual(transition.type, .dissolve)
        XCTAssertEqual(transition.fromClipID, f.clip("Camera", 0).id)
    }

    func testDroppingMediaOnATrack() throws {
        let f = try AppFixture()
        let batch = try XCTUnwrap(TimelineEdits.placeMedia(f.project, mediaIDs: ["med_broll"], at: t(40), trackID: f.track("Graphics").id, insert: false))
        XCTAssertEqual(batch.label, "Place servers")
        try f.apply(batch)
        XCTAssertEqual(f.clip("Graphics").range, TimeRange(start: t(40), end: t(50)))
        let insert = try XCTUnwrap(TimelineEdits.placeMedia(f.project, mediaIDs: ["med_camera", "med_screen"], at: t(10), trackID: nil, insert: true))
        try f.apply(insert)
        XCTAssertEqual(f.clips("Camera").count, 3, "the insert split the take and the new take sits in the middle")
        assertValid(f.project)
    }
}

final class SelectionRuleTests: XCTestCase {
    func testClickSelectsTheLinkGroupUnlessOptionIsDown() throws {
        let f = try AppFixture()
        let camera = f.clip("Camera").id
        let group = Set(f.project.linkedClipIDs(of: camera))
        XCTAssertEqual(SelectionRules.click(camera, in: f.project, current: [], modifiers: .init(), linkedSelection: true), group)
        XCTAssertEqual(SelectionRules.click(camera, in: f.project, current: [], modifiers: .init(option: true), linkedSelection: true), [camera])
        XCTAssertEqual(SelectionRules.click(camera, in: f.project, current: [], modifiers: .init(), linkedSelection: false), [camera])
    }

    func testShiftTogglesAndPressingASelectedClipKeepsTheSelection() throws {
        let f = try AppFixture()
        let broll = f.clip("B-roll").id
        let music = f.clip("Music").id
        var selection = SelectionRules.click(broll, in: f.project, current: [], modifiers: .init(), linkedSelection: true)
        selection = SelectionRules.click(music, in: f.project, current: selection, modifiers: .init(shift: true), linkedSelection: true)
        XCTAssertEqual(selection, [broll, music])
        XCTAssertEqual(SelectionRules.click(broll, in: f.project, current: selection, modifiers: .init(), linkedSelection: true), selection)
        selection = SelectionRules.click(broll, in: f.project, current: selection, modifiers: .init(command: true), linkedSelection: true)
        XCTAssertEqual(selection, [music])
    }

    func testMarqueeAndSelectForward() throws {
        let f = try AppFixture()
        let picked = SelectionRules.marquee([f.clip("B-roll").id], in: f.project, current: [f.clip("Music").id], modifiers: .init(shift: true), linkedSelection: true)
        XCTAssertEqual(picked, [f.clip("B-roll").id, f.clip("Music").id])
        try f.blade(at: [30])
        let forward = SelectionRules.forward(from: t(20), in: f.project)
        XCTAssertEqual(forward, Set([f.clip("B-roll").id] + f.project.linkedClipIDs(of: f.clip("Camera", 1).id)))
    }

    func testEditPoints() throws {
        let f = try AppFixture()
        XCTAssertEqual(EditPoints.next(after: t(0), in: f.project), t(20))
        XCTAssertEqual(EditPoints.next(after: t(20), in: f.project), t(25))
        XCTAssertEqual(EditPoints.previous(before: t(20), in: f.project), t(0))
        XCTAssertNil(EditPoints.next(after: t(60), in: f.project))
        XCTAssertEqual(EditPoints.nextMarker(after: t(0), in: f.project), t(30))
    }
}
