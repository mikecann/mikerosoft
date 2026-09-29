import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

/// Renders the Text section of the Video tab offscreen, to look at:
///
///     TANDEM_TEXT_UI_OUT=~/dev/me/tandem-research/text-ui \
///     swift test --package-path tools/tandem --filter TextInspectorSnapshots
///
/// Without the variable it still renders each state once, so a view that
/// can't be built fails here rather than in the app.
@MainActor
final class TextInspectorSnapshots: XCTestCase {
    private var folder: URL!
    private var model: EditorModel!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-text-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Text.tandem"), name: "Text", owner: .app)
        model = EditorModel(session: session)
    }

    override func tearDown() async throws {
        model.tearDown()
        _ = model.session.close()
        try? FileManager.default.removeItem(at: folder)
        settleMainThread()
    }

    private func title(_ text: TextContent) throws -> Clip {
        let track = try XCTUnwrap(model.project.track(named: "Text"))
        XCTAssertNotNil(model.apply(EditBatch(label: "Title", commands: [
            .insertClip(trackID: track.id, clip: Clip(id: "clip_title", content: .text(text), start: .zero, duration: t(3)))
        ])))
        return try XCTUnwrap(model.project.clip("clip_title"))
    }

    private func render(_ clip: Clip, _ name: String) throws {
        let view = VideoInspector(model: model, clip: clip)
            .frame(width: 330, alignment: .top)
            .background(Theme.panel.color)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "\(name) didn't render")
        XCTAssertGreaterThan(image.height, 200, name)
        guard let out = ProcessInfo.processInfo.environment["TANDEM_TEXT_UI_OUT"], !out.isEmpty else { return }
        let dir = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(dir.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testALabelWithItsOwnSettings() throws {
        // The feedback's URL end card: lower case, no outline, no shadow.
        let clip = try title(TextContent(text: "github.com/mikecann/workbench", preset: "label", style: TextStyle(strokeWidth: 0, uppercase: false, shadow: false)))
        try render(clip, "1-label-own-settings")
    }

    func testACalloutAsThePresetDrawsIt() throws {
        try render(try title(TextContent(text: "14 tips", preset: "callout")), "2-callout-preset")
    }

    func testAFontThatIsntInstalled() throws {
        try render(try title(TextContent(text: "Hello", style: TextStyle(font: "Nope Sans Test", size: 90))), "3-missing-font")
    }
}
