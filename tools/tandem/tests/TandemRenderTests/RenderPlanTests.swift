import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

func t(_ seconds: Double) -> Time { Time(seconds: seconds) }

/// Supplies analysis results straight from a table, for tests.
final class FakeAssets: RenderAssets, @unchecked Sendable {
    var proxies: [String: URL] = [:]
    var mattes: [String: URL] = [:]
    /// Mattes made in the person-only mode, when a test needs both.
    var personMattes: [String: URL] = [:]
    var voices: [String: URL] = [:]
    var loudnesses: [String: Loudness] = [:]

    func proxyURL(for item: MediaItem) -> URL? { proxies[item.id] }
    func matteURL(for item: MediaItem) -> URL? { mattes[item.id] }
    func matteURL(for item: MediaItem, mode: CutoutMode) -> URL? { mode == .person ? personMattes[item.id] : mattes[item.id] }
    func isolatedVoiceURL(for item: MediaItem) -> URL? { voices[item.id] }
    func loudness(for item: MediaItem) -> Loudness? { loudnesses[item.id] }
}

extension StackNode {
    var clipIDs: [String] { layers.map(\.clipID) }
}

final class RenderPlanTests: XCTestCase {
    var camera = MediaItem(id: "med_cam", path: "cam.mov", kind: .video, role: .camera, duration: t(60), width: 3840, height: 2160, hasVideo: true, hasAudio: true)
    var screen = MediaItem(id: "med_scr", path: "scr.mov", kind: .video, role: .screen, duration: t(60), width: 3200, height: 1800, hasVideo: true, hasAudio: true)
    var image = MediaItem(id: "med_img", path: "shot.png", kind: .image, role: .image, width: 1920, height: 1080, hasVideo: false)
    var music = MediaItem(id: "med_music", path: "bed.m4a", kind: .audio, role: .music, duration: t(120), hasAudio: true)

    func project(video: [Track], audio: [Track] = []) -> Project {
        Project(name: "Plan", media: [camera, screen, image, music], videoTracks: video, audioTracks: audio)
    }

    func mediaClip(_ id: String, _ media: String, start: Double, duration: Double, source: Double = 10, speed: Double = 1) -> Clip {
        Clip(id: id, content: .media(mediaID: media), start: t(start), duration: t(duration), sourceStart: t(source), speed: speed)
    }

    func testLayersStackBottomTrackFirst() {
        let v1 = Track(kind: .video, name: "Screen", clips: [mediaClip("clip_s", "med_scr", start: 0, duration: 10)])
        let v2 = Track(kind: .video, name: "Camera", clips: [mediaClip("clip_c", "med_cam", start: 2, duration: 4)])
        let v3 = Track(kind: .video, name: "Text", clips: [Clip(id: "clip_t", content: .text(TextContent(text: "Hi")), start: t(3), duration: t(1))])
        let plan = RenderPlanner.plan(project(video: [v1, v2, v3]), format: nil, assets: nil)

        XCTAssertEqual(plan.duration, t(10))
        XCTAssertEqual(plan.instructions.map(\.range), [
            TimeRange(start: t(0), end: t(2)),
            TimeRange(start: t(2), end: t(3)),
            TimeRange(start: t(3), end: t(4)),
            TimeRange(start: t(4), end: t(6)),
            TimeRange(start: t(6), end: t(10))
        ])
        XCTAssertEqual(plan.instructions[2].stack.flatMap(\.clipIDs), ["clip_s", "clip_c", "clip_t"])
        XCTAssertEqual(plan.instructions[0].stack.flatMap(\.clipIDs), ["clip_s"])
        // Text is drawn by the compositor, so it gets no composition track.
        XCTAssertEqual(plan.videoSegments.map(\.clipID).sorted(), ["clip_c", "clip_s"])
        XCTAssertEqual(plan.videoTrackCount, 2)
    }

