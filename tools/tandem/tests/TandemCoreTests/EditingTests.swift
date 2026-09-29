import XCTest
@testable import TandemCore

final class PlacementTests: XCTestCase {
    func testPlacingATakeLinksAndSyncsItsFiles() throws {
        let (f, _) = try Fixture.edited()
        let camera = f.clips("Camera")[0]
        let screen = f.clips("Screen")[0]
        let voice = f.clips("Voice")[0]
        XCTAssertEqual(camera.sourceStart, .zero)
        XCTAssertEqual(screen.sourceStart, t(0.5), "the screen started 0.5 s before the camera")
        XCTAssertEqual(voice.mediaID, "med_camera")
        XCTAssertNotNil(camera.linkGroup)
        XCTAssertEqual(Set([camera, screen, voice].map(\.linkGroup)).count, 1)
        XCTAssertEqual(voice.audio?.normalizeTo, -20, "speech is levelled to the project's speech level")
        XCTAssertEqual(voice.audio?.gainDB, 0)
        XCTAssertEqual(f.clips("Music")[0].audio?.gainDB, -31)
        XCTAssertEqual(f.clips("B-roll")[0].sourceStart, t(1))
        XCTAssertTrue(f.clips("SFX").isEmpty, "B-roll sound isn't placed by default")
        assertValid(f.project)
    }

    func testPlaceFailsOnOccupiedTrack() throws {
        let (_, c) = try Fixture.edited()
        XCTAssertThrowsError(try c.run("Again", .placeMedia(mediaIDs: ["med_broll"], at: t(22), duration: t(2))))
    }

    func testInsertSplitsCutTracksAndShiftsTheRest() throws {
        let (f, c) = try Fixture.edited()
        let slug = Clip(id: "clip_slug", content: .solid(color: .black), start: t(10), duration: t(5))
        try c.run("Insert", .insertClip(trackID: f.track("Camera").id, clip: slug, mode: .insert))
        XCTAssertEqual(c.clips("Camera").map(\.range), [
            TimeRange(start: t(0), end: t(10)),
            TimeRange(start: t(10), end: t(15)),
            TimeRange(start: t(15), end: t(65))
        ])
        XCTAssertEqual(c.clips("Voice").map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(15), end: t(65))])
        XCTAssertEqual(c.clips("Screen").count, 2)
        XCTAssertEqual(c.clips("Music").map(\.range), [TimeRange(start: t(0), end: t(60))], "music follows without a cut")
        XCTAssertEqual(c.clips("B-roll")[0].start, t(25))
        XCTAssertEqual(c.project.markers[0].time, t(35))
        assertValid(c.project)
    }
}

final class CuttingTests: XCTestCase {
    func testBladeSplitsLinkedClipsIntoNewGroups() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0]
        try c.run("Cut", .blade(at: t(10), clipIDs: [camera.id]))
        for name in ["Camera", "Voice", "Screen"] {
            XCTAssertEqual(c.clips(name).count, 2, name)
            XCTAssertEqual(c.clips(name)[1].start, t(10))
        }
        XCTAssertEqual(c.clips("Camera")[1].sourceStart, t(10))
        XCTAssertEqual(c.clips("Screen")[1].sourceStart, t(10.5))
        XCTAssertEqual(c.clips("Camera")[0].id, camera.id, "the left part keeps the ID")
        let left = Set(["Camera", "Voice", "Screen"].map { c.clips($0)[0].linkGroup })
        let right = Set(["Camera", "Voice", "Screen"].map { c.clips($0)[1].linkGroup })
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(right.count, 1)
        XCTAssertNotEqual(left, right)
        XCTAssertEqual(c.clips("Music").count, 1, "unlinked tracks aren't cut")
        assertValid(c.project)
    }

    func testBladeAtPlayheadCutsEveryTargetedTrack() throws {
        let (_, c) = try Fixture.edited()
        let result = try c.run("Cut", .blade(at: t(22)))
        XCTAssertEqual(result.createdIDs.count, 5, "screen, camera, B-roll, voice and music")
        XCTAssertEqual(c.clips("B-roll")[1].sourceStart, t(3))
    }

    func testBladeOnNothingWarnsInsteadOfFailing() throws {
        let (_, c) = try Fixture.edited()
        let result = try c.run("Cut", .blade(at: t(90)))
        XCTAssertEqual(result.warnings, ["Nothing to cut at 01:30.000."])
    }

    func testFadesSplitSensibly() throws {
        let (_, c) = try Fixture.edited()
        let music = c.clips("Music")[0]
        try c.run("Fades", .updateClip(clipID: music.id, patch: .object(["audio": .object(["fadeIn": .number(1)])])))
        try c.run("Cut", .blade(at: t(30), clipIDs: [music.id]))
        let (left, right) = (c.clips("Music")[0], c.clips("Music")[1])
        XCTAssertEqual(left.audio?.fadeIn, t(1))
        XCTAssertEqual(left.audio?.fadeOut, .zero)
        XCTAssertEqual(right.audio?.fadeIn, .zero)
        XCTAssertEqual(right.audio?.fadeOut, t(2))
    }
}

