import Foundation
import XCTest
@testable import TandemCore
@testable import TandemImport

/// The mini fixture is a small version of decision-models: two takes, an
/// intro that replaces the first segment, a loosened cut, a layout
/// override, B-roll in the EDL, graphics, music cues and sound effects.
/// Expected timeline (seconds):
///
///     0-5 intro | 5-9.5 cam | 9.5-14.5 scr | 14.5-18.5 scr | 18.5-23.5 scr
///     23.5-29.5 cam (B-roll 25.5-27.5) | 29.5-32 cam (screen ran out)
///     32-37 scr (take B, override) | 37-43 scr (take B)
final class EDLImporterTests: XCTestCase {
    static let media: [String: ProbedMedia] = [
        "take-a-camera.mov": .video(100),
        "take-a-screen.mov": .video(99, width: 3200, height: 1800),
        "take-b-camera.mov": .video(50),
        "take-b-screen.mov": .video(50, width: 3200, height: 1800),
        "intro.mp4": .video(5, fps: .fps25),
        "chart.mp4": .video(5, audio: false),
        "a.mp4": .video(8, audio: false),
        "b.mp4": .video(8, audio: false),
        "intro.mp3": .audio(12),
        "one.mp3": .audio(30),
        "two.mp3": .audio(30),
        "outro.mp3": .audio(8),
        "swipe.wav": .audio(0.4),
        "in.wav": .audio(0.6),
        "out.wav": .audio(0.5),
        "ding.mp3": .audio(1)
    ]

    func importMini(_ edit: (inout EDLRecipe) -> Void = { _ in }) async throws -> ImportResult {
        var recipe = try EDLRecipe.load(from: Fixtures.url("edl/mini-recipe.json"))
        edit(&recipe)
        let edl = try SegmentEDL.load(from: Fixtures.url("edl/mini-edl.json"))
        let importer = EDLImporter(recipe: recipe, locating: MediaLocating(prober: FakeProbe(media: Self.media)))
        return try await importer.importEDL(edl, source: "mini-edl.json")
    }

    func testSegmentsBecomeLinkedTakeClipsInOrder() async throws {
        let result = try await importMini()
        let p = result.project
        assertValid(p)
        XCTAssertEqual(result.report.count(.failed), 0, result.report.text)
        XCTAssertEqual(result.report.count(.missingMedia), 0, result.report.text)
        XCTAssertEqual(p.name, "Mini")
        XCTAssertEqual(p.settings.frameRate, .fps30)

        let camera = p.clips(on: "Camera")
        XCTAssertEqual(camera.map(\.start.seconds), [0, 5, 9.5, 14.5, 18.5, 23.5, 29.5, 32, 37])
        XCTAssertEqual(p.duration, t(43))
        // The loosened cut starts earlier and runs longer than the EDL said.
        XCTAssertEqual(camera[1].sourceStart, t(9.8))
        XCTAssertEqual(camera[1].duration, t(4.5))
        // Take B starts at EDL time 100, so its clips use local file time.
        XCTAssertEqual(camera[7].sourceStart, t(5))
        XCTAssertEqual(p.media(camera[7].mediaID!)?.path, "/fixture/mini/source/take-b-camera.mov")

        let voice = p.clips(on: "Voice")
        XCTAssertEqual(voice.map(\.start), camera.map(\.start))
        XCTAssertEqual(voice[3].audio?.normalizeTo, -28.74, "a recipe's own voice level wins")
        XCTAssertEqual(voice[0].audio?.normalizeTo, -28.74, "the intro is levelled like the voice")
        XCTAssertEqual(voice.last?.audio?.fadeOut, t(1), "the voice fades with the picture at the end")

        let screen = p.clips(on: "Screen")
        XCTAssertEqual(screen.map(\.start.seconds), [5, 9.5, 14.5, 18.5, 23.5, 32, 37])
        XCTAssertEqual(screen[1].sourceStart, camera[2].sourceStart, "screen and camera share take time")

        // Each segment's camera, voice and screen are one link group.
        for (index, clip) in camera.enumerated() where index > 0 {
            let linked = Set(p.linkedClipIDs(of: clip.id))
            XCTAssertTrue(linked.contains(voice[index].id), "segment \(index)")
            if let partner = screen.first(where: { $0.start == clip.start }) {
                XCTAssertTrue(linked.contains(partner.id), "segment \(index)")
            }
        }
    }

