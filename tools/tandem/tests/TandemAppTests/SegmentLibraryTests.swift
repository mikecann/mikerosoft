import XCTest
@testable import TandemApp
import TandemAPI
import TandemAssets
@testable import TandemCore
import TandemMedia

/// The app's side of segments: what the save sheet starts from, finding a
/// dragged segment, dropping it, and the Segments tab's words.
final class SegmentLibraryTests: XCTestCase {
    /// A saved segment in a temp shared library: a card, a title asking for
    /// its words, and a whoosh.
    func savedSegment() throws -> (StoredSegment, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-app-segments-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: video.appendingPathComponent("sfx"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4000).write(to: video.appendingPathComponent("sfx/whoosh.wav"))
        var project = Project.standard(name: "Video")
        project.media = [MediaItem(id: "med_whoosh", path: "sfx/whoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)]
        let coordinator = ProjectCoordinator(project: project)
        let text = try XCTUnwrap(project.track(named: "Text"))
        let graphics = try XCTUnwrap(project.track(named: "Graphics"))
        try coordinator.apply(EditBatch(label: "Intro", commands: [
            .insertClip(trackID: graphics.id, clip: Clip(id: "clip_card", content: .solid(color: RGBA(r: 0.1, g: 0.1, b: 0.1)), start: t(4), duration: t(3))),
            .insertClip(trackID: text.id, clip: Clip(id: "clip_title", name: "Title", content: .text(TextContent(text: "Welcome back\nto the channel", preset: "callout")), start: t(4.5), duration: t(2))),
            .placeMedia(mediaIDs: ["med_whoosh"], at: t(4))
        ]))
        let ids = ["clip_card", "clip_title"] + coordinator.project.track(named: "SFX")!.clips.map(\.id)
        var setup = SegmentSaveSetup.make(clipIDs: ids, in: coordinator.project)
        setup.titles[0].asked = true
        let library = SharedLibrary(root: root.appendingPathComponent("Tandem Library", isDirectory: true))
        let draft = try SegmentMaker.draft(name: setup.name, clipIDs: ids, in: coordinator.project, folder: ProjectFolder(root: video), fields: setup.fields)
        return (try SegmentStore(library: library).save(draft), root)
    }

    func testTheSaveSheetStartsFromTheSelection() throws {
        let fixture = try AppFixture()
        let ids = [fixture.clip("Camera").id, fixture.clip("Voice").id, fixture.clip("B-roll").id]
        let setup = SegmentSaveSetup.make(clipIDs: ids, in: fixture.project)
        XCTAssertEqual(setup.name, "Segment", "no title to name it after")
        XCTAssertEqual(setup.titles, [])
        XCTAssertEqual(setup.summary, "3 clips, 60 s, on Camera, Voice and B-roll, playing 2 files")
        XCTAssertEqual(setup.fields, [])

        let titled = SegmentSaveSetup.defaultName([SegmentSaveSetup.Title(clipID: "c", text: "  Like and subscribe \nplease", label: "Title")])
        XCTAssertEqual(titled, "Like and subscribe")
        XCTAssertEqual(SegmentSaveSetup.defaultName([SegmentSaveSetup.Title(clipID: "c", text: "{{title}}", label: "Title")]), "Segment")
    }

    func testADraggedSegmentDropsLikeATemplate() throws {
        let (segment, _) = try savedSegment()
        XCTAssertEqual(segment.name, "Welcome back")
        XCTAssertEqual(segment.segment.template.fields.map(\.label), ["Title"])
        SegmentShelf.shared.update([segment])
        defer { SegmentShelf.shared.update([]) }

        let id = SegmentShelf.templateID(segment)
        XCTAssertEqual(LibraryDrag.parse(LibraryDrag.template(id).payload), .template(id))
        let template = try XCTUnwrap(BuiltInTemplates.template(id))
        XCTAssertNil(BuiltInTemplates.template("segment:Nope"))
        let builtIn = try XCTUnwrap(BuiltInTemplates.all.first)
        XCTAssertEqual(BuiltInTemplates.template(builtIn.id), builtIn, "the built-in ones still come first")

        let fixture = try AppFixture()
        let batch = LibraryDrops.template(template, at: t(40))
        XCTAssertEqual(batch.label, "Add welcome back")
        try fixture.apply(batch)
        let whoosh = try XCTUnwrap(fixture.project.media.first { $0.path.hasSuffix("/Segments/Welcome back/whoosh.wav") })
        XCTAssertEqual(fixture.project.track(named: "SFX")?.clips.last?.mediaID, whoosh.id)
        guard case .text(let title)? = fixture.project.track(named: "Text")?.clips.last?.content else { return XCTFail("no title") }
        XCTAssertEqual(title.text, "Welcome back\nto the channel", "the field's default")

        // A segment missing a file doesn't drop half made.
        try FileManager.default.removeItem(at: segment.folder.appendingPathComponent("whoosh.wav"))
        XCTAssertNil(SegmentShelf.shared.template(id))
    }

    @MainActor
    func testTheSheetSavesTheSelectionAndAsksBeforeReplacing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-app-sheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try AppFixture()
        let text = fixture.track("Text").id
        try fixture.apply(EditBatch(label: "Title", commands: [
            .insertClip(trackID: text, clip: Clip(id: "clip_cta", name: "Call", content: .text(TextContent(text: "Comment below", preset: "callout")), start: t(5), duration: t(2)))
        ]))
        let library = SharedLibrary(root: root.appendingPathComponent("Tandem Library", isDirectory: true))
        let model = SaveSegmentModel(project: fixture.project, folder: ProjectFolder(root: root), clipIDs: ["clip_cta"], library: library)
        model.discard = { try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(model.setup.name, "Comment below")
        XCTAssertTrue(model.destination.hasSuffix("/Tandem Library/Segments/Comment below"), model.destination)
        model.setup.titles[0].asked = true

        func save() async throws -> StoredSegment {
            var stored: StoredSegment?
            model.onSaved = { stored = $0 }
            model.save()
            let deadline = Date().addingTimeInterval(10)
            while stored == nil, model.stage == .saving, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return try XCTUnwrap(stored, "\(model.stage)")
        }
        let first = try await save()
        XCTAssertEqual(first.segment.template.fields, [TemplateField(key: "call", label: "Call", defaultValue: "Comment below")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.segmentsFolder.appendingPathComponent("Comment below/segment.json").path))

        // The same name again: the sheet asks, and the second press replaces.
        model.save()
        XCTAssertEqual(model.stage, .exists)
        model.setup.titles[0].asked = false
        let replaced = try await save()
        XCTAssertEqual(replaced.segment.template.fields, [])
        model.setup.name = "   "
        XCTAssertFalse(model.canSave)
    }

    func testTheSegmentsTabsWords() throws {
        let (segment, _) = try savedSegment()
        XCTAssertEqual(SegmentLibraryText.filter([segment], by: "welcome").map(\.id), [segment.id])
        XCTAssertEqual(SegmentLibraryText.filter([segment], by: "outro").count, 0)
        XCTAssertEqual(SegmentLibraryText.filter([segment], by: "").count, 1)
        XCTAssertEqual(SegmentLibraryText.seconds(t(3)), "3 s")
        XCTAssertEqual(SegmentLibraryText.seconds(t(5.24)), "5.2 s")
        let help = SegmentLibraryText.help(segment)
        XCTAssertTrue(help.contains("3 s on Text, Graphics, SFX"), help)
        XCTAssertTrue(help.contains("Words to fill in: Title"), help)
        XCTAssertTrue(help.contains("Saved from Video"), help)

        let lanes = SegmentLanes.of(segment.insertableTemplate())
        XCTAssertEqual(lanes.map(\.track), ["video|Text", "video|Graphics", "audio|SFX"])
        XCTAssertEqual(lanes[0].bars.first?.start ?? -1, 0.5, accuracy: 0.001)
    }

    func testSharedAssetsCarryTheirChipAndMakeTheirOwnThumbnails() {
        let sticker = Asset(provider: "shared", providerID: "Stickers/Star.mov", kind: .sticker, name: "Star")
        let sound = Asset(provider: "shared", providerID: "Sound effects/Pop.wav", kind: .sfx, name: "Pop")
        let look = Asset(provider: "import", providerID: "looks-1/Warm.cube", kind: .lut, name: "Warm")
        let downloaded = Asset(provider: "noto", providerID: "1f680", kind: .sticker, name: "Rocket")
        XCTAssertTrue(SharedChip.shows(sticker))
        XCTAssertFalse(SharedChip.shows(downloaded))
        XCTAssertTrue(AssetMedia.makesItsOwnThumbnail(sticker))
        XCTAssertFalse(AssetMedia.makesItsOwnThumbnail(sound), "sounds draw waveforms instead")
        XCTAssertTrue(AssetMedia.makesItsOwnThumbnail(look))
        XCTAssertFalse(AssetMedia.makesItsOwnThumbnail(downloaded))
    }
}