final class RippleTests: XCTestCase {
    func testRippleDeleteRangeCutsTheTakeAndMovesEverythingElse() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(12))))
        for name in ["Camera", "Voice", "Screen"] {
            XCTAssertEqual(c.clips(name).map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(10), end: t(58))], name)
        }
        XCTAssertEqual(c.clips("Camera")[1].sourceStart, t(12))
        XCTAssertEqual(c.clips("Music").map(\.range), [TimeRange(start: t(0), end: t(58))], "the bed keeps playing and gets shorter")
        XCTAssertEqual(c.clips("Music")[0].sourceStart, .zero)
        XCTAssertEqual(c.clips("B-roll")[0].range, TimeRange(start: t(18), end: t(23)))
        XCTAssertEqual(c.project.markers[0].time, t(28))
        XCTAssertEqual(c.project.duration, t(58))
        assertValid(c.project)
    }

    func testFollowingClipThatStartsInsideTheRangeKeepsItsHead() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(19), end: t(21))))
        let broll = c.clips("B-roll")[0]
        XCTAssertEqual(broll.range, TimeRange(start: t(19), end: t(23)))
        XCTAssertEqual(broll.sourceStart, t(1))
    }

    func testRippleDeleteOfATakeClipClosesTheTimeline() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.track("Camera").id
        try c.run("Cut", .blade(at: t(10), trackIDs: [camera]), .blade(at: t(20), trackIDs: [camera]))
        let middle = c.clips("Camera")[1].id
        try c.run("Delete", .removeClips(clipIDs: [middle], ripple: true))
        for name in ["Camera", "Voice", "Screen"] {
            XCTAssertEqual(c.clips(name).map(\.range), [TimeRange(start: t(0), end: t(10)), TimeRange(start: t(10), end: t(50))], name)
        }
        XCTAssertEqual(c.clips("B-roll")[0].range, TimeRange(start: t(10), end: t(15)))
        XCTAssertEqual(c.clips("Music")[0].range, TimeRange(start: t(0), end: t(50)))
        XCTAssertEqual(c.project.markers[0].time, t(20))
        assertValid(c.project)
    }

    func testRippleDeleteOnAFollowTrackOnlyMovesThatTrack() throws {
        let (f, c) = try Fixture.edited()
        try c.run("More B-roll", .placeMedia(mediaIDs: ["med_broll"], at: t(30), duration: t(5)))
        try c.run("Delete", .removeClips(clipIDs: [f.clips("B-roll")[0].id], ripple: true))
        XCTAssertEqual(c.clips("B-roll").map(\.range), [TimeRange(start: t(25), end: t(30))])
        XCTAssertEqual(c.clips("Camera")[0].range, TimeRange(start: t(0), end: t(60)))
        XCTAssertEqual(c.project.markers[0].time, t(30))
    }

    func testLiftLeavesAGap() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Lift", .removeClips(clipIDs: [f.clips("B-roll")[0].id]))
        XCTAssertTrue(c.clips("B-roll").isEmpty)
        XCTAssertEqual(c.project.duration, t(60))
    }

    func testRippleDeleteNeedsClipsToLineUp() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.track("Camera").id
        try c.run("Cut", .blade(at: t(10), trackIDs: [camera]), .blade(at: t(20), trackIDs: [camera]))
        try c.run("Unlink screen", .unlink(clipIDs: c.clips("Screen").map(\.id)))
        try c.run("Cut screen", .blade(at: t(15), trackIDs: [f.track("Screen").id]))
        let cameraMiddle = c.clips("Camera")[1].id
        let screenPiece = c.clips("Screen")[2].id
        XCTAssertEqual(c.clips("Screen")[2].range, TimeRange(start: t(15), end: t(20)))
        XCTAssertThrowsError(try c.run("Delete", .removeClips(clipIDs: [cameraMiddle, screenPiece], ripple: true, includeLinked: false))) { error in
            XCTAssertTrue("\(error)".contains("line up"), "\(error)")
        }
    }

    func testCloseGapOnAFollowTrack() throws {
        let (f, c) = try Fixture.edited()
        try c.run("More B-roll", .placeMedia(mediaIDs: ["med_broll"], at: t(30), duration: t(5)))
        try c.run("Close", .closeGap(trackID: f.track("B-roll").id, at: t(27)))
        XCTAssertEqual(c.clips("B-roll").map(\.start), [t(20), t(25)])
    }

    func testCloseGapRefusesToCutAnotherTakeTrack() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.track("Camera").id
        try c.run("Cut", .blade(at: t(10), trackIDs: [camera]), .blade(at: t(20), trackIDs: [camera]))
        try c.run("Lift camera", .removeClips(clipIDs: [c.clips("Camera")[1].id], includeLinked: false))
        XCTAssertThrowsError(try c.run("Close", .closeGap(trackID: f.track("Camera").id, at: t(15))))
    }

    func testInsertTimeOpensAGap() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Open", .insertTime(at: t(30), duration: t(2)))
        XCTAssertEqual(c.clips("Camera").map(\.range), [TimeRange(start: t(0), end: t(30)), TimeRange(start: t(32), end: t(62))])
        XCTAssertEqual(c.clips("Music").map(\.range), [TimeRange(start: t(0), end: t(60))])
    }
}

