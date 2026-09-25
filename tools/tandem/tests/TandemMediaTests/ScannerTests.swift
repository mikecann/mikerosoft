import AVFoundation
import TandemCore
import XCTest
@testable import TandemMedia

final class FingerprintTests: TempFolderTestCase {
    func testRoundTripsThroughItsString() {
        let print = Fingerprint(size: 1234, modified: 1_790_000_000_123, hash: "abcd")
        XCTAssertEqual(print.description, "1234-1790000000123-abcd")
        XCTAssertEqual(Fingerprint(print.description), print)
        XCTAssertNil(Fingerprint("nonsense"))
    }

    func testHashesBothEndsOfBigFiles() throws {
        let size = 3 * Fingerprint.sampleLength
        var bytes = [UInt8](repeating: 7, count: size)
        let url = file("big.bin")
        try Data(bytes).write(to: url)
        let original = try Fingerprint.compute(for: url)

        // A change in the middle isn't seen (by design, it's cheap)...
        bytes[size / 2] = 9
        try Data(bytes).write(to: url)
        XCTAssertEqual(try Fingerprint.compute(for: url).hash, original.hash)

        // ...but a change in the last megabyte is.
        bytes[size - 10] = 9
        try Data(bytes).write(to: url)
        XCTAssertNotEqual(try Fingerprint.compute(for: url).hash, original.hash)
    }

    func testStatMatchNoticesTouches() throws {
        let url = file("a.wav")
        try Data("hello".utf8).write(to: url)
        let print = try Fingerprint.compute(for: url)
        XCTAssertTrue(print.matchesStat(of: url))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
        XCTAssertFalse(print.matchesStat(of: url))
        XCTAssertEqual(try Fingerprint.compute(for: url).contentID, print.contentID)
    }
}

final class RoleTests: XCTestCase {
    func testRecordItNames() {
        XCTAssertEqual(MediaScanner.role(forPath: "source/2026-09-24_102826-camera.mov"), .camera)
        XCTAssertEqual(MediaScanner.role(forPath: "source/main vid/2026-09-24_105434-screen.mov"), .screen)
        XCTAssertEqual(MediaScanner.role(forPath: "edit/main-camera-cfr.mov"), .camera)
    }

    func testFoldersBeatWordsInNames() {
        XCTAssertEqual(MediaScanner.role(forPath: "music/camera-shutter.mp3"), .music)
        XCTAssertEqual(MediaScanner.role(forPath: "sfx/screen-tap.wav"), .sfx)
        XCTAssertEqual(MediaScanner.role(forPath: "broll/hf-decider.mp4"), .broll)
        XCTAssertEqual(MediaScanner.role(forPath: "motion-graphics/out/leaderboard.mp4"), .graphic)
        XCTAssertEqual(MediaScanner.role(forPath: "graphics/logo.png"), .graphic)
        XCTAssertEqual(MediaScanner.role(forPath: "assets/stickers/like.mov"), .sticker)
    }

    func testImagesAndStrays() {
        XCTAssertEqual(MediaScanner.role(forPath: "thumbs/screenshot.png"), .image)
        XCTAssertEqual(MediaScanner.role(forPath: "Decision Models v14.mp4"), .other)
        XCTAssertEqual(MediaScanner.role(forPath: "whoosh.wav"), .sfx)
        XCTAssertEqual(MediaScanner.role(forPath: "voice.wav"), .music)
    }

    func testShortStrayAudioIsAnEffect() {
        XCTAssertEqual(MediaScanner.role(forPath: "ping.wav", kind: .audio, duration: Time(seconds: 1.5)), .sfx)
        XCTAssertEqual(MediaScanner.role(forPath: "bed.wav", kind: .audio, duration: Time(seconds: 90)), .music)
        // A name that says what it is wins over the duration.
        XCTAssertEqual(MediaScanner.role(forPath: "music/sting.wav", kind: .audio, duration: Time(seconds: 2)), .music)
    }
}

final class ScannerTests: TempFolderTestCase {
    var folder: ProjectFolder { ProjectFolder(root: temp) }

