import Foundation
import XCTest
@testable import TandemAPI
import TandemAssets
@testable import TandemCore
import TandemMedia

/// Transition sounds for agents (the schema, the timeline) and the defaults
/// the app puts on each type.
final class TransitionSoundAPITests: XCTestCase {
    typealias Defaults = TransitionSoundDefaults

    // MARK: - Defaults

    func testPushesSlidesAndWipesSwooshAndTheRestAreSilent() {
        for type in [TransitionType.push, .slide, .cutSlide, .wipe] {
            XCTAssertEqual(Defaults.builtIn(type), Defaults.lightSwoosh, type.rawValue)
        }
        for type in [TransitionType.dissolve, .fadeToBlack, .fadeFromBlack, .zoom] {
            XCTAssertNil(Defaults.builtIn(type), type.rawValue)
        }
        XCTAssertEqual(Defaults.lightSwoosh.assetID, "elevenlabs:sfx_2ybnc2tu")
        // Its loudest 400 ms is -11.7 LUFS: 15 LU under speech at -20.
        XCTAssertEqual(-11.7 + Defaults.lightSwoosh.gainDB, Defaults.speechLevel - Defaults.underSpeech, accuracy: 0.001)
        XCTAssertEqual(Defaults.lightSwoosh.offset, -0.39, "loudest 0.39 s in, on the middle")
    }

    func testMikesPicksWinOverTandems() {
        let boom = Asset(provider: "import", providerID: "sfx/Boom.wav", kind: .sfx, name: "Boom", duration: 1, loudness: Loudness(integratedLUFS: -18, truePeakDBTP: -3, loudnessRange: 0))
        let peaks = Waveform(samplesPerSecond: 100, peaks: (0..<100).map { index in Float(max(0, 1 - abs(Double(index) - 20) / 10)) })
        func sound(_ type: TransitionType, _ choices: [String: String]) -> Defaults.Sound? {
            Defaults.sound(for: type, choices: choices, asset: { $0 == boom.id ? boom : nil }, waveform: { _ in peaks })
        }
        XCTAssertEqual(sound(.push, [:]), Defaults.lightSwoosh, "nothing picked")
        XCTAssertNil(sound(.push, ["push": ""]), "none picked")
        XCTAssertEqual(sound(.dissolve, ["dissolve": Defaults.lightSwoosh.assetID]), Defaults.lightSwoosh, "as measured, whatever picks it")
        // -35 LUFS wanted, -18 measured; loudest in the 10 ms from 0.2 s.
        XCTAssertEqual(sound(.zoom, ["zoom": boom.id]), Defaults.Sound(assetID: boom.id, gainDB: -17, offset: -0.21))
        XCTAssertNil(sound(.zoom, ["zoom": "import:gone.wav"]), "a pick the library lost is silent")
        XCTAssertEqual(sound(.wipe, ["zoom": boom.id]), Defaults.lightSwoosh, "a pick for another type")
    }

    func testTheLoudestMomentIsTheMiddleOfTheLoudest50Milliseconds() {
        XCTAssertEqual(Defaults.loudestMoment(nil, length: 1), 0)
        // A clipped plateau 0.36 to 0.42 s, like the swoosh's.
        var peaks = [Float](repeating: 0.1, count: 100)
        for index in 36...41 { peaks[index] = 1 }
        XCTAssertEqual(Defaults.loudestMoment(Waveform(samplesPerSecond: 100, peaks: peaks), length: 1), 0.39, accuracy: 0.011)
        let late = Waveform(samplesPerSecond: 100, peaks: [0, 0, 0, 1])
        XCTAssertEqual(Defaults.loudestMoment(late, length: 0.02), 0.02, "never past the end")
        let quiet = Asset(provider: "import", providerID: "a.wav", kind: .sfx, name: "A", duration: 1)
        XCTAssertEqual(Defaults.sound(for: quiet, waveform: nil).gainDB, TransitionSound.defaultGainDB, "unmeasured: sound effects' usual")
    }

