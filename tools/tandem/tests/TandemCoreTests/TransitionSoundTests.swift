import XCTest
@testable import TandemCore

/// A transition's sound is a clip of its own on SFX, tied to the transition
/// by `soundClipID`: it follows the transition's middle wherever an edit
/// takes it and goes when the transition goes, however that happens.
final class TransitionSoundTests: XCTestCase {
    /// A light swoosh, a second long.
    let swoosh = MediaItem(id: "med_swoosh", path: "assets/sfx/swoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)
    let whoosh = MediaItem(id: "med_whoosh", path: "assets/sfx/whoosh.wav", kind: .audio, role: .sfx, duration: t(1.5), hasAudio: true)

    /// The fixture's take cut at 30 s, with the swoosh in the media.
    func cutTake() throws -> (f: Fixture, c: ProjectCoordinator, left: String, right: String) {
        let (f, c) = try Fixture.edited()
        try c.run("Sounds", .addMedia(item: swoosh), .addMedia(item: whoosh))
        try c.run("Cut", .blade(at: t(30), clipIDs: [f.clips("Camera")[0].id]))
        return (f, c, c.clips("Camera")[0].id, c.clips("Camera")[1].id)
    }

    /// A 0.7 s push on the cut at 30 s with the swoosh, loudest 0.39 s in,
    /// peaking on the cut.
    @discardableResult
    func push(_ c: ProjectCoordinator, _ left: String, _ right: String, sound: TransitionSound? = TransitionSound(mediaID: "med_swoosh", gainDB: -23.3, offset: t(-0.39))) throws -> ProjectCoordinator.CommitResult {
        try c.run("Push", .addTransition(
            trackID: c.project.track(named: "Camera")!.id,
            transition: Transition(id: "tr_p", type: .push, duration: t(0.7), fromClipID: left, toClipID: right),
            sound: sound
        ))
    }

    func transition(_ c: ProjectCoordinator, _ id: String = "tr_p") -> Transition? {
        c.project.location(ofTransition: id).map { c.project[$0.track].transitions[$0.index] }
    }

    func sound(_ c: ProjectCoordinator, _ id: String = "tr_p") -> Clip? {
        transition(c, id)?.soundClipID.flatMap { c.project.clip($0) }
    }

    // MARK: - Where it goes

    func testTheSoundGoesOnSFXPeakingOnTheCut() throws {
        let (_, c, left, right) = try cutTake()
        let result = try push(c, left, right)
        let clip = try XCTUnwrap(sound(c))
        XCTAssertEqual(result.createdIDs, ["tr_p", clip.id], "the transition, then its sound")
        XCTAssertEqual(c.project.track(containingClip: clip.id)?.name, "SFX")
        XCTAssertEqual(clip.start, t(29.61), "0.39 s before the cut")
        XCTAssertEqual(clip.duration, t(1), "the whole file")
        XCTAssertEqual(clip.mediaID, "med_swoosh")
        XCTAssertEqual(clip.audio?.gainDB, -23.3)
        assertValid(c.project)
    }

    func testWithoutAnOffsetItStartsWithTheTransitionAtTheUsualGain() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right, sound: TransitionSound(mediaID: "med_swoosh"))
        let clip = try XCTUnwrap(sound(c))
        XCTAssertEqual(clip.start, t(29.65), "the push runs 29.65 to 30.35")
        XCTAssertEqual(clip.audio?.gainDB, TransitionSound.defaultGainDB)
    }

    func testTheWindowAndMiddle() throws {
        let (_, c, left, right) = try cutTake()
        let camera = c.project.track(named: "Camera")!
        let centred = Transition(type: .push, duration: t(0.7), fromClipID: left, toClipID: right)
        XCTAssertEqual(centred.window(on: camera), TimeRange(start: t(29.65), end: t(30.35)))
        XCTAssertEqual(centred.middle(on: camera), t(30))
        let head = Transition(type: .fadeFromBlack, duration: t(1), fromClipID: nil, toClipID: right)
        XCTAssertEqual(head.window(on: camera), TimeRange(start: t(30), end: t(31)))
        XCTAssertEqual(head.middle(on: camera), t(30.5))
        let tail = Transition(type: .fadeToBlack, duration: t(100), fromClipID: right, toClipID: nil)
        XCTAssertEqual(tail.window(on: camera), TimeRange(start: t(30), end: t(60)), "never longer than its clip")
        let apart = Transition(type: .push, duration: t(1), fromClipID: right, toClipID: left)
        XCTAssertNil(apart.window(on: camera), "clips that don't meet")
    }

    /// A sound already on SFX there leaves it be: the swoosh goes on a new
    /// SFX track, as the section cards' whooshes do.
    func testATakenSFXTrackGetsASecond() throws {
        let (_, c, left, right) = try cutTake()
        let sfx = c.project.track(named: "SFX")!.id
        try c.run("Hit", .placeMedia(mediaIDs: ["med_whoosh"], at: t(29.5), audioTrackID: sfx))
        try push(c, left, right)
        XCTAssertEqual(c.project.track(containingClip: try XCTUnwrap(sound(c)).id)?.name, "SFX 2")
        XCTAssertEqual(c.project.track(named: "SFX 2")?.rippleMode, .follow)
        assertValid(c.project)
    }

    func testTheSoundNeedsSoundInTheProject() throws {
        let (_, c, left, right) = try cutTake()
        try c.run("Still", .addMedia(item: MediaItem(id: "med_still", path: "images/slide.png", kind: .image, role: .image, width: 1920, height: 1080)))
        XCTAssertThrowsError(try push(c, left, right, sound: TransitionSound(mediaID: "med_nothing")))
        XCTAssertThrowsError(try push(c, left, right, sound: TransitionSound(mediaID: "med_still")), "a still has no sound")
        XCTAssertNil(transition(c), "nothing half done")
    }

    // MARK: - Going with the transition

    func testRemovingTheTransitionRemovesItsSoundAndUndoBringsBothBack() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let soundID = try XCTUnwrap(sound(c)).id
        try c.run("Remove", .removeTransition(transitionID: "tr_p"))
        XCTAssertNil(c.project.clip(soundID))
        XCTAssertTrue(c.project.track(named: "SFX")!.clips.isEmpty)
        c.undo()
        XCTAssertEqual(sound(c)?.id, soundID)
        XCTAssertEqual(sound(c)?.start, t(29.61))
        c.undo()
        XCTAssertNil(transition(c))
        XCTAssertNil(c.project.clip(soundID), "undoing the add takes the sound too")
        c.redo()
        XCTAssertEqual(sound(c)?.id, soundID)
    }

    func testDeletingAClipItJoinsRemovesTheSound() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let soundID = try XCTUnwrap(sound(c)).id
        try c.run("Lift", .removeClips(clipIDs: [right]))
        XCTAssertNil(transition(c))
        XCTAssertNil(c.project.clip(soundID))
        assertValid(c.project)
    }

    func testMovingTheClipsApartRemovesTheSound() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let soundID = try XCTUnwrap(sound(c)).id
        let result = try c.run("Move", .moveClips(clipIDs: [right], delta: t(5)))
        XCTAssertNil(transition(c))
        XCTAssertNil(c.project.clip(soundID))
        XCTAssertTrue(result.warnings.contains { $0.contains("moved apart") })
        assertValid(c.project)
    }

    /// Cutting away the clip it plays out of takes the transition, and the
    /// sound, which the ripple had squashed to the start, goes too.
    func testRippleDeletingAClipItJoinsRemovesTheSound() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let soundID = try XCTUnwrap(sound(c)).id
        try c.run("Ripple", .rippleDeleteRange(range: TimeRange(start: .zero, end: t(30))))
        XCTAssertNil(transition(c))
        XCTAssertNil(c.project.clip(soundID))
        assertValid(c.project)
    }

    /// A section card making room at the cut takes the transition's place,
    /// and its sound with it.
    func testASectionCardThatMakesRoomTakesTheSound() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let soundID = try XCTUnwrap(sound(c)).id
        try c.run("Card", .addSectionCards(markerIDs: ["mk_s2"], mode: .insert))
        XCTAssertNil(transition(c))
        XCTAssertNil(c.project.clip(soundID))
        assertValid(c.project)
    }

    func testRemovingTheTrackRemovesTheSound() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let soundID = try XCTUnwrap(sound(c)).id
        try c.run("Remove track", .removeTrack(trackID: c.project.track(named: "Camera")!.id))
        XCTAssertNil(c.project.clip(soundID))
    }

    // MARK: - Following it

    func testRollingTheCutTakesTheSoundAlong() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        try c.run("Roll", .roll(leftClipID: left, rightClipID: right, delta: t(1)))
        XCTAssertEqual(sound(c)?.start, t(30.61))
        assertValid(c.project)
    }

    func testRipplingTheTakeMovesTheSoundWithIt() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(10), duration: t(2))))
        XCTAssertEqual(sound(c)?.start, t(27.61))
        try c.run("Room", .insertTime(at: t(5), duration: t(3)))
        XCTAssertEqual(sound(c)?.start, t(30.61))
        assertValid(c.project)
    }

    /// A ripple through the sound (a pause cut from around the cut) would
    /// chop its tail on SFX; it goes with the transition whole instead.
    func testARippleThroughTheSoundKeepsItWhole() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(29.8), end: t(30.2))))
        XCTAssertNotNil(transition(c), "the clips still meet, at 29.8")
        let clip = try XCTUnwrap(sound(c))
        XCTAssertEqual(clip.start, t(29.41))
        XCTAssertEqual(clip.duration, t(1))
        assertValid(c.project)
    }

    /// A ripple that takes all of the sound but leaves the transition (the
    /// clips still meet, at the new cut) brings the sound back with it.
    func testARippleThatSwallowsTheSoundBringsItBack() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let soundID = try XCTUnwrap(sound(c)).id
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(29.5), end: t(30.7))))
        XCTAssertNotNil(transition(c), "the clips meet at 29.5 now")
        let clip = try XCTUnwrap(sound(c))
        XCTAssertEqual(clip.id, soundID)
        XCTAssertEqual(clip.start, t(29.11), "0.39 s before the new cut")
        XCTAssertEqual(clip.duration, t(1))
        assertValid(c.project)
    }

    func testMovingBothClipsCarriesTheSound() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        try c.run("Move", .moveClips(clipIDs: [left, right], delta: t(5)))
        XCTAssertNotNil(transition(c))
        XCTAssertEqual(sound(c)?.start, t(34.61))
        assertValid(c.project)
    }

    /// The swoosh stays on the cut whatever the push's length: a longer
    /// push is slower around the same moment.
    func testChangingTheLengthKeepsTheSoundOnTheCut() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        try c.run("Longer", .updateTransition(transitionID: "tr_p", patch: .object(["duration": .number(1.2)])))
        XCTAssertEqual(sound(c)?.start, t(29.61))
        try c.run("Type", .updateTransition(transitionID: "tr_p", patch: .object(["type": .string("wipe")])))
        XCTAssertEqual(sound(c)?.start, t(29.61), "a new type keeps the sound where it is")
    }

    /// A fade at a clip's head has its middle move with its length, and
    /// the sound goes along.
    func testAFadeAtAClipsHeadCarriesItsSoundAsItGrows() throws {
        let (_, c, _, right) = try cutTake()
        try c.run("Fade", .addTransition(
            trackID: c.project.track(named: "Camera")!.id,
            transition: Transition(id: "tr_f", type: .fadeFromBlack, duration: t(1), fromClipID: nil, toClipID: right),
            sound: TransitionSound(mediaID: "med_swoosh", offset: .zero)
        ))
        XCTAssertEqual(sound(c, "tr_f")?.start, t(30.5))
        try c.run("Longer", .updateTransition(transitionID: "tr_f", patch: .object(["duration": .number(2)])))
        XCTAssertEqual(sound(c, "tr_f")?.start, t(31))
        // Its gain changed in the same patch still leaves it in step.
        try c.run("Shorter", .updateTransition(transitionID: "tr_f", patch: .object(["duration": .number(1), "sound": .object(["gainDB": .number(-20)])])))
        XCTAssertEqual(sound(c, "tr_f")?.start, t(30.5))
        XCTAssertEqual(sound(c, "tr_f")?.audio?.gainDB, -20)
    }

    /// Mike can nudge the sound; it keeps the nudge as the transition moves.
    func testANudgedSoundKeepsItsNudge() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let soundID = try XCTUnwrap(sound(c)).id
        try c.run("Nudge", .moveClips(clipIDs: [soundID], delta: t(0.1)))
        XCTAssertEqual(sound(c)?.start, t(29.71), "the nudge stays")
        try c.run("Roll", .roll(leftClipID: left, rightClipID: right, delta: t(-1)))
        XCTAssertEqual(sound(c)?.start, t(28.71))
        try c.run("Trim", .trim(clipID: soundID, edge: .end, to: t(29.3)))
        XCTAssertEqual(sound(c)?.duration, t(0.59), "trimmed, and still its sound")
        XCTAssertEqual(transition(c)?.soundClipID, soundID)
    }

    func testCuttingTheSoundKeepsTheTieOnItsFirstPart() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let soundID = try XCTUnwrap(sound(c)).id
        try c.run("Cut", .blade(at: t(30), trackIDs: [c.project.track(named: "SFX")!.id]))
        XCTAssertEqual(transition(c)?.soundClipID, soundID)
        XCTAssertEqual(c.project.track(named: "SFX")?.clips.count, 2)
    }

    // MARK: - The sound on its own

    func testDeletingTheSoundLeavesTheTransitionSilent() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        try c.run("Delete", .removeClips(clipIDs: [try XCTUnwrap(sound(c)).id]))
        XCTAssertNotNil(transition(c))
        XCTAssertNil(transition(c)?.soundClipID)
        assertValid(c.project)
    }

    func testOverwritingTheSoundLeavesTheTransitionSilent() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let sfx = c.project.track(named: "SFX")!.id
        try c.run("Over", .placeMedia(mediaIDs: ["med_music"], at: t(29), duration: t(3), mode: .overwrite, audioTrackID: sfx))
        XCTAssertNil(transition(c)?.soundClipID)
        assertValid(c.project)
    }

    func testASoundOnALockedTrackStaysPutAndSaysSo() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let sfx = c.project.track(named: "SFX")!.id
        try c.run("Lock", .updateTrack(trackID: sfx, patch: .object(["locked": .bool(true)])))
        let rolled = try c.run("Roll", .roll(leftClipID: left, rightClipID: right, delta: t(1)))
        XCTAssertEqual(sound(c)?.start, t(29.61))
        XCTAssertTrue(rolled.warnings.contains { $0.contains("locked") }, "\(rolled.warnings)")
        let removed = try c.run("Remove", .removeTransition(transitionID: "tr_p"))
        XCTAssertEqual(c.project.track(named: "SFX")?.clips.count, 1, "left where it is")
        XCTAssertTrue(removed.warnings.contains { $0.contains("locked") }, "\(removed.warnings)")
        assertValid(c.project)
    }

    // MARK: - Changing it

    func testUpdateTransitionChangesTheSound() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right, sound: nil)
        func update(_ sound: JSONValue) throws {
            try c.run("Sound", .updateTransition(transitionID: "tr_p", patch: .object(["sound": sound])))
        }
        XCTAssertThrowsError(try update(.object(["gainDB": .number(-20)])), "no sound yet, so it needs a file")
        try update(.object(["mediaID": .string("med_swoosh"), "offset": .number(-0.39)]))
        let soundID = try XCTUnwrap(sound(c)).id
        XCTAssertEqual(sound(c)?.start, t(29.61))
        XCTAssertEqual(sound(c)?.audio?.gainDB, -15)

        try update(.object(["gainDB": .number(-23.3)]))
        XCTAssertEqual(sound(c)?.audio?.gainDB, -23.3)
        XCTAssertEqual(sound(c)?.start, t(29.61), "a gain doesn't move it")

        try update(.object(["offset": .number(-0.5)]))
        XCTAssertEqual(sound(c)?.start, t(29.5))

        // Another file keeps the clip, where it starts and its gain.
        try update(.object(["mediaID": .string("med_whoosh")]))
        XCTAssertEqual(sound(c)?.id, soundID)
        XCTAssertEqual(sound(c)?.mediaID, "med_whoosh")
        XCTAssertEqual(sound(c)?.duration, t(1.5))
        XCTAssertEqual(sound(c)?.start, t(29.5))
        XCTAssertEqual(sound(c)?.audio?.gainDB, -23.3)

        try update(.null)
        XCTAssertNil(transition(c)?.soundClipID)
        XCTAssertNil(c.project.clip(soundID))
        assertValid(c.project)

        XCTAssertThrowsError(try update(.object(["mediaID": .string("med_swoosh"), "volume": .number(3)])))
        XCTAssertThrowsError(try update(.string("swoosh")))
    }

    func testALockedSoundCantBeChanged() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        try c.run("Lock", .updateTrack(trackID: c.project.track(named: "SFX")!.id, patch: .object(["locked": .bool(true)])))
        XCTAssertThrowsError(try c.run("Gain", .updateTransition(transitionID: "tr_p", patch: .object(["sound": .object(["gainDB": .number(-10)])]))))
        XCTAssertThrowsError(try c.run("None", .updateTransition(transitionID: "tr_p", patch: .object(["sound": .null]))))
        XCTAssertEqual(sound(c)?.audio?.gainDB, -23.3)
    }

    func testTheSoundIsChangedWithSoundNotItsClipID() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let soundID = try XCTUnwrap(sound(c)).id
        XCTAssertThrowsError(try c.run("Point", .updateTransition(transitionID: "tr_p", patch: .object(["soundClipID": .string("clip_other")]))))
        // Sending back what it has, as an agent echoing the transition does, is fine.
        XCTAssertNoThrow(try c.run("Echo", .updateTransition(transitionID: "tr_p", patch: .object(["soundClipID": .string(soundID), "duration": .number(0.8)]))))
    }

    /// A sound already on the timeline can be given to a new transition.
    func testASoundAlreadyThereCanBeTied() throws {
        let (_, c, left, right) = try cutTake()
        let sfx = c.project.track(named: "SFX")!.id
        try c.run("Whoosh", .insertClip(trackID: sfx, clip: Clip(id: "clip_whoosh", content: .media(mediaID: "med_whoosh"), start: t(29), duration: t(1.5))))
        try c.run("Push", .addTransition(
            trackID: c.project.track(named: "Camera")!.id,
            transition: Transition(id: "tr_p", type: .push, duration: t(0.7), fromClipID: left, toClipID: right, soundClipID: "clip_whoosh")
        ))
        try c.run("Roll", .roll(leftClipID: left, rightClipID: right, delta: t(1)))
        XCTAssertEqual(c.project.clip("clip_whoosh")?.start, t(30))
        XCTAssertThrowsError(try c.run("Both", .addTransition(
            trackID: c.project.track(named: "Camera")!.id,
            transition: Transition(type: .fadeToBlack, duration: t(1), fromClipID: right, toClipID: nil, soundClipID: "clip_whoosh")
        )), "one transition's sound")
        XCTAssertThrowsError(try c.run("Picture", .addTransition(
            trackID: c.project.track(named: "Camera")!.id,
            transition: Transition(type: .fadeToBlack, duration: t(1), fromClipID: right, toClipID: nil, soundClipID: left)
        )), "a picture isn't a sound")
    }

    // MARK: - The file

    func testTheTieIsWrittenAndReadAndOldFilesHaveNone() throws {
        let tied = Transition(id: "tr_a", type: .push, duration: t(0.7), fromClipID: "clip_a", toClipID: "clip_b", soundClipID: "clip_s")
        let data = try JSONEncoder().encode(tied)
        XCTAssertEqual(try JSONDecoder().decode(Transition.self, from: data), tied)
        let old = #"{"id": "tr_a", "type": "push", "duration": 0.7, "fromClipID": "clip_a", "toClipID": "clip_b"}"#
        XCTAssertNil(try JSONDecoder().decode(Transition.self, from: Data(old.utf8)).soundClipID)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(Transition(type: .push, duration: t(1), fromClipID: "a", toClipID: "b")), as: UTF8.self).contains("soundClipID"), "silent ones don't write it")
    }

    func testValidationCatchesABrokenTie() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        var broken = c.project
        let camera = broken.location(ofTrack: broken.track(named: "Camera")!.id)!
        broken[camera].transitions[0].soundClipID = "clip_gone"
        XCTAssertTrue(ProjectValidator.validate(broken).contains { $0.severity == .error && $0.message.contains("isn't a clip on an audio track") })
        broken[camera].transitions[0].soundClipID = left
        XCTAssertTrue(ProjectValidator.validate(broken).contains { $0.severity == .error && $0.message.contains("isn't a clip on an audio track") })
        var shared = c.project
        let soundID = shared[camera].transitions[0].soundClipID
        shared[camera].transitions.append(Transition(type: .fadeToBlack, duration: t(1), fromClipID: right, toClipID: nil, soundClipID: soundID))
        XCTAssertTrue(ProjectValidator.validate(shared).contains { $0.severity == .error && $0.message.contains("two transitions") })
    }

    /// Edits of a project with sounds replay the same from the journal:
    /// a new SFX track made while keeping sounds in step gets the same ID.
    func testReplayMakesTheSameTracks() throws {
        let (_, c, left, right) = try cutTake()
        try push(c, left, right)
        let sfx = c.project.track(named: "SFX")!.id
        try c.run("Busy", .placeMedia(mediaIDs: ["med_whoosh"], at: t(31), audioTrackID: sfx))
        let batch = EditBatch(label: "Roll", commands: [.roll(leftClipID: left, rightClipID: right, delta: t(1))])
        func run() throws -> Project {
            var project = c.project
            var context = EditContext(seed: 42)
            for command in batch.commands { try Editing.apply(command, to: &project, context: &context) }
            return project
        }
        let first = try run()
        XCTAssertEqual(first.track(containingClip: try XCTUnwrap(transition(c)?.soundClipID))?.name, "SFX 2", "SFX is busy at 30.61")
        XCTAssertEqual(first, try run())
    }
}