    func testWalkSkipsTandemExportsHiddenAndToolingFolders() throws {
        for path in [
            "source/a-camera.mov", "music/bed.mp3", "graphics/logo.png", "top.wav",
            ".tandem/cache/proxy/x/proxy.mov", "exports/final.mp4", "node_modules/pkg/demo.mp4",
            ".build/debug/x.mov", ".git/objects/y.mov", ".hidden/z.mov", "Old.wfp.dir/clip.mov",
            "source/.DS_Store", "notes.txt", "source/.partial.mov", "motion-graphics/node_modules/a.mp4"
        ] { touch(path) }
        let found = MediaScanner.mediaFiles(in: folder).map { folder.path(for: $0) }
        XCTAssertEqual(found, ["graphics/logo.png", "music/bed.mp3", "source/a-camera.mov", "top.wav"])
        XCTAssertTrue(MediaScanner.isSkippedPath("exports/final.mp4"))
        XCTAssertTrue(MediaScanner.isSkippedPath("a/Old.wfp.dir/clip.mov"))
        XCTAssertTrue(MediaScanner.isSkippedPath("source/.partial.mov"))
        XCTAssertFalse(MediaScanner.isSkippedPath("source/a-camera.mov"))
    }

    func testScanFindsProbesAndKeepsKnownIDs() async throws {
        try await SyntheticMedia.writeMovie(to: file("broll/clip.mp4"), .init(width: 320, height: 180, duration: 1))
        try SyntheticMedia.writeAudioFile(to: file("music/bed.wav"), segments: [(2, 0.5)])
        try SyntheticMedia.writePNG(to: file("graphics/logo.png"), width: 64, height: 32, alpha: true)
        touch("music/broken.mp3", contents: "not really an mp3")

        let first = try await MediaScanner.scanReport(folder, known: [])
        XCTAssertEqual(first.items.map(\.path).sorted(), ["broll/clip.mp4", "graphics/logo.png", "music/bed.wav"])
        XCTAssertEqual(first.skipped.map(\.path), ["music/broken.mp3"])

        let clip = try XCTUnwrap(first.items.first { $0.path == "broll/clip.mp4" })
        XCTAssertEqual(clip.kind, .video)
        XCTAssertEqual(clip.role, .broll)
        XCTAssertEqual(clip.width, 320)
        XCTAssertEqual(clip.height, 180)
        XCTAssertTrue(clip.hasAudio)
        XCTAssertNotNil(clip.fingerprint)

        let bed = try XCTUnwrap(first.items.first { $0.path == "music/bed.wav" })
        XCTAssertEqual(bed.kind, .audio)
        XCTAssertEqual(bed.role, .music)
        XCTAssertFalse(bed.hasVideo)
        XCTAssertEqual(bed.duration?.seconds ?? 0, 2, accuracy: 0.001)

        let logo = try XCTUnwrap(first.items.first { $0.path == "graphics/logo.png" })
        XCTAssertEqual(logo.kind, .image)
        XCTAssertEqual(logo.role, .graphic)
        XCTAssertEqual(logo.width, 64)
        XCTAssertTrue(logo.hasAlpha)

        // A user's role and look survive a rescan; unchanged files come back as they were.
        var known = first.items
        let bedIndex = try XCTUnwrap(known.firstIndex { $0.path == "music/bed.wav" })
        known[bedIndex].role = .sfx
        known[bedIndex].look = [Effect(type: "colour")]
        let second = try await MediaScanner.scan(folder, known: known)
        XCTAssertEqual(Set(second.map(\.id)), Set(first.items.map(\.id)))
        XCTAssertEqual(second.first { $0.path == "music/bed.wav" }, known[bedIndex])
    }

    func testRenamedFileKeepsItsIDAndMissingFilesAreReported() async throws {
        try SyntheticMedia.writeAudioFile(to: file("music/a.wav"), segments: [(1, 0.5)])
        try SyntheticMedia.writeAudioFile(to: file("music/b.wav"), segments: [(1, 0.25)])
        let first = try await MediaScanner.scan(folder, known: [])
        let a = try XCTUnwrap(first.first { $0.path == "music/a.wav" })
        let b = try XCTUnwrap(first.first { $0.path == "music/b.wav" })

        try FileManager.default.moveItem(at: file("music/a.wav"), to: file("music/renamed.wav"))
        try FileManager.default.removeItem(at: file("music/b.wav"))
        let report = try await MediaScanner.scanReport(folder, known: first)

        XCTAssertEqual(report.items.count, 1)
        XCTAssertEqual(report.items.first?.id, a.id)
        XCTAssertEqual(report.items.first?.path, "music/renamed.wav")
        XCTAssertEqual(report.renamed, [RenamedMedia(id: a.id, from: "music/a.wav", to: "music/renamed.wav")])
        XCTAssertEqual(report.missing.map(\.id), [b.id])
    }