final class TrimTests: XCTestCase {
    func testRippleTrimEndPullsLaterClipsIn() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(30), clipIDs: [f.clips("Camera")[0].id]))
        let left = c.clips("Camera")[0].id
        try c.run("Trim", .trim(clipID: left, edge: .end, to: t(28), ripple: true))
        for name in ["Camera", "Voice", "Screen"] {
            XCTAssertEqual(c.clips(name).map(\.range), [TimeRange(start: t(0), end: t(28)), TimeRange(start: t(28), end: t(58))], name)
        }
        XCTAssertEqual(c.clips("Camera")[1].sourceStart, t(30))
        XCTAssertEqual(c.clips("Music")[0].range, TimeRange(start: t(0), end: t(58)))
        XCTAssertEqual(c.project.markers[0].time, t(28))
        assertValid(c.project)
    }

    func testRippleTrimStartKeepsTheClipInPlace() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(30), clipIDs: [f.clips("Camera")[0].id]))
        let right = c.clips("Camera")[1].id
        try c.run("Trim", .trim(clipID: right, edge: .start, to: t(31), ripple: true))
        XCTAssertEqual(c.clips("Camera").map(\.range), [TimeRange(start: t(0), end: t(30)), TimeRange(start: t(30), end: t(59))])
        XCTAssertEqual(c.clips("Camera")[1].sourceStart, t(31))
        XCTAssertEqual(c.clips("Screen")[1].sourceStart, t(31.5))
        XCTAssertEqual(c.clips("Music")[0].range, TimeRange(start: t(0), end: t(59)))
        assertValid(c.project)
    }

    func testTrimIntoANeighbourFailsAndChangesNothing() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(30), clipIDs: [f.clips("Camera")[0].id]))
        let before = c.project
        let revision = c.revision
        XCTAssertThrowsError(try c.run("Trim", .trim(clipID: c.clips("Camera")[0].id, edge: .end, to: t(31))))
        XCTAssertEqual(c.project, before)
        XCTAssertEqual(c.revision, revision)
    }

    func testTrimPastTheMediaFails() throws {
        let (f, c) = try Fixture.edited()
        XCTAssertThrowsError(try c.run("Trim", .trim(clipID: f.clips("Camera")[0].id, edge: .end, to: t(61)))) { error in
            XCTAssertTrue("\(error)".contains("needs media up to"), "\(error)")
        }
    }

    func testRollMovesTheCutOnEveryLinkedTrack() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(30), clipIDs: [f.clips("Camera")[0].id]))
        let (left, right) = (c.clips("Camera")[0].id, c.clips("Camera")[1].id)
        try c.run("Roll", .roll(leftClipID: left, rightClipID: right, delta: t(1)))
        for name in ["Camera", "Voice", "Screen"] {
            XCTAssertEqual(c.clips(name).map(\.range), [TimeRange(start: t(0), end: t(31)), TimeRange(start: t(31), end: t(60))], name)
        }
        XCTAssertEqual(c.clips("Camera")[1].sourceStart, t(31))
    }

    func testSlipChangesMediaNotPosition() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(30), clipIDs: [f.clips("Camera")[0].id]))
        try c.run("Slip", .slip(clipID: c.clips("Camera")[1].id, delta: t(-1)))
        XCTAssertEqual(c.clips("Camera")[1].start, t(30))
        XCTAssertEqual(c.clips("Camera")[1].sourceStart, t(29))
        XCTAssertEqual(c.clips("Screen")[1].sourceStart, t(29.5))
        XCTAssertThrowsError(try c.run("Slip too far", .slip(clipID: c.clips("Camera")[0].id, delta: t(-1))))
    }

    func testSlideTrimsTheNeighbours() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.track("Camera").id
        try c.run("Cut", .blade(at: t(20), trackIDs: [camera]), .blade(at: t(40), trackIDs: [camera]))
        try c.run("Slide", .slide(clipID: c.clips("Camera")[1].id, delta: t(2)))
        for name in ["Camera", "Voice", "Screen"] {
            XCTAssertEqual(c.clips(name).map(\.range), [
                TimeRange(start: t(0), end: t(22)),
                TimeRange(start: t(22), end: t(42)),
                TimeRange(start: t(42), end: t(60))
            ], name)
        }
        XCTAssertEqual(c.clips("Camera")[1].sourceStart, t(20), "the slid clip shows the same media")
        XCTAssertEqual(c.clips("Camera")[2].sourceStart, t(42))
        assertValid(c.project)
    }

    func testSpeedOnAFollowTrackOnlyRipplesThatTrack() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Speed", .setSpeed(clipID: f.clips("B-roll")[0].id, speed: 2, ripple: true))
        let broll = c.clips("B-roll")[0]
        XCTAssertEqual(broll.range, TimeRange(start: t(20), end: t(22.5)))
        XCTAssertEqual(broll.sourceDuration, t(5))
        XCTAssertEqual(c.clips("Camera")[0].range, TimeRange(start: t(0), end: t(60)))
    }
}