    func testLayoutsBecomeCameraTransforms() async throws {
        let p = try await importMini().project
        let camera = p.clips(on: "Camera")
        let pip = [2, 3, 4, 7, 8]
        for index in 1..<camera.count {
            let video = camera[index].video ?? VideoProperties()
            if pip.contains(index) {
                XCTAssertEqual(video.transform.scale, 0.5, "segment \(index)")
                XCTAssertEqual(video.transform.position, Point(x: 0.89, y: 0.8), "segment \(index)")
                XCTAssertEqual(video.cutout?.enabled, true, "segment \(index)")
                XCTAssertEqual(video.layoutPreset, "pipRight")
            } else {
                XCTAssertEqual(video.transform, Transform(), "segment \(index)")
                XCTAssertNil(video.cutout, "segment \(index)")
                XCTAssertEqual(video.layoutPreset, "full")
            }
        }
    }

    func testScreenThatEndsEarlyFallsBackToTheCamera() async throws {
        let result = try await importMini()
        let clip = result.project.clips(on: "Camera")[6]
        XCTAssertEqual(clip.video?.layoutPreset, "full")
        let item = result.report.items.first { $0.message.contains("screen recording") }
        XCTAssertEqual(item?.severity, .approximated)
        XCTAssertEqual(item?.at, [29.5])
    }

    func testIntroReplacesTheStartOfTheEDL() async throws {
        let p = try await importMini().project
        let intro = p.clips(on: "Camera")[0]
        XCTAssertEqual(p.media(intro.mediaID!)?.path, "/fixture/mini/intro.mp4")
        XCTAssertEqual(intro.range, TimeRange(start: .zero, end: t(5)))
        XCTAssertEqual(p.clips(on: "Voice")[0].mediaID, intro.mediaID)
        XCTAssertTrue(p.clips(on: "Screen").allSatisfy { $0.start >= t(5) })
    }

    func testTransitionsFollowTheRules() async throws {
        let p = try await importMini().project
        let cameraTrack = p.track(named: "Camera")!
        let camera = cameraTrack.clips
        func between(_ track: Track, at time: Double) -> Transition? {
            track.transitions.first { t in
                guard let from = t.fromClipID, let to = t.toClipID,
                      let a = track.clips.first(where: { $0.id == from }),
                      let b = track.clips.first(where: { $0.id == to }) else { return false }
                return a.end == Time(seconds: time) && b.start == Time(seconds: time)
            }
        }
        for time in [9.5, 23.5, 32.0] {
            let transition = between(cameraTrack, at: time)
            XCTAssertEqual(transition?.type, .cutSlide, "layout switch at \(time)")
            XCTAssertEqual(transition?.duration, t(1))
        }
        XCTAssertNil(between(cameraTrack, at: 29.5), "camera to camera is a plain cut")
        let screenTrack = p.track(named: "Screen")!
        let push = between(screenTrack, at: 18.5)
        XCTAssertEqual(push?.type, .push)
        XCTAssertEqual(push?.direction, .left)
        XCTAssertNil(between(screenTrack, at: 14.5), "no new topic there")

        let endFades = p.allTracks.flatMap(\.transitions).filter { $0.type == .fadeToBlack }
        XCTAssertEqual(endFades.count, 2, "both visible layers fade at the end")
        XCTAssertTrue(endFades.allSatisfy { $0.toClipID == nil && $0.duration == t(1) })
        XCTAssertTrue(endFades.contains { $0.fromClipID == camera.last?.id })
    }

    func testInsertsLandOnTheirWordsAndSlideInAndOut() async throws {
        let p = try await importMini().project
        let graphics = p.track(named: "Graphics")!
        XCTAssertEqual(graphics.clips.map(\.range), [TimeRange(start: t(11.5), end: t(14.5))])
        XCTAssertEqual(Set(graphics.transitions.map(\.direction)), [.down, .up])

        let broll = p.track(named: "B-roll")!
        XCTAssertEqual(broll.clips.map(\.range), [
            TimeRange(start: t(25.5), end: t(27.5)),
            TimeRange(start: t(34), end: t(35)),
            TimeRange(start: t(35), end: t(36.5))
        ])
        // The EDL's B-roll is the screen recording at take time 42.
        let overlay = broll.clips[0]
        XCTAssertEqual(p.media(overlay.mediaID!)?.path, "/fixture/mini/source/take-a-screen.mov")
        XCTAssertEqual(overlay.sourceStart, t(42))
        XCTAssertNil(overlay.linkGroup, "B-roll isn't part of the take's link group")
        // a.mp4 slides in, b.mp4 slides out, and they butt together.
        let heads = broll.transitions.filter { $0.fromClipID == nil }.compactMap(\.toClipID)
        let tails = broll.transitions.filter { $0.toClipID == nil }.compactMap(\.fromClipID)
        XCTAssertEqual(Set(heads), [broll.clips[0].id, broll.clips[1].id])
        XCTAssertEqual(Set(tails), [broll.clips[0].id, broll.clips[2].id])
    }

