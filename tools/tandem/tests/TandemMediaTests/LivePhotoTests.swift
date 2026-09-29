import AVFoundation
import TandemCore
import XCTest
@testable import TandemMedia

/// A Live Photo exported from Photos arrives as a still and a short movie
/// with the same name (`IMG_0130.HEIC`, `IMG_0130.mov`). The still is the
/// media item; the movie is its motion clip, not media of its own.
final class LivePhotoTests: TempFolderTestCase {
    var folder: ProjectFolder { ProjectFolder(root: temp) }

    static let identifier = "2DBED4F3-97B8-4C72-94BA-0C01D9FDAE98"

    /// A movie like the one an iPhone records around a Live Photo.
    func writeMotionClip(_ path: String, seconds: Double = 2, identifier: String? = nil) async throws {
        var spec = SyntheticMedia.Video(width: 192, height: 144, duration: seconds)
        if let identifier { spec.metadata = [.quickTimeMetadataContentIdentifier: identifier] }
        try await SyntheticMedia.writeMovie(to: file(path), spec)
    }

    func testCandidatesShareAFolderAndAName() {
        let paths = [
            "photos/IMG_0130.HEIC", "photos/IMG_0130.mov", "photos/IMG_0131.jpg", "photos/img_0131.MOV",
            "other/IMG_0130.mov", "graphics/logo.png", "graphics/logo.mov", "photos/IMG_0140.MOV"
        ]
        let pairs = LivePhotos.candidates(paths).map { "\(paths[$0.still]) + \(paths[$0.movie])" }
        // A PNG is never a Live Photo, so an animated logo beside its still
        // one stays a video.
        XCTAssertEqual(pairs, ["photos/IMG_0130.HEIC + photos/IMG_0130.mov", "photos/IMG_0131.jpg + photos/img_0131.MOV"])
    }

    func testContentIdentifiersDecideWhenBothHaveOne() {
        let clip = LivePhotos.Movie(duration: 2, hasVideo: true, hasAlpha: false, contentIdentifier: "A1")
        XCTAssertTrue(LivePhotos.isMotionClip(clip, ofStillWith: "A1"))
        XCTAssertFalse(LivePhotos.isMotionClip(clip, ofStillWith: "B2"), "another photo's movie, whatever its name")
        var long = clip
        long.duration = 8
        XCTAssertTrue(LivePhotos.isMotionClip(long, ofStillWith: "A1"))

        // Without both, it has to look like one: short, a picture, no alpha.
        XCTAssertTrue(LivePhotos.isMotionClip(clip, ofStillWith: nil))
        long.contentIdentifier = nil
        XCTAssertFalse(LivePhotos.isMotionClip(long, ofStillWith: "A1"))
        var sticker = clip
        sticker.contentIdentifier = nil
        sticker.hasAlpha = true
        XCTAssertFalse(LivePhotos.isMotionClip(sticker, ofStillWith: nil))
        var sound = clip
        sound.contentIdentifier = nil
        sound.hasVideo = false
        XCTAssertFalse(LivePhotos.isMotionClip(sound, ofStillWith: nil))
    }

    func testAScanKeepsTheStillAndRecordsItsMotionClip() async throws {
        try SyntheticMedia.writeStill(to: file("photos/IMG_0130.HEIC"))
        try await writeMotionClip("photos/IMG_0130.mov")
        try SyntheticMedia.writeStill(to: file("photos/IMG_0131.jpg"))
        try await writeMotionClip("photos/IMG_0131.mov", seconds: 1)

        let report = try await MediaScanner.scanReport(folder, known: [])
        XCTAssertEqual(report.items.map(\.path).sorted(), ["photos/IMG_0130.HEIC", "photos/IMG_0131.jpg"])
        XCTAssertEqual(report.items.first { $0.path == "photos/IMG_0130.HEIC" }?.livePhotoVideo, "photos/IMG_0130.mov")
        XCTAssertEqual(report.items.first { $0.path == "photos/IMG_0131.jpg" }?.livePhotoVideo, "photos/IMG_0131.mov")
        XCTAssertEqual(report.items.map(\.role), [.image, .image])
        XCTAssertEqual(report.livePhotos, 2)
    }

