import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

/// Renders the Colour tab offscreen, to look at:
///
///     TANDEM_COLOUR_UI_OUT=~/dev/me/tandem-research/colour-ui \
///     swift test --package-path tools/tandem --filter ColourInspectorSnapshots
///
/// Without the variable it still renders each state once, so a view that
/// can't be built fails here rather than in the app.
@MainActor
final class ColourInspectorSnapshots: XCTestCase {
    private var folder: URL!
    private var model: EditorModel!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-colour-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Colour.tandem"), name: "Colour", owner: .app)
        model = EditorModel(session: session)
        let camera = MediaItem(
            id: "med_camera", path: "source/take1-camera.mov", kind: .video, role: .camera,
            takeID: "take1", takeOffset: .zero, duration: t(60), frameRate: .fps30,
            width: 3840, height: 2160, hasVideo: true, hasAudio: true
        )
        let screen = MediaItem(
            id: "med_screen", path: "source/take1-screen.mov", kind: .video, role: .screen,
            takeID: "take1", takeOffset: .zero, duration: t(60), frameRate: .fps30,
            width: 3200, height: 1800, hasVideo: true, hasAudio: false
        )
        let result = model.apply(EditBatch(label: "Build", commands: [
            .addMedia(item: camera),
            .addMedia(item: screen),
            .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(60))
        ]))
        XCTAssertNotNil(result)
        // Cut the take so the whole take has several clips.
        let first = try XCTUnwrap(cameraClips.first)
        model.apply(EditBatch(label: "Cuts", commands: [30.0, 20, 10].map { .blade(at: t($0), clipIDs: [first.id]) }))
    }

    override func tearDown() async throws {
        model.tearDown()
        _ = model.session.close()
        try? FileManager.default.removeItem(at: folder)
        AppDefaults.store.removeObject(forKey: "colourCollapsedSections")
    }

    private var cameraClips: [Clip] {
        model.project.track(named: "Camera")?.clips ?? []
    }

    /// Mike's usual camera grade, plus a touch of the new wheels.
    private func gradeTheTake() {
        model.apply(InspectorEdits.look("med_camera", [
            Effect(id: "fx_adjust", type: "colorAdjust", params: [
                "contrast": .number(25), "blackLevel": .number(-7), "temperature": .number(-3), "saturation": .number(8)
            ]),
            Effect(id: "fx_wheels", type: "colorWheels", params: [
                "shadowsHue": .number(200), "shadowsAmount": .number(14),
                "highlightsHue": .number(35), "highlightsAmount": .number(10), "highlightsBrightness": .number(4)
            ]),
            Effect(id: "fx_hsl", type: "hsl", params: ["redSaturation": .number(-8), "orangeSaturation": .number(-8)]),
            Effect(id: "fx_vignette", type: "vignette", params: ["amount": .number(-30)]),
            Effect(id: "fx_sharpen", type: "sharpen", params: ["amount": .number(3)])
        ], label: "Grade"))
    }

    private func panel(_ clip: Clip, width: CGFloat = 330) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ClipHeader(model: model, clip: clip)
            ColourInspector(model: model, clip: clip)
        }
        .frame(width: width, alignment: .top)
        .background(Theme.panel.color)
        .environment(\.colorScheme, .dark)
    }

    @discardableResult
    private func render(_ view: some View, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "\(name) didn't render", file: file, line: line)
        XCTAssertGreaterThan(image.height, 200, name, file: file, line: line)
        if let out = ProcessInfo.processInfo.environment["TANDEM_COLOUR_UI_OUT"], !out.isEmpty {
            let dir = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name + ".png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        return image
    }

    func testWholeTake() throws {
        gradeTheTake()
        let clip = try XCTUnwrap(cameraClips.dropFirst().first)
        model.selection = [clip.id]
        try render(panel(clip), "1-whole-take")
        try render(panel(clip, width: 300), "5-narrow-300")
        try render(panel(clip, width: 440), "6-wide-440")
    }

    func testUngradedTake() throws {
        let clip = try XCTUnwrap(cameraClips.first)
        try render(panel(clip), "2-ungraded")
    }

    func testThisClipWithAnimation() throws {
        gradeTheTake()
        let clip = try XCTUnwrap(cameraClips.first)
        // The clip's own exposure, animated, and a warmer white balance.
        model.apply(EditBatch(label: "Clip grade", commands: [
            .addEffect(clipID: clip.id, effect: Effect(id: "fx_mine", type: "colorAdjust", params: ["exposure": .number(0.3), "temperature": .number(12)]), index: nil),
            .setKeyframes(clipID: clip.id, parameter: "video.effects.fx_mine.exposure", keyframes: [
                Keyframe(time: t(0), value: .number(0)), Keyframe(time: t(5), value: .number(0.6))
            ])
        ]))
        let updated = try XCTUnwrap(model.project.clip(clip.id))
        let view = ColourInspectorWithTarget(model: model, clip: updated)
        try render(view.frame(width: 330).background(Theme.panel.color).environment(\.colorScheme, .dark), "3-this-clip")
    }

    func testLightOffAndCollapsedSections() throws {
        gradeTheTake()
        let clip = try XCTUnwrap(cameraClips.first)
        let look = try XCTUnwrap(model.project.media("med_camera")?.look)
        let change = try XCTUnwrap(ColourGrade(look).toggling(.light))
        model.apply(InspectorEdits.look("med_camera", change.effects, label: change.label))
        AppDefaults.store.set("wheels,mixer,vignette,lut", forKey: "colourCollapsedSections")
        try render(panel(clip), "4-light-off-collapsed")
    }

    func testTitleClip() throws {
        let track = try XCTUnwrap(model.project.track(named: "Text"))
        model.apply(EditBatch(label: "Title", commands: [
            .insertClip(trackID: track.id, clip: Clip(id: "clip_title", content: .text(TextContent(text: "TIP 1", preset: "callout")), start: t(2), duration: t(3)), mode: .place)
        ]))
        let clip = try XCTUnwrap(model.project.clip("clip_title"))
        try render(panel(clip), "7-title")
    }
}

