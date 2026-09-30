import AppKit
import XCTest
@testable import TandemApp
import TandemAPI
@testable import TandemCore

/// The section card in the app: the Text tab's template (with and without
/// its whooshes), the inspector's edits, Timeline > Add section cards at
/// section markers, the timeline's label and the icons.
final class SectionCardAppTests: XCTestCase {
    /// The whooshes as `SectionCardSounds.use` hands them over once copied
    /// into a project.
    static let sounds = SectionCardSounds.Resolved(
        media: [
            MediaItem(id: "med_whooshin", path: "assets/sfx/whoosh-in.wav", kind: .audio, role: .sfx, duration: t(1.2), hasAudio: true),
            MediaItem(id: "med_whooshout", path: "assets/sfx/whoosh-out.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)
        ],
        soundIn: SectionCardSound(mediaID: "med_whooshin", gainDB: -14),
        soundOut: SectionCardSound(mediaID: "med_whooshout", gainDB: -19)
    )

    func card(in project: Project) -> Clip? {
        project.videoTracks.flatMap(\.clips).first { SectionCard.isCard($0.content) }
    }

    // MARK: - The template

    func testTheTileAddsOneCardClip() throws {
        let fixture = try AppFixture()
        let template = BuiltInTemplates.sectionCard
        XCTAssertEqual(template.clips.count, 1, "silent: one clip")
        let result = try fixture.apply(LibraryDrops.template(template, at: t(40)))
        let card = try XCTUnwrap(card(in: fixture.project))
        XCTAssertEqual(result.createdIDs.first { $0.hasPrefix("clip_") }, card.id)
        XCTAssertEqual(fixture.project.track(containingClip: card.id)?.name, "Graphics")
        XCTAssertEqual(card.start, t(40))
        XCTAssertEqual(card.duration, SectionCard.defaultDuration)
        let props = try XCTUnwrap(SectionCard.props(of: card))
        XCTAssertEqual(props.number, "01")
        XCTAssertEqual(props.title, "The leaderboard")
        XCTAssertEqual(props.subtitle, "Who's on top")
        assertValid(fixture.project)
    }

    func testTheTileBringsItsWhooshes() throws {
        let fixture = try AppFixture()
        let template = BuiltInTemplates.makeSectionCard(sounds: Self.sounds)
        try fixture.apply(LibraryDrops.template(template, at: t(40)))
        let card = try XCTUnwrap(card(in: fixture.project))
        let group = try XCTUnwrap(card.linkGroup, "the card and its sounds go together")
        let sounds = fixture.clips("SFX").filter { $0.linkGroup == group }
        XCTAssertEqual(sounds.map(\.mediaID), ["med_whooshin", "med_whooshout"])
        XCTAssertEqual(sounds.map(\.start), [t(40.2), t(40 + 3.2 - 0.88)])
        XCTAssertEqual(sounds.map { $0.audio?.gainDB }, [-14, -19])
        XCTAssertEqual(fixture.project.media("med_whooshin")?.path, "assets/sfx/whoosh-in.wav", "added with the card")
        // A second card uses the same files.
        try fixture.apply(LibraryDrops.template(template, at: t(50)))
        XCTAssertEqual(fixture.project.media.filter { $0.role == .sfx }.count, 2)
        assertValid(fixture.project)
    }

    /// The whooshes go where their offsets say: the section card's own
    /// start with their sweeps.
    func testTheTilePlacesTheWhooshesByTheirOffsets() {
        var sounds = Self.sounds
        sounds.soundIn.offset = .zero
        sounds.soundOut.offset = .zero
        let template = BuiltInTemplates.makeSectionCard(sounds: sounds)
        XCTAssertEqual(template.clips.map(\.offset), [.zero, .zero, t(3.2 - 0.88)])
        XCTAssertEqual(template.duration, SectionCard.fittedDuration(for: SectionCard.Props(title: "The leaderboard", subtitle: "Who's on top", number: "01")), "as long as its words need")
    }

    func testADropUsesTheWhooshesTheDragBroughtIn() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cards-\(UUID().uuidString)")
        XCTAssertNil(SectionCardSoundCache.shared.sounds(for: folder))
        SectionCardSoundCache.shared.set(Self.sounds, for: folder)
        XCTAssertEqual(SectionCardSoundCache.shared.sounds(for: folder), Self.sounds)
        XCTAssertEqual(BuiltInTemplates.template("sectionCard")?.clips.count, 3, "the card and a whoosh for each sweep")
        XCTAssertEqual(BuiltInTemplates.template("likeAndSubscribe")?.clips.count, 1)
        SectionCardSoundCache.shared.clear()
        XCTAssertEqual(BuiltInTemplates.template("sectionCard")?.clips.count, 1)
    }

    // MARK: - The inspector

