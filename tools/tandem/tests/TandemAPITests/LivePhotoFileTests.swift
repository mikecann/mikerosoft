import Foundation
import XCTest
@testable import TandemAPI
import TandemAssets
@testable import TandemCore
import TandemMedia

/// A Live Photo is one media item, the still, with its movie in
/// `livePhotoVideo`. Everything that moves a project's files moves the
/// movie too: archiving copies it in beside the still, relink finds it
/// beside the still, and a segment carries it.
final class LivePhotoFileTests: XCTestCase {
    /// A project in `<temp>/video` whose Live Photo lives outside it:
    ///
    ///     <temp>/outside/photos/IMG_0130.HEIC  the still, on the timeline
    ///     <temp>/outside/photos/IMG_0130.mov   its movie
    private func fixture() throws -> ArchiveFixture {
        let f = try ArchiveFixture(write: false)
        try f.make(f.outside("photos/IMG_0130.HEIC"), seed: 30)
        try f.make(f.outside("photos/IMG_0130.mov"), seed: 31)
        var still = try f.item("med_live", f.outside("photos/IMG_0130.HEIC"), kind: .image)
        still.livePhotoVideo = f.outside("photos/IMG_0130.mov").path
        var project = Project(id: "prj_live", name: "Video")
        project.media = [still]
        project.videoTracks = [
            Track(id: "trk_broll", kind: .video, name: "B-roll", clips: [
                Clip(id: "clip_live", content: .media(mediaID: "med_live"), start: t(0), duration: t(3))
            ], rippleMode: .follow)
        ]
        try ProjectFile.save(project, revision: 1, to: f.projectURL)
        return f
    }

    private static let still = "media/photos/IMG_0130.HEIC"
    private static let movie = "media/photos/IMG_0130.mov"

    func testConsolidatingCopiesTheMovieInWithItsStill() async throws {
        let f = try fixture()
        let result = try f.archive()
        XCTAssertEqual(Set(result.collected.map(\.path)), [Self.still, Self.movie])
        XCTAssertEqual(result.missing, [])
        XCTAssertEqual(result.collected.first { $0.path == Self.movie }?.usedBy, ["med_live motion clip"])

        let project = try f.load().project
        let item = try XCTUnwrap(project.media("med_live"))
        XCTAssertEqual(item.path, Self.still)
        XCTAssertEqual(item.livePhotoVideo, Self.movie)
        XCTAssertEqual(try Data(contentsOf: f.inVideo(Self.movie)), try Data(contentsOf: f.outside("photos/IMG_0130.mov")))

        // With the photos gone, nothing is missing, and a scan of the
        // folder knows the copy is the still's movie, not a video.
        try FileManager.default.moveItem(at: f.outside, to: f.root.appendingPathComponent("outside-gone"))
        let folder = ProjectFolder(projectFile: f.projectURL)
        XCTAssertEqual(MediaRelinker.missing(in: project, folder: folder).map(\.id), [])
        let scan = try await MediaScanner.scan(folder, known: project.media)
        XCTAssertEqual(scan.map(\.path), [Self.still])
        XCTAssertEqual(scan.first?.livePhotoVideo, Self.movie)
    }