final class MoveTests: XCTestCase {
    func testMoveKeepsLinkedClipsTogether() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Move", .moveClips(clipIDs: [f.clips("Camera")[0].id], delta: t(5)))
        for name in ["Camera", "Voice", "Screen"] {
            XCTAssertEqual(c.clips(name)[0].start, t(5), name)
        }
    }

    func testMoveToAnotherTrack() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Move", .moveClips(clipIDs: [f.clips("B-roll")[0].id], delta: t(10), toTrackID: f.track("Graphics").id))
        XCTAssertTrue(c.clips("B-roll").isEmpty)
        XCTAssertEqual(c.clips("Graphics")[0].range, TimeRange(start: t(30), end: t(35)))
    }

    func testMoveOntoAClipFailsUnlessOverwriting() throws {
        let (f, c) = try Fixture.edited()
        let broll = f.clips("B-roll")[0].id
        XCTAssertThrowsError(try c.run("Move", .moveClips(clipIDs: [broll], toTrackID: f.track("Camera").id)))
        try c.run("Overwrite", .moveClips(clipIDs: [broll], toTrackID: f.track("Camera").id, mode: .overwrite))
        XCTAssertEqual(c.clips("Camera").map(\.range), [
            TimeRange(start: t(0), end: t(20)),
            TimeRange(start: t(20), end: t(25)),
            TimeRange(start: t(25), end: t(60))
        ])
        assertValid(c.project)
    }

    func testMovingAudioOntoAVideoTrackFails() throws {
        let (f, c) = try Fixture.edited()
        XCTAssertThrowsError(try c.run("Move", .moveClips(clipIDs: [f.clips("Music")[0].id], toTrackID: f.track("Camera").id, includeLinked: false)))
    }
}