    func testSoundEffectsFollowTransitionsKeepingTheirGap() async throws {
        let p = try await importMini().project
        let sfx = p.clips(on: "SFX")
        func name(_ clip: Clip) -> String { URL(fileURLWithPath: p.media(clip.mediaID!)!.path).lastPathComponent }
        let placed = sfx.map { "\(name($0))@\(($0.start.seconds * 100).rounded() / 100)" }
        XCTAssertEqual(placed, [
            "swipe.wav@9.3", "in.wav@11.55", "out.wav@13.8", "swipe.wav@18.3", "ding.mp3@20.5",
            "swipe.wav@23.3", "in.wav@25.55", "swipe.wav@31.8", "in.wav@34.05", "out.wav@35.8"
        ])
        XCTAssertEqual(sfx[0].audio?.gainDB, -22)
        XCTAssertEqual(sfx[1].audio?.gainDB, -20)
        XCTAssertEqual(sfx[4].audio?.gainDB, -18)
    }

    func testMusicCuesAlternateTracksAndCrossfade() async throws {
        let p = try await importMini().project
        let music = p.clips(on: "Music")
        let music2 = p.clips(on: "Music 2")
        XCTAssertEqual(music.map(\.range), [TimeRange(start: .zero, end: t(10)), TimeRange(start: t(31.5), end: t(36.3))])
        XCTAssertEqual(music2.map(\.range), [TimeRange(start: t(9), end: t(32.5)), TimeRange(start: t(35.3), end: t(43))])
        XCTAssertEqual(music[0].audio?.fadeIn, .zero)
        XCTAssertEqual(music[0].audio?.fadeOut, t(1))
        XCTAssertEqual(music2[0].audio?.fadeIn, t(1))
        XCTAssertEqual(music2[1].audio?.fadeOut, t(1.5), "the last cue gets the end fade")
        XCTAssertEqual(music2[1].sourceStart, .zero)
        XCTAssertEqual(music[1].audio?.normalizeTo, -20)
        XCTAssertEqual(music[1].audio?.gainDB, -27)
        XCTAssertEqual(p.track(named: "Music 2")?.rippleMode, .follow)
    }

    func testSectionsBecomeMarkers() async throws {
        let p = try await importMini().project
        XCTAssertEqual(p.markers.map(\.name), ["Intro", "Part one", "Part two", "Outro"])
        XCTAssertEqual(p.markers.map(\.time.seconds), [0, 9.5, 32, 35.3])
        XCTAssertTrue(p.markers.allSatisfy { $0.kind == .section })
    }

    func testCameraMediaCarriesTheGradeAndTake() async throws {
        let p = try await importMini().project
        let camera = p.media.first { $0.path.hasSuffix("take-a-camera.mov") }!
        XCTAssertEqual(camera.look.map(\.type), ["hsl", "vignette"])
        XCTAssertEqual(camera.look[0].params["redSaturation"], .number(-17))
        let screen = p.media.first { $0.path.hasSuffix("take-a-screen.mov") }!
        XCTAssertNotNil(camera.takeID)
        XCTAssertEqual(camera.takeID, screen.takeID)
        XCTAssertTrue(screen.look.isEmpty)
    }

    func testMissingInsertIsReportedNotFatal() async throws {
        let result = try await importMini { recipe in
            recipe.inserts?.append(.init(path: "graphics/missing.mp4", at: 31, duration: 2))
        }
        assertValid(result.project)
        XCTAssertEqual(result.report.count(.missingMedia), 1)
        XCTAssertEqual(result.project.clips(on: "Graphics").count, 1)
    }

    func testRecipeRoundTripsAndResolvesPaths() throws {
        let recipe = try EDLRecipe.load(from: Fixtures.url("edl/mini-recipe.json"))
        XCTAssertEqual(recipe.resolve("source/a.mov"), "/fixture/mini/source/a.mov")
        XCTAssertEqual(recipe.resolve("/abs/b.mov"), "/abs/b.mov")
        XCTAssertEqual(recipe.transitions?.topicPush?.at, [30])
        let data = try JSONEncoder().encode(recipe)
        XCTAssertEqual(try EDLRecipe.decode(data, name: "again"), recipe)
    }
}

extension EDLImporterTests {
    func testReportIsReadable() async throws {
        let result = try await importMini()
        print(result.report.text)
        XCTAssertEqual(result.report.stats["segments"], 8)
        XCTAssertEqual(result.report.stats["duration"], 43)
    }
}