    func testArchivingElsewhereCarriesTheMovieSoTheCopyStandsAlone() async throws {
        let f = try fixture()
        let shelf = f.root.appendingPathComponent("shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        let result = try f.archive(to: shelf)
        XCTAssertEqual(Set(result.collected.map(\.path)), [Self.still, Self.movie])
        XCTAssertEqual(try f.load().project.media("med_live")?.livePhotoVideo, f.outside("photos/IMG_0130.mov").path, "the original is left alone")

        // Take the original and the photos away, as on another Mac.
        try FileManager.default.moveItem(at: f.video, to: f.root.appendingPathComponent("video-gone"))
        try FileManager.default.moveItem(at: f.outside, to: f.root.appendingPathComponent("outside-gone"))
        let copy = result.projectFile.url
        let project = try ProjectFile.load(from: copy).project
        let item = try XCTUnwrap(project.media("med_live"))
        XCTAssertEqual(item.path, Self.still)
        XCTAssertEqual(item.livePhotoVideo, Self.movie)
        let folder = ProjectFolder(projectFile: copy)
        XCTAssertEqual(
            try Data(contentsOf: folder.url(forPath: Self.movie)),
            try Data(contentsOf: f.root.appendingPathComponent("outside-gone/photos/IMG_0130.mov"))
        )
        let scan = try await MediaScanner.scan(folder, known: project.media)
        XCTAssertEqual(scan.map(\.path), [Self.still], "the movie isn't media of its own")
        XCTAssertEqual(scan.first?.livePhotoVideo, Self.movie, "and isn't forgotten")
    }

    /// While the app consolidates, its folder watcher may add the copies as
    /// new media before the project points at them; they go again.
    func testCopiesAScanAddedMeanwhileAreRemovedAgain() throws {
        let f = try fixture()
        var project = try f.load().project
        project.media += [
            MediaItem(id: "med_still_copy", path: Self.still, kind: .image, role: .broll),
            MediaItem(id: "med_movie_copy", path: Self.movie, kind: .video, role: .broll)
        ]
        let map = [f.outside("photos/IMG_0130.HEIC").path: Self.still, f.outside("photos/IMG_0130.mov").path: Self.movie]
        let (commands, count) = ProjectArchiver.rewriteCommands(project, map: map, added: ["med_still_copy", "med_movie_copy"])
        XCTAssertEqual(count, 2)
        XCTAssertEqual(commands, [
            .updateMedia(mediaID: "med_live", patch: .object(["path": .string(Self.still), "livePhotoVideo": .string(Self.movie)])),
            .removeMedia(mediaID: "med_still_copy"),
            .removeMedia(mediaID: "med_movie_copy")
        ])
    }

    func testRelinkFindsTheMovieBesideTheStill() throws {
        let f = try ArchiveFixture(write: false)
        let picked = f.root.appendingPathComponent("picked", isDirectory: true)
        try f.make(picked.appendingPathComponent("IMG_0130.HEIC"), seed: 30)
        try f.make(picked.appendingPathComponent("IMG_0130.mov"), seed: 31)
        try f.make(picked.appendingPathComponent("IMG_0131.HEIC"), seed: 32)
        var moved = try f.item("med_live", picked.appendingPathComponent("IMG_0130.HEIC"), stored: "/Volumes/Gone/photos/IMG_0130.HEIC", kind: .image)
        moved.livePhotoVideo = "/Volumes/Gone/photos/IMG_0130.mov"
        var alone = try f.item("med_alone", picked.appendingPathComponent("IMG_0131.HEIC"), stored: "/Volumes/Gone/photos/IMG_0131.HEIC", kind: .image)
        alone.livePhotoVideo = "/Volumes/Gone/photos/IMG_0131.mov"

        let found = MediaRelinker.search(for: [moved, alone], in: [picked], folder: ProjectFolder(root: f.video)).found
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.mediaID, $0) })
        let movie = picked.appendingPathComponent("IMG_0130.mov").standardizedFileURL.path
        XCTAssertEqual(byID["med_live"]?.to, picked.appendingPathComponent("IMG_0130.HEIC").standardizedFileURL.path)
        XCTAssertEqual(byID["med_live"]?.livePhotoVideo, movie)
        XCTAssertNotNil(byID["med_alone"])
        XCTAssertNil(byID["med_alone"]?.livePhotoVideo, "no movie beside it")

        var project = Project(id: "prj_relink_live", name: "Moved")
        project.media = [moved, alone]
        var context = EditContext()
        for command in MediaRelinker.commands(for: found) {
            try Editing.apply(command, to: &project, context: &context)
        }
        XCTAssertEqual(project.media("med_live")?.livePhotoVideo, movie)
        XCTAssertEqual(project.media("med_alone")?.livePhotoVideo, "/Volumes/Gone/photos/IMG_0131.mov", "left for the next scan to forget")
    }

    func testASegmentCarriesTheMovie() throws {
        let f = try ArchiveFixture(write: false)
        try f.make(f.inVideo("photos/IMG_0130.HEIC"), seed: 30)
        try f.make(f.inVideo("photos/IMG_0130.mov"), seed: 31)
        var still = try f.item("med_live", f.inVideo("photos/IMG_0130.HEIC"), stored: "photos/IMG_0130.HEIC", kind: .image)
        still.livePhotoVideo = "photos/IMG_0130.mov"
        var project = Project.standard(name: "Video")
        project.media = [still]
        let broll = try XCTUnwrap(project.videoTracks.firstIndex { $0.name == "B-roll" })
        project.videoTracks[broll].clips = [Clip(id: "clip_live", content: .media(mediaID: "med_live"), start: t(5), duration: t(3))]

        let store = SegmentStore(library: SharedLibrary(root: f.root.appendingPathComponent("Tandem Library", isDirectory: true)))
        let draft = try SegmentMaker.draft(name: "Photo", clipIDs: ["clip_live"], in: project, folder: ProjectFolder(root: f.video))
        let saved = try store.save(draft)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: saved.folder.path)), ["segment.json", "IMG_0130.HEIC", "IMG_0130.mov"])
        XCTAssertEqual(saved.segment.media.first?.livePhotoVideo, "IMG_0130.mov")
        XCTAssertEqual(try Data(contentsOf: saved.folder.appendingPathComponent("IMG_0130.mov")), try Data(contentsOf: f.inVideo("photos/IMG_0130.mov")))

        // Into another video: the still and its movie, where they are.
        var other = Project.standard(name: "Other")
        var context = EditContext()
        for command in saved.insertBatch(at: t(0)).commands {
            try Editing.apply(command, to: &other, context: &context)
        }
        let item = try XCTUnwrap(other.media.first)
        XCTAssertEqual(item.path, saved.folder.appendingPathComponent("IMG_0130.HEIC").path)
        XCTAssertEqual(item.livePhotoVideo, saved.folder.appendingPathComponent("IMG_0130.mov").path)

        // A movie gone from the segment's folder isn't carried.
        try FileManager.default.removeItem(at: saved.folder.appendingPathComponent("IMG_0130.mov"))
        let reloaded = try store.load("Photo")
        XCTAssertEqual(reloaded.missingFiles, [], "the still is all a clip needs")
        XCTAssertNil(reloaded.insertableTemplate().clips.first?.media?.livePhotoVideo)
    }
}
