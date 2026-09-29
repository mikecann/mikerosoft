import XCTest
@testable import TandemAPI
import TandemAssets
@testable import TandemCore
import TandemMedia
import TandemRender

/// Stands in for the asset library: records what it was asked for, and
/// fails when told to, as an offline Mac would.
final class RecordingInstaller: FontInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    let failure: String?

    init(failure: String? = nil) {
        self.failure = failure
    }

    var requests: [String] { lock.withLock { asked } }

    func install(_ assetID: String, in folder: ProjectFolder, projectID: String, projectFile: URL) async throws -> [String] {
        lock.withLock { asked.append(assetID) }
        if let failure { throw ServiceError(.unavailable, failure) }
        return ["assets/font/tilt-warp-test.ttf"]
    }
}

/// Fonts that aren't installed are reported with the fix, the fonts
/// built-in presets need are installed the first time they're used, and a
/// font added to the project reaches whichever process has it open.
final class TextFontTests: XCTestCase {
    func skipIfTiltWarpIsInstalled() throws {
        if ProjectFonts.isAvailable("Tilt Warp") { throw XCTSkip("Tilt Warp is installed on this Mac") }
    }

    func testApplyingCaptionsInstallsThePresetFontTheFirstTime() async throws {
        try skipIfTiltWarpIsInstalled()
        let h = try ServiceHarness()
        defer { h.close() }
        let installer = RecordingInstaller()
        h.service.fontInstaller = installer

        let dryRun = try await CaptionsRequest(from: t(0), to: t(10)).run(on: h.service, context: h.context)
        XCTAssertEqual(installer.requests, [], "a dry run doesn't download anything")
        XCTAssertTrue(dryRun.warnings.contains { $0.hasPrefix("Tilt Warp, the caption preset's font, isn't installed") && $0.contains("tandem assets use fontsource:tilt-warp") }, "\(dryRun.warnings)")

        let applied = try await CaptionsRequest(from: t(0), to: t(10), apply: true).run(on: h.service, context: h.context)
        XCTAssertEqual(installer.requests, ["fontsource:tilt-warp"])
        XCTAssertEqual(applied.installedFonts?.map(\.name), ["Tilt Warp"])
        XCTAssertTrue(applied.readableText.contains("Installed Tilt Warp, the caption preset's font, into the project: assets/font/tilt-warp-test.ttf."), applied.readableText)
    }

    func testCaptionsSayWhyTheFontIsMissingWhenItCantBeInstalled() async throws {
        try skipIfTiltWarpIsInstalled()
        let h = try ServiceHarness()
        defer { h.close() }
        h.service.fontInstaller = RecordingInstaller(failure: "The Mac is offline.")
        let applied = try await CaptionsRequest(from: t(0), to: t(10), apply: true).run(on: h.service, context: h.context)
        XCTAssertNotNil(applied.applied, "the captions still go in")
        XCTAssertTrue(applied.warnings.contains("Couldn't install Tilt Warp from the asset library: The Mac is offline."), "\(applied.warnings)")
        let missing = try XCTUnwrap(applied.warnings.first { $0.contains("isn't installed") })
        XCTAssertTrue(missing.contains("tandem assets use fontsource:tilt-warp"), missing)
        XCTAssertTrue(applied.readableText.contains("Warning: Tilt Warp, the caption preset's font, isn't installed"), applied.readableText)
    }

    func testAFrameInstallsAPresetFontBeforeItRenders() async throws {
        try skipIfTiltWarpIsInstalled()
        var project = APIFixture.project()
        let location = try XCTUnwrap(project.location(ofTrack: "trk_text"))
        project[location].clips.append(Clip(id: "clip_cap", content: .text(TextContent(text: "so this is", preset: "caption")), start: t(10), duration: t(1)))
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        let installer = RecordingInstaller(failure: "Fontsource didn't answer.")
        h.service.fontInstaller = installer
        let result = try await FrameRequest(time: t(10.5)).run(on: h.service, context: h.context)
        XCTAssertEqual(installer.requests, ["fontsource:tilt-warp"])
        XCTAssertTrue(result.warnings.contains("Couldn't install Tilt Warp from the asset library: Fontsource didn't answer."), "\(result.warnings)")
    }