final class TransitionTests: XCTestCase {
    func testDissolveBetweenTakePieces() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(30), clipIDs: [f.clips("Camera")[0].id]))
        let (left, right) = (c.clips("Camera")[0].id, c.clips("Camera")[1].id)
        let result = try c.run("Dissolve", .addTransition(
            trackID: f.track("Camera").id,
            transition: Transition(id: "tr_d", type: .dissolve, duration: t(0.5), fromClipID: left, toClipID: right)
        ))
        XCTAssertEqual(result.createdIDs, ["tr_d"])
        XCTAssertThrowsError(try c.run("Twice", .addTransition(
            trackID: f.track("Camera").id,
            transition: Transition(type: .push, duration: t(0.5), fromClipID: left, toClipID: right)
        )))
    }

    func testTransitionNeedsHandles() throws {
        let (f, c) = try Fixture.edited()
        try c.run("B-roll 2", .placeMedia(mediaIDs: ["med_broll"], at: t(25), sourceStart: .zero, duration: t(5)))
        let (a, b) = (c.clips("B-roll")[0].id, c.clips("B-roll")[1].id)
        XCTAssertThrowsError(try c.run("Push", .addTransition(
            trackID: f.track("B-roll").id,
            transition: Transition(type: .push, direction: .down, duration: t(1), fromClipID: a, toClipID: b)
        ))) { error in
            XCTAssertTrue("\(error)".contains("more media before its start"), "\(error)")
        }
    }

    func testTransitionIntoAStillNeedsNoHandles() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Still", .addMedia(item: MediaItem(id: "med_still", path: "images/slide.png", kind: .image, role: .image, width: 1920, height: 1080)))
        try c.run("Place", .placeMedia(mediaIDs: ["med_still"], at: t(25), duration: t(4)))
        let (a, b) = (c.clips("B-roll")[0].id, c.clips("B-roll")[1].id)
        try c.run("Push", .addTransition(
            trackID: f.track("B-roll").id,
            transition: Transition(type: .push, direction: .left, duration: t(0.7), fromClipID: a, toClipID: b)
        ))
        XCTAssertEqual(c.project.track(named: "B-roll")!.transitions.count, 1)
    }

    func testTailTransitionFollowsASplit() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Fade", .addTransition(
            trackID: f.track("Camera").id,
            transition: Transition(id: "tr_f", type: .fadeToBlack, duration: t(1.1), fromClipID: camera, toClipID: nil)
        ))
        try c.run("Cut", .blade(at: t(50), clipIDs: [camera]))
        let transition = c.project.track(named: "Camera")!.transitions[0]
        XCTAssertEqual(transition.fromClipID, c.clips("Camera")[1].id)
    }

    func testMovingClipsApartDropsTheirTransition() throws {
        let (f, c) = try Fixture.edited()
        try c.run("B-roll 2", .placeMedia(mediaIDs: ["med_broll"], at: t(25), sourceStart: t(6), duration: t(4)))
        let (a, b) = (c.clips("B-roll")[0].id, c.clips("B-roll")[1].id)
        try c.run("Dissolve", .addTransition(
            trackID: f.track("B-roll").id,
            transition: Transition(type: .dissolve, duration: t(0.5), fromClipID: a, toClipID: b)
        ))
        let result = try c.run("Move", .moveClips(clipIDs: [b], delta: t(5)))
        XCTAssertTrue(c.project.track(named: "B-roll")!.transitions.isEmpty)
        XCTAssertFalse(result.warnings.isEmpty)
    }
}

