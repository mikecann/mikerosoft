import XCTest
@testable import TandemApp
@testable import TandemAssets
@testable import TandemCore

final class AssetApplyingTests: XCTestCase {
    private func placement(_ asset: Asset, files: [String]) -> AssetPlacement {
        AssetPlacement(asset: asset, mediaItem: nil, files: files, role: .other, trackName: nil, audio: nil)
    }

    func testLooksGradePicturesAndFontsSetTitles() throws {
        let fixture = try AppFixture()
        try fixture.apply(EditBatch(label: "Title", commands: [
            .insertClip(trackID: fixture.track("Text").id, clip: Clip(id: "clip_title", content: .text(TextContent(text: "Hello", preset: "callout")), start: t(2), duration: t(3)), mode: .overwrite)
        ]))
        let camera = fixture.clip("Camera")
        let title = try XCTUnwrap(fixture.project.clip("clip_title"))
        let music = fixture.clip("Music")
        let look = Asset(provider: "import", providerID: "looks/teal.cube", kind: .lut, name: "Teal and orange")
        let font = Asset(provider: "fontsource", providerID: "inter", kind: .font, name: "Inter")
        let sticker = Asset(provider: "noto", providerID: "1f680", kind: .sticker, name: "Rocket")

        XCTAssertTrue(AssetApplying.canApply(look, to: camera, trackKind: .video))
        XCTAssertFalse(AssetApplying.canApply(look, to: music, trackKind: .audio), "a look is for pictures")
        XCTAssertFalse(AssetApplying.canApply(look, to: title, trackKind: .video), "and not for titles")
        XCTAssertTrue(AssetApplying.canApply(font, to: title, trackKind: .video))
        XCTAssertFalse(AssetApplying.canApply(font, to: camera, trackKind: .video), "a font is for titles")
        XCTAssertFalse(AssetApplying.canApply(sticker, to: camera, trackKind: .video), "media is placed, not applied")
        XCTAssertTrue(AssetApplying.appliesToClips(look.kind))
        XCTAssertFalse(AssetApplying.appliesToClips(sticker.kind))
        XCTAssertEqual(AssetApplying.targets(for: font, among: [camera.id, title.id, music.id], in: fixture.project), [title.id])

        let graded = AssetApplying.commands(for: placement(look, files: ["assets/lut/teal-abcdefgh.cube"]), on: camera, effectID: "fx_look")
        try fixture.apply(EditBatch(label: "Look", commands: graded))
        let lut = try XCTUnwrap(fixture.clip("Camera").video?.effects.first { $0.type == "lut" })
        XCTAssertEqual(lut.params["path"], .string("assets/lut/teal-abcdefgh.cube"))
        XCTAssertEqual(lut.params["intensity"], .number(1))
        // A second look replaces the file rather than stacking another LUT.
        try fixture.apply(EditBatch(label: "Off", commands: [.updateEffect(clipID: camera.id, effectID: lut.id, patch: .object(["enabled": .bool(false)]))]))
        let regraded = AssetApplying.commands(for: placement(look, files: ["assets/lut/cool-abcdefgh.cube"]), on: fixture.clip("Camera"), effectID: "fx_other")
        try fixture.apply(EditBatch(label: "Look again", commands: regraded))
        let luts = fixture.clip("Camera").video?.effects.filter { $0.type == "lut" } ?? []
        XCTAssertEqual(luts.count, 1)
        XCTAssertEqual(luts.first?.params["path"], .string("assets/lut/cool-abcdefgh.cube"))
        XCTAssertEqual(luts.first?.enabled, true, "and turns it back on")

        try fixture.apply(EditBatch(label: "Font", commands: AssetApplying.commands(for: placement(font, files: ["assets/font/inter-abcdefgh.ttf"]), on: title)))
        guard case .text(let text)? = fixture.project.clip("clip_title")?.content else { return XCTFail("expected a title") }
        XCTAssertEqual(text.style.font, "Inter")
        XCTAssertEqual(text.text, "Hello", "only the typeface changes")
        XCTAssertEqual(text.preset, "callout")
        let named = AssetApplying.commands(for: placement(font, files: []), on: title, family: "Inter Display")
        try fixture.apply(EditBatch(label: "Family", commands: named))
        guard case .text(let renamed)? = fixture.project.clip("clip_title")?.content else { return XCTFail("expected a title") }
        XCTAssertEqual(renamed.style.font, "Inter Display", "the family the font file names wins")
        assertValid(fixture.project)

        XCTAssertEqual(AssetApplying.label(for: look, count: 1), "Apply Teal and orange")
        XCTAssertEqual(AssetApplying.label(for: look, count: 3), "Apply Teal and orange to 3 clips")
        XCTAssertEqual(AssetApplying.label(for: font, count: 2), "Set 2 titles in Inter")
        XCTAssertEqual(AssetApplying.dropLabel(for: look, clipName: "Camera"), "Grade Camera with Teal and orange")
        XCTAssertTrue(AssetApplying.commands(for: placement(sticker, files: ["assets/sticker/rocket.mov"]), on: camera).isEmpty)
    }