    func testInspectorEditsPatchTheProps() throws {
        let fixture = try AppFixture()
        try fixture.apply(LibraryDrops.template(BuiltInTemplates.sectionCard, at: t(40)))
        var clip = try XCTUnwrap(card(in: fixture.project))
        func reread() throws { clip = try XCTUnwrap(fixture.project.clip(clip.id)) }

        XCTAssertNil(SectionCardEdits.set(clip, SectionCard.Key.title, text: "The leaderboard ", label: "Card title"), "no change, no edit")
        try fixture.apply(SectionCardEdits.set(clip, SectionCard.Key.title, text: "Methodology", label: "Card title"))
        try reread()
        try fixture.apply(SectionCardEdits.set(clip, SectionCard.Key.subtitle, text: "Let's keep it fair", label: "Card subtitle"))
        try reread()
        try fixture.apply(SectionCardEdits.total(clip, text: "3"))
        try reread()
        try fixture.apply(SectionCardEdits.set(clip, SectionCard.Key.kicker, text: "Section", label: "Card kicker"))
        try reread()
        var props = try XCTUnwrap(SectionCard.props(of: clip))
        XCTAssertEqual(props, SectionCard.Props(title: "Methodology", subtitle: "Let's keep it fair", number: "01", total: 3, kicker: "Section"))
        XCTAssertEqual(props.kickerLine, "Section 1 of 3")

        // Clearing a field removes the prop, so the card leaves it out.
        try fixture.apply(SectionCardEdits.set(clip, SectionCard.Key.subtitle, text: "", label: "Card subtitle"))
        try reread()
        try fixture.apply(SectionCardEdits.total(clip, text: "0"))
        try reread()
        guard case .graphic(let graphic) = clip.content else { return XCTFail("not a graphic") }
        XCTAssertNil(graphic.props[SectionCard.Key.subtitle])
        XCTAssertNil(graphic.props[SectionCard.Key.total])
        XCTAssertNil(SectionCardEdits.total(clip, text: "lots"), "not a number")

        // Colours: a change is a colour prop, Convex's own removes it.
        try fixture.apply(SectionCardEdits.colour(clip, SectionCard.Key.accent, RGBA(hex: 0x3366FF), label: "Card accent"))
        try reread()
        props = try XCTUnwrap(SectionCard.props(of: clip))
        XCTAssertEqual(props.colors.accent.hexString, "#3366FF")
        XCTAssertNil(SectionCardEdits.colour(clip, SectionCard.Key.accent, RGBA(hex: 0x3366FF), label: "Card accent"))
        try fixture.apply(SectionCardEdits.resetColours(clip))
        try reread()
        XCTAssertEqual(SectionCard.props(of: clip)?.colors, .convex)
        XCTAssertNil(SectionCardEdits.resetColours(clip))
        XCTAssertEqual(SectionCardEdits.kickers(current: "Tip"), ["", "Section", "Tip"])
        XCTAssertEqual(SectionCardEdits.kickers(current: "Chapter"), ["", "Section", "Tip", "Chapter"])
        assertValid(fixture.project)
    }

    func testTheCursorSwitch() throws {
        let fixture = try AppFixture()
        try fixture.apply(LibraryDrops.template(BuiltInTemplates.sectionCard, at: t(40)))
        var clip = try XCTUnwrap(card(in: fixture.project))
        func graphicProps() -> [String: ParamValue] {
            if case .graphic(let graphic) = clip.content { return graphic.props }
            return [:]
        }
        XCTAssertEqual(SectionCard.props(of: clip)?.cursor, true, "on by default")
        XCTAssertNil(SectionCardEdits.cursor(clip, on: true), "no change, no edit")
        let off = try XCTUnwrap(SectionCardEdits.cursor(clip, on: false))
        XCTAssertEqual(off.label, "No card cursor")
        try fixture.apply(off)
        clip = try XCTUnwrap(fixture.project.clip(clip.id))
        XCTAssertEqual(SectionCard.props(of: clip)?.cursor, false)
        XCTAssertEqual(graphicProps()[SectionCard.Key.cursor], .bool(false))
        try fixture.apply(SectionCardEdits.cursor(clip, on: true))
        clip = try XCTUnwrap(fixture.project.clip(clip.id))
        XCTAssertNil(graphicProps()[SectionCard.Key.cursor], "on is the default, so the prop goes")
    }