    /// The CLI's path when the app doesn't have the project open: the
    /// command opens it headless and renders it itself, with the real
    /// renderer. Before, only the app registered a project's fonts, so this
    /// drew the titles in SF Pro and said nothing.
    func testAHeadlessRenderUsesTheProjectsOwnFonts() async throws {
        let source = try XCTUnwrap(FontFixtures.systemTrueType())
        let folder = TempFolder()
        let family = FontFixtures.uniqueFamily()
        var project = Project(id: "prj_fonts", name: "Fonts", settings: ProjectSettings(width: 320, height: 180, frameRate: .fps30))
        project.videoTracks = [Track(id: "trk_text", kind: .video, name: "Text", clips: [
            Clip(id: "clip_title", content: .text(TextContent(text: "Hello fonts", style: TextStyle(font: family, size: 120))), start: .zero, duration: t(2))
        ], rippleMode: .follow)]
        let url = try APIFixture.write(to: folder.url, name: "Fonts", project: project)
        let client = ProjectClient(projectURL: url, author: "claude")
        client.fontInstaller = nil

        let before = try await client.call(FrameRequest(time: t(1)))
        XCTAssertTrue(before.warnings.contains { $0.hasPrefix("\(family) isn't installed") }, "\(before.warnings)")

        // The font in the project's assets/font, as `tandem assets use` or
        // an archive leaves it.
        try FontFixtures.renamed(source, family: family, to: ProjectFonts.folder(of: ProjectFolder(projectFile: url)).appendingPathComponent("face.ttf"))
        let after = try await client.call(FrameRequest(time: t(1)))
        XCTAssertEqual(after.warnings.filter { $0.contains("isn't installed") }, [], "\(after.warnings)")
        XCTAssertNotEqual(after.png, before.png, "drawn in the project's own font this time")
        XCTAssertTrue(ProjectFonts.isAvailable(family))

        let exported = try await client.call(ExportRequest(preset: "review", output: folder.file("review.mp4").path, from: .zero, to: t(1)))
        XCTAssertEqual(exported.warnings.filter { $0.contains("isn't installed") }, [])
    }

    func testStatusAndValidateNameAFontThatIsntInstalled() throws {
        var project = APIFixture.project()
        let location = try XCTUnwrap(project.location(ofTrack: "trk_text"))
        project[location].clips.append(Clip(id: "clip_odd", content: .text(TextContent(text: "odd", style: TextStyle(font: "Nope Sans Test"))), start: t(10), duration: t(1)))
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        let expected = "Nope Sans Test isn't installed, so 1 text clip is drawn in SF Pro instead. Install it with: tandem assets use fontsource:nope-sans-test"
        let status = h.service.status()
        XCTAssertEqual(status.warnings, [expected])
        XCTAssertTrue(status.readableText.contains("Warning: \(expected)"), status.readableText)
        // A warning, not an error (the fixture's media files aren't on disk,
        // which is what makes it fail).
        let validate = h.service.validate()
        XCTAssertTrue(validate.issues.contains(ValidationIssue(.warning, expected, objectID: "clip_odd")), "\(validate.issues)")
    }

