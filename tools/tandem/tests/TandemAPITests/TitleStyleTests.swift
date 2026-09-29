import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// Titles keep only what was asked for: captions are their preset and their
/// words, a title's own style is listed for agents, and undo history an
/// older Tandem kept comes back looking as it did.
final class TitleStyleTests: XCTestCase {
    func captionClips(_ h: ServiceHarness) throws -> [Clip] {
        try XCTUnwrap(h.service.coordinator.project.track(named: "Captions")).clips
    }

    func testCaptionClipsStoreThePresetAndOnlyWhatWasPassed() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        _ = try await CaptionsRequest(from: t(0), to: t(10), y: 0.8, apply: true).run(on: h.service, context: h.context)

        let clips = try captionClips(h)
        XCTAssertFalse(clips.isEmpty)
        for clip in clips {
            guard case .text(let text) = clip.content else { return XCTFail("not text") }
            XCTAssertEqual(text.preset, "caption")
            XCTAssertTrue(text.style.isEmpty, "the preset decides the look: \(text.style)")
            XCTAssertNil(text.animationDuration)
            XCTAssertEqual(clip.video?.transform.position.y, 0.8, "--y is what was passed")
        }
        // And in the file: the preset and the words, no style.
        let data = try JSONEncoder().encode(clips[0])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try XCTUnwrap((json["content"] as? [String: Any])?["text"] as? [String: Any])
        XCTAssertEqual(Set(content.keys), ["text", "preset", "words"])
    }

    func testHeadlessUndoHistoryFromAnOlderTandemKeepsItsTitles() throws {
        let folder = TempFolder()
        var project = APIFixture.project()
        project.schemaVersion = 1
        let location = try XCTUnwrap(project.location(ofTrack: "trk_text"))
        let full = TextStyle(font: "SF Pro Display", size: 64, weight: 800, color: .white, strokeWidth: 0, alignment: "center", uppercase: false, shadow: false, lineSpacing: 0)
        project[location].clips[0].content = .text(TextContent(text: "DECISION MODELS", preset: "callout", style: full, animationDuration: t(0.4)))
        let url = try APIFixture.write(to: folder.url, project: project)
        // What an older CLI left: the project before its last edit, the way
        // it wrote titles.
        let history = HeadlessHistory(projectURL: url)
        history.recordEdit(label: "Cut", author: "cli", before: project, beforeRevision: 1, afterRevision: 2)
        let entry = try XCTUnwrap(history.peekUndo(at: 2))
        guard case .text(let text) = try XCTUnwrap(entry.project.clip("clip_txt1")).content else { return XCTFail("not text") }
        XCTAssertTrue(text.style.isEmpty, "undoing brings back the callout as it looked")
        XCTAssertEqual(entry.project.schemaVersion, Project.currentSchemaVersion)
    }

    func testTheTimelineListsWhatATitleSetsItself() throws {
        var project = APIFixture.project()
        let location = try XCTUnwrap(project.location(ofTrack: "trk_text"))
        project[location].clips[0].content = .text(TextContent(text: "github.com/mikecann", preset: "label", style: TextStyle(strokeWidth: 0, uppercase: false)))
        let text = TimelineDump.render(project, revision: 1, options: TimelineDump.Options())
        XCTAssertTrue(text.contains("style strokeWidth=0 uppercase=false"), text)
    }
}
