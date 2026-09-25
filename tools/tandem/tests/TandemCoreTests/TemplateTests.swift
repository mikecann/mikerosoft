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
}
