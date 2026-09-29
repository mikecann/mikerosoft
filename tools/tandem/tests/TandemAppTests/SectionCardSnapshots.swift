import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore
import TandemRender

/// Renders a section card's Video tab and the Section card tile's art
/// offscreen, to look at:
///
///     TANDEM_CARD_UI_OUT=~/dev/me/tandem-research/title-cards/tandem/ui \
///     swift test --package-path tools/tandem --filter SectionCardSnapshots
///
/// Without the variable it still renders them once, so a view that can't
/// be built fails here rather than in the app.
@MainActor
final class SectionCardSnapshots: XCTestCase {
    private var folder: URL!
    private var model: EditorModel!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-card-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Cards.tandem"), name: "Cards", owner: .app)
        model = EditorModel(session: session)
    }

    override func tearDown() async throws {
        model.tearDown()
        _ = model.session.close()
        try? FileManager.default.removeItem(at: folder)
        settleMainThread()
    }

    private func write(_ image: CGImage, _ name: String) throws {
        guard let out = ProcessInfo.processInfo.environment["TANDEM_CARD_UI_OUT"], !out.isEmpty else { return }
        let dir = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testTheVideoTabOfASectionCard() throws {
        let graphics = try XCTUnwrap(model.project.track(named: "Graphics"))
        let props = SectionCard.Props(title: "Methodology", subtitle: "Let's keep it fair", number: "01", total: 3, kicker: "Section")
        model.apply(EditBatch(label: "Card", commands: [
            .insertClip(trackID: graphics.id, clip: Clip(id: "clip_card", content: SectionCard.content(props), start: .zero, duration: SectionCard.defaultDuration))
        ]))
        let clip = try XCTUnwrap(model.project.clip("clip_card"))
        let panel = VStack(alignment: .leading, spacing: 0) {
            ClipHeader(model: model, clip: clip)
            VideoInspector(model: model, clip: clip)
        }
        .frame(width: 330, height: 760, alignment: .top)
        .background(Theme.panel.color)
        // In a window, so the text fields and colour wells draw as AppKit
        // draws them (ImageRenderer leaves placeholders).
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: 330, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: panel)
        hosting.frame = CGRect(x: 0, y: 0, width: 330, height: 760)
        window.contentView = hosting
        window.display()
        settleMainThread()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()
        let image = try XCTUnwrap(rep.cgImage)
        XCTAssertGreaterThan(image.height, 300)
        try write(image, "video-tab")
    }

    func testTheTileArt() throws {
        for (name, time) in [("tile", SectionCard.Motion(duration: 3.2).outStart(0) + 0.22), ("hold", 1.6)] {
            let art = try XCTUnwrap(SectionCardArt.image(SectionCard.Props(title: "Methodology", subtitle: "Let's keep it fair", number: "01", total: 3), size: CGSize(width: 520, height: 292.5), time: time))
            XCTAssertEqual(art.width, 520)
            try write(art, "tile-\(name)")
        }
    }
}
