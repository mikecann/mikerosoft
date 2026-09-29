import Foundation
import XCTest
@testable import TandemCore
@testable import TandemImport

/// The Mini fixture is an unzipped `.wfp` shaped like Mike's 2026 projects:
///
///     V3 (tag 8, locked)  chart 6-9 (push down in, push up out, 80%), sticker 10-11 (WebM),
///                         old B-roll 12-14 (missing, Sparkle transition, multiply), logo 14.5-16 (keyframes)
///     V2 (tag 6)          title template 1-4, camera PiP 5-12 (cutout, shadow)
///     V1 (tag 2, main)    camera 0-5 | screen 5-12 | camera 12-16 (fade to black) | camera 20-22 at 2x
///     audio lanes         the main track's sound and the PiP's sound
///     standalone audio    music bed 0-22, whooshes at 4.8 and 9 (the second reversed, track muted)
final class FilmoraImporterTests: XCTestCase {
    static let media: [String: ProbedMedia] = [
        "take-camera.mov": .video(120),
        "take-screen.mov": .video(120, width: 3200, height: 1800),
        "bed.mp3": .audio(300),
        "Cartoon Whoosh 02.m4a": .audio(0.8),
        "chart.mp4": .video(5, audio: false),
        "logo.png": .image(width: 800, height: 400, alpha: true)
    ]

    func importMini(from url: URL = Fixtures.url("wfp/Mini"), speechLevels: FilmoraImporter.SpeechLevels = .normalize) async throws -> ImportResult {
        let probe = FakeProbe(media: Self.media, undecodable: ["Subscribe Element.webm"])
        let importer = FilmoraImporter(locating: MediaLocating(prober: probe), speechLevels: speechLevels)
        return try await importer.importProject(at: url)
    }

    func testReadsTheProjectInfo() throws {
        let wfp = try WfpProject.load(from: Fixtures.url("wfp/Mini"))
        XCTAssertEqual(wfp.name, "Mini Filmora")
        XCTAssertEqual(wfp.frameRate, .fps25)
        XCTAssertEqual(wfp.width, 3840)
        XCTAssertEqual(wfp.height, 2160)
        XCTAssertEqual(wfp.mainTimeline?.tracks.count, 8)
        XCTAssertNotNil(wfp.timeline(2))
    }

    func testTracksKeepFilmoraLayeringAndGetNames() async throws {
        let result = try await importMini()
        let p = result.project
        assertValid(p)
        XCTAssertEqual(result.report.count(.failed), 0, result.report.text)
        XCTAssertEqual(p.name, "Mini Filmora")
        XCTAssertEqual(p.settings.frameRate, .fps25)
        XCTAssertEqual(p.settings.width, 3840)
        XCTAssertEqual(p.videoTracks.map(\.name), ["Main", "Camera", "Graphics"], "bottom to top, the empty track dropped")
        XCTAssertEqual(p.audioTracks.map(\.name), ["Voice", "Voice 2", "Music", "SFX"])
        XCTAssertEqual(p.videoTracks.map(\.rippleMode), [.cut, .cut, .follow])
        XCTAssertEqual(p.audioTracks.map(\.rippleMode), [.cut, .cut, .follow, .follow])
        XCTAssertTrue(p.track(named: "SFX")!.muted)
        XCTAssertTrue(p.track(named: "Graphics")!.locked)
    }

    func testClipsKeepTimesSourcesAndSpeed() async throws {
        let p = try await importMini().project
        let main = p.clips(on: "Main")
        XCTAssertEqual(main.map(\.range), [
            TimeRange(start: t(0), end: t(5)),
            TimeRange(start: t(5), end: t(12)),
            TimeRange(start: t(12), end: t(16)),
            TimeRange(start: t(20), end: t(22))
        ])
        XCTAssertEqual(main.map(\.sourceStart), [t(10), t(20), t(30), t(50)])
        XCTAssertEqual(main.map(\.speed), [1, 1, 1, 2], "speeds are Filmora's exact values, not rounded ratios")
        XCTAssertEqual(main[3].sourceEnd, t(54))
        XCTAssertEqual(p.media(main[1].mediaID!)?.path, "/FIXTURE/source/take-screen.mov")
        let music = p.clips(on: "Music")
        XCTAssertEqual(music.map(\.range), [TimeRange(start: .zero, end: t(22))])
        XCTAssertEqual(music[0].sourceStart, t(5))
        // A still starts at source 0 whatever Filmora's virtual in point was.
        let logo = p.clips(on: "Graphics").last!
        XCTAssertEqual(logo.sourceStart, .zero)
        XCTAssertEqual(p.media(logo.mediaID!)?.kind, .image)
    }

