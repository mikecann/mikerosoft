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

final class SectionCardCursorTests: XCTestCase {
    func testTheCursorIsAPropOnByDefault() {
        XCTAssertTrue(SectionCard.Props().cursor)
        XCTAssertTrue(SectionCard.Props([:]).cursor)
        XCTAssertNil(SectionCard.Props(title: "Results").params[SectionCard.Key.cursor], "on is the default, so it's left out")
        let off = SectionCard.Props(title: "Results", cursor: false)
        XCTAssertEqual(off.params[SectionCard.Key.cursor], .bool(false))
        XCTAssertEqual(SectionCard.Props(off.params), off, "a round trip")
        // Read leniently, like the other props.
        XCTAssertFalse(SectionCard.Props(["cursor": .string("off")]).cursor)
        XCTAssertFalse(SectionCard.Props(["cursor": .string("false")]).cursor)
        XCTAssertFalse(SectionCard.Props(["cursor": .number(0)]).cursor)
        XCTAssertTrue(SectionCard.Props(["cursor": .string("on")]).cursor)
        XCTAssertTrue(SectionCard.Props(["cursor": .bool(true)]).cursor)
        XCTAssertTrue(SectionCard.Key.all.contains(SectionCard.Key.cursor))
    }

    /// Like a terminal's: it comes in with the words, is lit as the title
    /// lands (0.97 s), then goes off and on every 0.53 s with hard steps,
    /// and is gone once the wipe out starts.
    func testTheCursorBlinksLikeATerminal() {
        let motion = SectionCard.Motion(duration: 3.2)
        XCTAssertEqual(motion.cursorLands, 0.97, accuracy: 1e-9)
        XCTAssertFalse(motion.cursorLit(at: 0.3), "not before the words come in")
        XCTAssertTrue(motion.cursorLit(at: 0.6), "in with the words")
        XCTAssertTrue(motion.cursorLit(at: 0.97), "lit as the title lands")
        XCTAssertTrue(motion.cursorLit(at: 0.97 + 0.529))
        XCTAssertFalse(motion.cursorLit(at: 0.97 + 0.531), "then off")
        XCTAssertFalse(motion.cursorLit(at: 0.97 + 1.059))
        XCTAssertTrue(motion.cursorLit(at: 0.97 + 1.061), "and on again")
        XCTAssertTrue(motion.cursorLit(at: motion.outStart(0) - 0.001))
        XCTAssertFalse(motion.cursorLit(at: motion.outStart(0)), "gone with the wipe out")
        XCTAssertFalse(motion.cursorLit(at: 3.1))

        // All through a long hold: off at 1.50 s, on at 2.03, off 2.56, on
        // 3.09, off 3.62; the next spell would start after the wipe out
        // does (4.12).
        let long = SectionCard.Motion(duration: 5)
        var switches: [Double] = []
        var previous = long.cursorLit(at: 1)
        for frame in 30..<150 {
            let lit = long.cursorLit(at: Double(frame) / 30)
            if lit != previous { switches.append(Double(frame) / 30) }
            previous = lit
        }
        XCTAssertEqual(switches.count, 5)
        for (got, wanted) in zip(switches, [1.5, 2.03, 2.56, 3.09, 3.62]) {
            XCTAssertEqual(got, wanted, accuracy: 1.0 / 30)
        }

        // A lit spell the wipe out would cut to a flash isn't started.
        let brief = SectionCard.Motion(duration: 3.0)
        XCTAssertLessThan(brief.outStart(0) - (brief.cursorLands + 2 * SectionCard.Motion.cursorBlink), SectionCard.Motion.cursorBlink / 2)
        XCTAssertFalse(brief.cursorLit(at: brief.cursorLands + 2 * SectionCard.Motion.cursorBlink + 0.01))
    }
}

