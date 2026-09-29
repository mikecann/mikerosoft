import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore
import TandemRender

/// The Export dialog resolves presets the way the CLI does
/// (`ExportPreset.plan(for:)`) and shows what each makes of the open
/// project. To look at it:
///
///     TANDEM_EXPORT_UI_OUT=/private/tmp/claude-501/tandem-export/ui \
///     swift test --package-path tools/tandem --filter ExportSheetTests
@MainActor
final class ExportSheetTests: XCTestCase {
    func canvas(_ width: Int, _ height: Int, formats: [OutputFormat] = []) -> ProjectSettings {
        ProjectSettings(width: width, height: height, alternateFormats: formats)
    }

    func testEachPresetShowsWhatItMakesOfThisProject() {
        let portrait = canvas(1080, 1920)
        XCTAssertEqual(ExportSheetOverlay.detail(.youtube4K, settings: portrait), "HEVC · 2160×3840 · 30p")
        XCTAssertEqual(ExportSheetOverlay.detail(.youtube1080, settings: portrait), "H.264 · 1080×1920 · 30p")
        XCTAssertEqual(ExportSheetOverlay.detail(.review, settings: portrait), "H.264 · 720×1280 · 30p")
        XCTAssertEqual(ExportSheetOverlay.detail(.short, settings: portrait), "H.264 · 1080×1920 · 30p")

        let landscape = canvas(3840, 2160)
        XCTAssertEqual(ExportSheetOverlay.detail(.youtube4K, settings: landscape), "HEVC · 3840×2160 · 30p")
        XCTAssertEqual(ExportSheetOverlay.detail(.youtube1080, settings: landscape), "H.264 · 1920×1080 · 30p")
        XCTAssertEqual(ExportSheetOverlay.detail(.short, settings: landscape), "No 9:16 layout yet")
        XCTAssertEqual(ExportSheetOverlay.detail(.short, settings: canvas(3840, 2160, formats: [.portrait])), "H.264 · 1080×1920 · 30p")
    }

    func testTheSheetOpensOnThePresetThatFitsTheTimeline() {
        XCTAssertEqual(ExportSheetOverlay.presets[ExportSheetOverlay.defaultIndex(settings: canvas(1080, 1920))].name, "YouTube 1080p")
        XCTAssertEqual(ExportSheetOverlay.presets[ExportSheetOverlay.defaultIndex(settings: canvas(1920, 1080))].name, "YouTube 1080p")
        XCTAssertEqual(ExportSheetOverlay.presets[ExportSheetOverlay.defaultIndex(settings: canvas(3840, 2160))].name, "YouTube 4K")
    }

    func testTheSizeLineSaysHowTheFrameComparesWithTheTimeline() throws {
        let portrait = canvas(1080, 1920)
        func size(_ preset: ExportPreset, _ settings: ProjectSettings) throws -> String {
            ExportSheetOverlay.sizeText(try preset.plan(for: settings), settings: settings)
        }
        XCTAssertEqual(try size(.youtube1080, portrait), "1080 × 1920, 30 fps, same as the timeline")
        XCTAssertEqual(try size(.youtube4K, portrait), "2160 × 3840, 30 fps, upscaled from the 1080 × 1920 timeline")
        let landscape = canvas(3840, 2160, formats: [.portrait])
        XCTAssertEqual(try size(.youtube1080, landscape), "1920 × 1080, 30 fps, scaled down from the 3840 × 2160 timeline")
        XCTAssertEqual(try size(.short, landscape), "1080 × 1920, 30 fps, the timeline's Short (9:16) layout")

        // An upscale says it adds nothing, and which preset keeps the size.
        XCTAssertEqual(ExportSheetOverlay.upscaleNote(try ExportPreset.youtube4K.plan(for: portrait), settings: portrait),
                       "No sharper than the timeline. YouTube 1080p exports it at 1080 × 1920.")
        XCTAssertNil(ExportSheetOverlay.upscaleNote(try ExportPreset.youtube1080.plan(for: portrait), settings: portrait))
    }

    func testTheShortWithoutALayoutSaysWhatToDo() {
        XCTAssertEqual(
            ExportSheetOverlay.problem(.noPortrait(width: 3840, height: 2160)),
            "This project has no 9:16 layout for the short yet. An agent can lay one out with `tandem short --apply`, with the screen on top and the camera below."
        )
    }

    /// The sheet over a native portrait project and a landscape one without
    /// a short layout, rendered offscreen. Without the variable it still
    /// renders, so a view that can't be built fails here.
    func testSnapshots() throws {
        for (name, settings, pick) in [
            ("portrait-default", canvas(1080, 1920), nil as String?),
            ("portrait-4k", canvas(1080, 1920), "YouTube 4K"),
            ("landscape-short", canvas(3840, 2160), "Short 9:16")
        ] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-export-ui-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let session = try ProjectSession.create(at: folder.appendingPathComponent("Workbench.tandem"), settings: settings, owner: .app)
            let model = EditorModel(session: session)
            defer {
                model.tearDown()
                _ = model.session.close()
                settleMainThread()
            }
            let index = pick.flatMap { wanted in ExportSheetOverlay.presets.firstIndex { $0.name == wanted } }
            let sheet = ExportSheetOverlay(model: model, initialPreset: index)
                .frame(width: 900, height: 620)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, "\(name) didn't render")
            XCTAssertGreaterThan(image.height, 400, name)
            if let out = ProcessInfo.processInfo.environment["TANDEM_EXPORT_UI_OUT"], !out.isEmpty {
                let dir = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(name + ".png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
    }
}