    func testTransformsCutoutShadowAndOpacity() async throws {
        let p = try await importMini().project
        let pip = p.clips(on: "Camera").first { $0.mediaID != nil }!
        XCTAssertEqual(pip.video?.transform.scale, 0.5)
        XCTAssertEqual(pip.video?.transform.position.x ?? 0, 0.8899, accuracy: 1e-9)
        XCTAssertEqual(pip.video?.transform.position.y ?? 0, 0.8004, accuracy: 1e-9)
        XCTAssertEqual(pip.video?.cutout?.enabled, true)
        let shadow = pip.video?.effects.first { $0.type == "dropShadow" }
        XCTAssertEqual(shadow?.params["distance"], .number(4))
        XCTAssertEqual(shadow?.params["blur"], .number(5))
        XCTAssertEqual(shadow?.params["opacity"], .number(60))
        XCTAssertNil(p.clips(on: "Main")[0].video?.cutout, "the full-frame camera has no cutout")
        XCTAssertEqual(pip.video?.layoutPreset, "pipRight")
        XCTAssertEqual(p.clips(on: "Main")[0].video?.layoutPreset, "full")
        XCTAssertNil(p.clips(on: "Main")[1].video?.layoutPreset, "only camera clips get a layout name")

        let graphics = p.clips(on: "Graphics")
        XCTAssertEqual(graphics[0].video?.opacity ?? 0, 0.8, accuracy: 1e-9)
        let logo = graphics.last!
        XCTAssertEqual(logo.video?.transform.rotation, 15)
        let scale = logo.keyframes["video.transform.scale"] ?? []
        XCTAssertEqual(scale.map(\.time), [.zero, t(1)])
        XCTAssertEqual(scale.map(\.value), [.number(1), .number(1.2)])
        let opacity = logo.keyframes["video.opacity"] ?? []
        XCTAssertEqual(opacity.map(\.time), [.zero, t(0.5)])
        XCTAssertEqual(opacity.map(\.value), [.number(0), .number(1)])
    }

    func testCameraGradeMovesToTheMediaLook() async throws {
        let p = try await importMini().project
        let camera = p.media.first { $0.path.hasSuffix("take-camera.mov") }!
        let hsl = camera.look.first { $0.type == "hsl" }
        XCTAssertEqual(hsl?.params["redSaturation"], .number(-17))
        XCTAssertEqual(camera.look.first { $0.type == "vignette" }?.params["amount"], .number(-30))
        XCTAssertEqual(camera.look.first { $0.type == "colorAdjust" }?.params["blackLevel"], .number(7))
        for clip in p.allTracks.flatMap(\.clips) where clip.mediaID == camera.id {
            XCTAssertFalse(clip.video?.effects.contains { ["hsl", "vignette", "colorAdjust"].contains($0.type) } ?? false)
        }
    }

    func testAudioLevelsAndFades() async throws {
        let result = try await importMini()
        let p = result.project
        // Speech is normalised to the speech level, as placing it would be,
        // instead of Filmora's +3 and +3.5 dB.
        for clip in p.clips(on: "Voice") + p.clips(on: "Voice 2") {
            XCTAssertEqual(clip.audio?.normalizeTo, -20, clip.name ?? clip.id)
            XCTAssertEqual(clip.audio?.gainDB, 0, clip.name ?? clip.id)
        }
        XCTAssertTrue(result.report.items(.note).contains { $0.message.hasPrefix("5 speech clips were normalised to -20 LUFS") && $0.message.contains("+0.0 to +3.5 dB") }, result.report.text)
        XCTAssertEqual(p.clips(on: "Voice")[2].audio?.fadeOut, t(1))
        let music = p.clips(on: "Music")[0]
        XCTAssertEqual(music.audio?.gainDB ?? 0, -30.6, accuracy: 1e-9)
        XCTAssertEqual(music.audio?.fadeIn, t(1))
        XCTAssertEqual(music.audio?.fadeOut, t(2))
        let whooshes = p.clips(on: "SFX")
        XCTAssertEqual(whooshes.map(\.audio?.gainDB), [-15, -15])
        XCTAssertEqual(whooshes[1].audio?.fadeOut, whooshes[1].duration, "a fade longer than its clip is clamped")
    }