/// The Colour tab switched to This clip, as a click on the switch would.
@MainActor
private struct ColourInspectorWithTarget: View {
    let model: EditorModel
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClipHeader(model: model, clip: clip)
            ColourInspector(model: model, clip: clip, initialTarget: .clip)
        }
    }
}

/// The tab's edits reach the project through the editor model: the look
/// for the whole take, the clip's effects (with keyframes) for this clip,
/// each as one undo step with a name that reads well.
@MainActor
final class ColourEditorTests: XCTestCase {
    private var folder: URL!
    private var model: EditorModel!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-colour-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Colour.tandem"), name: "Colour", owner: .app)
        model = EditorModel(session: session)
        let camera = MediaItem(
            id: "med_camera", path: "source/take1-camera.mov", kind: .video, role: .camera,
            takeID: "take1", takeOffset: .zero, duration: t(60), frameRate: .fps30,
            width: 3840, height: 2160, hasVideo: true, hasAudio: true
        )
        model.apply(EditBatch(label: "Build", commands: [
            .addMedia(item: camera),
            .placeMedia(mediaIDs: ["med_camera"], at: .zero, duration: t(60))
        ]))
    }

    override func tearDown() async throws {
        model.tearDown()
        _ = model.session.close()
        try? FileManager.default.removeItem(at: folder)
    }

    private var clip: Clip { model.project.track(named: "Camera")!.clips[0] }
    private var look: [Effect] { model.project.media("med_camera")?.look ?? [] }

    private func editor(_ target: ColourTarget) -> ColourEditor {
        ColourEditor(model: model, clip: clip, item: model.media(for: clip), target: target)
    }

    func testTheWholeTakeEditsTheLook() {
        editor(.take).set(.light, ["contrast": .number(25)], label: "Contrast")
        XCTAssertEqual(look.count, 1)
        XCTAssertEqual(look.first?.type, "colorAdjust")
        XCTAssertEqual(look.first?.params["contrast"], .number(25))
        XCTAssertEqual(model.session.coordinator.undoLabel, "Contrast (whole take)")
        XCTAssertTrue(clip.video?.effects.isEmpty ?? true, "the clip itself is untouched")

        editor(.take).set(.colour, ["temperature": .number(-3)], label: "Temperature")
        XCTAssertEqual(look.count, 1, "Light and Colour share one effect")
        editor(.take).toggle(.light)
        XCTAssertEqual(look.map(\.enabled), [false, true])
        XCTAssertEqual(model.session.coordinator.undoLabel, "Turn off light (whole take)")
        editor(.take).reset(.colour)
        XCTAssertEqual(look.count, 1)
        XCTAssertEqual(model.session.coordinator.undoLabel, "Reset colour (whole take)")
        // Light is still off: changing it turns it back on.
        editor(.take).set(.light, ["contrast": .number(25)], label: "Contrast")
        XCTAssertEqual(look.map(\.enabled), [true])
        // Nothing to do makes no undo step.
        let revision = model.revision
        editor(.take).set(.light, ["contrast": .number(25)], label: "Contrast")
        XCTAssertEqual(model.revision, revision)
    }

    func testThisClipEditsTheClipAndItsKeyframes() throws {
        editor(.clip).set(.mixer, ["redSaturation": .number(-8)], label: "Red saturation")
        let hsl = try XCTUnwrap(clip.video?.effects.first)
        XCTAssertEqual(hsl.type, "hsl")
        XCTAssertEqual(hsl.params["redSaturation"], .number(-8))
        XCTAssertEqual(model.session.coordinator.undoLabel, "Red saturation")
        XCTAssertTrue(look.isEmpty, "the take's look is untouched")

        // Animate it, then a change at the playhead sets a keyframe.
        let path = "video.effects.\(hsl.id).redSaturation"
        model.apply(EditBatch(label: "Animate", commands: [.setKeyframes(clipID: clip.id, parameter: path, keyframes: [
            Keyframe(time: t(0), value: .number(-8)), Keyframe(time: t(10), value: .number(0))
        ])]))
        model.playback.seek(to: t(5))
        editor(.clip).set(.mixer, ["redSaturation": .number(-20)], label: "Red saturation")
        XCTAssertEqual(clip.keyframes[path]?.map(\.value), [.number(-8), .number(-20), .number(0)])
        XCTAssertEqual(clip.video?.effects.first?.params["redSaturation"], .number(-8), "the plain value stays")

        editor(.clip).reset(.mixer)
        XCTAssertTrue(clip.video?.effects.isEmpty ?? false)
        XCTAssertNil(clip.keyframes[path], "its animation goes with it")
    }

    func testTheTabOpensWhereTheGradeIs() {
        let item = model.media(for: clip)!
        XCTAssertEqual(ColourInspector.defaultTarget(for: clip, item: item), .take, "a camera take")
        editor(.clip).set(.light, ["exposure": .number(0.5)], label: "Exposure")
        XCTAssertEqual(ColourInspector.defaultTarget(for: clip, item: model.media(for: clip)!), .clip, "only the clip is graded")
        editor(.take).set(.light, ["contrast": .number(10)], label: "Contrast")
        XCTAssertEqual(ColourInspector.defaultTarget(for: clip, item: model.media(for: clip)!), .take, "both: the take, as Mike grades")
    }
}