    /// Fit to text sets the card's length for its words and moves its
    /// whoosh out with the wipe out.
    func testFitToTextSetsTheLength() throws {
        let fixture = try AppFixture()
        try fixture.apply(LibraryDrops.template(BuiltInTemplates.makeSectionCard(sounds: Self.sounds), at: t(40)))
        var clip = try XCTUnwrap(card(in: fixture.project))
        XCTAssertNil(SectionCardEdits.fitToText(clip, in: fixture.project), "the tile's card fits its words already")
        try fixture.apply(SectionCardEdits.set(clip, SectionCard.Key.title, text: "Which decision model should you pick?", label: "Card title"))
        clip = try XCTUnwrap(fixture.project.clip(clip.id))
        let batch = try XCTUnwrap(SectionCardEdits.fitToText(clip, in: fixture.project))
        XCTAssertEqual(batch.label, "Fit card to text")
        try fixture.apply(batch)
        clip = try XCTUnwrap(fixture.project.clip(clip.id))
        // "Which decision model should you pick? Who's on top": 50
        // characters, 1.4 + 50 / 17 = 4.34 s, up to 4.4.
        XCTAssertEqual(clip.duration.seconds, 4.4, accuracy: 1e-9)
        XCTAssertEqual(clip.start, t(40))
        let sounds = fixture.clips("SFX").filter { $0.linkGroup == clip.linkGroup }.sorted { $0.start < $1.start }
        XCTAssertEqual(sounds.map(\.start), [t(40.2), t(40 + 4.4 - 0.88)], "the whoosh out moved with the wipe out")
        XCTAssertNil(SectionCardEdits.fitToText(clip, in: fixture.project))
        let props = try XCTUnwrap(SectionCard.props(of: clip))
        XCTAssertEqual(SectionCardEdits.fitHelp(props, length: clip.duration, frameRate: .fps30), "As long as its words need: 4.4 s for 50 characters.")
        XCTAssertTrue(SectionCardEdits.fitHelp(props, length: t(3.2), frameRate: .fps30).hasPrefix("Makes the card 4.4 s long"))
        XCTAssertEqual(SectionCardEdits.seconds(t(3.2)), "3.2 s")
        assertValid(fixture.project)
    }

    // MARK: - Add section cards at section markers

    func testCardsAtSectionMarkersInOneStep() throws {
        let fixture = try AppFixture()
        try fixture.apply(EditBatch(label: "Markers", commands: [
            .addMarker(marker: Marker(time: t(10), name: "Methodology", kind: .section)),
            .addMarker(marker: Marker(time: t(48), name: "Results", kind: .section))
        ]))
        XCTAssertTrue(SectionCardBatches.canAddAtMarkers(fixture.project))
        let batch = try XCTUnwrap(SectionCardBatches.atMarkers(fixture.project, sounds: Self.sounds))
        XCTAssertEqual(batch.label, "Section cards at 3 markers")
        let result = try fixture.apply(batch)
        let cards = fixture.project.videoTracks.flatMap(\.clips).filter { SectionCard.isCard($0.content) }.sorted { $0.start < $1.start }
        XCTAssertEqual(cards.compactMap { SectionCard.props(of: $0)?.label }, ["01 Methodology", "02 Section 2", "03 Results"])
        XCTAssertEqual(fixture.clips("SFX").count, 6, "two whooshes a card")
        XCTAssertEqual(fixture.project.media.filter { $0.role == .sfx }.count, 2)
        XCTAssertNotNil(fixture.coordinator.undo(), "one step")
        XCTAssertTrue(fixture.project.videoTracks.flatMap(\.clips).allSatisfy { !SectionCard.isCard($0.content) })
        XCTAssertFalse(result.createdIDs.isEmpty)
        // Silent without the whooshes.
        try fixture.apply(try XCTUnwrap(SectionCardBatches.atMarkers(fixture.project, sounds: nil)))
        XCTAssertTrue(fixture.clips("SFX").isEmpty)
    }

    func testNoSectionMarkersNoCommand() throws {
        var project = try AppFixture().project
        project.markers = [Marker(time: t(5), name: "Just a marker"), Marker(time: .zero, name: "Cold open", kind: .section)]
        XCTAssertFalse(SectionCardBatches.canAddAtMarkers(project))
        XCTAssertNil(SectionCardBatches.atMarkers(project, sounds: nil))
    }

    // MARK: - The timeline, menus and icons

    @MainActor
    func testTheTimelineNamesACardByItsNumberAndTitle() {
        let clip = Clip(content: SectionCard.content(SectionCard.Props(title: "Methodology", number: "01")), start: .zero, duration: t(3.2))
        XCTAssertEqual(ClipRenderer.name(of: clip, in: Project.standard(name: "X")), "01 Methodology")
        let blank = Clip(content: SectionCard.content(SectionCard.Props()), start: .zero, duration: t(3.2))
        XCTAssertEqual(ClipRenderer.name(of: blank, in: Project.standard(name: "X")), "Section card")
        let other = Clip(name: "Chart", content: .graphic(GraphicContent(template: "remotion:BarChart")), start: .zero, duration: t(3))
        XCTAssertEqual(ClipRenderer.name(of: other, in: Project.standard(name: "X")), "Chart")
    }

    @MainActor
    func testTheCommandHasAKeyATitleAndIcons() throws {
        XCTAssertEqual(EditorCommand.addSectionCards.title, "Add section cards at section markers")
        for name in [Icons.command(.addSectionCards)!, Icons.sectionCard, Icons.cardTitle, Icons.cardSubtitle, Icons.cardNumber, Icons.cardProgress, Icons.cardKicker, Icons.cardColours, Icons.cardCursor, Icons.cardLength] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }
}