    func testContentIdentifiersConfirmOrRefuseAPair() async throws {
        try SyntheticMedia.writeStill(to: file("photos/IMG_0130.HEIC"), contentIdentifier: Self.identifier)
        try await writeMotionClip("photos/IMG_0130.mov", identifier: Self.identifier)
        try SyntheticMedia.writeStill(to: file("photos/IMG_0131.HEIC"), contentIdentifier: "CB2FE88E-E41A-46BB-A769-2A92668B92F7")
        try await writeMotionClip("photos/IMG_0131.mov", identifier: "35BEF47D-D606-4C9B-9B71-021E0538AEBB")
        XCTAssertEqual(LivePhotos.contentIdentifier(ofStill: file("photos/IMG_0130.HEIC")), Self.identifier)
        let movieIdentifier = await LivePhotos.contentIdentifier(ofMovie: file("photos/IMG_0130.mov"))
        XCTAssertEqual(movieIdentifier, Self.identifier)

        let items = try await MediaScanner.scan(folder, known: [])
        XCTAssertEqual(items.map(\.path).sorted(), ["photos/IMG_0130.HEIC", "photos/IMG_0131.HEIC", "photos/IMG_0131.mov"])
        XCTAssertEqual(items.first { $0.path == "photos/IMG_0130.HEIC" }?.livePhotoVideo, "photos/IMG_0130.mov")
        XCTAssertNil(items.first { $0.path == "photos/IMG_0131.HEIC" }?.livePhotoVideo)
    }

    func testALongMovieWithAPhotosNameIsAVideoOfItsOwn() async throws {
        try SyntheticMedia.writeStill(to: file("photos/IMG_0140.jpg"))
        try await writeMotionClip("photos/IMG_0140.MOV", seconds: 8)
        let items = try await MediaScanner.scan(folder, known: [])
        XCTAssertEqual(items.map(\.path).sorted(), ["photos/IMG_0140.MOV", "photos/IMG_0140.jpg"])
        XCTAssertTrue(items.allSatisfy { $0.livePhotoVideo == nil })
    }

    func testRescansLeaveTheMotionClipWithItsStillUntilItsGone() async throws {
        try SyntheticMedia.writeStill(to: file("photos/IMG_0130.HEIC"))
        try await writeMotionClip("photos/IMG_0130.mov")
        let first = try await MediaScanner.scan(folder, known: [])
        let again = try await MediaScanner.scanReport(folder, known: first)
        XCTAssertEqual(again.items, first)
        XCTAssertEqual(again.livePhotos, 0, "it was paired already")

        try FileManager.default.removeItem(at: file("photos/IMG_0130.mov"))
        let gone = try await MediaScanner.scan(folder, known: first)
        XCTAssertEqual(gone.map(\.id), first.map(\.id))
        XCTAssertNil(gone.first?.livePhotoVideo)
    }

    func testAMotionClipThatLandsLaterJoinsItsStill() async throws {
        // Photos writes an export one file at a time, and the folder
        // watcher can scan in between.
        try SyntheticMedia.writeStill(to: file("photos/IMG_0130.HEIC"))
        let first = try await MediaScanner.scan(folder, known: [])
        try await writeMotionClip("photos/IMG_0130.mov")
        let second = try await MediaScanner.scan(folder, known: first)
        XCTAssertEqual(second.map(\.id), first.map(\.id))
        XCTAssertEqual(second.first?.livePhotoVideo, "photos/IMG_0130.mov")
    }

    func testAMovieAlreadyInTheProjectStaysMediaOfItsOwn() async throws {
        // Projects made before Live Photos were paired have the motion
        // clips as media, maybe on the timeline, so a rescan leaves them be.
        try SyntheticMedia.writeStill(to: file("photos/IMG_0130.HEIC"))
        try await writeMotionClip("photos/IMG_0130.mov")
        let still = try await MediaScanner.probe(file("photos/IMG_0130.HEIC"), folder: folder)
        let movie = try await MediaScanner.probe(file("photos/IMG_0130.mov"), folder: folder)
        let items = try await MediaScanner.scan(folder, known: [still, movie])
        XCTAssertEqual(Set(items.map(\.id)), [still.id, movie.id])
        XCTAssertTrue(items.allSatisfy { $0.livePhotoVideo == nil })
    }

    func testDroppedFilesFindTheirMotionClips() async throws {
        // Files from Finder, before they're in a project.
        try SyntheticMedia.writeStill(to: file("Export/IMG_0130.HEIC"))
        try await writeMotionClip("Export/IMG_0130.mov")
        try SyntheticMedia.writeStill(to: file("Export/IMG_0140.jpg"))
        try await writeMotionClip("Export/IMG_0140.MOV", seconds: 8)
        let urls = MediaScanner.mediaFiles(in: ProjectFolder(root: temp.appendingPathComponent("Export")))
        let clips = await LivePhotos.motionClips(among: urls)
        XCTAssertEqual(clips.map { "\($0.key.lastPathComponent) -> \($0.value.lastPathComponent)" }, ["IMG_0130.mov -> IMG_0130.HEIC"])
        // By name alone, before anything is read, both look like one.
        XCTAssertEqual(LivePhotos.likelyMotionClips(among: urls).map(\.lastPathComponent).sorted(), ["IMG_0130.mov", "IMG_0140.MOV"])
    }
}