final class DecisionModelsRecipeTests: XCTestCase {
    func testBuiltInRecipeDecodes() throws {
        let recipe = try EDLRecipe.decisionModels
        XCTAssertEqual(recipe.name, "Decision Models")
        XCTAssertEqual(recipe.takes.map(\.start), [0, 671.396458, 1349.822228])
        XCTAssertEqual(recipe.cutAdjustments?.count, 96)
        XCTAssertEqual(recipe.sections?.count, 10)
        XCTAssertEqual(recipe.sections?.last?.outro, true)
        XCTAssertEqual(recipe.inserts?.count, 6)
        XCTAssertEqual(recipe.transitions?.topicPush?.at, [290.8, 430.6, 806.1, 965.0])
        XCTAssertTrue(recipe.resolve("edit/edl-v2.json").hasSuffix("/dev/convex/convex-videos/decision-models/edit/edl-v2.json"))
        XCTAssertEqual(try EDLRecipe.builtIn("decision-models"), recipe)
        XCTAssertNil(try EDLRecipe.builtIn("nope"))
        // Voice and intro play at the project's speech level, where v14 had them.
        XCTAssertNil(recipe.voice)
        XCTAssertNil(recipe.intro?.normalizeTo)
        // Every adjustment only ever moves a segment's edges a little.
        for adjustment in recipe.cutAdjustments ?? [] {
            XCTAssertLessThan(abs(adjustment.newStart - adjustment.start), 1.1)
            XCTAssertLessThan(abs(adjustment.newEnd - adjustment.end), 1.6)
        }
    }
}

extension EDLImporterTests {
    func importEDL(_ edl: SegmentEDL, _ edit: (inout EDLRecipe) -> Void = { _ in }) async throws -> ImportResult {
        var recipe = try EDLRecipe.load(from: Fixtures.url("edl/mini-recipe.json"))
        recipe.intro = nil
        recipe.cutAdjustments = nil
        recipe.layoutOverrides = nil
        recipe.inserts = nil
        recipe.sections = nil
        recipe.sfx = nil
        edit(&recipe)
        return try await EDLImporter(recipe: recipe, locating: MediaLocating(prober: FakeProbe(media: Self.media))).importEDL(edl, source: "inline")
    }

    func testWithoutARecipeLevelTheVoiceAndIntroGetTheSpeechLevel() async throws {
        let result = try await importMini { recipe in
            recipe.voice = nil
            recipe.intro?.normalizeTo = nil
        }
        let voice = result.project.clips(on: "Voice")
        XCTAssertEqual(voice.map(\.audio?.normalizeTo), Array(repeating: -20, count: voice.count), "the intro and every voice clip")
        XCTAssertTrue(voice.allSatisfy { $0.audio?.gainDB == 0 })
        XCTAssertEqual(result.project.clips(on: "Music").first?.audio?.gainDB, -27, "music keeps the recipe's own level")
    }

    func testTopLevelOverlaysAndScreenOffsets() async throws {
        let edl = SegmentEDL(
            segments: [
                .init(start: 10, end: 14, layout: .cam),
                .init(start: 20, end: 25, layout: .screen, screenOffset: 0.5)
            ],
            overlays: [.init(timeline: 2, duration: 1.5, screenAt: 60)]
        )
        let p = try await importEDL(edl).project
        assertValid(p)
        // The overlay sits 2 s into the EDL's own timeline, showing take time 60.
        let broll = p.clips(on: "B-roll")
        XCTAssertEqual(broll.map(\.range), [TimeRange(start: t(2), end: t(3.5))])
        XCTAssertEqual(broll[0].sourceStart, t(60))
        // The screen of the second segment runs half a second ahead of the voice.
        let screen = p.clips(on: "Screen")
        XCTAssertEqual(screen[1].sourceStart, t(20.5))
        XCTAssertEqual(p.clips(on: "Camera")[1].sourceStart, t(20))
    }

    func testSegmentsStayInsideTheirRecordingSession() async throws {
        // Take B starts at EDL time 100; a segment running past it is cut there.
        let edl = SegmentEDL(segments: [.init(start: 95, end: 102, layout: .cam), .init(start: 103, end: 106, layout: .cam)])
        let result = try await importEDL(edl)
        assertValid(result.project)
        let camera = result.project.clips(on: "Camera")
        XCTAssertEqual(camera.map(\.duration), [t(5), t(3)])
        XCTAssertEqual(camera[1].sourceStart, t(3), "take B's own clock")
        XCTAssertTrue(result.report.items(.approximated).contains { $0.message.contains("recording session") })
    }

    func testUnmatchedCutAdjustmentsAreNoted() async throws {
        let edl = SegmentEDL(segments: [.init(start: 10, end: 14, layout: .cam)])
        let result = try await importEDL(edl) { recipe in
            recipe.cutAdjustments = [.init(start: 50, end: 55, newStart: 49.8, newEnd: 55.2)]
        }
        XCTAssertTrue(result.report.items(.note).contains { $0.message.contains("matched no segment") })
        XCTAssertEqual(result.project.clips(on: "Camera").map(\.range), [TimeRange(start: .zero, end: t(4))])
    }
}