    func testAStatusCallRegistersAFontAnotherProcessAddedToTheProject() async throws {
        let source = try XCTUnwrap(FontFixtures.systemTrueType())
        let family = FontFixtures.uniqueFamily()
        var project = APIFixture.project()
        let location = try XCTUnwrap(project.location(ofTrack: "trk_text"))
        project[location].clips.append(Clip(id: "clip_own", content: .text(TextContent(text: "own", style: TextStyle(font: family))), start: t(10), duration: t(1)))
        let h = try ServiceHarness(project: project)
        let server = TandemHTTPServer(service: h.service)
        let port = try await server.start()
        defer {
            server.stop()
            h.close()
        }
        let client = TandemHTTPClient(port: port, token: server.token, author: "claude")
        let before = try await client.call(StatusRequest())
        XCTAssertEqual(before.warnings?.count, 1)

        // What `tandem assets use` does from its own process: copy the file
        // in, then ask the app for the status.
        try FontFixtures.renamed(source, family: family, to: ProjectFonts.folder(of: h.session.folder).appendingPathComponent("face.ttf"))
        let after = try await client.call(StatusRequest())
        XCTAssertEqual(after.warnings, [])
        XCTAssertTrue(ProjectFonts.isAvailable(family), "the serving process has the font")
    }

    func testAnOldAppsStatusStillReads() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let status = try ServiceJSON.decoder().decode(StatusResult.self, from: ServiceJSON.encoder().encode(h.service.status()))
        XCTAssertEqual(status.warnings, [])
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: ServiceJSON.encoder().encode(status)) as? [String: Any])
        fields["warnings"] = nil
        let old = try ServiceJSON.decoder().decode(StatusResult.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertNil(old.warnings)
    }

    // MARK: - assets use

    /// A Fontsource that knows one family, with a real font file behind it.
    func fontsource(_ h: AssetHarness, family: String, slug: String) throws {
        let source = try XCTUnwrap(FontFixtures.systemTrueType())
        let file = h.folder.url.appendingPathComponent("face.ttf")
        try FontFixtures.renamed(source, family: family, to: file)
        let list = #"[{"id": "\#(slug)", "family": "\#(family)", "subsets": ["latin"], "weights": [400], "styles": ["normal"], "category": "display", "license": "OFL-1.1", "type": "google"}]"#
        let detail = #"{"id": "\#(slug)", "family": "\#(family)", "license": "OFL-1.1", "variants": {"400": {"normal": {"latin": {"url": {"ttf": "https://cdn.test/\#(slug)/latin-400-normal.ttf"}}}}}}"#
        h.transport.on("api.fontsource.org/v1/fonts", body: Data(list.utf8))
        h.transport.on("api.fontsource.org/v1/fonts/\(slug)", body: Data(detail.utf8))
        h.transport.on("latin-400-normal.ttf", body: try Data(contentsOf: file))
    }

    func testTheFixAMissingFontWarningGivesWorksWithoutASearch() async throws {
        let h = try await AssetHarness()
        let family = FontFixtures.uniqueFamily()
        let slug = String(ProjectFonts.fontsourceID(for: family).dropFirst("fontsource:".count))
        try fontsource(h, family: family, slug: slug)
        let (client, url) = try h.project()

        let used = try await h.service.use(AssetUseRequest(id: "fontsource:\(slug)"), project: client)

        XCTAssertEqual(used.asset.kind, .font)
        XCTAssertTrue(used.readableText.hasPrefix("Installed the font \(family)"), used.readableText)
        let copied = ProjectFonts.folder(of: ProjectFolder(projectFile: url))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copied.path).count, 1)
        XCTAssertTrue(ProjectFonts.isAvailable(family))
    }

    func testAFontUseSaysTheAppHasItToo() {
        var result = AssetUseResult(
            asset: Asset(provider: "fontsource", providerID: "tilt-warp", kind: .font, name: "Tilt Warp"),
            mediaID: nil, files: ["assets/font/tilt-warp.ttf"], role: .other, trackName: nil, gainDB: nil, at: nil, applied: nil,
            fonts: ["TiltWarp-Regular"], licence: nil
        )
        result.fontsReached = "app"
        XCTAssertTrue(result.readableText.contains("The Tandem app has it now too."), result.readableText)
    }
}
