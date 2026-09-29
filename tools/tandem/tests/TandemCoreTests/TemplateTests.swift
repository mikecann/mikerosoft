import XCTest
@testable import TandemCore

final class TemplateTests: XCTestCase {
    /// A cut-down section card: a background, a title with a placeholder, a
    /// number, and a whoosh.
    func sectionCard() throws -> Template {
        let json = #"""
        {
          "id": "sectionCard",
          "name": "Section card",
          "duration": 3.3,
          "fields": [{"key": "number", "label": "Number", "defaultValue": "1"}, {"key": "title", "label": "Title"}],
          "clips": [
            {"track": "Graphics", "clip": {"content": {"solid": {"color": {"r": 0.1, "g": 0.1, "b": 0.1}}}, "duration": 3.3}},
            {"track": "Text", "offset": 0.2, "clip": {"content": {"text": {"text": "TIP {{number}}", "preset": "label"}}, "duration": 3}},
            {"track": "Text 2", "offset": 0.4, "clip": {"content": {"text": {"text": "{{title}}", "preset": "sectionHeader"}}, "duration": 2.8}},
            {"track": "SFX", "trackKind": "audio", "clip": {"duration": 1, "audio": {"gainDB": -15}}, "mediaPath": "sfx/whoosh.wav"}
          ]
        }
        """#
        return try JSONDecoder().decode(Template.self, from: Data(json.utf8))
    }

    func testInsertExpandsIntoLinkedClips() throws {
        let (_, c) = try Fixture.edited()
        try c.run("SFX", .addMedia(item: MediaItem(id: "med_whoosh", path: "sfx/whoosh.wav", kind: .audio, role: .sfx, duration: t(1.2), hasAudio: true)))
        let result = try c.run("Card", .insertTemplate(template: try sectionCard(), at: t(30), values: ["title": "CURSOR DOCS"]))
        XCTAssertEqual(result.createdIDs.filter { $0.hasPrefix("clip_") }.count, 4)
        let text = c.clips("Text")[0]
        XCTAssertEqual(text.start, t(30.2))
        guard case .text(let content) = text.content else { return XCTFail("not text") }
        XCTAssertEqual(content.text, "TIP 1")
        guard case .text(let title) = c.clips("Text 2")[0].content else { return XCTFail("not text") }
        XCTAssertEqual(title.text, "CURSOR DOCS")
        XCTAssertEqual(c.clips("SFX")[0].mediaID, "med_whoosh")
        let groups = Set(result.createdIDs.compactMap { c.project.clip($0)?.linkGroup })
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(c.clips("Graphics")[0].tags.contains("template:sectionCard"))
        assertValid(c.project)
    }

    func testMissingTemplateMediaFails() throws {
        let (_, c) = try Fixture.edited()
        XCTAssertThrowsError(try c.run("Card", .insertTemplate(template: try sectionCard(), at: t(30))))
    }

    /// An intro card that fades up from black and dissolves into a second
    /// card, as a template.
    func testTransitionsComeWithTheClipsTheyJoin() throws {
        let (_, c) = try Fixture.edited()
        let json = #"""
        {"id": "intro", "name": "Intro", "duration": 4, "clips": [
          {"track": "Graphics", "clip": {"content": {"solid": {"color": {"r": 0, "g": 0, "b": 0}}}, "duration": 2}},
          {"track": "Graphics", "offset": 2, "clip": {"content": {"solid": {"color": {"r": 1, "g": 1, "b": 1}}}, "duration": 2}},
          {"track": "Text", "offset": 0.5, "clip": {"content": {"text": {"text": "HELLO"}}, "duration": 1}}
        ], "transitions": [
          {"to": 0, "type": "fadeFromBlack", "duration": 0.5},
          {"from": 0, "to": 1, "type": "dissolve", "duration": 0.5}
        ]}
        """#
        let template = try JSONDecoder().decode(Template.self, from: Data(json.utf8))
        XCTAssertEqual(template.transitions.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(Template.self, from: try JSONEncoder().encode(template)), template, "round trips")
        let result = try c.run("Intro", .insertTemplate(template: template, at: t(40), mode: .overwrite))
        let graphics = try XCTUnwrap(c.project.track(named: "Graphics"))
        let cards = graphics.clips.sorted { $0.start < $1.start }
        XCTAssertEqual(cards.map(\.start), [t(40), t(42)])
        let transitions = graphics.transitions.sorted { $0.type.rawValue > $1.type.rawValue }
        XCTAssertEqual(transitions.map(\.type), [.fadeFromBlack, .dissolve])
        XCTAssertEqual(transitions[0].toClipID, cards[0].id)
        XCTAssertNil(transitions[0].fromClipID)
        XCTAssertEqual(transitions[1].fromClipID, cards[0].id)
        XCTAssertEqual(transitions[1].toClipID, cards[1].id)
        XCTAssertTrue(result.createdIDs.contains(transitions[1].id))
        assertValid(c.project)

        // A transition between clips on two tracks, or on a clip it hasn't, fails.
        var crossing = template
        crossing.transitions = [TemplateTransition(from: 1, to: 2, type: .dissolve, duration: t(0.5))]
        XCTAssertThrowsError(try c.run("Crossing", .insertTemplate(template: crossing, at: t(50), mode: .overwrite)))
        crossing.transitions = [TemplateTransition(from: nil, to: 7, type: .dissolve, duration: t(0.5))]
        XCTAssertThrowsError(try c.run("Nowhere", .insertTemplate(template: crossing, at: t(50), mode: .overwrite)))
    }

    /// A saved segment's clips carry the media items for their files, so
    /// inserting it adds them, once, keeping their IDs when they're free.
    func testCarriedMediaIsAddedOnceWhenTheProjectLacksIt() throws {
        let (_, c) = try Fixture.edited()
        let path = "/Users/mike/Movies/Tandem Library/Segments/Intro/sting.wav"
        let sting = MediaItem(id: "med_sting", path: "sting.wav", kind: .audio, role: .sfx, duration: t(2), hasAudio: true)
        let json = #"""
        {"id": "segment:Intro", "name": "Intro", "duration": 2, "clips": [
          {"track": "SFX", "trackKind": "audio", "clip": {"duration": 1, "audio": {"gainDB": -15}}, "mediaPath": "PATH", "media": {"id": "med_sting", "path": "sting.wav", "kind": "audio", "role": "sfx", "duration": 2, "hasAudio": true}},
          {"track": "SFX", "trackKind": "audio", "offset": 1, "clip": {"duration": 1, "sourceStart": 1}, "mediaPath": "PATH", "media": {"id": "med_sting", "path": "sting.wav", "kind": "audio", "role": "sfx", "duration": 2, "hasAudio": true}}
        ]}
        """#.replacingOccurrences(of: "PATH", with: path)
        let template = try JSONDecoder().decode(Template.self, from: Data(json.utf8))
        XCTAssertEqual(template.clips[0].media?.id, sting.id)
        XCTAssertEqual(try JSONDecoder().decode(Template.self, from: try JSONEncoder().encode(template)), template, "round trips")

        try c.run("Intro", .insertTemplate(template: template, at: t(40), mode: .overwrite))
        let added = c.project.media.filter { $0.path == path }
        XCTAssertEqual(added.map(\.id), ["med_sting"], "added once, with its own ID")
        XCTAssertEqual(c.clips("SFX").map(\.mediaID), ["med_sting", "med_sting"])
        assertValid(c.project)

        // Again: the file is in the project now, so nothing more is added.
        try c.run("Intro again", .insertTemplate(template: template, at: t(50), mode: .overwrite))
        XCTAssertEqual(c.project.media.filter { $0.path == path }.count, 1)
        XCTAssertEqual(c.clips("SFX").count, 4)

        // A project already using the ID for another file gets a new one.
        var other = template
        other.clips = [other.clips[0]]
        other.clips[0].mediaPath = "/elsewhere/Segments/Outro/sting.wav"
        try c.run("Outro", .insertTemplate(template: other, at: t(55), mode: .overwrite))
        let second = try XCTUnwrap(c.project.media.first { $0.path == "/elsewhere/Segments/Outro/sting.wav" })
        XCTAssertNotEqual(second.id, "med_sting")
        XCTAssertTrue(second.id.hasPrefix("med_"))
        assertValid(c.project)
    }
}
