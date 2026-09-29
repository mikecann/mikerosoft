import XCTest
@testable import TandemCore

/// Title styles: a field a clip sets wins over its preset, even when it's
/// the default value, and projects saved before that keep their look.
final class TextStyleTests: XCTestCase {
    let yellow = RGBA(r: 1, g: 0.8, b: 0.16)

    /// Stands in for a preset that shouts, outlines, boxes and shadows.
    var loud: TextStyle.Resolved {
        TextStyle(strokeColor: .black, strokeWidth: 6, backgroundColor: yellow, uppercase: true, shadow: true).resolved()
    }

    func testExplicitFalseAndZeroBeatThePreset() {
        let own = TextStyle(strokeWidth: 0, uppercase: false, shadow: false)
        let style = own.resolved(over: loud)
        XCTAssertFalse(style.uppercase)
        XCTAssertFalse(style.shadow)
        XCTAssertEqual(style.strokeWidth, 0)
        XCTAssertFalse(style.hasOutline)
        XCTAssertEqual(style.backgroundColor, yellow, "the box wasn't touched")
    }

    func testUnsetFieldsInheritThePreset() {
        XCTAssertEqual(TextStyle().resolved(over: loud), loud)
        let bigger = TextStyle(size: 120).resolved(over: loud)
        XCTAssertEqual(bigger.size, 120)
        XCTAssertTrue(bigger.uppercase)
        XCTAssertTrue(bigger.hasOutline)
        // With nothing under it, a style falls back to the defaults.
        XCTAssertEqual(TextStyle().resolved(), TextStyle.defaults)
        XCTAssertEqual(TextStyle(uppercase: true).over(TextStyle(size: 80, uppercase: false)), TextStyle(size: 80, uppercase: true))
    }

    func testASeeThroughBoxOrOutlineSwitchesThePresetsOff() {
        let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
        let style = TextStyle(strokeColor: clear, backgroundColor: clear).resolved(over: loud)
        XCTAssertNil(style.backgroundColor)
        XCTAssertFalse(style.hasOutline)
    }

