import CoreImage
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// A project's own fonts reach whatever process renders it, and titles in a
/// font that isn't there are reported rather than quietly drawn in SF Pro.
final class ProjectFontsTests: XCTestCase {
    func fontFile() throws -> URL {
        try XCTUnwrap(FontFixtures.systemTrueType(), "no TrueType font in /System/Library/Fonts/Supplemental")
    }

    func title(_ id: String, _ text: String, preset: String? = nil, font: String? = nil, enabled: Bool = true) -> Clip {
        var clip = Clip(id: id, content: .text(TextContent(text: text, preset: preset, style: TextStyle(font: font))), start: .zero, duration: t(2))
        clip.enabled = enabled
        return clip
    }

    func testANewFontFileInTheProjectIsRegistered() throws {
        let media = try TestMedia()
        let family = FontFixtures.uniqueFamily()
        XCTAssertFalse(ProjectFonts.isAvailable(family))
        XCTAssertEqual(ProjectFonts.registerNew(in: media.projectFolder), [], "no assets/font yet")

        let file = ProjectFonts.folder(of: media.projectFolder).appendingPathComponent("face.ttf")
        try FontFixtures.renamed(try fontFile(), family: family, to: file)
        XCTAssertEqual(ProjectFonts.registerNew(in: media.projectFolder).map(\.lastPathComponent), ["face.ttf"])
        XCTAssertTrue(ProjectFonts.isAvailable(family))
        XCTAssertTrue(ProjectFonts.isAvailable(FontFixtures.postScriptName(of: family)))
        XCTAssertEqual(ProjectFonts.registerNew(in: media.projectFolder), [], "each file once")
    }

    func testMissingFontsAreListedWithTheFix() throws {
        let project = smallProject(video: [Track(kind: .video, name: "Text", clips: [
            title("clip_a", "one", font: "Nope Sans Test"),
            title("clip_b", "two", font: "NopeSansTest-Bold"),
            title("clip_c", "three", font: "nope sans test"),
            title("clip_d", "system", font: "SF Pro Display"),
            title("clip_e", "arial", font: "Arial"),
            title("clip_f", "label", preset: "label"),
            title("clip_g", "off", font: "Nope Sans Test", enabled: false)
        ])], media: [])
        let missing = ProjectFonts.missing(in: project)
        XCTAssertEqual(missing.map(\.name), ["Nope Sans Test", "NopeSansTest-Bold"])
        XCTAssertEqual(missing[0].clipIDs, ["clip_a", "clip_c", "clip_g"], "names match whatever their case")
        XCTAssertEqual(missing[0].assetID, "fontsource:nope-sans-test")
        XCTAssertEqual(missing[1].assetID, "fontsource:nope-sans-test", "the PostScript name suggests the same family")
        XCTAssertNil(missing[0].presetID)
        XCTAssertEqual(
            missing[0].warning,
            "Nope Sans Test isn't installed, so 3 text clips are drawn in SF Pro instead. Install it with: tandem assets use fontsource:nope-sans-test"
        )
        XCTAssertEqual(ProjectFonts.missing(in: project, drawnOnly: true)[0].clipIDs, ["clip_a", "clip_c"], "a clip that's off isn't drawn")
    }

    func testAPresetsFontIsNamedAsThePresets() throws {
        guard !ProjectFonts.isAvailable("Tilt Warp") else { throw XCTSkip("Tilt Warp is installed on this Mac") }
        let project = smallProject(video: [Track(kind: .video, name: "Captions", clips: [title("clip_cap", "so this is", preset: "caption")])], media: [])
        let missing = try XCTUnwrap(ProjectFonts.missing(in: project).first)
        XCTAssertEqual(missing.presetID, "caption")
        XCTAssertEqual(missing.assetID, "fontsource:tilt-warp")
        XCTAssertEqual(
            missing.warning,
            "Tilt Warp, the caption preset's font, isn't installed, so 1 text clip is drawn in SF Pro instead. Install it with: tandem assets use fontsource:tilt-warp"
        )
    }

    func testFontsourceIDsFromFontNames() {
        XCTAssertEqual(ProjectFonts.fontsourceID(for: "Tilt Warp"), "fontsource:tilt-warp")
        XCTAssertEqual(ProjectFonts.fontsourceID(for: "TiltWarp-Regular"), "fontsource:tilt-warp")
        XCTAssertEqual(ProjectFonts.fontsourceID(for: "Inter"), "fontsource:inter")
        XCTAssertEqual(ProjectFonts.fontsourceID(for: "OpenSans-SemiBold"), "fontsource:open-sans")
        XCTAssertEqual(ProjectFonts.fontsourceID(for: "Bebas Neue"), "fontsource:bebas-neue")
    }

    func testTitlesDrawnBeforeTheFontArrivedAreDrawnAgain() throws {
        let media = try TestMedia()
        let family = FontFixtures.uniqueFamily()
        let request = TextRenderer.Request(
            text: "Hello there", font: family, size: 64, weight: 400, color: [1, 1, 1, 1],
            strokeColor: nil, strokeWidth: 0, backgroundColor: nil, alignment: "center",
            shadow: false, lineSpacing: 0, maxWidth: 4000, highlight: nil,
            highlightColor: [1, 1, 0, 1], visibleLength: nil, firstLineScale: 1, firstLineColor: nil
        )
        let fallback = try XCTUnwrap(TextRenderer.shared.image(request)).extent
        try FontFixtures.renamed(try fontFile(), family: family, to: ProjectFonts.folder(of: media.projectFolder).appendingPathComponent("face.ttf"))
        ProjectFonts.registerNew(in: media.projectFolder)
        let drawn = try XCTUnwrap(TextRenderer.shared.image(request)).extent
        XCTAssertNotEqual(drawn.width, fallback.width, "the cached SF Pro drawing was used again")
    }

    func testARenderPicksUpAFontAddedSinceTheLastOne() async throws {
        let media = try TestMedia()
        let family = FontFixtures.uniqueFamily()
        let project = smallProject(video: [Track(kind: .video, name: "Text", clips: [title("clip_t", "Hello", font: family)])], media: [])
        let context = RenderContext(project: project, folder: media.projectFolder)
        let before = try await FrameRenderer(context: context).warnings()
        XCTAssertEqual(before, [ProjectFonts.missing(in: project)[0].warning])

        // As `tandem assets use` would, while the app has the project open.
        try FontFixtures.renamed(try fontFile(), family: family, to: ProjectFonts.folder(of: media.projectFolder).appendingPathComponent("face.ttf"))
        let after = try await FrameRenderer(context: context).warnings()
        XCTAssertEqual(after, [], "the build registered the new file first")
        XCTAssertTrue(ProjectFonts.isAvailable(family))
    }
}