final class EffectTests: XCTestCase {
    func testAddUpdateAndRemoveEffects() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Shadow", .addEffect(clipID: camera, effect: Effect(id: "fx_s", type: "dropShadow")))
        try c.run("Tweak", .updateEffect(clipID: camera, effectID: "fx_s", patch: .object(["params": .object(["opacity": .number(40)])])))
        XCTAssertEqual(c.project.clip(camera)?.video?.effects.first?.params["opacity"], .number(40))
        try c.run("Animate", .setKeyframes(clipID: camera, parameter: "video.effects.fx_s.opacity", keyframes: [
            Keyframe(time: .zero, value: .number(0)), Keyframe(time: t(1), value: .number(60))
        ]))
        XCTAssertEqual(c.project.clip(camera)?.resolvedVideo(at: t(2)).effects.first?.params["opacity"], .number(60))
        try c.run("Remove", .removeEffect(clipID: camera, effectID: "fx_s"))
        XCTAssertEqual(c.project.clip(camera)?.video?.effects, [])
        XCTAssertTrue(c.project.clip(camera)?.keyframes.isEmpty ?? false)
    }

    func testVideoEffectOnAudioClipFails() throws {
        let (f, c) = try Fixture.edited()
        XCTAssertThrowsError(try c.run("Shadow", .addEffect(clipID: f.clips("Music")[0].id, effect: Effect(type: "dropShadow"))))
    }

    func testUnknownEffectIsKeptWithAWarning() throws {
        let (f, c) = try Fixture.edited()
        let result = try c.run("Glitch", .addEffect(clipID: f.clips("Camera")[0].id, effect: Effect(type: "vhsGlitch")))
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testRegistryFillsDefaults() {
        let definition = EffectRegistry.standard.definition("dropShadow")!
        let values = definition.resolvedParams(Effect(type: "dropShadow", params: ["blur": .number(9)]))
        XCTAssertEqual(values["distance"], .number(4))
        XCTAssertEqual(values["blur"], .number(9))
    }
}

final class CoordinatorTests: XCTestCase {
    func testUndoAndRedo() throws {
        let (f, c) = try Fixture.edited()
        let before = c.project
        try c.run("Cut", .blade(at: t(10)))
        XCTAssertEqual(c.undoLabel, "Cut")
        c.undo()
        XCTAssertEqual(c.project, before)
        c.redo()
        XCTAssertEqual(c.clips("Camera").count, 2)
        _ = f
    }

    func testStaleRevisionIsRejected() throws {
        let (_, c) = try Fixture.edited()
        let revision = c.revision
        try c.run("Cut", .blade(at: t(10)))
        XCTAssertThrowsError(try c.apply(EditBatch(label: "Agent", author: "claude", commands: [.blade(at: t(20))], expectedRevision: revision))) { error in
            XCTAssertEqual(error as? EditError, .staleRevision(expected: revision, actual: revision + 1))
        }
    }

    func testIdempotencyKeyAppliesOnce() throws {
        let (_, c) = try Fixture.edited()
        let batch = EditBatch(label: "Cut", commands: [.blade(at: t(10))], idempotencyKey: "abc")
        let first = try c.apply(batch)
        let second = try c.apply(batch)
        XCTAssertEqual(first, second)
        XCTAssertEqual(c.clips("Camera").count, 2)
    }

    func testFailingCommandRollsBackTheWholeBatch() throws {
        let (f, c) = try Fixture.edited()
        let before = c.project
        XCTAssertThrowsError(try c.run("Two", .blade(at: t(10)), .removeClips(clipIDs: ["clip_missing"]))) { error in
            XCTAssertTrue("\(error)".contains("command 2 of 2"), "\(error)")
        }
        XCTAssertEqual(c.project, before)
        _ = f
    }

    func testObserversHearAboutEdits() throws {
        let (_, c) = try Fixture.edited()
        var events: [ProjectCoordinator.ChangeEvent.Kind] = []
        c.observe { events.append($0.kind) }
        try c.run("Cut", .blade(at: t(10)))
        c.undo()
        XCTAssertEqual(events, [.edit, .undo])
    }