    func testDecodingKeepsOnlyTheFieldsGiven() throws {
        let style = try JSONDecoder().decode(TextStyle.self, from: Data(#"{"uppercase": false, "size": 64, "font": null}"#.utf8))
        XCTAssertEqual(style, TextStyle(size: 64, uppercase: false))
        XCTAssertEqual(style.setFields, ["size", "uppercase"])
        XCTAssertTrue(try JSONDecoder().decode(TextStyle.self, from: Data("{}".utf8)).isEmpty)
    }

    func testTitlesWriteOnlyWhatTheySet() throws {
        func json(_ content: TextContent) throws -> [String: Any] {
            let data = try JSONEncoder().encode(content)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let caption = try json(TextContent(text: "Hi there", preset: "caption"))
        XCTAssertEqual(Set(caption.keys), ["text", "preset"], "no style or animation length the preset didn't ask for")
        let own = try json(TextContent(text: "url", preset: "label", style: TextStyle(uppercase: false)))
        XCTAssertEqual(own["style"] as? [String: Bool], ["uppercase": false])
        let content = TextContent(text: "x", preset: "callout", style: TextStyle(size: 90, shadow: false), animationDuration: t(0.5))
        XCTAssertEqual(try JSONDecoder().decode(TextContent.self, from: JSONEncoder().encode(content)), content)
    }

    func testAnUpdatePatchCanSetAndClearAField() throws {
        let clip = Clip(id: "clip_t", content: .text(TextContent(text: "url", preset: "label")), start: .zero, duration: t(2))
        let patch = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"content": {"text": {"style": {"uppercase": false}}}}"#.utf8))
        let set = try JSONValue.applyMergePatch(patch, to: clip)
        guard case .text(let text) = set.content else { return XCTFail("not text") }
        XCTAssertEqual(text.style, TextStyle(uppercase: false))
        let clear = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"content": {"text": {"style": {"uppercase": null}}}}"#.utf8))
        guard case .text(let cleared) = try JSONValue.applyMergePatch(clear, to: set).content else { return XCTFail("not text") }
        XCTAssertTrue(cleared.style.isEmpty, "null takes the preset's value back")
    }

    // MARK: - Old files

    /// A schema 1 file as the old app wrote it: every field of every style.
    static let oldFile = #"""
    {"revision": 3, "project": {"schemaVersion": 1, "id": "prj_old", "name": "Old", "videoTracks": [{"id": "trk_text", "kind": "video", "name": "Text", "rippleMode": "follow", "clips": [
      {"id": "clip_callout", "start": 0, "duration": 2, "content": {"text": {"text": "14 tips", "preset": "callout", "animationDuration": 0.4,
        "style": {"alignment": "center", "color": {"r": 1, "g": 1, "b": 1, "a": 1}, "font": "SF Pro Display", "lineSpacing": 0, "shadow": false, "size": 64, "strokeWidth": 0, "uppercase": false, "weight": 800}}}},
      {"id": "clip_caption", "start": 2, "duration": 1, "content": {"text": {"text": "so this is", "preset": "caption", "animationDuration": 0.5,
        "style": {"alignment": "center", "color": {"r": 1, "g": 1, "b": 1, "a": 1}, "font": "TiltWarp-Regular", "lineSpacing": 0, "shadow": true, "size": 84,
                  "strokeColor": {"r": 0, "g": 0, "b": 0, "a": 1}, "strokeWidth": 7, "uppercase": false, "weight": 400}}}}
    ]}]}}
    """#

    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-styles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func text(_ id: String, in project: Project) throws -> TextContent {
        guard case .text(let text) = try XCTUnwrap(project.clip(id)).content else { throw XCTSkip("\(id) isn't text") }
        return text
    }

    func testAnOldProjectFileKeepsItsLook() throws {
        let url = try folder().appendingPathComponent("Old.tandem")
        try Data(Self.oldFile.utf8).write(to: url)
        let (project, revision) = try ProjectFile.load(from: url)
        XCTAssertEqual(revision, 3)
        XCTAssertEqual(project.schemaVersion, Project.currentSchemaVersion)

        // Values equal to the old defaults meant "the preset's".
        let callout = try text("clip_callout", in: project)
        XCTAssertTrue(callout.style.isEmpty, "\(callout.style)")
        XCTAssertNil(callout.animationDuration)

        // Anything else was the clip's own, and stays.
        let caption = try text("clip_caption", in: project)
        XCTAssertEqual(caption.style, TextStyle(
            font: "TiltWarp-Regular", size: 84, weight: 400, strokeColor: RGBA(r: 0, g: 0, b: 0), strokeWidth: 7, shadow: true
        ))
        XCTAssertEqual(caption.animationDuration, t(0.5))
    }

    func testAnUpgradedProjectIsntUpgradedAgain() throws {
        let url = try folder().appendingPathComponent("Old.tandem")
        try Data(Self.oldFile.utf8).write(to: url)
        var (project, _) = try ProjectFile.load(from: url)
        // A new edit that switches the callout's shadow off and keeps it
        // lower case, both the old defaults.
        let location = try XCTUnwrap(project.location(ofClip: "clip_callout"))
        var callout = try text("clip_callout", in: project)
        callout.style = TextStyle(uppercase: false, shadow: false)
        project[location.track].clips[location.index].content = .text(callout)
        try ProjectFile.save(project, revision: 4, to: url)

        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains(#""schemaVersion" : 2"#), "saved as the current schema")
        let (reloaded, _) = try ProjectFile.load(from: url)
        XCTAssertEqual(try text("clip_callout", in: reloaded).style, TextStyle(uppercase: false, shadow: false))
    }

    func testAJournalEntryFromBeforeTheUpgradeIsReadTheOldWay() throws {
        let folder = try folder()
        let journal = ProjectJournal.forProject(at: folder.appendingPathComponent("Video.tandem"))
        let project = Project.standard(name: "Video")
        let textTrack = try XCTUnwrap(project.track(named: "Text")).id
        // What the old app journaled for a callout dropped from the library.
        let full = TextStyle(font: "SF Pro Display", size: 64, weight: 800, color: .white, strokeWidth: 0, alignment: "center", uppercase: false, shadow: false, lineSpacing: 0)
        let old = EditBatch(label: "Add pop callout", commands: [
            .insertClip(trackID: textTrack, clip: Clip(id: "clip_old", content: .text(TextContent(text: "14 tips", preset: "callout", style: full, animationDuration: t(0.4))), start: .zero, duration: t(2)))
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(ProjectJournal.Entry(revision: 1, date: Date(), batch: old, seed: 1, snapshot: nil, reason: nil, schemaVersion: nil))
        line.append(0x0A)
        try line.write(to: journal.url)
        // Then this Tandem's own edit, which means what it says.
        journal.append(batch: EditBatch(label: "Lower case", commands: [
            .insertClip(trackID: textTrack, clip: Clip(id: "clip_new", content: .text(TextContent(text: "url", preset: "label", style: TextStyle(uppercase: false))), start: t(3), duration: t(2)))
        ]), revision: 2, seed: 2)

        let recovered = try XCTUnwrap(journal.recover(project: project, revision: 0))
        XCTAssertTrue(try text("clip_old", in: recovered.project).style.isEmpty)
        XCTAssertNil(try text("clip_old", in: recovered.project).animationDuration)
        XCTAssertEqual(try text("clip_new", in: recovered.project).style, TextStyle(uppercase: false))
    }

    // MARK: - Splitting

    func testSplittingAPresetTitleLeavesNoAnimationAtTheCut() throws {
        let titled = Clip(id: "clip_a", content: .text(TextContent(text: "TIP 1", preset: "label")), start: .zero, duration: t(4))
        let (left, right) = try XCTUnwrap(titled.split(at: t(2), rightID: "clip_b"))
        guard case .text(let l) = left.content, case .text(let r) = right.content else { return XCTFail("not text") }
        XCTAssertEqual(l.animationOut, "none", "nil would bring the preset's fade back")
        XCTAssertNil(l.animationIn)
        XCTAssertEqual(r.animationIn, "none")
        XCTAssertNil(r.animationOut)

        let plain = Clip(id: "clip_c", content: .text(TextContent(text: "plain", animationIn: "fade", animationOut: "fade")), start: .zero, duration: t(4))
        let (plainLeft, _) = try XCTUnwrap(plain.split(at: t(2), rightID: "clip_d"))
        guard case .text(let p) = plainLeft.content else { return XCTFail("not text") }
        XCTAssertNil(p.animationOut, "without a preset there's nothing to switch off")
    }
}