    func testKeepingFilmorasLevels() async throws {
        let result = try await importMini(speechLevels: .keepFilmora)
        let p = result.project
        // Filmora's Auto Normalization levels to about -24 LUFS on Tandem's
        // meter, then adds the clip's LoudnessGain.
        let voice = p.clips(on: "Voice")
        XCTAssertEqual(voice[0].audio?.normalizeTo, -24)
        XCTAssertEqual(voice[0].audio?.gainDB, 3)
        XCTAssertEqual(p.clips(on: "Voice 2")[0].audio?.normalizeTo, -24)
        XCTAssertEqual(p.clips(on: "Voice 2")[0].audio?.gainDB, 3.5)
        let screen = try XCTUnwrap(voice.first { p.media($0.mediaID!)?.role == .screen })
        XCTAssertNil(screen.audio?.normalizeTo, "no Auto Normalization, just its volume")
        XCTAssertEqual(p.clips(on: "Music")[0].audio?.gainDB ?? 0, -30.6, accuracy: 1e-9)
        XCTAssertTrue(result.report.items(.note).contains { $0.message.hasPrefix("Filmora's Auto Normalization became normalise to -24 LUFS") }, result.report.text)
        XCTAssertFalse(result.report.text.contains("speech clips were normalised"))
    }

    func testTransitionsMapToTandemTypes() async throws {
        let result = try await importMini()
        let p = result.project
        let main = p.track(named: "Main")!
        let cutSlide = main.transitions.first { $0.type == .cutSlide }
        XCTAssertEqual(cutSlide?.fromClipID, main.clips[0].id)
        XCTAssertEqual(cutSlide?.toClipID, main.clips[1].id)
        XCTAssertEqual(cutSlide?.duration, t(1.04))
        let fade = main.transitions.first { $0.type == .fadeToBlack }
        XCTAssertEqual(fade?.fromClipID, main.clips[2].id)
        XCTAssertNil(fade?.toClipID)
        XCTAssertEqual(fade?.duration, t(1))

        let voice = p.track(named: "Voice")!
        XCTAssertEqual(voice.transitions.map(\.type), [.dissolve, .dissolve], "audio fades play as crossfades")
        XCTAssertTrue(voice.transitions.contains { $0.fromClipID == voice.clips[0].id && $0.toClipID == voice.clips[1].id })

        let graphics = p.track(named: "Graphics")!
        let chart = graphics.clips[0]
        let slideIn = graphics.transitions.first { $0.toClipID == chart.id && $0.fromClipID == nil }
        let slideOut = graphics.transitions.first { $0.fromClipID == chart.id && $0.toClipID == nil }
        XCTAssertEqual(slideIn?.type, .push)
        XCTAssertEqual(slideIn?.direction, .down)
        XCTAssertEqual(slideIn?.duration, t(0.6))
        XCTAssertEqual(slideOut?.direction, .up)
        XCTAssertEqual(slideOut?.duration, t(0.8))
        let sparkle = graphics.transitions.first { $0.toClipID == graphics.clips[1].id }
        XCTAssertEqual(sparkle?.type, .dissolve)
        XCTAssertTrue(result.report.items(.approximated).contains { $0.message.contains("Sparkle Motion Transition 15") })
    }