    func testInstructionsCoverTheWholeTimelineIncludingGaps() {
        let v1 = Track(kind: .video, name: "V1", clips: [mediaClip("clip_a", "med_scr", start: 1, duration: 2)])
        let a1 = Track(kind: .audio, name: "Music", clips: [mediaClip("clip_m", "med_music", start: 0, duration: 5, source: 0)])
        let plan = RenderPlanner.plan(project(video: [v1], audio: [a1]), format: nil, assets: nil)
        XCTAssertEqual(plan.instructions.first?.range.start, .zero)
        XCTAssertEqual(plan.instructions.last?.range.end, t(5))
        for (a, b) in zip(plan.instructions, plan.instructions.dropFirst()) {
            XCTAssertEqual(a.range.end, b.range.start)
        }
        XCTAssertEqual(plan.instructions.first?.stack, [])
        XCTAssertEqual(plan.instructions.last?.stack, [])
    }

    func testHiddenTracksDisabledClipsAndFormatHiddenClipsAreSkipped() {
        var hidden = Track(kind: .video, name: "Hidden", clips: [mediaClip("clip_h", "med_scr", start: 0, duration: 5)])
        hidden.hidden = true
        var disabled = mediaClip("clip_d", "med_cam", start: 0, duration: 5)
        disabled.enabled = false
        var portraitOnlyHidden = mediaClip("clip_p", "med_cam", start: 5, duration: 5)
        portraitOnlyHidden.video = VideoProperties(formatOverrides: ["portrait": FormatOverride(hidden: true)])
        let v2 = Track(kind: .video, name: "V2", clips: [disabled, portraitOnlyHidden])
        let p = project(video: [hidden, v2])

        let main = RenderPlanner.plan(p, format: nil, assets: nil)
        XCTAssertEqual(Set(main.instructions.flatMap { $0.stack.flatMap(\.clipIDs) }), ["clip_p"])
        let portrait = RenderPlanner.plan(p, format: "portrait", assets: nil)
        XCTAssertTrue(portrait.instructions.allSatisfy { $0.stack.isEmpty })
        XCTAssertTrue(portrait.videoSegments.isEmpty)
    }

