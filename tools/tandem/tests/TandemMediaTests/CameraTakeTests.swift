import AVFoundation
import TandemCore
import XCTest
@testable import TandemMedia

/// A video named like nothing in particular (a phone's `IMG_0151.MOV`)
/// becomes the camera take when it's a recording with a voice and a face.
final class CameraTakeTests: TempFolderTestCase {
    var folder: ProjectFolder { ProjectFolder(root: temp) }

    static let iPhone: [AVMetadataIdentifier: String] = [.quickTimeMetadataMake: "Apple", .quickTimeMetadataModel: "iPhone XS Max"]

    // The spoken and played sound, made once: the system voice takes a
    // moment.
    nonisolated(unsafe) private static var sounds: URL?

    /// A folder holding `speech.wav` (the system voice talking for about
    /// eight seconds) and `music.wav`.
    func soundFolder() async throws -> URL {
        if let sounds = Self.sounds { return sounds }
        let sounds = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-camera-sounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        let spoken = try await SyntheticMedia.writeSpeech(
            "Hi, I'm building a workbench today. First I cut the legs to length, then I glue the rails, and then I screw the top on.",
            to: sounds.appendingPathComponent("speech.wav"), leadIn: 0.2
        )
        try XCTSkipUnless(spoken, "no system voice to make test speech with")
        try SyntheticMedia.writeMusic(to: sounds.appendingPathComponent("music.wav"), seconds: 8)
        Self.sounds = sounds
        return sounds
    }

    override class func tearDown() {
        if let sounds { try? FileManager.default.removeItem(at: sounds) }
        sounds = nil
        super.tearDown()
    }

    enum Sound { case speech, music, silence }

    /// An eight second movie with that sound, showing a face or not.
    @discardableResult
    func writeTake(_ path: String, sound: Sound, face: Bool, metadata: [AVMetadataIdentifier: String] = [:]) async throws -> URL {
        let sounds = try await soundFolder()
        var spec = SyntheticMedia.Video(width: 320, height: 240, duration: 8)
        switch sound {
        case .speech: spec.audioFile = sounds.appendingPathComponent("speech.wav")
        case .music: spec.audioFile = sounds.appendingPathComponent("music.wav")
        case .silence: spec.audio = SyntheticMedia.Audio(amplitude: 0)
        }
        if face {
            guard let picture = SyntheticMedia.face() else { throw XCTSkip("Vision doesn't see a face in the emoji on this Mac") }
            spec.picture = picture
        }
        spec.metadata = metadata
        let url = file(path)
        try await SyntheticMedia.writeMovie(to: url, spec)
        return url
    }

    func testVerdicts() {
        // Speech in two or more of the classifier's windows, and a quarter of them.
        XCTAssertTrue(CameraTakes.heardSpeech([0.9, 0.1, 0.8, 0, 0.1, 0, 0.2, 0.1]))
        XCTAssertFalse(CameraTakes.heardSpeech([0.9, 0.1, 0.1, 0, 0.1, 0, 0.2, 0.1]))
        XCTAssertFalse(CameraTakes.heardSpeech([0.9, 0.6] + Array(repeating: 0, count: 10)))
        XCTAssertFalse(CameraTakes.heardSpeech([]))
        // A face at least a tenth of the frame high, in two frames or more.
        XCTAssertTrue(CameraTakes.sawFace([0.35, 0, 0.41, 0.22, 0, 0.25]))
        XCTAssertFalse(CameraTakes.sawFace([0.3, 0, 0, 0, 0, 0]))
        XCTAssertFalse(CameraTakes.sawFace([0.05, 0.06, 0.07, 0.05, 0.04, 0.06]), "a webcam bubble, or someone far off")
    }

    func testOnlyVideosNothingElseExplainsAreLookedAt() {
        let take = MediaItem(path: "source/IMG_0151.MOV", kind: .video, role: .other, duration: Time(seconds: 87), hasVideo: true, hasAudio: true)
        XCTAssertTrue(CameraTakes.isCandidate(take))
        var named = take
        named.role = .screen
        XCTAssertFalse(CameraTakes.isCandidate(named), "its name or folder said what it is")
        var silent = take
        silent.hasAudio = false
        XCTAssertFalse(CameraTakes.isCandidate(silent))
        var short = take
        short.duration = Time(seconds: 3)
        XCTAssertFalse(CameraTakes.isCandidate(short), "a Live Photo's movie is about that long")
    }

    func testWhereTakesAreAndWhatMadeThem() {
        XCTAssertTrue(CameraTakes.isInTakesFolder("source/IMG_0151.MOV"))
        XCTAssertTrue(CameraTakes.isInTakesFolder("Source/main vid/clip.mov"))
        XCTAssertFalse(CameraTakes.isInTakesFolder("IMG_0151.MOV"))
        XCTAssertFalse(CameraTakes.isInTakesFolder("drafts/Decision Models v3 draft.mp4"))
        XCTAssertFalse(CameraTakes.isInTakesFolder("/Users/mike/source/clip.mov"), "outside the project folder")

        XCTAssertEqual(CameraTakes.cameraName(make: "Apple", model: "iPhone XS Max"), "Apple iPhone XS Max")
        XCTAssertEqual(CameraTakes.cameraName(make: "Canon", model: "Canon EOS R6"), "Canon EOS R6")
        XCTAssertEqual(CameraTakes.cameraName(make: nil, model: "iPhone 16 Pro"), "iPhone 16 Pro")
        XCTAssertEqual(CameraTakes.cameraName(make: "GoPro", model: " "), "GoPro")
        XCTAssertNil(CameraTakes.cameraName(make: nil, model: ""))
    }