    func testJournalReplayRecreatesTheSameIDs() throws {
        let fixture = Fixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = ProjectJournal(url: folder.appendingPathComponent("j.jsonl"))
        let c = ProjectCoordinator(project: fixture.project, journal: journal)
        try c.run("Place", .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(60)))
        try c.run("Cut", .blade(at: t(10)), .blade(at: t(20)))
        c.undo()
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(5), end: t(6))))
        let recovered = journal.recover(project: fixture.project, revision: 0)
        XCTAssertEqual(recovered?.project, c.project)
        XCTAssertEqual(recovered?.revision, c.revision)
    }
}

final class ValidatorTests: XCTestCase {
    func testOverlapIsAnError() {
        var project = Project.standard(name: "Bad")
        project.videoTracks[0].clips = [
            Clip(id: "clip_a", content: .solid(color: .black), start: t(0), duration: t(5)),
            Clip(id: "clip_b", content: .solid(color: .black), start: t(4), duration: t(5))
        ]
        let errors = ProjectValidator.validate(project).filter { $0.severity == .error }
        XCTAssertEqual(errors.map(\.objectID), ["clip_b"])
    }
}

/// Random edits must never break the timeline: no overlaps, valid media
/// ranges, and linked take clips staying aligned.
final class RandomEditTests: XCTestCase {
    func testRandomEditsKeepInvariants() throws {
        var rng = SplitMix64(seed: 42)
        var applied = 0
        var attempted = 0
        for round in 0..<8 {
            let (_, c) = try Fixture.edited()
            for step in 0..<60 {
                let project = c.project
                let clips = project.allTracks.flatMap(\.clips)
                guard let clip = clips.randomElement(using: &rng) else { break }
                let time = Time(seconds: Double(rng.next() % 6000) / 100)
                let small = Time(seconds: Double(rng.next() % 400) / 100 - 2)
                let commands: [EditCommand] = [
                    .blade(at: time),
                    .blade(at: time, clipIDs: [clip.id]),
                    .rippleDeleteRange(range: TimeRange(start: time, duration: Time(seconds: 0.5 + Double(rng.next() % 300) / 100))),
                    .trim(clipID: clip.id, edge: .end, to: clip.end + small, ripple: rng.next() % 2 == 0),
                    .trim(clipID: clip.id, edge: .start, to: clip.start + small, ripple: rng.next() % 2 == 0),
                    .removeClips(clipIDs: [clip.id], ripple: rng.next() % 2 == 0),
                    .moveClips(clipIDs: [clip.id], delta: small),
                    .slip(clipID: clip.id, delta: small),
                    .slide(clipID: clip.id, delta: small),
                    .setSpeed(clipID: clip.id, speed: [0.5, 1, 2, 4][Int(rng.next() % 4)], ripple: true),
                    .insertTime(at: time, duration: Time(seconds: 1))
                ]
                let command = commands[Int(rng.next() % UInt64(commands.count))]
                attempted += 1
                if (try? c.run("Random \(round).\(step)", command)) != nil { applied += 1 }
                let after = c.project
                assertValid(after)
                var groups: [String: [Clip]] = [:]
                for clip in after.allTracks.flatMap(\.clips) {
                    if let group = clip.linkGroup { groups[group, default: []].append(clip) }
                }
                for (_, members) in groups {
                    XCTAssertEqual(Set(members.map(\.range)).count, 1, "linked clips drifted apart after \(command)")
                }
                if after.allTracks.allSatisfy({ $0.clips.isEmpty }) { break }
            }
            // Whatever the edits did, the file round trip and undo must be exact.
            let data = try ProjectFile.encoder().encode(c.project)
            XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), c.project, "JSON round trip in round \(round)")
            let edited = c.project
            while c.undo() != nil {}
            XCTAssertEqual(c.project.allTracks.flatMap(\.clips).count, Fixture().project.allTracks.flatMap(\.clips).count)
            while c.redo() != nil {}
            XCTAssertEqual(c.project, edited)
        }
        // Make sure the test exercises real edits, not just rejected ones.
        XCTAssertGreaterThan(Double(applied) / Double(attempted), 0.4, "\(applied) of \(attempted) random edits applied")
    }
}
