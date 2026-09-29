import XCTest
@testable import TandemCore

final class SectionCardPropsTests: XCTestCase {
    func testPropsAreReadLeniently() {
        let props = SectionCard.Props([
            "title": .string("Methodology"), "subtitle": .string("Let's keep it fair"),
            "number": .number(1), "total": .string("3"), "kicker": .string("Section"),
            "accent": .string("#112233"), "band3": .color(RGBA(r: 0, g: 0, b: 1))
        ])
        XCTAssertEqual(props.number, "01", "a number is written with two digits")
        XCTAssertEqual(props.total, 3)
        XCTAssertEqual(props.index, 1)
        XCTAssertEqual(props.kickerLine, "Section 1 of 3")
        XCTAssertEqual(props.colors.accent, RGBA(hex: 0x112233))
        XCTAssertEqual(props.colors.band2, SectionCard.Colors.convex.band2)
        XCTAssertEqual(props.colors.band3, RGBA(r: 0, g: 0, b: 1))
        XCTAssertEqual(props.label, "01 Methodology")
        XCTAssertEqual(SectionCard.Props(props.params), props, "props survive a round trip")

        let plain = SectionCard.Props(title: "Results")
        XCTAssertEqual(plain.params, ["title": .string("Results")], "empty words, no total and Convex's colours are left out")
        XCTAssertEqual(SectionCard.Props([:]).label, "Section card")
        XCTAssertEqual(SectionCard.Props(["title": .string("A\nB")]).label, "A B")
    }

    func testProgressFollowsCardD() {
        XCTAssertEqual(SectionCard.Props(number: "02", total: 3).progress, .bars(count: 3, lit: 2))
        XCTAssertEqual(SectionCard.Props(number: "06", total: 6).progress, .bars(count: 6, lit: 6))
        let list = SectionCard.Props(number: "03", total: 14)
        XCTAssertEqual(list.progress, .proportional(index: 3, total: 14), "past six sections, a bar in proportion")
        XCTAssertEqual(list.progress?.countText, "3 / 14")
        XCTAssertNil(SectionCard.Props(number: "01").progress, "no total, no bars")
        XCTAssertNil(SectionCard.Props(number: "A", total: 3).progress, "a number that isn't one")
        XCTAssertNil(SectionCard.Props(number: "04", total: 3).progress, "past the total")
        XCTAssertEqual(SectionCard.Props(number: "", total: 3, kicker: "Tip").kickerLine, "Tip")
        XCTAssertEqual(SectionCard.Props(number: "07", kicker: "Tip").kickerLine, "Tip 7")
        XCTAssertNil(SectionCard.Props(number: "01", total: 3).kickerLine)
    }

    func testCubicBezierMatchesCSS() {
        let ease = CubicBezier(0.25, 0.1, 0.25, 1)
        XCTAssertEqual(ease.value(at: 0.5), 0.8024033877399112, accuracy: 1e-6, "CSS ease at 50%")
        let sweep = SectionCard.Motion.sweepEasing
        XCTAssertEqual(sweep.value(at: 0.5), 0.5, accuracy: 1e-9)
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(sweep.value(at: x) + sweep.value(at: 1 - x), 1, accuracy: 1e-6, "symmetric")
            XCTAssertLessThanOrEqual(sweep.value(at: x), sweep.value(at: min(1, x + 0.05)) + 1e-12, "never goes back")
        }
        XCTAssertEqual(CubicBezier(0, 0, 1, 1).value(at: 0.3), 0.3, accuracy: 1e-9)
        XCTAssertEqual(sweep.value(at: -1), 0)
        XCTAssertEqual(sweep.value(at: 2), 1)
    }
}

final class SectionCardMotionTests: XCTestCase {
    let motion = SectionCard.Motion(duration: 3.2)

    func testTimingIsTheMockups() {
        XCTAssertEqual(motion.timeScale, 1)
        XCTAssertEqual([0, 1, 2].map(motion.inStart), [0, 0.08, 0.16])
        XCTAssertEqual(motion.outStart(0), 2.32, accuracy: 1e-9)
        XCTAssertEqual(motion.outStart(2) + motion.sweepLength, 3.2, accuracy: 1e-9, "the last band leaves as the card ends")
        // A longer card only holds longer.
        let long = SectionCard.Motion(duration: 5)
        XCTAssertEqual(long.inStart(2), motion.inStart(2))
        XCTAssertEqual(5 - long.outStart(0), 3.2 - motion.outStart(0), accuracy: 1e-9)
        XCTAssertEqual(long.contentProgress(at: 0.97), motion.contentProgress(at: 0.97))
    }

