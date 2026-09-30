import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

/// Renders the timeline and its toolbar offscreen with a few agent edits
/// waiting for review, to look at:
///
///     TANDEM_REVIEW_UI_OUT=/private/tmp/review-ui \
///     swift test --package-path tools/tandem --filter ReviewSnapshots
///
/// Without the variable it still renders once, so a view that can't be
/// built fails here rather than in the app.
@MainActor
final class ReviewSnapshots: XCTestCase {
    private var folder: URL!
    private var model: EditorModel!
    private var window: NSWindow?

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-review-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try ProjectSession.create(at: folder.appendingPathComponent("ESLint.tandem"), name: "ESLint", owner: .app)
        model = EditorModel(session: session)
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        model.tearDown()
        _ = model.session.close()
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ image: CGImage, _ name: String) throws {
        guard let out = ProcessInfo.processInfo.environment["TANDEM_REVIEW_UI_OUT"], !out.isEmpty else { return }
        let dir = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// Lets observation, the review log and the window catch up.
    private func settle() {
        for _ in 0..<30 {
            _ = model.session.review.log
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
        }
    }

    func testTheTimelineWithAgentEdits() throws {
        guard NSScreen.screens.first != nil else { throw XCTSkip("no screen") }
        let fixture = try AppFixture()
        let whoosh = MediaItem(id: "med_whoosh", path: "sfx/whoosh.wav", kind: .audio, role: .sfx, duration: t(1.2), hasAudio: true)
        model.apply(EditBatch(label: "Media", commands: (fixture.project.media + [whoosh]).map { .addMedia(item: $0) }))
        model.apply(EditBatch(label: "Build", commands: [
            .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(60)),
            .placeMedia(mediaIDs: ["med_broll"], at: t(4), sourceStart: t(1), duration: t(4)),
            .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(60)),
            .addMarker(marker: Marker(id: "mk_s2", time: t(30), name: "§2 Rules", kind: .section))
        ]))
        let coordinator = model.session.coordinator
        func agent(_ label: String, _ commands: [EditCommand]) throws {
            try coordinator.apply(EditBatch(label: label, author: "claude", commands: commands))
        }
        let graphics = try XCTUnwrap(model.project.track(named: "Graphics")).id
        let card = SectionCard.Props(title: "Rules", number: "02", total: 3)
        try agent("B-roll over the config", [.placeMedia(mediaIDs: ["med_broll"], at: t(17), sourceStart: t(2), duration: t(5))])
        try agent("Whoosh into §2", [.placeMedia(mediaIDs: ["med_whoosh"], at: t(29.4))])
        try agent("Section card for §2", [.insertClip(trackID: graphics, clip: Clip(content: SectionCard.content(card), start: t(29.6), duration: t(4)))])
        try agent("Tighten a pause", [.rippleDeleteRange(range: TimeRange(start: t(44), end: t(45.2)))])
        let music = try XCTUnwrap(model.project.track(named: "Music")?.clips.first).id
        try agent("Duck the music", [.updateClip(clipID: music, patch: .object(["audio": .object(["gainDB": .number(-34)])]))])
        // Mike's own edit after them, which isn't highlighted.
        try coordinator.apply(EditBatch(label: "Mike's shot", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(50), duration: t(3))]))
        settle()
        XCTAssertEqual(model.review.editCount, 5)

        model.timeline.fitPending = false
        model.timeline.scale = TimelineScale(pixelsPerSecond: 21, scrollSeconds: 0)
        model.selection = [try XCTUnwrap(model.project.track(named: "B-roll")?.clips[1].id)]
        _ = NSApplication.shared
        let size = CGSize(width: 1_400, height: 420)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: TimelinePanel(model: model, actions: EditorActions(model: model)))
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderBack(nil)
        self.window = window
        settle()
        let image = try XCTUnwrap(WindowSnapshot.image(of: window))
        XCTAssertEqual(image.width, Int(size.width * window.backingScaleFactor))
        try write(image, "timeline-review")

        // Stepped to the first change.
        XCTAssertTrue(model.goToAgentChange(forward: true))
        settle()
        try write(try XCTUnwrap(WindowSnapshot.image(of: window)), "timeline-review-stepped")
    }
}