    func testAbsolutePathsInsideTheFolderMatchAndBecomeRelative() async throws {
        try SyntheticMedia.writeAudioFile(to: file("music/a.wav"), segments: [(1, 0.5)])
        var imported = try await MediaScanner.scan(folder, known: [])
        imported[0].path = file("music/a.wav").path
        let rescanned = try await MediaScanner.scan(folder, known: imported)
        XCTAssertEqual(rescanned.map(\.id), imported.map(\.id))
        XCTAssertEqual(rescanned.map(\.path), ["music/a.wav"])
    }

    func testKnownFilesOutsideTheFolderAreKeptWhileTheyExist() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-outside-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: outside) }
        try SyntheticMedia.writeAudioFile(to: outside, segments: [(1, 0.5)])
        let item = try await MediaScanner.probe(outside, folder: folder)
        XCTAssertTrue(item.path.hasPrefix("/"))
        let found = try await MediaScanner.scanReport(folder, known: [item])
        XCTAssertEqual(found.items, [item])
        try FileManager.default.removeItem(at: outside)
        let gone = try await MediaScanner.scanReport(folder, known: [item])
        XCTAssertEqual(gone.items, [])
        XCTAssertEqual(gone.missing, [item])
    }

    func testKnownFilesInSkippedFoldersStay() async throws {
        try SyntheticMedia.writeAudioFile(to: file("exports/final.wav"), segments: [(1, 0.5)])
        let render = try await MediaScanner.probe(file("exports/final.wav"), folder: folder)
        XCTAssertEqual(render.path, "exports/final.wav")
        let report = try await MediaScanner.scanReport(folder, known: [render])
        XCTAssertEqual(report.items, [render])
        XCTAssertEqual(report.missing, [])
        // A copy elsewhere doesn't steal its ID.
        try FileManager.default.copyItem(at: file("exports/final.wav"), to: file("music/final copy.wav"))
        let again = try await MediaScanner.scanReport(folder, known: [render])
        XCTAssertEqual(again.items.count, 2)
        XCTAssertEqual(again.items.first { $0.path == "exports/final.wav" }?.id, render.id)
        XCTAssertNotEqual(again.items.first { $0.path == "music/final copy.wav" }?.id, render.id)
    }

    func testChangedFileIsProbedAgainUnderTheSameID() async throws {
        try SyntheticMedia.writeAudioFile(to: file("music/a.wav"), segments: [(1, 0.5)])
        let first = try await MediaScanner.scan(folder, known: [])
        try SyntheticMedia.writeAudioFile(to: file("music/a.wav"), segments: [(3, 0.5)])
        let second = try await MediaScanner.scan(folder, known: first)
        XCTAssertEqual(second.first?.id, first.first?.id)
        XCTAssertEqual(second.first?.duration?.seconds ?? 0, 3, accuracy: 0.001)
        XCTAssertNotEqual(second.first?.fingerprint, first.first?.fingerprint)
    }

    func testScannedItemsSurviveAJSONRoundTripUnchanged() async throws {
        // refreshMedia compares scanned items with the saved project, so
        // every probed value must be stable through JSON.
        try await SyntheticMedia.writeMovie(to: file("source/t-camera.mov"), .init(duration: 1.3))
        let items = try await MediaScanner.scan(folder, known: [])
        let decoded = try JSONDecoder().decode([MediaItem].self, from: JSONEncoder().encode(items))
        XCTAssertEqual(decoded, items)
    }
}

final class ProbeTests: TempFolderTestCase {
    var folder: ProjectFolder { ProjectFolder(root: temp) }