final class SectionCardFitTests: XCTestCase {
    /// 1.4 s for the wipes and 0.8 s to take the card in, then 15
    /// characters a second (spaces included) for the title, subtitle and
    /// kicker, rounded up to a tenth of a second, from 4 s to 7 s.
    func testTheLengthFitsTheWords() {
        func fitted(_ props: SectionCard.Props) -> Double { SectionCard.fittedDuration(for: props).seconds }
        let usual = SectionCard.Props(title: "Methodology", subtitle: "Let's keep it fair", number: "01", total: 3)
        XCTAssertEqual(usual.readingText, "Methodology Let's keep it fair")
        XCTAssertEqual(fitted(usual), 4.2, accuracy: 1e-9, "2.2 + 30 / 15")
        XCTAssertEqual(fitted(SectionCard.Props(title: "Results")), 4, accuracy: 1e-9, "at least 4 s")
        XCTAssertEqual(fitted(SectionCard.Props()), 4, accuracy: 1e-9)

        let tip = SectionCard.Props(title: "Low change cost", subtitle: "Just do it & reverse", number: "01", total: 14, kicker: "Tip")
        XCTAssertEqual(tip.readingText, "Low change cost Just do it & reverse Tip 1 of 14", "the kicker as the card shows it")
        XCTAssertEqual(tip.readingText.count, 48)
        XCTAssertEqual(fitted(tip), 5.4, accuracy: 1e-9, "2.2 + 48 / 15")

        let long = SectionCard.Props(title: "Why deterministic decision models beat vibes", subtitle: "And how we measured it across fourteen real tasks")
        XCTAssertEqual(fitted(long), 7, accuracy: 1e-9, "at most 7 s")

        // Spaces and line breaks count once.
        XCTAssertEqual(SectionCard.Props(title: "Low\nchange   cost ").readingText, "Low change cost")
        // On a frame at the project's rate: Mike's ESLint card needs
        // 2.2 + 46 / 15 = 5.27 s, up to 5.3, which is 132.5 frames at 25.
        let eslint = SectionCard.Props(title: "The one I would turn on", subtitle: "Require access control", number: "03", total: 5)
        XCTAssertEqual(fitted(eslint), 5.3, accuracy: 1e-9)
        let at25 = SectionCard.fittedDuration(for: eslint, frameRate: .fps25)
        XCTAssertEqual(at25.frameIndex(at: .fps25) * FrameRate.fps25.flicksPerFrame, at25.flicks)
        XCTAssertEqual(at25.seconds, 5.32, accuracy: 1e-9, "so 133 frames")
        XCTAssertEqual(SectionCard.fittedDuration(for: eslint, frameRate: .fps30).seconds, 5.3, accuracy: 1e-9)
    }