    func testSpaceOverTheBrowserPreviews() {
        XCTAssertEqual(SpaceKey.action(previewing: nil, hovered: nil), .playPause)
        XCTAssertEqual(SpaceKey.action(previewing: nil, hovered: "noto:1f680"), .open("noto:1f680"))
        XCTAssertEqual(SpaceKey.action(previewing: "noto:1f680", hovered: "noto:1f680"), .close)
        XCTAssertEqual(SpaceKey.action(previewing: "noto:1f680", hovered: nil), .close)
        XCTAssertEqual(SpaceKey.action(previewing: "noto:1f680", hovered: "noto:1f525"), .open("noto:1f525"), "hovering another asset switches to it")
    }

    func testGenerationFormsBuildRequests() {
        var music = GenerationForm(kind: .music)
        XCTAssertEqual(music.problem, "Describe the music you want.")
        XCTAssertEqual(music.seconds, 30)
        music.prompt = "  calm lo-fi bed with soft keys  "
        music.seconds = 900
        music.takes = 9
        XCTAssertNil(music.problem)
        let request = music.request
        XCTAssertEqual(request.kind, .music)
        XCTAssertEqual(request.prompt, "calm lo-fi bed with soft keys")
        XCTAssertEqual(request.duration, 600)
        XCTAssertEqual(request.variations, 4)
        XCTAssertTrue(request.instrumental)
        XCTAssertFalse(request.loop)
        XCTAssertEqual(music.costNote, "4 paid requests, one a take.")

        var sfx = GenerationForm(kind: .sfx)
        XCTAssertEqual(sfx.seconds, 3)
        XCTAssertEqual(sfx.problem, "Describe the sound you want.")
        sfx.prompt = "soft whoosh"
        XCTAssertEqual(sfx.costNote, "About 120 credits, at 40 a second.")
        sfx.loop = true
        sfx.seconds = 0.1
        XCTAssertEqual(sfx.request.duration, 0.5)
        XCTAssertTrue(sfx.request.loop)
        XCTAssertEqual(sfx.range, 0.5...30)
        XCTAssertEqual(music.range, 3...600)
        // Both bodies pass the provider's own checks.
        XCTAssertNoThrow(try ElevenLabsProvider.musicBody(music.request, prompt: music.request.prompt))
        XCTAssertNoThrow(try ElevenLabsProvider.soundBody(sfx.request, prompt: sfx.request.prompt))
        XCTAssertEqual(GenerationForm.permission(for: .sfx), ElevenLabsProvider.permission(for: .sfx))
        XCTAssertEqual(GenerationForm.permission(for: .music), ElevenLabsProvider.permission(for: .music))
    }

    func testGeneratingSaysWhatsMissing() {
        let noKey = ProviderStatus(.needsKey, "Add an ElevenLabs API key to the Keychain: security add-generic-password -s elevenlabs -a elevenlabs -w")
        let blocked = GenerationForm.blocker(for: .music, status: noKey, refused: [])
        XCTAssertEqual(blocked?.canTry, false)
        XCTAssertTrue(blocked?.message.contains("security add-generic-password") == true)

        let limited = ProviderStatus(.limited, "Sound effects are off: missing_permissions. Music still works.")
        XCTAssertNil(GenerationForm.blocker(for: .music, status: limited, refused: ["sound_generation"]), "music still works")
        let sfx = GenerationForm.blocker(for: .sfx, status: limited, refused: ["sound_generation"])
        XCTAssertEqual(sfx?.canTry, true, "the permission may have been turned on since")
        XCTAssertTrue(sfx?.message.contains("sound_generation") == true)
        XCTAssertNil(GenerationForm.blocker(for: .sfx, status: .ready, refused: []))
        XCTAssertEqual(GenerationForm.blocker(for: .sfx, status: nil, refused: [])?.canTry, false)
    }
}
