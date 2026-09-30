import XCTest
@testable import TandemCore

/// Speech levelling: what placing sound sets, `normalizeSpeech`, the
/// project's speech level and the gain maths the render shares.
final class LevelTests: XCTestCase {
    /// A voice-over and a sound effect beside the fixture's take and music.
    func project() -> (Fixture, ProjectCoordinator) {
        var fixture = Fixture()
        fixture.project.media += [
            MediaItem(id: "med_vo", path: "vo/line.m4a", kind: .audio, role: .music, duration: t(20), hasAudio: true),
            MediaItem(id: "med_whoosh", path: "sfx/whoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true),
            MediaItem(id: "med_intro", path: "Intro.mp4", kind: .video, role: .other, duration: t(5), hasVideo: true, hasAudio: true)
        ]
        return (fixture, ProjectCoordinator(project: fixture.project))
    }

    // MARK: - Placing

    func testPlacedSpeechIsNormalisedAndMusicAndEffectsKeepTheirGains() throws {
        let (f, c) = project()
        try c.run("Place", .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(30)))
        try c.run("Music", .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(30)))
        try c.run("Whoosh", .placeMedia(mediaIDs: ["med_whoosh"], at: t(5)))
        let voice = c.clips("Voice")[0]
        XCTAssertEqual(voice.audio?.normalizeTo, AudioLevels.defaultSpeechLoudness)
        XCTAssertEqual(voice.audio?.normalizeTo, -20)
        XCTAssertEqual(voice.audio?.gainDB, 0)
        XCTAssertEqual(c.clips("Music")[0].audio, AudioProperties(gainDB: -31, fadeOut: t(2)))
        XCTAssertEqual(c.clips("SFX")[0].audio, AudioProperties(gainDB: -15))
        XCTAssertEqual(f.project.settings.speechLoudness, -20)
    }

    func testPlacingUsesTheProjectsSpeechLevel() throws {
        let (_, c) = project()
        try c.run("Level", .updateSettings(patch: .object(["speechLoudness": .number(-18)])))
        try c.run("Place", .placeMedia(mediaIDs: ["med_camera"], at: .zero, duration: t(10)))
        XCTAssertEqual(c.clips("Voice")[0].audio?.normalizeTo, -18)
    }

    func testAnythingPlacedOnASpeechTrackIsSpeech() throws {
        let (f, c) = project()
        // A voice-over the scanner took for music, dropped on Voice.
        try c.run("VO", .placeMedia(mediaIDs: ["med_vo"], at: t(40), audioTrackID: f.track("Voice").id))
        XCTAssertEqual(c.clips("Voice")[0].audio, AudioProperties(normalizeTo: -20))
        // Camera sound is speech wherever it goes.
        try c.run("Camera on SFX", .placeMedia(mediaIDs: ["med_camera"], at: t(70), duration: t(5), audioTrackID: f.track("SFX").id))
        XCTAssertEqual(c.clips("SFX")[0].audio?.normalizeTo, -20)
        // A file with no clearer role (a rendered intro) lands on Voice as speech.
        try c.run("Intro", .placeMedia(mediaIDs: ["med_intro"], at: t(100)))
        XCTAssertEqual(c.clips("Voice").last?.audio?.normalizeTo, -20)
        // The same music on the Music track keeps its bed level.
        try c.run("Music", .placeMedia(mediaIDs: ["med_vo"], at: t(40)))
        XCTAssertEqual(c.clips("Music")[0].audio?.gainDB, -31)
        XCTAssertNil(c.clips("Music")[0].audio?.normalizeTo)
    }

    // MARK: - Normalise speech clips

    /// A Filmora-style project: voice with hand gains, one clip on the old
    /// -14 default, music, a whoosh, and screen sound on Voice.
    func imported() throws -> ProjectCoordinator {
        let (f, c) = project()
        try c.run("Build",
            .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(30)),
            .placeMedia(mediaIDs: ["med_camera"], at: t(30), sourceStart: t(30), duration: t(10)),
            .placeMedia(mediaIDs: ["med_screen"], at: t(40), duration: t(5), audioTrackID: f.track("Voice").id, includeAudio: true),
            .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(45)),
            .placeMedia(mediaIDs: ["med_whoosh"], at: t(5))
        )
        let voice = c.clips("Voice")
        try c.run("Filmora levels",
            .updateClip(clipID: voice[0].id, patch: .object(["audio": .object(["gainDB": .number(3.9), "normalizeTo": .null, "fadeOut": .number(0.5)])])),
            .updateClip(clipID: voice[1].id, patch: .object(["audio": .object(["normalizeTo": .number(-14), "voiceIsolation": .number(0.5)])])),
            .updateClip(clipID: voice[2].id, patch: .object(["audio": .object(["gainDB": .number(0.35), "normalizeTo": .null])]))
        )
        return c
    }

    func testNormalizeSpeechLevelsEverySpeechClipAsOneUndoStep() throws {
        let c = try imported()
        let before = c.project
        let result = try c.run("Normalise speech clips", .normalizeSpeech)
        XCTAssertEqual(result.warnings, [])
        for clip in c.clips("Voice") {
            XCTAssertEqual(clip.audio?.normalizeTo, -20, clip.id)
            XCTAssertEqual(clip.audio?.gainDB, 0, clip.id)
        }
        let voice = c.clips("Voice")
        XCTAssertEqual(voice[0].audio?.fadeOut, t(0.5), "fades stay")
        XCTAssertEqual(voice[1].audio?.voiceIsolation, 0.5, "voice isolation stays")
        XCTAssertEqual(c.clips("Music")[0].audio, before.track(named: "Music")!.clips[0].audio, "music keeps its gain")
        XCTAssertEqual(c.clips("SFX")[0].audio?.gainDB, -15, "sound effects keep theirs")
        assertValid(c.project)

        c.undo()
        XCTAssertEqual(c.project, before, "one undo puts every clip back")
    }

    /// Where speech plays: the project's speech level once it's levelled,
    /// or an import's own level before that.
    func testTheSpeechLevelIsWhereTheVoicePlays() throws {
        let c = try imported()
        // Levelled clips: -14 (10 s) is the only one; the others have
        // gains but no level, so they don't say.
        XCTAssertEqual(AudioLevels.speechLevel(in: c.project), -14)
        try c.run("Normalise", .normalizeSpeech)
        XCTAssertEqual(AudioLevels.speechLevel(in: c.project), -20)
        // Like the Decision Models import: every take at -28.74.
        for clip in c.clips("Voice") {
            try c.run("Import level", .updateClip(clipID: clip.id, patch: .object(["audio": .object(["normalizeTo": .number(-28.74)])])))
        }
        XCTAssertEqual(AudioLevels.speechLevel(in: c.project), -28.74, accuracy: 1e-9)
        // Nothing levelled: the project's speech level.
        XCTAssertEqual(AudioLevels.speechLevel(in: Project.standard(name: "Empty")), -20)
    }

    func testNormalizeSpeechSaysWhenThereIsNothingToDo() throws {
        let c = try imported()
        try c.run("Once", .normalizeSpeech)
        XCTAssertEqual(try c.run("Twice", .normalizeSpeech).warnings, ["Every speech clip is already at -20 LUFS with no gain."])
        let empty = ProjectCoordinator(project: Project.standard(name: "Empty"))
        XCTAssertEqual(try empty.run("None", .normalizeSpeech).warnings.first?.hasPrefix("There are no speech clips"), true)
    }

    func testNormalizeSpeechLeavesLockedTracksAndKeepsGainAnimation() throws {
        let c = try imported()
        let voice = c.clips("Voice")
        try c.run("Duck", .setKeyframes(clipID: voice[0].id, parameter: "audio.gainDB", keyframes: [
            Keyframe(time: t(1), value: .number(0)), Keyframe(time: t(2), value: .number(-6))
        ]))
        let locked = try c.run("Voice 2", .addTrack(kind: .audio, name: "Voice 2")).createdIDs[0]
        try c.run("PiP sound", .placeMedia(mediaIDs: ["med_camera"], at: t(50), duration: t(5), audioTrackID: locked))
        try c.run("Gain", .updateClip(clipID: c.project.track(locked)!.clips[0].id, patch: .object(["audio": .object(["gainDB": .number(4)])])))
        try c.run("Lock", .updateTrack(trackID: locked, patch: .object(["locked": .bool(true)])))

        let result = try c.run("Normalise speech clips", .normalizeSpeech)
        XCTAssertEqual(result.warnings, [
            "Locked track \"Voice 2\" was left as it was.",
            "1 speech clip keeps its gain animation, which plays on top of the level."
        ])
        XCTAssertEqual(c.project.track(locked)!.clips[0].audio?.gainDB, 4)
        XCTAssertEqual(c.clips("Voice")[0].keyframes["audio.gainDB"]?.count, 2)
        XCTAssertEqual(c.clips("Voice")[0].audio?.normalizeTo, -20)
    }

    func testSpeechClipsAreCameraAndVoiceSoundAndTakeTracks() throws {
        let c = try imported()
        let speech = AudioLevels.speechClips(in: c.project)
        XCTAssertEqual(speech.map(\.track.name), ["Voice", "Voice", "Voice"])
        XCTAssertEqual(speech.map(\.clip.mediaID), ["med_camera", "med_camera", "med_screen"], "the screen's sound on Voice counts")
        XCTAssertFalse(AudioLevels.isSpeechTrack(c.project.track(named: "Music")!))
        XCTAssertTrue(AudioLevels.isSpeechTrack(c.project.track(named: "Voice")!))
        XCTAssertFalse(AudioLevels.isSpeechTrack(c.project.track(named: "Camera")!), "video tracks carry no sound")
    }

    // MARK: - The speech level setting

    func testChangingTheSpeechLevelMovesTheClipsAtTheOldLevel() throws {
        let c = try imported()
        try c.run("Normalise", .normalizeSpeech)
        let voice = c.clips("Voice")
        try c.run("Own level", .updateClip(clipID: voice[1].id, patch: .object(["audio": .object(["normalizeTo": .number(-24)])])))
        try c.run("Gain", .updateClip(clipID: voice[2].id, patch: .object(["audio": .object(["gainDB": .number(2)])])))

        try c.run("Speech level", .updateSettings(patch: .object(["speechLoudness": .number(-18)])))
        XCTAssertEqual(c.project.settings.speechLoudness, -18)
        XCTAssertEqual(c.clips("Voice").map(\.audio?.normalizeTo), [-18, -24, -18], "a clip with its own level keeps it")
        XCTAssertEqual(c.clips("Voice")[2].audio?.gainDB, 2, "gains stay")

        XCTAssertThrowsError(try c.run("Too loud", .updateSettings(patch: .object(["speechLoudness": .number(-3)]))))
        XCTAssertThrowsError(try c.run("Too quiet", .updateSettings(patch: .object(["speechLoudness": .number(-60)]))))
        XCTAssertEqual(c.project.settings.speechLoudness, -18)
    }

    func testProjectsFromBeforeTheSpeechLevelLoadWithTheDefault() throws {
        let old = #"{"width": 3840, "height": 2160, "loudnessTarget": -14, "truePeakCeiling": -1}"#
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.speechLoudness, -20)
        XCTAssertEqual(settings.loudnessTarget, -14)

        // A whole project file as the earlier build wrote it.
        var project = Project.standard(name: "Old")
        project.settings.speechLoudness = -17
        var json = try JSONSerialization.jsonObject(with: ProjectFile.encoder().encode(ProjectFile.Envelope(revision: 3, project: project))) as! [String: Any]
        var body = json["project"] as! [String: Any]
        var fields = body["settings"] as! [String: Any]
        XCTAssertEqual(fields.removeValue(forKey: "speechLoudness") as? Double, -17, "new files write it")
        body["settings"] = fields
        json["project"] = body
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("old.tandem")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = try ProjectFile.load(from: url)
        XCTAssertEqual(loaded.project.settings.speechLoudness, -20)
        XCTAssertEqual(loaded.revision, 3)
    }

    // MARK: - Gain maths

    func testNormaliseGainIsTheTargetMinusTheMeasurementWithinThirtyDecibels() {
        XCTAssertEqual(AudioLevels.normalizeGainDB(target: -20, measuredLUFS: -32.2)!, 12.2, accuracy: 1e-9)
        XCTAssertEqual(AudioLevels.normalizeGainDB(target: -20, measuredLUFS: -14), -6)
        XCTAssertEqual(AudioLevels.normalizeGainDB(target: -20, measuredLUFS: -70), 30, "at most +30 dB")
        XCTAssertEqual(AudioLevels.normalizeGainDB(target: -40, measuredLUFS: 0), -30, "at most -30 dB")
        XCTAssertEqual(AudioLevels.normalizeGainDB(target: -20, measuredLUFS: -.infinity), 0, "a silent file has nothing to level")
        XCTAssertNil(AudioLevels.normalizeGainDB(target: -20, measuredLUFS: nil), "not measured yet")
    }

    func testGainIsAddedAfterNormalising() {
        let measured = -32.2
        XCTAssertEqual(AudioLevels.playbackLoudness(AudioProperties(gainDB: 2, normalizeTo: -20), measuredLUFS: measured)!, -18, accuracy: 1e-9)
        XCTAssertEqual(AudioLevels.playbackLoudness(AudioProperties(gainDB: 3.9), measuredLUFS: measured)!, -28.3, accuracy: 1e-9)
        XCTAssertNil(AudioLevels.playbackLoudness(AudioProperties(normalizeTo: -20), measuredLUFS: nil))
        XCTAssertNil(AudioLevels.playbackLoudness(AudioProperties(normalizeTo: -20), measuredLUFS: -.infinity))
    }
}