    func testConstantFrameRateMovie() async throws {
        let url = file("cam.mov")
        try await SyntheticMedia.writeMovie(to: url, .init(width: 640, height: 360, fps: 30, duration: 2))
        let item = try await MediaScanner.probe(url, folder: folder)
        XCTAssertEqual(item.path, "cam.mov")
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.frameRate, FrameRate(30))
        XCTAssertEqual(item.width, 640)
        XCTAssertEqual(item.height, 360)
        XCTAssertEqual(item.duration?.seconds ?? 0, 2, accuracy: 0.05)
        XCTAssertTrue(item.hasVideo)
        XCTAssertTrue(item.hasAudio)
        XCTAssertFalse(item.hasAlpha)
        XCTAssertFalse(item.variableFrameRate)
    }

    func testVariableFrameRateLooksAtFrameTiming() async throws {
        // Like a record-it screen recording: a 30 fps grid with frames held
        // for a long time while nothing changes.
        var times: [Double] = []
        var t = 0.0
        for i in 0..<40 {
            times.append(t)
            t += i % 5 == 4 ? 1.0 : 1.0 / 30
        }
        let url = file("screen.mov")
        try await SyntheticMedia.writeMovie(to: url, .init(frameTimes: times, audio: nil))
        let item = try await MediaScanner.probe(url, folder: folder)
        XCTAssertTrue(item.variableFrameRate)
        XCTAssertEqual(item.frameRate, FrameRate(30))
        XCTAssertFalse(item.hasAudio)
    }

    func testAFewDroppedFramesDontMakeAFileVariable() {
        var times = (0..<3000).map { Int64($0) * 640 }
        times.removeAll { [700, 1500, 2200].contains($0 / 640) }
        let timing = FrameTiming(presentationTimes: times, timescale: 19_200)
        XCTAssertFalse(timing.isVariable)
        XCTAssertEqual(timing.rate, FrameRate(30))
    }

    func testFrameRateSnapping() {
        XCTAssertEqual(FrameTiming.snap(framesPerSecond: 29.97), FrameRate(30_000, 1001))
        XCTAssertEqual(FrameTiming.snap(framesPerSecond: 25.0001), FrameRate(25))
        XCTAssertEqual(FrameTiming.snap(framesPerSecond: 12.5), FrameRate(25, 2))
        // 600-based timescales alternate 20 and 21 ticks at 29.97.
        let ntsc = (0..<300).map { Int64((Double($0) * 600 * 1001 / 30_000).rounded()) }
        XCTAssertEqual(FrameTiming(presentationTimes: ntsc, timescale: 600).rate, FrameRate(30_000, 1001))
    }

    func testRotationIsApplied() async throws {
        let url = file("portrait.mov")
        try await SyntheticMedia.writeMovie(to: url, .init(width: 320, height: 180, duration: 0.5, audio: nil, transform: CGAffineTransform(rotationAngle: .pi / 2)))
        let item = try await MediaScanner.probe(url, folder: folder)
        XCTAssertEqual(item.width, 180)
        XCTAssertEqual(item.height, 320)
    }

    func testHEVCWithAlpha() async throws {
        let url = file("sticker.mov")
        try await SyntheticMedia.writeMovie(to: url, .init(width: 128, height: 128, duration: 0.5, codec: .hevcWithAlpha, audio: nil))
        let item = try await MediaScanner.probe(url, folder: folder)
        XCTAssertTrue(item.hasAlpha)
    }

    func testAudioOnlyFiles() async throws {
        let url = file("voice.m4a")
        try await SyntheticMedia.writeMovie(to: file("tmp.mov"), .init(duration: 1))
        // An .m4a with just the sound.
        let asset = AVURLAsset(url: file("tmp.mov"))
        let export = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A))
        try await export.export(to: url, as: .m4a)
        let item = try await MediaScanner.probe(url, folder: folder)
        XCTAssertEqual(item.kind, .audio)
        XCTAssertFalse(item.hasVideo)
        XCTAssertTrue(item.hasAudio)
        XCTAssertNil(item.width)
    }

    func testUnreadableFileThrows() async throws {
        let url = file("half.mov")
        try Data(repeating: 0, count: 4096).write(to: url)
        do {
            _ = try await MediaScanner.probe(url, folder: folder)
            XCTFail("expected an error")
        } catch {
            // Any error will do; the scanner reports it as skipped.
        }
    }
}

final class TakePairingTests: TempFolderTestCase {
    var folder: ProjectFolder { ProjectFolder(root: temp) }

    func testTakeNames() {
        XCTAssertEqual(TakePairing.takeName(forPath: "edit/main-camera.mov")?.base, "main")
        XCTAssertEqual(TakePairing.takeName(forPath: "edit/main-screen.mov")?.role, "screen")
        XCTAssertEqual(TakePairing.takeName(forPath: "a-b-camera.mov")?.base, "a-b")
        XCTAssertNil(TakePairing.takeName(forPath: "camera.mov"))
        XCTAssertNil(TakePairing.takeName(forPath: "main-camera-cfr.mov"))
    }