    func testListeningHearsSpeechButNotMusicOrSilence() async throws {
        let speech = try await writeTake("speech.mov", sound: .speech, face: false)
        let music = try await writeTake("music.mov", sound: .music, face: false)
        let silence = try await writeTake("silence.mov", sound: .silence, face: false)
        let heard = try await CameraTakes.speechConfidences(in: speech, duration: 8)
        XCTAssertTrue(CameraTakes.heardSpeech(heard), "\(heard)")
        let played = try await CameraTakes.speechConfidences(in: music, duration: 8)
        XCTAssertFalse(CameraTakes.heardSpeech(played), "\(played)")
        let quiet = try await CameraTakes.speechConfidences(in: silence, duration: 8)
        XCTAssertFalse(CameraTakes.heardSpeech(quiet), "\(quiet)")
    }

    func testLookingFindsAFaceButNotAPlainPicture() async throws {
        let face = try await writeTake("face.mov", sound: .silence, face: true)
        let plain = try await writeTake("plain.mov", sound: .silence, face: false)
        let seen = try await CameraTakes.faceHeights(in: face, duration: 8)
        XCTAssertTrue(CameraTakes.sawFace(seen), "\(seen)")
        let none = try await CameraTakes.faceHeights(in: plain, duration: 8)
        XCTAssertFalse(CameraTakes.sawFace(none), "\(none)")
    }

    func testAVoiceAndAFaceInARecordingMakeTheCameraTake() async throws {
        // The workbench short: a selfie video in source/.
        try await writeTake("source/IMG_0151.MOV", sound: .speech, face: true, metadata: Self.iPhone)
        // Phone footage of the build guide, talked over: no face.
        try await writeTake("photos/IMG_0141.MOV", sound: .speech, face: false, metadata: Self.iPhone)
        // A face with no voice, and a face over music.
        try await writeTake("source/IMG_0152.MOV", sound: .silence, face: true)
        try await writeTake("source/IMG_0153.MOV", sound: .music, face: true)
        // A render of an edit: a voice and a face, but no camera made it and
        // it isn't in source/.
        try await writeTake("Workbench v1.mp4", sound: .speech, face: true)
        // Another phone video of someone talking, outside source/.
        try await writeTake("photos/IMG_0160.MOV", sound: .speech, face: true, metadata: Self.iPhone)

        let report = try await MediaScanner.scanReport(folder, known: [])
        let roles = Dictionary(uniqueKeysWithValues: report.items.map { ($0.path, $0.role) })
        XCTAssertEqual(roles, [
            "source/IMG_0151.MOV": .camera, "photos/IMG_0141.MOV": .other, "source/IMG_0152.MOV": .other,
            "source/IMG_0153.MOV": .other, "Workbench v1.mp4": .other, "photos/IMG_0160.MOV": .camera
        ])
        let why = Dictionary(uniqueKeysWithValues: report.cameraTakes.map { ($0.path, $0.reason) })
        XCTAssertEqual(why, [
            "photos/IMG_0160.MOV": "an Apple iPhone XS Max video with speech and a face in it",
            "source/IMG_0151.MOV": "an Apple iPhone XS Max video with speech and a face in it"
        ])
        XCTAssertEqual(Set(report.cameraTakes.map(\.mediaID)), Set(report.items.filter { $0.role == .camera }.map(\.id)))

        // A role Mike changed stays changed, and known files aren't looked at again.
        var known = report.items
        let index = try XCTUnwrap(known.firstIndex { $0.path == "source/IMG_0151.MOV" })
        known[index].role = .other
        let again = try await MediaScanner.scanReport(folder, known: known)
        XCTAssertEqual(again.items.first { $0.path == "source/IMG_0151.MOV" }?.role, .other)
        XCTAssertEqual(again.cameraTakes, [])
    }

    func testAVideoInSourceNeedsNoCameraMetadata() async throws {
        let url = try await writeTake("source/take.mov", sound: .speech, face: true)
        // The app probes a file dropped from Finder on its own.
        let item = try await MediaScanner.probe(url, folder: folder)
        XCTAssertEqual(item.role, .camera)
        let reason = await CameraTakes.reason(for: MediaItem(path: "source/take.mov", kind: .video, role: .other, duration: item.duration, hasVideo: true, hasAudio: true), at: url)
        XCTAssertEqual(reason, "a video in source/ with speech and a face in it")
    }

    func testRecordItCameraFilesSayWhy() async throws {
        try await SyntheticMedia.writeMovie(to: file("source/t1-camera.mov"), .init(duration: 1))
        try await SyntheticMedia.writeMovie(to: file("source/t1-screen.mov"), .init(duration: 1))
        try await SyntheticMedia.writeMovie(to: file("broll/webcam.mov"), .init(duration: 1))
        let report = try await MediaScanner.scanReport(folder, known: [])
        XCTAssertEqual(report.cameraTakes.map(\.path), ["source/t1-camera.mov"])
        XCTAssertEqual(report.cameraTakes.first?.reason, "named like a record-it camera file")
    }
}