    func testTheGainFollowsTheProjectsSpeech() {
        let media = MediaItem(id: "med_swoosh", path: "assets/sfx/swoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)
        let resolved = Defaults.Resolved(assetID: Defaults.lightSwoosh.assetID, name: "Swoosh", media: media, sound: TransitionSound(mediaID: media.id, gainDB: -23.3, offset: t(-0.39)))
        // The fixture's voice plays at -14 LUFS, 6 LU over Tandem's -20.
        let project = APIFixture.project()
        XCTAssertEqual(AudioLevels.speechLevel(in: project), -14)
        XCTAssertEqual(resolved.levelled(for: project).sound.gainDB, -17.3)
        XCTAssertEqual(resolved.levelled(for: project).levelled(for: project), resolved.levelled(for: project), "once")

        var prepared = resolved.prepared(for: project)
        XCTAssertEqual(prepared.addMedia, [.addMedia(item: media)])
        XCTAssertEqual(prepared.sound.gainDB, -17.3)
        var has = project
        has.media.append(media)
        XCTAssertEqual(resolved.prepared(for: has).addMedia, [], "already there")
        var watched = project
        watched.media.append(MediaItem(id: "med_other", path: media.path, kind: .audio, role: .sfx, duration: t(1), hasAudio: true))
        prepared = resolved.prepared(for: watched)
        XCTAssertEqual(prepared.addMedia, [])
        XCTAssertEqual(prepared.sound.mediaID, "med_other", "the watcher's item for the same file")
    }

    /// Using the default copies the file into the project's assets/sfx and
    /// gives the sound it plays with.
    func testUsingTheSwooshCopiesItIn() async throws {
        let temp = TempFolder("tandem-transition-sounds")
        let library = try CardSoundsFixture.library(at: temp.url.appendingPathComponent("library"), withSounds: false)
        XCTAssertFalse(Defaults.available(Defaults.lightSwoosh, in: library))
        var asset = Asset(provider: "elevenlabs", providerID: "sfx_2ybnc2tu", kind: .sfx, name: "A quick light swoosh", duration: 1)
        try AssetFixtures.wav(at: library.folder(for: asset).appendingPathComponent("original.wav"), seconds: 1)
        asset.state = .normalised
        asset.files = AssetFiles(original: "original.wav")
        try library.catalog.upsert(asset)
        XCTAssertTrue(Defaults.available(Defaults.lightSwoosh, in: library))

        let video = temp.url.appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        let resolved = try await Defaults.use(Defaults.lightSwoosh, in: library, folder: ProjectFolder(root: video), projectID: "prj_x", projectFile: nil)
        XCTAssertEqual(resolved.media.id, AssetLibrary.mediaID(for: Defaults.lightSwoosh.assetID))
        XCTAssertTrue(resolved.media.path.hasPrefix("assets/sfx/"), resolved.media.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.appendingPathComponent(resolved.media.path).path))
        XCTAssertEqual(resolved.sound, TransitionSound(mediaID: resolved.media.id, gainDB: -23.3, offset: t(-0.39)))
    }

    // MARK: - For agents

    func testAgentsAddChangeAndReadTheSound() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let swoosh = MediaItem(id: "med_swoosh", path: "assets/sfx/swoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)
        // As an agent sends it, the offset written as a time.
        let batch = #"""
        {"label": "Push with a swoosh", "commands": [
          {"addMedia": {"item": {"id": "med_swoosh", "path": "assets/sfx/swoosh.wav", "kind": "audio", "role": "sfx", "duration": 1, "hasAudio": true}}},
          {"removeTransition": {"transitionID": "tr_dissolve"}},
          {"addTransition": {"trackID": "trk_camera", "transition": {"id": "tr_push", "type": "push", "fromClipID": "clip_cam1", "toClipID": "clip_cam2"}, "sound": {"mediaID": "med_swoosh", "gainDB": -23.3, "offset": "-00:00.390"}}}
        ]}
        """#
        let applied = try h.service.apply(try ServiceJSON.decodeRequest(ApplyRequest.self, from: Data(batch.utf8)), context: h.context)
        let project = h.service.coordinator.project
        XCTAssertEqual(project.media(swoosh.id)?.path, swoosh.path)
        let sound = try XCTUnwrap(project.track("trk_sfx")?.clips.first)
        XCTAssertEqual(applied.createdIDs, ["tr_push", sound.id])
        XCTAssertEqual(sound.start, t(29.61))
        let text = TimelineDump.render(project)
        XCTAssertTrue(text.contains("~ push 0.700s into clip_cam2  tr_push  sound \(sound.id)"), text)

        try h.apply(.updateTransition(transitionID: "tr_push", patch: .object(["sound": .null])))
        XCTAssertTrue(h.service.coordinator.project.track("trk_sfx")?.clips.isEmpty ?? false)
    }

    func testTheSchemaTakesTheSoundAndSaysWhatsWrong() throws {
        func problems(_ text: String) throws -> [String] { CommandSchema.validate(command: try json(text), path: "commands[0]") }
        XCTAssertEqual(try problems(#"{"updateTransition": {"transitionID": "t", "patch": {"sound": {"gainDB": -20}}}}"#), [])
        XCTAssertEqual(try problems(#"{"updateTransition": {"transitionID": "t", "patch": {"sound": null}}}"#), [])
        XCTAssertEqual(try problems(#"{"updateTransition": {"transitionID": "t", "patch": {"sound": {"volume": 3}}}}"#).count, 1)
        XCTAssertTrue(try problems(#"{"updateTransition": {"transitionID": "t", "patch": {"sound": {"volume": 3}}}}"#)[0].contains("unknown field \"volume\""))
        XCTAssertEqual(try problems(#"{"addTransition": {"trackID": "t", "transition": {"type": "push"}, "sound": {"gainDB": -3}}}"#), [#"commands[0].addTransition.sound: missing "mediaID""#])
    }
}