    /// Fit to text: the card's length, and its whoosh out moved with the
    /// sweep out; the whoosh in stays.
    func testFittingACardMovesItsWhooshOut() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Sounds",
            .addMedia(item: MediaItem(id: "med_in", path: "assets/sfx/in.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)),
            .addMedia(item: MediaItem(id: "med_out", path: "assets/sfx/out.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)),
            .addMarker(marker: Marker(id: "mk_tip", time: t(12), name: "Low change cost", kind: .section, note: "Just do it & reverse"))
        )
        try c.run("Card", .addSectionCards(duration: t(3.2), soundIn: SectionCardSound(mediaID: "med_in", offset: .zero), soundOut: SectionCardSound(mediaID: "med_out")))
        let card = try XCTUnwrap(c.clips("Graphics").first)
        let group = try XCTUnwrap(card.linkGroup)
        func sounds() -> [Clip] { c.project.audioTracks.flatMap(\.clips).filter { $0.linkGroup == group }.sorted { $0.start < $1.start } }
        let before = sounds()
        XCTAssertEqual(before.map(\.start), [card.start, card.start + t(3.2 - 0.88)])

        let commands = try SectionCard.fitToText(card.id, in: c.project)
        XCTAssertFalse(commands.isEmpty)
        try c.apply(EditBatch(label: "Fit to text", commands: commands))
        let fitted = try XCTUnwrap(c.project.clip(card.id))
        XCTAssertEqual(fitted.start, card.start, "it keeps its start")
        XCTAssertEqual(fitted.duration.seconds, 4.6, accuracy: 1e-9, "36 characters: 2.2 + 36 / 15 = 4.6")
        let after = sounds()
        XCTAssertEqual(after[0].start, before[0].start, "the whoosh in stays")
        XCTAssertEqual(after[1].start, fitted.start + Time(seconds: SectionCard.Motion(duration: fitted.duration.seconds).outStart(0)), "the whoosh out lands on the sweep out")
        XCTAssertEqual(try SectionCard.fitToText(card.id, in: c.project), [], "already fitted")
        XCTAssertThrowsError(try SectionCard.fitToText(c.clips("Camera")[0].id, in: c.project), "not a card")
        assertValid(c.project)
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
        for (card, marker) in zip(made, [t(12), t(30), t(45)]) {
            let covered = try XCTUnwrap(SectionCard.Motion(duration: card.clip.duration.seconds, aspect: 9.0 / 16).covered)
            XCTAssertEqual(card.clip.duration, SectionCard.fittedDuration(for: card.props, frameRate: .fps30), "as long as its words need")
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
            XCTAssertEqual(sounds[1].start, card.clip.start + Time(seconds: SectionCard.Motion(duration: card.clip.duration.seconds).outStart(0)), "the whoosh out, as the out sweep starts")
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

    /// Each card is as long as its words need, unless a length is given;
    /// its whoosh out follows its own sweep out.
    func testEachCardFitsItsWords() throws {
        let (_, c) = try marked()
        try c.run("Long", .updateMarker(markerID: "mk_results", patch: .object([
            "name": .string("Which decision model should you pick?"), "note": .string("Three questions to ask first")
        ])))
        try c.run("Whooshes",
            .addMedia(item: MediaItem(id: "med_in", path: "assets/sfx/in.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)),
            .addMedia(item: MediaItem(id: "med_out", path: "assets/sfx/out.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true))
        )
        // "Which decision model should you pick? Three questions to ask
        // first" is 66 characters: 2.2 + 66 / 15 = 6.6 s.
        let placements = try SectionCard.placements(in: c.project, markerIDs: nil)
        XCTAssertEqual(placements.map { ($0.duration.seconds * 10).rounded() / 10 }, [4.2, 4, 6.6])
        // A kicker is read too: "Methodology Let's keep it fair Section 1
        // of 3" is 45 characters, 5.2 s, and the long one reaches 7 s.
        let kicked = try SectionCard.placements(in: c.project, markerIDs: nil, kicker: "Section")
        XCTAssertEqual(kicked.map { ($0.duration.seconds * 10).rounded() / 10 }, [5.2, 4, 7])
        try c.run("Cards", .addSectionCards(soundIn: SectionCardSound(mediaID: "med_in"), soundOut: SectionCardSound(mediaID: "med_out")))
        let made = cards(c)
        XCTAssertEqual(made.map(\.clip.duration), placements.map(\.duration))
        let last = try XCTUnwrap(made.last)
        let sounds = c.project.audioTracks.flatMap(\.clips).filter { $0.linkGroup == last.clip.linkGroup }.sorted { $0.start < $1.start }
        XCTAssertEqual(sounds.last?.start, last.clip.start + Time(seconds: SectionCard.Motion(duration: last.clip.duration.seconds).outStart(0)), "the whoosh out on its own sweep out")
        let covered = try XCTUnwrap(SectionCard.Motion(duration: last.clip.duration.seconds).covered)
        XCTAssertLessThanOrEqual(last.clip.start + Time(seconds: covered.lowerBound), t(45), "a long card still hides its cut")
        assertValid(c.project)

        // A length given is every card's.
        XCTAssertNotNil(c.undo())
        try c.run("Cards", .addSectionCards(duration: t(4)))
        XCTAssertEqual(Set(cards(c).map(\.clip.duration)), [t(4)])
    }

    /// fitSectionCards refits cards made at an older length: each gets the
    /// length its words need, keeping its start, and its whoosh out moves
    /// with its sweep out. One undo step, and nothing ripples.
    func testFittingEveryCardAtOnce() throws {
        let (_, c) = try marked()
        try c.run("Whooshes",
            .addMedia(item: MediaItem(id: "med_in", path: "assets/sfx/in.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)),
            .addMedia(item: MediaItem(id: "med_out", path: "assets/sfx/out.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true))
        )
        // Cards as they used to be made: 3.2 s each.
        try c.run("Cards", .addSectionCards(duration: t(3.2), soundIn: SectionCardSound(mediaID: "med_in"), soundOut: SectionCardSound(mediaID: "med_out")))
        let before = cards(c)
        XCTAssertEqual(Set(before.map(\.clip.duration)), [t(3.2)])
        let camera = c.clips("Camera")
        try c.run("Fit", .fitSectionCards())
        let after = cards(c)
        XCTAssertEqual(after.map(\.clip.id), before.map(\.clip.id))
        XCTAssertEqual(after.map(\.clip.start), before.map(\.clip.start), "each keeps its start")
        XCTAssertEqual(after.map(\.clip.duration), after.map { SectionCard.fittedDuration(for: $0.props, frameRate: .fps30) })
        for card in after {
            let sounds = c.project.audioTracks.flatMap(\.clips).filter { $0.linkGroup == card.clip.linkGroup }.sorted { $0.start < $1.start }
            XCTAssertEqual(sounds.first?.start, card.clip.start + t(0.2), "the whoosh in stays")
            XCTAssertEqual(sounds.last?.start, card.clip.start + Time(seconds: SectionCard.Motion(duration: card.clip.duration.seconds).outStart(0)), "the whoosh out on its sweep out")
        }
        XCTAssertEqual(c.clips("Camera"), camera, "nothing ripples")
        assertValid(c.project)
        XCTAssertNotNil(c.undo())
        XCTAssertEqual(cards(c).map(\.clip.duration), before.map(\.clip.duration), "one undo step")

        // Just the cards named; already fitted ones are left alone.
        try c.run("Fit one", .fitSectionCards(clipIDs: [before[0].clip.id]))
        XCTAssertEqual(cards(c).map(\.clip.duration.seconds), [4.2, 3.2, 3.2])
        try c.run("Fit all", .fitSectionCards())
        let fitted = cards(c).map(\.clip)
        XCTAssertNoThrow(try c.run("Again", .fitSectionCards()), "nothing left to fit is fine, so a batch with it still works")
        XCTAssertEqual(cards(c).map(\.clip), fitted)
        XCTAssertThrowsError(try c.run("Camera", .fitSectionCards(clipIDs: [camera[0].id])), "not a card")
    }

    func testFittingNeedsCards() throws {
        let (_, c) = try marked()
        XCTAssertThrowsError(try c.run("Fit", .fitSectionCards())) { error in
            XCTAssertEqual(error as? EditError, .invalid("there are no section cards to fit"))
        }
    }

    func testInsertMakesRoomSoTheWipesShowBothShots() throws {
        let (_, c) = try marked()
        let cameraBefore = c.clips("Camera")
        try c.run("Cards", .addSectionCards(markerIDs: ["mk_method"], mode: .insert))
        let card = try XCTUnwrap(cards(c).first)
        let motion = SectionCard.Motion(duration: card.clip.duration.seconds, aspect: 9.0 / 16)
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