    func testCentredTransitionOverlapsClipsOnDifferentTracks() {
        // A 1 s dissolve on the cut at 5 s: A plays on to 5.5, B starts at 4.5.
        let a = mediaClip("clip_a", "med_cam", start: 0, duration: 5, source: 10)
        let b = mediaClip("clip_b", "med_cam", start: 5, duration: 5, source: 30)
        let dissolve = Transition(id: "tr_x", type: .dissolve, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b")
        let v1 = Track(kind: .video, name: "V1", clips: [a, b], transitions: [dissolve])
        let plan = RenderPlanner.plan(project(video: [v1]), format: nil, assets: nil)

        let segA = plan.videoSegments.first { $0.clipID == "clip_a" }!
        let segB = plan.videoSegments.first { $0.clipID == "clip_b" }!
        XCTAssertEqual(segA.timeline, TimeRange(start: t(0), end: t(5.5)))
        XCTAssertEqual(segA.sourceStart, t(10))
        XCTAssertEqual(segB.timeline, TimeRange(start: t(4.5), end: t(10)))
        XCTAssertEqual(segB.sourceStart, t(29.5))
        XCTAssertNotEqual(segA.track, segB.track)
        XCTAssertEqual(plan.videoTrackCount, 2)

        XCTAssertEqual(plan.instructions.map(\.range), [
            TimeRange(start: t(0), end: t(4.5)),
            TimeRange(start: t(4.5), end: t(5.5)),
            TimeRange(start: t(5.5), end: t(10))
        ])
        guard case .transition(let ref, let from, let to) = plan.instructions[1].stack.first else {
            return XCTFail("expected a transition node")
        }
        XCTAssertEqual(ref.transition.id, "tr_x")
        XCTAssertEqual(ref.window, TimeRange(start: t(4.5), end: t(5.5)))
        XCTAssertEqual(from?.clipIDs, ["clip_a"])
        XCTAssertEqual(to?.clipIDs, ["clip_b"])
        if case .layer(let layer)? = from {
            XCTAssertEqual(layer.pictureTrack, segA.track)
        }
    }

    func testHeadAndTailTransitionsStayInsideTheirClip() {
        let a = mediaClip("clip_a", "med_cam", start: 2, duration: 4)
        let fadeIn = Transition(id: "tr_in", type: .fadeFromBlack, duration: t(1), fromClipID: nil, toClipID: "clip_a")
        let fadeOut = Transition(id: "tr_out", type: .fadeToBlack, duration: t(1.5), fromClipID: "clip_a", toClipID: nil)
        let v1 = Track(kind: .video, name: "V1", clips: [a], transitions: [fadeIn, fadeOut])
        let plan = RenderPlanner.plan(project(video: [v1]), format: nil, assets: nil)
        XCTAssertEqual(plan.videoSegments.first?.timeline, TimeRange(start: t(2), end: t(6)))
        XCTAssertEqual(plan.instructions.map(\.range), [
            TimeRange(start: t(0), end: t(2)),
            TimeRange(start: t(2), end: t(3)),
            TimeRange(start: t(3), end: t(4.5)),
            TimeRange(start: t(4.5), end: t(6))
        ])
        guard case .transition(let head, nil, let to?) = plan.instructions[1].stack.first else {
            return XCTFail("expected a head transition")
        }
        XCTAssertEqual(head.transition.id, "tr_in")
        XCTAssertEqual(to.clipIDs, ["clip_a"])
        guard case .transition(let tail, let from?, nil) = plan.instructions[3].stack.first else {
            return XCTFail("expected a tail transition")
        }
        XCTAssertEqual(tail.transition.id, "tr_out")
        XCTAssertEqual(from.clipIDs, ["clip_a"])
    }

    func testOverlappingTransitionsOnAShortClipNest() {
        // B is 1 s long with 0.8 s transitions at both ends, so for a moment
        // A, B and C all show: (A to B) to C.
        let a = mediaClip("clip_a", "med_cam", start: 0, duration: 2, source: 10)
        let b = mediaClip("clip_b", "med_cam", start: 2, duration: 1, source: 20)
        let c = mediaClip("clip_c", "med_cam", start: 3, duration: 2, source: 30)
        let ab = Transition(id: "tr_ab", type: .dissolve, duration: t(1.6), fromClipID: "clip_a", toClipID: "clip_b")
        let bc = Transition(id: "tr_bc", type: .dissolve, duration: t(1.6), fromClipID: "clip_b", toClipID: "clip_c")
        let v1 = Track(kind: .video, name: "V1", clips: [a, b, c], transitions: [ab, bc])
        let plan = RenderPlanner.plan(project(video: [v1]), format: nil, assets: nil)
        let middle = plan.instructions.first { $0.range.contains(t(2.5)) }!
        guard case .transition(let outer, let from?, let to?) = middle.stack.first else {
            return XCTFail("expected nested transitions")
        }
        XCTAssertEqual(outer.transition.id, "tr_bc")
        XCTAssertEqual(to.clipIDs, ["clip_c"])
        guard case .transition(let inner, _, _) = from else { return XCTFail("expected inner transition") }
        XCTAssertEqual(inner.transition.id, "tr_ab")
        XCTAssertEqual(from.clipIDs, ["clip_a", "clip_b"])
        XCTAssertEqual(plan.videoTrackCount, 3)
    }

    func testSpeedAndFreezeMapping() {
        let fast = mediaClip("clip_f", "med_scr", start: 0, duration: 2, source: 4, speed: 4)
        var frozen = mediaClip("clip_z", "med_cam", start: 2, duration: 3, source: 7)
        frozen.freezeFrame = true
        let into = Transition(id: "tr_z", type: .dissolve, duration: t(1), fromClipID: "clip_f", toClipID: "clip_z")
        let v1 = Track(kind: .video, name: "V1", clips: [fast, frozen], transitions: [into])
        let plan = RenderPlanner.plan(project(video: [v1]), format: nil, assets: nil)
        let f = plan.videoSegments.first { $0.clipID == "clip_f" }!
        XCTAssertEqual(f.speed, 4)
        XCTAssertEqual(f.timeline, TimeRange(start: t(0), end: t(2.5)))
        let z = plan.videoSegments.first { $0.clipID == "clip_z" }!
        XCTAssertTrue(z.freeze)
        // A frozen clip holds its frame through the transition handle.
        XCTAssertEqual(z.sourceStart, t(7))
        XCTAssertEqual(z.timeline, TimeRange(start: t(1.5), end: t(5)))
    }

    /// A clip used from near the start of its file still plays through the
    /// whole transition: the frames before the file starts are its first
    /// frame, held (the assembler holds it), so the plan asks for all of it.
    func testTheFirstFrameHoldsBeforeTheStartOfTheFile() {
        let a = mediaClip("clip_a", "med_cam", start: 0, duration: 5, source: 10)
        let b = mediaClip("clip_b", "med_cam", start: 5, duration: 5, source: 0.2)
        let d = Transition(id: "tr_x", type: .dissolve, duration: t(1), fromClipID: "clip_a", toClipID: "clip_b")
        let plan = RenderPlanner.plan(project(video: [Track(kind: .video, name: "V1", clips: [a, b], transitions: [d])]), format: nil, assets: nil)
        let segB = plan.videoSegments.first { $0.clipID == "clip_b" }!
        XCTAssertEqual(segB.sourceStart, t(-0.3), "0.3 s before the file: its first frame held")
        XCTAssertEqual(segB.timeline.start, t(4.5), "the whole of the transition")
    }

    func testMatteSegmentsMirrorTheirClip() {
        var pip = mediaClip("clip_c", "med_cam", start: 1, duration: 3, source: 12, speed: 2)
        pip.video = VideoProperties(transform: Transform(position: Point(x: 0.87, y: 0.77), scale: 0.5), cutout: Cutout())
        let assets = FakeAssets()
        assets.mattes["med_cam"] = URL(fileURLWithPath: "/tmp/matte.mov")
        let plan = RenderPlanner.plan(project(video: [Track(kind: .video, name: "Camera", clips: [pip])]), format: nil, assets: assets)
        let picture = plan.videoSegments.first { $0.role == .picture }!
        let matte = plan.videoSegments.first { $0.role == .matte }!
        XCTAssertEqual(matte.timeline, picture.timeline)
        XCTAssertEqual(matte.sourceStart, picture.sourceStart)
        XCTAssertEqual(matte.speed, 2)
        XCTAssertNotEqual(matte.track, picture.track)
        guard case .layer(let layer)? = plan.instructions.first(where: { !$0.stack.isEmpty })?.stack.first else {
            return XCTFail("expected a layer")
        }
        XCTAssertEqual(layer.pictureTrack, picture.track)
        XCTAssertEqual(layer.matteTrack, matte.track)

        // Without a matte the clip still renders, uncut, with a warning.
        let bare = RenderPlanner.plan(project(video: [Track(kind: .video, name: "Camera", clips: [pip])]), format: nil, assets: FakeAssets())
        XCTAssertEqual(bare.videoSegments.count, 1)
        XCTAssertFalse(bare.warnings.isEmpty)
    }

    func testImagesAndGraphicsGetNoCompositionTracks() {
        let still = Clip(id: "clip_i", content: .media(mediaID: "med_img"), start: .zero, duration: t(2))
        let graphic = Clip(id: "clip_g", content: .graphic(GraphicContent(template: "remotion:Bar")), start: t(2), duration: t(2))
        let plan = RenderPlanner.plan(project(video: [Track(kind: .video, name: "V1", clips: [still, graphic])]), format: nil, assets: nil)
        XCTAssertTrue(plan.videoSegments.isEmpty)
        XCTAssertEqual(plan.instructions.first?.stack.flatMap(\.clipIDs), ["clip_i"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("Graphic") })
    }

    // MARK: Audio

    func testMuteSoloAndMutedClips() {
        let voice = Track(kind: .audio, name: "Voice", clips: [mediaClip("clip_v", "med_cam", start: 0, duration: 5)])
        var musicTrack = Track(kind: .audio, name: "Music", clips: [mediaClip("clip_m", "med_music", start: 0, duration: 5)])
        var sfx = Track(kind: .audio, name: "SFX", clips: [mediaClip("clip_x", "med_music", start: 1, duration: 1)])

        var plan = RenderPlanner.plan(project(video: [], audio: [voice, musicTrack, sfx]), format: nil, assets: nil)
        XCTAssertEqual(Set(plan.audioSegments.map(\.clipID)), ["clip_v", "clip_m", "clip_x"])

        musicTrack.muted = true
        plan = RenderPlanner.plan(project(video: [], audio: [voice, musicTrack, sfx]), format: nil, assets: nil)
        XCTAssertEqual(Set(plan.audioSegments.map(\.clipID)), ["clip_v", "clip_x"])

        sfx.solo = true
        plan = RenderPlanner.plan(project(video: [], audio: [voice, musicTrack, sfx]), format: nil, assets: nil)
        XCTAssertEqual(plan.audioSegments.map(\.clipID), ["clip_x"])

        sfx.solo = false
        var quiet = mediaClip("clip_v", "med_cam", start: 0, duration: 5)
        quiet.audio = AudioProperties(muted: true)
        plan = RenderPlanner.plan(project(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [quiet]), sfx]), format: nil, assets: nil)
        XCTAssertEqual(plan.audioSegments.map(\.clipID), ["clip_x"])
    }

    func testAudioCrossfadeOverlapsOnSeparateTracks() {
        let a = mediaClip("clip_a", "med_music", start: 0, duration: 5, source: 10)
        let b = mediaClip("clip_b", "med_music", start: 5, duration: 5, source: 40)
        // Any transition type on audio plays as a crossfade.
        let x = Transition(id: "tr_x", type: .push, duration: t(2), fromClipID: "clip_a", toClipID: "clip_b")
        let track = Track(kind: .audio, name: "Music", clips: [a, b], transitions: [x])
        let plan = RenderPlanner.plan(project(video: [], audio: [track]), format: nil, assets: nil)
        let segA = plan.audioSegments.first { $0.clipID == "clip_a" }!
        let segB = plan.audioSegments.first { $0.clipID == "clip_b" }!
        XCTAssertEqual(segA.timeline, TimeRange(start: t(0), end: t(6)))
        XCTAssertEqual(segB.timeline, TimeRange(start: t(4), end: t(10)))
        XCTAssertNotEqual(segA.track, segB.track)
        // Equal power: halfway through, both are at 0.707, so the power sums to 1.
        let gA = gainAt(segA.envelope, t(5))
        let gB = gainAt(segB.envelope, t(5))
        XCTAssertEqual(gA, sqrt(0.5), accuracy: 0.01)
        XCTAssertEqual(gA * gA + gB * gB, 1, accuracy: 0.02)
        XCTAssertEqual(gainAt(segA.envelope, t(6)), 0, accuracy: 1e-9)
        XCTAssertEqual(gainAt(segB.envelope, t(4)), 0, accuracy: 1e-9)
    }

    func testMicroFadesOnHardCutsButNotSeamlessJoins() {
        // clip_a and clip_b continue the same media, so their join is seamless.
        // clip_c jumps, so both sides of that cut get 3 ms fades.
        let a = mediaClip("clip_a", "med_cam", start: 0, duration: 2, source: 10)
        let b = mediaClip("clip_b", "med_cam", start: 2, duration: 2, source: 12)
        let c = mediaClip("clip_c", "med_cam", start: 4, duration: 2, source: 30)
        let plan = RenderPlanner.plan(project(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [a, b, c])]), format: nil, assets: nil)
        let env = Dictionary(uniqueKeysWithValues: plan.audioSegments.map { ($0.clipID, $0.envelope) })

        // Start of the timeline and the jump cut fade in over 3 ms.
        XCTAssertEqual(env["clip_a"]!.first?.gain, 0)
        XCTAssertEqual(gainAt(env["clip_a"]!, t(0.003)), 1, accuracy: 1e-9)
        XCTAssertEqual(env["clip_c"]!.first?.gain, 0)
        XCTAssertEqual(env["clip_b"]!.last?.gain, 0)
        XCTAssertEqual(gainAt(env["clip_b"]!, t(4) - RenderPlanner.microFade), 1, accuracy: 1e-9)
        // The seamless join stays at full level.
        XCTAssertEqual(env["clip_a"]!.last?.gain, 1)
        XCTAssertEqual(env["clip_b"]!.first?.gain, 1)
    }

    func testAClipAfterAMutedOneStillFadesIn() {
        var a = mediaClip("clip_a", "med_cam", start: 0, duration: 2, source: 10)
        a.audio = AudioProperties(muted: true)
        let b = mediaClip("clip_b", "med_cam", start: 2, duration: 2, source: 12)
        let plan = RenderPlanner.plan(project(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [a, b])]), format: nil, assets: nil)
        XCTAssertEqual(plan.audioSegments.map(\.clipID), ["clip_b"])
        XCTAssertEqual(plan.audioSegments[0].envelope.first?.gain, 0)
    }

    func testGainFadesAndKeyframes() {
        var bed = mediaClip("clip_m", "med_music", start: 0, duration: 10, source: 0)
        bed.audio = AudioProperties(gainDB: -31, fadeIn: t(1), fadeOut: t(2))
        let plan = RenderPlanner.plan(project(video: [], audio: [Track(kind: .audio, name: "Music", clips: [bed])]), format: nil, assets: nil)
        let env = plan.audioSegments[0].envelope
        let level = pow(10, -31.0 / 20)
        XCTAssertEqual(gainAt(env, t(5)), level, accuracy: 1e-9)
        XCTAssertEqual(gainAt(env, t(0)), 0, accuracy: 1e-9)
        XCTAssertEqual(gainAt(env, t(10)), 0, accuracy: 1e-9)
        XCTAssertEqual(gainAt(env, t(0.5)), level * sqrt(0.5), accuracy: level * 0.01)

        var ducked = mediaClip("clip_k", "med_music", start: 0, duration: 4, source: 0)
        ducked.keyframes["audio.gainDB"] = [
            Keyframe(time: t(1), value: .number(0), interpolation: .linear),
            Keyframe(time: t(3), value: .number(-20))
        ]
        let keyed = RenderPlanner.plan(project(video: [], audio: [Track(kind: .audio, name: "Music", clips: [ducked])]), format: nil, assets: nil)
        let kenv = keyed.audioSegments[0].envelope
        XCTAssertEqual(gainAt(kenv, t(0.5)), 1, accuracy: 1e-9)
        // Halfway through a linear dB ramp from 0 to -20 is -10 dB.
        XCTAssertEqual(gainAt(kenv, t(2)), pow(10, -10.0 / 20), accuracy: 0.01)
        XCTAssertEqual(gainAt(kenv, t(3.5)), 0.1, accuracy: 1e-6)
        XCTAssertGreaterThan(kenv.count, 20)
    }

    func testNormalisationUsesMeasuredLoudness() {
        var voiceClip = mediaClip("clip_v", "med_cam", start: 0, duration: 4)
        voiceClip.audio = AudioProperties(gainDB: 2, normalizeTo: -16)
        let assets = FakeAssets()
        assets.loudnesses["med_cam"] = Loudness(integratedLUFS: -26, truePeakDBTP: -8, loudnessRange: 5)
        let plan = RenderPlanner.plan(project(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [voiceClip])]), format: nil, assets: assets)
        // +10 dB to reach -16 LUFS, then the clip's own +2 dB.
        XCTAssertEqual(gainAt(plan.audioSegments[0].envelope, t(2)), pow(10, 12.0 / 20), accuracy: 1e-6)

        // Not measured yet: plays at the clip gain and says why.
        let unmeasured = RenderPlanner.plan(project(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [voiceClip])]), format: nil, assets: FakeAssets())
        XCTAssertEqual(gainAt(unmeasured.audioSegments[0].envelope, t(2)), pow(10, 2.0 / 20), accuracy: 1e-6)
        XCTAssertTrue(unmeasured.warnings.contains { $0.contains("loudness") })
    }

    func testNormalisingASilentOrVeryQuietFile() {
        var voiceClip = mediaClip("clip_v", "med_cam", start: 0, duration: 4)
        voiceClip.audio = AudioProperties(gainDB: 2, normalizeTo: -20)
        let voice = [Track(kind: .audio, name: "Voice", clips: [voiceClip])]
        // A screen recording with no sound measures -inf: nothing to level,
        // and nothing to warn about.
        let silent = FakeAssets()
        silent.loudnesses["med_cam"] = Loudness(integratedLUFS: -.infinity, truePeakDBTP: -.infinity, loudnessRange: 0)
        let quiet = RenderPlanner.plan(project(video: [], audio: voice), format: nil, assets: silent)
        XCTAssertEqual(gainAt(quiet.audioSegments[0].envelope, t(2)), pow(10, 2.0 / 20), accuracy: 1e-6)
        XCTAssertEqual(quiet.warnings, [])
        // Very quiet sound gets at most +30 dB, then the clip gain.
        let faint = FakeAssets()
        faint.loudnesses["med_cam"] = Loudness(integratedLUFS: -70, truePeakDBTP: -50, loudnessRange: 0)
        let capped = RenderPlanner.plan(project(video: [], audio: voice), format: nil, assets: faint)
        XCTAssertEqual(gainAt(capped.audioSegments[0].envelope, t(2)), pow(10, 32.0 / 20), accuracy: 1e-6)
    }

    func testVoiceIsolationMixesTheCachedVoice() {
        var voiceClip = mediaClip("clip_v", "med_cam", start: 0, duration: 4)
        voiceClip.audio = AudioProperties(voiceIsolation: 0.75)
        let assets = FakeAssets()
        assets.voices["med_cam"] = URL(fileURLWithPath: "/tmp/voice.wav")
        let plan = RenderPlanner.plan(project(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [voiceClip])]), format: nil, assets: assets)
        let original = plan.audioSegments.first { $0.role == .sound }!
        let isolated = plan.audioSegments.first { $0.role == .isolatedVoice }!
        XCTAssertEqual(gainAt(original.envelope, t(2)), 0.25, accuracy: 1e-9)
        XCTAssertEqual(gainAt(isolated.envelope, t(2)), 0.75, accuracy: 1e-9)
        XCTAssertEqual(isolated.timeline, original.timeline)
        XCTAssertNotEqual(isolated.track, original.track)

        voiceClip.audio = AudioProperties(voiceIsolation: 1)
        let full = RenderPlanner.plan(project(video: [], audio: [Track(kind: .audio, name: "Voice", clips: [voiceClip])]), format: nil, assets: assets)
        XCTAssertEqual(full.audioSegments.map(\.role), [.isolatedVoice])
    }
}

/// Linear interpolation of an envelope, the way AVAudioMix ramps it.
func gainAt(_ envelope: [GainPoint], _ time: Time) -> Double {
    guard let first = envelope.first else { return 0 }
    if time <= first.time { return first.gain }
    for (a, b) in zip(envelope, envelope.dropFirst()) where time >= a.time && time <= b.time {
        let span = Double((b.time - a.time).flicks)
        let p = span > 0 ? Double((time - a.time).flicks) / span : 1
        return a.gain + (b.gain - a.gain) * p
    }
    return envelope.last!.gain
}