    func testBandsSweepAcrossAndLeaveTheFrame() throws {
        // Half way through the first band's sweep it's half way along, as
        // the mockup's translateX(360%) of a band 46% wide put it (372%
        // here, so it clears the frame).
        let middle = try XCTUnwrap(motion.band(0, sweepStartingAt: 0, at: 0.36))
        XCTAssertEqual(middle.left, -0.62 + 0.5 * 3.72 * 0.46, accuracy: 1e-6)
        XCTAssertEqual(middle.leftEdge(atY: 0) - middle.leftEdge(atY: 9.0 / 16), tan(16 * Double.pi / 180) * 9 / 16, accuracy: 1e-9, "skewed 16 degrees, top to the right")
        // Off the frame to the left when it starts, off to the right as it ends.
        let first = try XCTUnwrap(motion.band(0, sweepStartingAt: 0, at: 0))
        XCTAssertLessThan(first.rightEdge(atY: 0), 0)
        let last = try XCTUnwrap(motion.band(0, sweepStartingAt: 0, at: 0.7199))
        XCTAssertGreaterThan(last.leftEdge(atY: 9.0 / 16), 0.999, "the mockup's 360% left a sliver bottom right")
        XCTAssertNil(motion.band(0, sweepStartingAt: 0, at: 0.72))
        // A tall frame leans the bands more; they still start off and leave.
        let tall = SectionCard.Motion(duration: 3.2, aspect: 16.0 / 9)
        let start = try XCTUnwrap(tall.band(0, sweepStartingAt: 0, at: 0))
        XCTAssertLessThan(start.rightEdge(atY: 0), 0)
        let end = try XCTUnwrap(tall.band(0, sweepStartingAt: 0, at: 0.71999))
        XCTAssertGreaterThan(end.leftEdge(atY: 16.0 / 9), 0.999)
    }

    func testTheCardIsRevealedBehindTheBands() throws {
        XCTAssertEqual(motion.reveal(at: 1.5), .whole)
        let entering = motion.reveal(at: 0.3)
        XCTAssertNotNil(entering.before, "behind the first band on the way in")
        XCTAssertNil(entering.after)
        let leaving = motion.reveal(at: 3.0)
        XCTAssertNotNil(leaving.after, "the next shot behind the last band on the way out")
        XCTAssertTrue(motion.reveal(at: 3.2).hidden)
        XCTAssertTrue(motion.reveal(at: -0.1).hidden)
        XCTAssertEqual(motion.bands(at: 1.5).count, 0)
        XCTAssertEqual(motion.bands(at: 0.3).map(\.index), [0, 1, 2])
        XCTAssertEqual(motion.contentProgress(at: 0.5), 0)
        XCTAssertEqual(motion.contentProgress(at: 0.97), 1)

        let covered = try XCTUnwrap(motion.covered)
        XCTAssertEqual(covered.lowerBound, 0.43, accuracy: 0.02, "the before shot is gone once the first band has passed")
        XCTAssertEqual(covered.upperBound, 3.2 - 0.41, accuracy: 0.02, "the next shot shows as the last band comes in")
        let before = try XCTUnwrap(motion.band(0, sweepStartingAt: 0, at: covered.lowerBound))
        XCTAssertEqual(before.rightEdge(atY: 9.0 / 16), 1, accuracy: 1e-4)
    }

    func testShortCardsShrinkBothWipes() throws {
        let short = SectionCard.Motion(duration: 1.2)
        XCTAssertEqual(short.timeScale, 1.2 / 1.76, accuracy: 1e-9)
        XCTAssertEqual(short.outStart(2) + short.sweepLength, 1.2, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(short.inStart(2) + short.sweepLength, short.outStart(0) + 1e-9, "the wipes never overlap")
    }
}

final class SectionCardCommandTests: XCTestCase {
    /// The fixture's take (0 to 60 s) with section markers: the cold open
    /// at 0, Methodology at 12 (with a note), a plain marker at 20, the
    /// fixture's own Section 2 at 30, and Results at 45.
    func marked() throws -> (Fixture, ProjectCoordinator) {
        let (fixture, c) = try Fixture.edited()
        try c.run("Markers",
            .addMarker(marker: Marker(id: "mk_open", time: .zero, name: "Cold open", kind: .section)),
            .addMarker(marker: Marker(id: "mk_method", time: t(12), name: "Methodology", kind: .section, note: "Let's keep it fair")),
            .addMarker(marker: Marker(id: "mk_plain", time: t(20), name: "Look here")),
            .addMarker(marker: Marker(id: "mk_results", time: t(45), name: "Results", kind: .section))
        )
        return (fixture, c)
    }