    func testSidecarGivesExactOffsets() async throws {
        let short = SyntheticMedia.Video(duration: 0.5, audio: nil)
        try await SyntheticMedia.writeMovie(to: file("source/main-camera.mov"), short)
        try await SyntheticMedia.writeMovie(to: file("source/main-screen.mov"), short)
        try await SyntheticMedia.writeMovie(to: file("source/other-camera.mov"), short)
        let sidecar = TakeSidecar(files: [
            .init(role: "camera", startHostTime: 1000.25),
            .init(role: "screen", file: "main-screen.mov", startHostTime: 1000.0)
        ])
        try JSONEncoder().encode(sidecar).write(to: file("source/main.take.json"))

        let items = try await MediaScanner.scan(folder, known: [])
        let camera = try XCTUnwrap(items.first { $0.path == "source/main-camera.mov" })
        let screen = try XCTUnwrap(items.first { $0.path == "source/main-screen.mov" })
        let lone = try XCTUnwrap(items.first { $0.path == "source/other-camera.mov" })
        XCTAssertNotNil(camera.takeID)
        XCTAssertEqual(camera.takeID, screen.takeID)
        XCTAssertEqual(camera.takeOffset, Time(seconds: 0.25))
        XCTAssertEqual(screen.takeOffset, .zero)
        XCTAssertNil(lone.takeID)
        XCTAssertEqual(camera.role, .camera)
        XCTAssertEqual(screen.role, .screen)

        // The take ID is stable across scans.
        let again = try await MediaScanner.scan(folder, known: items)
        XCTAssertEqual(again.first { $0.path == "source/main-camera.mov" }?.takeID, camera.takeID)
    }

    func testCreationDatesWithinASecondAreRounding() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        try await SyntheticMedia.writeMovie(to: file("a-camera.mov"), .init(duration: 0.5, audio: nil, creationDate: start))
        try await SyntheticMedia.writeMovie(to: file("a-screen.mov"), .init(duration: 0.5, audio: nil, creationDate: start.addingTimeInterval(1)))
        let items = try await MediaScanner.scan(folder, known: [])
        XCTAssertEqual(items.compactMap(\.takeOffset), [.zero, .zero])
        XCTAssertNotNil(items.first?.takeID)
    }

    func testCreationDatesGiveOffsetsAndNonsenseIsClamped() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        try await SyntheticMedia.writeMovie(to: file("b-camera.mov"), .init(duration: 10, audio: nil, creationDate: start))
        try await SyntheticMedia.writeMovie(to: file("b-screen.mov"), .init(duration: 10, audio: nil, creationDate: start.addingTimeInterval(3.5)))
        try await SyntheticMedia.writeMovie(to: file("c-camera.mov"), .init(duration: 0.5, audio: nil, creationDate: start))
        try await SyntheticMedia.writeMovie(to: file("c-screen.mov"), .init(duration: 0.5, audio: nil, creationDate: start.addingTimeInterval(3600)))

        let report = try await MediaScanner.scanReport(folder, known: [])
        let offsets = Dictionary(uniqueKeysWithValues: report.items.map { ($0.path, $0.takeOffset?.seconds ?? -1) })
        XCTAssertEqual(offsets["b-camera.mov"] ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(offsets["b-screen.mov"] ?? -1, 3.5, accuracy: 0.0001)
        XCTAssertEqual(offsets["c-camera.mov"], 0)
        XCTAssertEqual(offsets["c-screen.mov"], 0)
        XCTAssertEqual(report.notes.count, 1)
        XCTAssertTrue(report.notes.first?.contains("c-screen.mov") ?? false, report.notes.description)
    }

    func testUnpairedTakeFileLosesItsTake() async throws {
        try await SyntheticMedia.writeMovie(to: file("d-camera.mov"), .init(duration: 0.5, audio: nil))
        try await SyntheticMedia.writeMovie(to: file("d-screen.mov"), .init(duration: 0.5, audio: nil))
        let items = try await MediaScanner.scan(folder, known: [])
        XCTAssertNotNil(items.first?.takeID)
        try FileManager.default.removeItem(at: file("d-screen.mov"))
        let after = try await MediaScanner.scan(folder, known: items)
        XCTAssertEqual(after.count, 1)
        XCTAssertNil(after.first?.takeID)
        XCTAssertNil(after.first?.takeOffset)
    }
}
