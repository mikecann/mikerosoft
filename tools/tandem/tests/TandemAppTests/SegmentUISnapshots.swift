import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import TandemAPI
@testable import TandemApp
import TandemAssets
@testable import TandemCore
import TandemMedia

/// Renders the shared library's views offscreen, to look at:
///
///     TANDEM_SEGMENT_UI_OUT=/private/tmp/segment-ui \
///     swift test --package-path tools/tandem --filter SegmentUISnapshots
///
/// Without the variable it still renders each once, so a view that can't
/// be built fails here rather than in the app.
@MainActor
final class SegmentUISnapshots: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-segment-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func render(_ view: some View, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "\(name) didn't render", file: file, line: line)
        XCTAssertGreaterThan(image.height, 40, name, file: file, line: line)
        if let out = ProcessInfo.processInfo.environment["TANDEM_SEGMENT_UI_OUT"], !out.isEmpty {
            let dir = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name + ".png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        return image
    }

    /// Three saved segments in a temp library.
    private func segments() throws -> [StoredSegment] {
        let library = SharedLibrary(root: folder.appendingPathComponent("Tandem Library", isDirectory: true))
        let video = folder.appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: video.appendingPathComponent("sfx"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4000).write(to: video.appendingPathComponent("sfx/whoosh.wav"))
        var project = Project.standard(name: "Video")
        project.media = [MediaItem(id: "med_whoosh", path: "sfx/whoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)]
        let coordinator = ProjectCoordinator(project: project)
        let text = try XCTUnwrap(project.track(named: "Text")).id
        let graphics = try XCTUnwrap(project.track(named: "Graphics")).id
        try coordinator.apply(EditBatch(label: "Build", commands: [
            .insertClip(trackID: graphics, clip: Clip(id: "clip_card", content: .solid(color: RGBA(r: 0.1, g: 0.1, b: 0.1)), start: t(0), duration: t(3.3))),
            .insertClip(trackID: text, clip: Clip(id: "clip_title", name: "Title", content: .text(TextContent(text: "Welcome back", preset: "callout")), start: t(0.2), duration: t(3))),
            .placeMedia(mediaIDs: ["med_whoosh"], at: t(0)),
            .insertClip(trackID: text, clip: Clip(id: "clip_like", content: .text(TextContent(text: "Like and subscribe", preset: "callout")), start: t(10), duration: t(2.5))),
            .insertClip(trackID: text, clip: Clip(id: "clip_comment", content: .text(TextContent(text: "Comment below", preset: "callout")), start: t(20), duration: t(2.5))),
            .insertClip(trackID: graphics, clip: Clip(id: "clip_bubble", content: .solid(color: RGBA(r: 1, g: 1, b: 1)), start: t(20.3), duration: t(1.5)))
        ]))
        let whoosh = try XCTUnwrap(coordinator.project.track(named: "SFX")?.clips.first).id
        let store = SegmentStore(library: library)
        let folderOf = ProjectFolder(root: video)
        let intro = try SegmentMaker.draft(name: "Intro", clipIDs: ["clip_card", "clip_title", whoosh], in: coordinator.project, folder: folderOf, fields: [SegmentMaker.Field(clipID: "clip_title", label: "Title")])
        let like = try SegmentMaker.draft(name: "Like and subscribe", clipIDs: ["clip_like"], in: coordinator.project, folder: folderOf)
        let comment = try SegmentMaker.draft(name: "Comment below", clipIDs: ["clip_comment", "clip_bubble"], in: coordinator.project, folder: folderOf)
        return try [intro, like, comment].map { try store.save($0) }
    }

    func testSegmentTilesAndTheSaveSheet() throws {
        let saved = try segments()
        let tiles = LazyVGrid(columns: TileGrid.columns(width: 130), alignment: .leading, spacing: 12) {
            ForEach(saved, id: \.id) { segment in
                LibraryTile(title: segment.name, selected: segment.name == "Intro", width: 130, height: 73, drag: .template(SegmentShelf.templateID(segment))) {
                    SegmentPreview(segment: segment)
                } select: {} add: {}
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(Theme.panel.color)
        try render(tiles, "1-segment-tiles")

        let session = try ProjectSession.create(at: folder.appendingPathComponent("Sheet.tandem"), name: "Sheet", owner: .app)
        defer { _ = session.close() }
        let model = EditorModel(session: session)
        defer { model.tearDown() }
        let text = try XCTUnwrap(model.project.track(named: "Text")).id
        model.apply(EditBatch(label: "Titles", commands: [
            .insertClip(trackID: text, clip: Clip(id: "clip_a", name: "Title", content: .text(TextContent(text: "Welcome back", preset: "callout")), start: t(0), duration: t(3))),
            .insertClip(trackID: text, clip: Clip(id: "clip_b", content: .text(TextContent(text: "Tip 1", preset: "label")), start: t(3), duration: t(2)))
        ]))
        let sheetModel = SaveSegmentModel(project: model.project, folder: model.folder, clipIDs: ["clip_a", "clip_b"], library: SharedLibrary(root: folder.appendingPathComponent("Tandem Library", isDirectory: true)))
        sheetModel.setup.titles[0].asked = true
        try render(SaveSegmentView(model: sheetModel), "2-save-sheet")

        try render(SharedChip().padding(8).background(Theme.panel.color), "3-shared-chip")
        // The Text tab's four sub-tabs, at the narrowest and the usual width.
        for width in [240.0, 300.0] {
            try render(TitleLibrary(model: model).frame(width: width, height: 160).background(Theme.panel.color), "5-text-tab-\(Int(width))")
        }
        try render(SettingsView(), "4-settings")
    }
}