    func cards(_ c: ProjectCoordinator) -> [(clip: Clip, props: SectionCard.Props)] {
        c.project.videoTracks.flatMap(\.clips).compactMap { clip in SectionCard.props(of: clip).map { (clip, $0) } }.sorted { $0.clip.start < $1.clip.start }
    }

    func testACardAtEverySectionMarkerAfterTheStart() throws {
        let (_, c) = try marked()
        let before = c.project
        let result = try c.run("Cards", .addSectionCards())
        let made = cards(c)
        XCTAssertEqual(made.map(\.props.number), ["01", "02", "03"])
        XCTAssertEqual(made.map(\.props.title), ["Methodology", "Section 2", "Results"], "titles from the marker names; the cold open and the plain marker get none")
        XCTAssertEqual(made.map(\.props.total), [3, 3, 3])
        XCTAssertEqual(made[0].props.subtitle, "Let's keep it fair", "the subtitle from the note")
        XCTAssertEqual(made[1].props.subtitle, "")
        XCTAssertEqual(Set(made.map { c.project.track(containingClip: $0.clip.id)?.name }), ["Graphics"])
        let covered = try XCTUnwrap(SectionCard.Motion(duration: 3.2, aspect: 9.0 / 16).covered)
        for (card, marker) in zip(made, [t(12), t(30), t(45)]) {
            XCTAssertEqual(card.clip.duration, SectionCard.defaultDuration)
            XCTAssertEqual(card.clip.start.frameIndex(at: .fps30) * FrameRate.fps30.flicksPerFrame, card.clip.start.flicks, "on a frame")
            XCTAssertLessThanOrEqual(card.clip.start + Time(seconds: covered.lowerBound), marker, "the card hides the frame from the marker on")
            XCTAssertGreaterThan(card.clip.start + Time(seconds: covered.lowerBound + 0.034), marker)
        }
        // Nothing else moved.
        XCTAssertEqual(c.project.track(named: "Camera")?.clips, before.track(named: "Camera")?.clips)
        XCTAssertEqual(c.project.markers, before.markers)
        XCTAssertEqual(result.createdIDs.count, 3)
        XCTAssertNil(made[0].clip.linkGroup, "no sounds, nothing to link")
        assertValid(c.project)
        // One undo step takes them all away.
        XCTAssertNotNil(c.undo())
        XCTAssertTrue(cards(c).isEmpty)
    }