    func testTitlesBecomeTextClips() async throws {
        let p = try await importMini().project
        let title = p.clips(on: "Camera").first { $0.mediaID == nil }!
        XCTAssertEqual(title.range, TimeRange(start: t(1), end: t(4)))
        guard case .text(let text) = title.content else { return XCTFail("expected text") }
        XCTAssertEqual(text.text, "Hello\nTandem")
        XCTAssertEqual(text.style.font, "Arial Black")
        XCTAssertEqual(text.style.weight, 900)
        XCTAssertEqual(text.style.color, RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(text.style.strokeColor, RGBA(r: 0, g: 0, b: 0))
        XCTAssertEqual(text.style.strokeWidth, 3)
        XCTAssertTrue(text.style.shadow)
        XCTAssertEqual(text.style.alignment, "left")
        XCTAssertEqual(text.animationIn, "typewriter")
        XCTAssertEqual(text.animationDuration, t(0.5))
        XCTAssertGreaterThan(text.style.size, 20)
        XCTAssertEqual(title.video?.transform.position, Point(x: 0.5, y: 0.86))
        XCTAssertTrue(title.tags.contains("filmora-template:Basic 1"))
    }

    func testClipsFromOneTakeAreLinked() async throws {
        let p = try await importMini().project
        let main = p.clips(on: "Main")
        let voice = p.clips(on: "Voice")
        XCTAssertEqual(Set(p.linkedClipIDs(of: main[0].id)), [main[0].id, voice[0].id])
        let pip = p.clips(on: "Camera").first { $0.mediaID != nil }!
        let pipVoice = p.clips(on: "Voice 2")[0]
        // The screen on the main track and the camera in the corner are one take.
        XCTAssertEqual(Set(p.linkedClipIDs(of: main[1].id)), [main[1].id, voice[1].id, pip.id, pipVoice.id])
        XCTAssertNil(p.clips(on: "Music")[0].linkGroup)
    }

    func testUnsupportedAndMissingThingsAreReported() async throws {
        let result = try await importMini()
        let p = result.project
        let report = result.report
        // The WebM sticker can't be decoded: left out, with a marker where it was.
        let sticker = p.markers.first { $0.kind == .todo }
        XCTAssertEqual(sticker?.time, t(10))
        XCTAssertTrue(sticker?.name.contains("Subscribe Element") ?? false)
        XCTAssertTrue(report.items(.unsupported).contains { $0.message.contains("Subscribe Element.webm") })
        // Missing B-roll stays on the timeline, offline, with the length Filmora recorded.
        let broll = p.clips(on: "Graphics")[1]
        XCTAssertEqual(p.media(broll.mediaID!)?.path, "/FIXTURE/gone/old-broll.mp4")
        XCTAssertEqual(p.media(broll.mediaID!)?.duration, t(10))
        XCTAssertEqual(report.count(.missingMedia), 1)
        XCTAssertTrue(report.items(.unsupported).contains { $0.message.contains("Multiply") })
        XCTAssertTrue(report.items(.unsupported).contains { $0.message.lowercased().contains("reverse") })
        // Filmora's markers come across with their comments.
        let markers = p.markers.filter { $0.kind == .marker }
        XCTAssertEqual(markers.map(\.time), [t(3), t(12)])
        XCTAssertEqual(markers.map(\.name), ["Marker", "Chapter 2"])
        XCTAssertEqual(markers[0].note, "check this")
    }

    func testZippedProjectImportsTheSame() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("Mini Filmora.wfp")
        try Fixtures.zip(Fixtures.url("wfp/Mini"), to: archive)
        var zipped = try await importMini(from: archive).project
        var unzipped = try await importMini().project
        zipped.metadata["importedFrom"] = nil
        unzipped.metadata["importedFrom"] = nil
        XCTAssertEqual(canonicalLinks(zipped), canonicalLinks(unzipped))
    }

    func testImportIsDeterministic() async throws {
        let first = try await importMini().project
        let second = try await importMini().project
        // Link group IDs come from the coordinator's own generator, so only
        // who is linked with whom has to match.
        XCTAssertEqual(canonicalLinks(first), canonicalLinks(second), "same file, same IDs")
    }

    /// Renames each link group after its members.
    func canonicalLinks(_ project: Project) -> Project {
        var members: [String: [String]] = [:]
        for clip in project.allTracks.flatMap(\.clips) {
            if let group = clip.linkGroup { members[group, default: []].append(clip.id) }
        }
        var result = project
        for location in result.trackLocations {
            for i in result[location].clips.indices {
                if let group = result[location].clips[i].linkGroup {
                    result[location].clips[i].linkGroup = "group:" + members[group]!.sorted().joined(separator: ",")
                }
            }
        }
        return result
    }
}

final class FilmoraMappingTests: XCTestCase {
    func clip(_ json: String) -> WfpClip {
        WfpClip(JSONNode(jsonString: json))
    }