    func testSoundsGoOnSFXLinkedToTheirCard() throws {
        let (_, c) = try marked()
        try c.run("Whooshes",
            .addMedia(item: MediaItem(id: "med_in", path: "assets/sfx/in.wav", kind: .audio, role: .sfx, duration: t(1.2), hasAudio: true)),
            .addMedia(item: MediaItem(id: "med_out", path: "assets/sfx/out.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)),
            // Something already on SFX where the second card's whoosh goes.
            .addMedia(item: MediaItem(id: "med_click", path: "sfx/click.wav", kind: .audio, role: .sfx, duration: t(2), hasAudio: true)),
            .insertClip(trackID: c.project.track(named: "SFX")!.id, clip: Clip(id: "clip_click", content: .media(mediaID: "med_click"), start: t(29.5), duration: t(2)))
        )
        try c.run("Cards", .addSectionCards(soundIn: SectionCardSound(mediaID: "med_in", gainDB: -14), soundOut: SectionCardSound(mediaID: "med_out")))
        let made = cards(c)
        XCTAssertEqual(made.count, 3)
        for card in made {
            let group = try XCTUnwrap(card.clip.linkGroup)
            let sounds = c.project.audioTracks.flatMap(\.clips).filter { $0.linkGroup == group }.sorted { $0.start < $1.start }
            XCTAssertEqual(sounds.map(\.mediaID), ["med_in", "med_out"])
            XCTAssertEqual(sounds[0].start, card.clip.start + t(0.2), "the whoosh in, 0.2 s into the card")
            XCTAssertEqual(sounds[0].audio?.gainDB, -14)
            XCTAssertEqual(sounds[1].start, card.clip.start + t(3.2 - 0.88), "the whoosh out, as the out sweep starts")
            XCTAssertEqual(sounds[1].audio?.gainDB, -15, "sound effects' usual gain")
        }
        XCTAssertEqual(c.clips("SFX").first { $0.id == "clip_click" }?.duration, t(2), "a sound already there isn't cut")
        let second = try XCTUnwrap(c.project.track(named: "SFX 2"), "made where SFX is taken")
        XCTAssertEqual(second.rippleMode, .follow)
        XCTAssertEqual(second.clips.count, 1)
        assertValid(c.project)
    }

    func testRunningAgainRenumbersAndKeepsTheWords() throws {
        let (_, c) = try marked()
        try c.run("Cards", .addSectionCards())
        let methodology = try XCTUnwrap(cards(c).first)
        try c.run("Subtitle", .updateClip(clipID: methodology.clip.id, patch: .object(["content": .object(["graphic": .object(["props": .object(["subtitle": .string("Fair and square")])])])])))
        try c.run("Intro", .addMarker(marker: Marker(time: t(6), name: "Intro", kind: .section)))
        try c.run("Cards again", .addSectionCards(kicker: "Section"))
        let made = cards(c)
        XCTAssertEqual(made.map(\.props.title), ["Intro", "Methodology", "Section 2", "Results"])
        XCTAssertEqual(made.map(\.props.number), ["01", "02", "03", "04"])
        XCTAssertEqual(Set(made.map(\.props.total)), [4])
        XCTAssertEqual(Set(made.map(\.props.kicker)), ["Section"])
        XCTAssertEqual(made[1].clip.id, methodology.clip.id, "the card that was there stays")
        XCTAssertEqual(made[1].props.subtitle, "Fair and square", "and keeps its words")
        XCTAssertEqual(made[1].clip.start, methodology.clip.start)
        assertValid(c.project)
    }

    func testInsertMakesRoomSoTheWipesShowBothShots() throws {
        let (_, c) = try marked()
        let cameraBefore = c.clips("Camera")
        try c.run("Cards", .addSectionCards(markerIDs: ["mk_method"], mode: .insert))
        let card = try XCTUnwrap(cards(c).first)
        let motion = SectionCard.Motion(duration: 3.2, aspect: 9.0 / 16)
        let covered = try XCTUnwrap(motion.covered)
        let camera = c.clips("Camera")
        XCTAssertEqual(camera.count, cameraBefore.count + 1, "the take is cut at the marker")
        XCTAssertEqual(camera[0].end, t(12), "the section before plays up to the marker, under the wipe in")
        let reveal = card.clip.start + Time(seconds: covered.upperBound)
        XCTAssertEqual(camera[1].start.seconds, reveal.seconds, accuracy: 1.0 / 30, "the next section starts as the wipe out shows it")
        XCTAssertLessThanOrEqual(camera[1].start, reveal)
        XCTAssertEqual(c.project.markers.first { $0.id == "mk_method" }?.time, camera[1].start, "the marker moves with its section")
        XCTAssertEqual(c.project.markers.first { $0.id == "mk_results" }?.time, t(45) + (camera[1].start - t(12)))
        XCTAssertEqual(card.props.total, 1)
        assertValid(c.project)
    }

    /// A transition on the cut at the marker can't survive room made there;
    /// the card covers that cut, so it takes the transition's place.
    func testInsertReplacesATransitionOnTheSectionCut() throws {
        let (_, c) = try marked()
        try c.run("Cut", .blade(at: t(12), clipIDs: [c.clips("Camera")[0].id]))
        let camera = c.clips("Camera")
        try c.run("Dissolve", .addTransition(trackID: c.project.track(named: "Camera")!.id, transition: Transition(id: "tr_cut", type: .dissolve, duration: t(0.5), fromClipID: camera[0].id, toClipID: camera[1].id)))
        let result = try c.run("Cards", .addSectionCards(markerIDs: ["mk_method"], mode: .insert))
        XCTAssertFalse(c.project.track(named: "Camera")!.transitions.contains { $0.id == "tr_cut" })
        XCTAssertTrue(result.warnings.contains { $0.contains("dissolve") && $0.contains("section card covers that cut") }, "\(result.warnings)")
        XCTAssertEqual(cards(c).count, 1)
        assertValid(c.project)
    }

    func testMistakesAreExplained() throws {
        let (fixture, c) = try Fixture.edited()
        var plain = fixture.project
        plain.markers = []
        let empty = ProjectCoordinator(project: plain)
        XCTAssertThrowsError(try empty.run("Cards", .addSectionCards())) { error in
            XCTAssertTrue("\(error)".contains("section markers"), "\(error)")
        }
        XCTAssertThrowsError(try c.run("Cards", .addSectionCards(markerIDs: ["mk_nope"])))
        XCTAssertThrowsError(try c.run("Cards", .addSectionCards(trackID: c.project.track(named: "Music")!.id)))
        XCTAssertThrowsError(try c.run("Cards", .addSectionCards(duration: t(0.5))))
        XCTAssertThrowsError(try c.run("Cards", .addSectionCards(soundIn: SectionCardSound(mediaID: "med_screen_nope"))))
        // place fails where the card track is taken.
        try c.run("Solid", .insertClip(trackID: c.project.track(named: "Graphics")!.id, clip: Clip(content: .solid(color: .black), start: t(29), duration: t(3))))
        XCTAssertThrowsError(try c.run("Cards", .addSectionCards(mode: .place)))
        // overwrite (the default) replaces it.
        XCTAssertNoThrow(try c.run("Cards", .addSectionCards()))
    }

    func testCommandJSON() throws {
        let json = #"{"addSectionCards": {"markerIDs": ["mk_a"], "kicker": "Tip", "mode": "insert", "duration": 4, "soundIn": {"mediaID": "med_in", "gainDB": -14, "offset": 0.1}}}"#
        let command = try JSONDecoder().decode(EditCommand.self, from: Data(json.utf8))
        XCTAssertEqual(command, .addSectionCards(markerIDs: ["mk_a"], duration: t(4), kicker: "Tip", mode: .insert, soundIn: SectionCardSound(mediaID: "med_in", gainDB: -14, offset: t(0.1))))
        let bare = try JSONDecoder().decode(EditCommand.self, from: Data(#"{"addSectionCards": {}}"#.utf8))
        XCTAssertEqual(bare, .addSectionCards())
    }
}

final class SectionCardTemplateTests: XCTestCase {
    func testGraphicPropsTakeTemplateFields() throws {
        let (_, c) = try Fixture.edited()
        let whoosh = MediaItem(id: "med_whoosh", path: "assets/sfx/whoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)
        let template = Template(id: "card", name: "Card", duration: t(3.2), fields: [TemplateField(key: "title", label: "Title", defaultValue: "Untitled")], clips: [
            TemplateClip(track: "Graphics", clip: Clip(content: .graphic(GraphicContent(template: SectionCard.template, props: ["title": .string("{{title}}"), "number": .string("0{{n}}")])), start: .zero, duration: t(3.2))),
            TemplateClip(track: "SFX", trackKind: .audio, offset: t(0.2), clip: Clip(content: .media(mediaID: ""), start: .zero, duration: t(1)), media: whoosh)
        ])
        try c.run("Card", .insertTemplate(template: template, at: t(40), values: ["title": "Results", "n": "2"], mode: .overwrite))
        let card = try XCTUnwrap(c.clips("Graphics").first)
        XCTAssertEqual(SectionCard.props(of: card)?.title, "Results")
        XCTAssertEqual(SectionCard.props(of: card)?.number, "02")
        XCTAssertEqual(c.project.media("med_whoosh")?.path, "assets/sfx/whoosh.wav", "the template brought its sound")
        XCTAssertEqual(c.clips("SFX").first?.mediaID, "med_whoosh")
        // Again: the sound is in the project now, so it's used, not added twice.
        try c.run("Card", .insertTemplate(template: template, at: t(50), mode: .overwrite))
        XCTAssertEqual(c.project.media.filter { $0.path == whoosh.path }.count, 1)
        XCTAssertEqual(SectionCard.props(of: c.clips("Graphics").last!)?.title, "Untitled")
        assertValid(c.project)
    }
}