    func testSpeedComesFromFilmorasOwnValue() {
        // Filmora's inclusive ends leave the source range a tick short.
        let normal = clip(#"{"type": 1, "tlBegin": 323500000, "tlEnd": 408399999, "inPoint": 1490000000, "outPoint": 1574899999, "speed": {"offset": 149.0, "offsetEnd": 157.4899999, "speedParam": "{\"Version\": 3, \"keyframeSets\": [{\"_time\": 0.0, \"_value\": 1.0}, {\"_time\": 671.39, \"_value\": 1.0}]}"}}"#)
        let speed = FilmoraSpeed(normal)
        XCTAssertEqual(speed.uniform, 1)
        XCTAssertFalse(speed.ramp)
        XCTAssertEqual(speed.sourceStart, 149)
        // In and out points are divided by the speed; offsets aren't.
        let fast = clip(#"{"type": 1, "tlBegin": 0, "tlEnd": 51539999, "inPoint": 508120000, "outPoint": 559669999, "speed": {"offset": 406.5, "offsetEnd": 447.733, "speedParam": "{\"Version\": 3, \"keyframeSets\": [{\"_time\": 0.0, \"_value\": 8.0}, {\"_time\": 762.4, \"_value\": 1.0}]}"}}"#)
        XCTAssertEqual(FilmoraSpeed(fast).uniform, 8)
        XCTAssertEqual(FilmoraSpeed(fast).sourceStart, 406.5)
        let ramp = clip(#"{"type": 1, "tlBegin": 0, "tlEnd": 49999999, "speed": {"offset": 0.0, "offsetEnd": 4.3, "speedParam": "{\"Version\": 2, \"keyframeSets\": [{\"_time\": 0.0, \"_value\": 1.0}, {\"_time\": 3.2, \"_value\": 0.98}, {\"_time\": 3.7, \"_value\": 0.4}, {\"_time\": 5.0, \"_value\": 0.1}]}"}}"#)
        XCTAssertTrue(FilmoraSpeed(ramp).ramp)
        XCTAssertNil(FilmoraSpeed(ramp).uniform)
        let reversed = clip(#"{"type": 2, "tlBegin": 0, "tlEnd": 9999999, "speed": {"offset": 0.0, "offsetEnd": 1.0, "reverse": true}}"#)
        XCTAssertTrue(FilmoraSpeed(reversed).reverse)
    }

    func testTransitionNamesMapOntoTandemTypes() {
        typealias M = FilmoraTransitions.Mapped
        XCTAssertEqual(FilmoraTransitions.map("Cut Slide Transition 03", onAudio: false, placement: .between), M(type: .cutSlide, direction: nil, exact: true))
        XCTAssertEqual(FilmoraTransitions.map("Push Down", onAudio: false, placement: .head), M(type: .push, direction: .down, exact: true))
        XCTAssertEqual(FilmoraTransitions.map("Push Up", onAudio: false, placement: .tail), M(type: .push, direction: .up, exact: true))
        XCTAssertEqual(FilmoraTransitions.map("Push Left", onAudio: false, placement: .between), M(type: .push, direction: .left, exact: true))
        XCTAssertEqual(FilmoraTransitions.map("Fast Push Right", onAudio: false, placement: .between), M(type: .push, direction: .right, exact: true))
        XCTAssertEqual(FilmoraTransitions.map("Dissolve", onAudio: false, placement: .between), M(type: .dissolve, direction: nil, exact: true))
        XCTAssertEqual(FilmoraTransitions.map("fade_black", onAudio: false, placement: .tail).type, .fadeToBlack)
        XCTAssertEqual(FilmoraTransitions.map("fade_black", onAudio: false, placement: .head).type, .fadeFromBlack)
        XCTAssertEqual(FilmoraTransitions.map("Fast Wipe Up", onAudio: false, placement: .between), M(type: .wipe, direction: .up, exact: true))
        XCTAssertEqual(FilmoraTransitions.map("Basic Zoom In", onAudio: false, placement: .between).type, .zoom)
        XCTAssertFalse(FilmoraTransitions.map("Sparkle Motion Transition 15", onAudio: false, placement: .between).exact)
        XCTAssertEqual(FilmoraTransitions.map("audio fade", onAudio: true, placement: .between), M(type: .dissolve, direction: nil, exact: true))
        XCTAssertEqual(FilmoraTransitions.map("Push Left", onAudio: true, placement: .between).type, .dissolve, "audio always crossfades")
    }

    func testColourGradeMapsOntoTandemEffects() {
        let params = JSONNode(jsonString: #"{"bEnableHSL": 1, "Red_satVal": -17.0, "Purple_satVal": -21.0, "Aqua_hueVal": 4.0, "Red_brightnessVal": 2.0, "Red_degreeMinVal": 3.0, "amount": -34.0, "size": 60.0, "roundness": 20.0, "u_blackLevel": 7.0, "u_contrast": 25.0, "u_temperature": -3.0, "u_exposure": 10.0, "u_saturation": 0.0}"#).object!
        let mapped = FilmoraColour.map(params, idKey: "clip")
        let byType = Dictionary(uniqueKeysWithValues: mapped.effects.map { ($0.type, $0.params) })
        XCTAssertEqual(byType["hsl"], ["redSaturation": .number(-17), "purpleSaturation": .number(-21), "aquaHue": .number(4), "redLuminance": .number(2)])
        XCTAssertEqual(byType["vignette"], ["amount": .number(-34), "size": .number(60)])
        XCTAssertEqual(byType["colorAdjust"]?["blackLevel"], .number(7))
        XCTAssertEqual(byType["colorAdjust"]?["contrast"], .number(25))
        XCTAssertEqual(byType["colorAdjust"]?["temperature"], .number(-3))
        XCTAssertNotNil(byType["colorAdjust"]?["exposure"])
        XCTAssertEqual(mapped.approximated, ["u_exposure"])
        XCTAssertEqual(mapped.unmapped, ["roundness"])
    }

    func testTitleColoursAreRGB() {
        XCTAssertEqual(FilmoraText.color(16_777_215), .white)
        XCTAssertEqual(FilmoraText.color(0xD4AA57), RGBA(r: 0xD4 / 255.0, g: 0xAA / 255.0, b: 0x57 / 255.0), "the gold of Mike's awards titles")
        XCTAssertNil(FilmoraText.color(-1), "-1 means not set")
        XCTAssertEqual(FilmoraText.weight(font: "HarmonyOS Sans Black", bold: false), 900)
        XCTAssertEqual(FilmoraText.weight(font: "Kanit Bold", bold: false), 700)
        XCTAssertEqual(FilmoraText.weight(font: "Arial", bold: true), 700)
        XCTAssertEqual(FilmoraText.animationName("Typewriter Appears", entering: true), "typewriter")
        XCTAssertEqual(FilmoraText.animationName("Up Dir Insert", entering: true), "slideUp")
        XCTAssertNil(FilmoraText.animationName("Wavy Appearance", entering: true))
        XCTAssertTrue(FilmoraText.isPlaceholder("Text Here"))
        XCTAssertFalse(FilmoraText.isPlaceholder("v1.46.0"))
    }

    func testKeyframeListsInTicksOrSeconds() {
        let seconds = JSONNode(jsonString: #"{"Version": 3, "keyframeSets": [{"_time": 3600.04, "_value": 55.3}, {"_time": 3600.5, "_value": 80.0}]}"#)
        let ticks = JSONNode(jsonString: #"{"Version": 2, "keyframeSets": [{"_time": 36000400000.0, "_value": 0.0}, {"_time": 36005000000.0, "_value": 100.0}]}"#)
        let a = FilmoraKeyframes.points(seconds, sourceStart: 3600, speed: 1)
        XCTAssertEqual(a.map { ($0.time * 1000).rounded() / 1000 }, [0.04, 0.5], "relative to the clip's source start")
        let b = FilmoraKeyframes.points(ticks, sourceStart: 3600, speed: 1)
        XCTAssertEqual(b.map { ($0.time * 1000).rounded() / 1000 }, [0.04, 0.5])
        XCTAssertEqual(FilmoraKeyframes.value(b, at: 0.27) ?? -1, 50, accuracy: 1e-6)
        XCTAssertEqual(FilmoraKeyframes.points(seconds, sourceStart: 3600, speed: 2).last?.time ?? 0, 0.25, accuracy: 1e-9, "twice as fast, half the time")
    }

    func testPathsFromFilmoraFilenames() {
        XCTAssertEqual(Wfp.path(fromFilename: "file://Users/m5-mike/a b/c.mov"), "/Users/m5-mike/a b/c.mov")
        XCTAssertEqual(Wfp.path(fromFilename: "file:///Users/x/c.mov"), "/Users/x/c.mov")
        XCTAssertEqual(Wfp.path(fromFilename: "file:/Users/x/c.mov"), "/Users/x/c.mov")
        XCTAssertNil(Wfp.path(fromFilename: "6_Cartoon_Whoosh_02/Data/Cartoon Whoosh 02.m4a"), "relative library paths use the resource's path")
    }
}
