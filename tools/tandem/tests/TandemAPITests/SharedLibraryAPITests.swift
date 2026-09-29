import Foundation
import XCTest
@testable import TandemAPI
import TandemAssets
@testable import TandemCore
import TandemMedia

/// A shared library in a temp folder beside a video folder, and a project
/// that uses it every way a project can:
///
///     <temp>/Tandem Library/Stickers/Star.mov          a sticker, where it is
///     <temp>/Tandem Library/Sound effects/Whoosh.wav   a sound, where it is
///     <temp>/Tandem Library/Looks/Warm.cube            a look on a clip
///     <temp>/Tandem Library/Fonts/TiltWarp.ttf         the caption preset's font
///     <temp>/Tandem Library/Segments/Intro/sting.wav   a segment's media
///     <temp>/Assets/shared/Stickers_Spin.webm-1a2b/normalised.mov
///                                                      the converted copy of Stickers/Spin.webm
final class SharedFixture {
    let archive: ArchiveFixture
    let shared: SharedLibrary
    let assetsRoot: URL

    init() throws {
        archive = try ArchiveFixture(write: false)
        shared = SharedLibrary(root: archive.root.appendingPathComponent("Tandem Library", isDirectory: true))
        try shared.create()
        assetsRoot = archive.root.appendingPathComponent("Assets", isDirectory: true)
        try archive.make(library("Stickers/Star.mov"), seed: 11)
        try archive.make(library("Sound effects/Whoosh.wav"), seed: 12)
        try archive.make(library("Looks/Warm.cube"), bytes: 900, seed: 13)
        try archive.make(library("Fonts/TiltWarp.ttf"), bytes: 700, seed: 14)
        try archive.make(library("Segments/Intro/sting.wav"), seed: 15)
        try archive.make(library("Stickers/Spin.webm"), seed: 16)
        try archive.make(converted, seed: 17)
        try Data(#"{"asset": {"provider": "shared", "providerID": "Stickers/Spin.webm", "kind": "sticker", "name": "Spin"}}"#.utf8)
            .write(to: converted.deletingLastPathComponent().appendingPathComponent("meta.json"))
    }

    var video: URL { archive.video }
    var projectURL: URL { archive.projectURL }

    func library(_ path: String) -> URL { shared.root.appendingPathComponent(path) }

    var converted: URL { assetsRoot.appendingPathComponent("shared/Stickers_Spin.webm-1a2b/normalised.mov") }

    var fonts: StubFonts { StubFonts(files: ["Tilt Warp": [library("Fonts/TiltWarp.ttf")]]) }

    /// The project: every shared file by its absolute path.
    func project() throws -> Project {
        let lut = Effect(id: "fx_warm", type: "lut", params: ["path": .string(library("Looks/Warm.cube").path), "intensity": .number(1)])
        var project = Project(id: "prj_shared", name: "Video")
        project.media = [
            try archive.item("med_star", library("Stickers/Star.mov"), role: .sticker),
            try archive.item("med_whoosh", library("Sound effects/Whoosh.wav"), kind: .audio, role: .sfx),
            try archive.item("med_spin", converted, role: .sticker),
            try archive.item("med_sting", library("Segments/Intro/sting.wav"), kind: .audio, role: .sfx)
        ]
        project.videoTracks = [
            Track(id: "trk_graphics", kind: .video, name: "Graphics", clips: [
                Clip(id: "clip_star", content: .media(mediaID: "med_star"), start: t(0), duration: t(2), video: VideoProperties(effects: [lut])),
                Clip(id: "clip_spin", content: .media(mediaID: "med_spin"), start: t(3), duration: t(2))
            ], rippleMode: .follow),
            Track(id: "trk_text", kind: .video, name: "Text", clips: [
                Clip(id: "clip_cap", content: .text(TextContent(text: "hi there", preset: "caption")), start: t(1), duration: t(2))
            ], rippleMode: .follow)
        ]
        project.audioTracks = [
            Track(id: "trk_sfx", kind: .audio, name: "SFX", clips: [
                Clip(id: "clip_whoosh", content: .media(mediaID: "med_whoosh"), start: t(0), duration: t(1)),
                Clip(id: "clip_sting", content: .media(mediaID: "med_sting"), start: t(2), duration: t(1))
            ], rippleMode: .follow)
        ]
        return project
    }

    func write(_ project: Project? = nil) throws {
        try ProjectFile.save(try project ?? self.project(), revision: 1, to: projectURL)
    }

    @discardableResult
    func archive(to destination: URL? = nil, dryRun: Bool = false, shared: SharedLibrary? = nil) throws -> ArchiveResult {
        let session = try ProjectSession.open(projectURL, owner: .cli)
        session.autosaveDelay = 3600
        defer { session.close() }
        let options = ArchiveOptions(destination: destination, dryRun: dryRun, author: "claude", fonts: fonts, sharedLibrary: shared ?? self.shared, assetsRoot: assetsRoot)
        return try ProjectArchiver(session: session, options: options).run()
    }
}

final class SharedLibraryArchiveTests: XCTestCase {
    static let expected: [String: String] = [
        "med_star": "media/Tandem Library/Stickers/Star.mov",
        "med_whoosh": "media/Tandem Library/Sound effects/Whoosh.wav",
        "med_spin": "media/Tandem Library/Stickers/Spin.mov",
        "med_sting": "media/Tandem Library/Segments/Intro/sting.wav"
    ]

    func testConsolidatingCopiesEverySharedFileAndPointsTheProjectAtIt() throws {
        let f = try SharedFixture()
        try f.write()
        let result = try f.archive()

        let collected = Dictionary(uniqueKeysWithValues: result.collected.map { ($0.path, $0) })
        XCTAssertEqual(Set(collected.keys), Set(Self.expected.values).union(["assets/lut/Warm.cube", "assets/font/TiltWarp.ttf"]))
        XCTAssertEqual(collected["media/Tandem Library/Stickers/Spin.mov"]?.original, ProjectArchiver.realPath(f.converted))
        for file in result.collected {
            XCTAssertEqual(try Data(contentsOf: f.video.appendingPathComponent(file.path)), try Data(contentsOf: URL(fileURLWithPath: file.original)), file.path)
        }
        XCTAssertEqual(result.missing, [])

        let project = try f.archive.load().project
        for (id, path) in Self.expected {
            XCTAssertEqual(project.media(id)?.path, path, id)
        }
        XCTAssertEqual(project.clip("clip_star")?.video?.effects.first?.params["path"], .string("assets/lut/Warm.cube"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.video.appendingPathComponent("assets/font/TiltWarp.ttf").path))

        // With the library gone, nothing is missing.
        try FileManager.default.moveItem(at: f.shared.root, to: f.archive.root.appendingPathComponent("gone", isDirectory: true))
        XCTAssertEqual(MediaRelinker.missing(in: project, folder: ProjectFolder(projectFile: f.projectURL)).map(\.id), [])
    }

    func testArchivingElsewhereCarriesTheSharedFilesAndOpensWithTheLibraryGone() throws {
        let f = try SharedFixture()
        try f.write()
        let shelf = f.archive.root.appendingPathComponent("shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        let planned = try f.archive(to: shelf, dryRun: true)
        XCTAssertTrue(planned.readableText.contains("media/Tandem Library/Stickers/Star.mov"), planned.readableText)

        let result = try f.archive(to: shelf)
        XCTAssertEqual(result.mode, .archive)
        let starOriginal = ProjectArchiver.realPath(f.library("Stickers/Star.mov"))
        let original = try f.archive.load().project
        XCTAssertEqual(original.media("med_star")?.path, f.library("Stickers/Star.mov").path, "the original still uses the library")

        // Bruce has no Tandem Library.
        try FileManager.default.moveItem(at: f.shared.root, to: f.archive.root.appendingPathComponent("gone", isDirectory: true))
        try FileManager.default.moveItem(at: f.assetsRoot, to: f.archive.root.appendingPathComponent("gone assets", isDirectory: true))
        let copy = URL(fileURLWithPath: result.projectFile)
        let archived = try ProjectFile.load(from: copy).project
        for (id, path) in Self.expected {
            XCTAssertEqual(archived.media(id)?.path, path, id)
        }
        XCTAssertEqual(archived.clip("clip_star")?.video?.effects.first?.params["path"], .string("assets/lut/Warm.cube"))
        XCTAssertEqual(MediaRelinker.missing(in: archived, folder: ProjectFolder(projectFile: copy)).map(\.id), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().appendingPathComponent("assets/lut/Warm.cube").path))
        let manifest = try XCTUnwrap(ArchiveManifest.load(from: copy.deletingLastPathComponent()))
        XCTAssertEqual(manifest.entry(for: "media/Tandem Library/Stickers/Star.mov")?.original, starOriginal)
    }

    /// Links are followed both ways: a library that's itself a link, a
    /// link in the project folder into the library, and a file in the
    /// library that links to one elsewhere.
    func testLinksIntoAndOutOfTheLibraryAreFollowed() throws {
        let f = try SharedFixture()
        let linkedLibrary = f.archive.root.appendingPathComponent("Linked Library")
        try FileManager.default.createSymbolicLink(at: linkedLibrary, withDestinationURL: f.shared.root)
        try FileManager.default.createSymbolicLink(at: f.video.appendingPathComponent("library"), withDestinationURL: f.shared.root)
        try f.archive.make(f.archive.outside("music/bed.m4a"), seed: 3)
        try FileManager.default.createDirectory(at: f.library("Music"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.library("Music/Bed.m4a"), withDestinationURL: f.archive.outside("music/bed.m4a"))
        var project = try f.project()
        // Through the linked library, through the project's own link, and
        // a library file that's a link to a file outside it.
        project.media[0].path = linkedLibrary.appendingPathComponent("Stickers/Star.mov").path
        project.media[1].path = "library/Sound effects/Whoosh.wav"
        project.media.append(try f.archive.item("med_bed", f.library("Music/Bed.m4a"), kind: .audio, role: .music))
        project.audioTracks[0].clips.append(Clip(id: "clip_bed", content: .media(mediaID: "med_bed"), start: t(4), duration: t(1)))
        try f.write(project)

        let result = try f.archive()
        let collected = Dictionary(uniqueKeysWithValues: result.collected.map { ($0.path, $0) })
        XCTAssertEqual(collected["media/Tandem Library/Stickers/Star.mov"]?.original, ProjectArchiver.realPath(f.library("Stickers/Star.mov")))
        XCTAssertEqual(collected["media/Tandem Library/Sound effects/Whoosh.wav"]?.original, ProjectArchiver.realPath(f.library("Sound effects/Whoosh.wav")))
        XCTAssertEqual(collected["media/Tandem Library/Music/Bed.m4a"]?.original, ProjectArchiver.realPath(f.archive.outside("music/bed.m4a")), "the file the link points to")
        let saved = try f.archive.load().project
        XCTAssertEqual(saved.media("med_star")?.path, "media/Tandem Library/Stickers/Star.mov")
        XCTAssertEqual(saved.media("med_whoosh")?.path, "media/Tandem Library/Sound effects/Whoosh.wav", "a link in the folder to the library counts as outside")
        XCTAssertEqual(saved.media("med_bed")?.path, "media/Tandem Library/Music/Bed.m4a")
        XCTAssertTrue(FileCopier.isPlainFile(f.video.appendingPathComponent("media/Tandem Library/Music/Bed.m4a")), "a real copy, not a link")

        // Named by the library the options know, however it's reached.
        let viaLink = try f.archive(dryRun: true, shared: SharedLibrary(root: linkedLibrary))
        XCTAssertFalse(viaLink.collected.contains { $0.kind == .media }, "every file's in the folder now")
    }

    func testTheServiceNamesSharedFilesByTheLibraryItFinds() async throws {
        let f = try SharedFixture()
        var project = try f.project()
        // A font every Mac has, so nothing on this Mac is looked for.
        project.videoTracks[1].clips[0].content = .text(TextContent(text: "hi", style: TextStyle(font: "Helvetica")))
        try f.write(project)
        let session = try ProjectSession.open(f.projectURL, owner: .cli)
        session.autosaveDelay = 3600
        let service = TandemService(session: session, mode: .headless, analysis: FakeAnalysis(), renderer: FakeRenderer())
        let shared = f.shared
        service.locateSharedLibrary = { shared }
        defer {
            service.shutdown()
            session.close()
        }
        let planned = try await service.archive(ArchiveRequest(dryRun: true), context: CallContext(author: "claude"))
        XCTAssertTrue(planned.collected.contains { $0.path == "media/Tandem Library/Sound effects/Whoosh.wav" }, planned.readableText)
    }
}

final class SharedLibraryRelinkTests: XCTestCase {
    func testMissingMediaIsFoundInTheSharedLibraryAfterTheFoldersGiven() async throws {
        let f = try SharedFixture()
        var project = Project(id: "prj_moved", name: "From Bruce")
        // Paths from another Mac, where the library was somewhere else.
        project.media = [
            try f.archive.item("med_star", f.library("Stickers/Star.mov"), stored: "/Users/mike/Movies/Tandem Library/Stickers/Star.mov", role: .sticker),
            try f.archive.item("med_whoosh", f.library("Sound effects/Whoosh.wav"), stored: "/Users/mike/Movies/Tandem Library/Sound effects/Whoosh.wav", kind: .audio, role: .sfx),
            try f.archive.item("med_other", f.archive.outside("x.wav"), stored: "/Users/mike/elsewhere/other.wav", kind: .audio, role: .sfx)
        ]
        try f.write(project)
        // A folder Mike picks has its own copy of the whoosh: that wins.
        let picked = f.archive.root.appendingPathComponent("picked", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.library("Sound effects/Whoosh.wav"), to: picked.appendingPathComponent("Whoosh.wav"))

        let session = try ProjectSession.open(f.projectURL, owner: .cli)
        session.autosaveDelay = 3600
        let service = TandemService(session: session, mode: .hosted, analysis: FakeAnalysis(), renderer: FakeRenderer())
        let shared = f.shared
        service.locateSharedLibrary = { shared }
        defer {
            service.shutdown()
            session.close()
        }
        let context = CallContext(author: "claude")
        let result = try await service.relink(RelinkRequest(search: [picked.path]), context: context)
        let found = Dictionary(uniqueKeysWithValues: result.relinked.map { ($0.mediaID, $0.to) })
        XCTAssertEqual(found["med_star"], f.library("Stickers/Star.mov").standardizedFileURL.path, "found in the shared library")
        XCTAssertEqual(found["med_whoosh"], picked.appendingPathComponent("Whoosh.wav").standardizedFileURL.path, "the folder given comes first")
        XCTAssertEqual(result.missing.map(\.mediaID), ["med_other"])
        XCTAssertEqual(result.searched.last, f.shared.root.path)
        XCTAssertEqual(service.coordinator.project.media("med_star")?.path, f.library("Stickers/Star.mov").standardizedFileURL.path)

        // No library, no looking.
        service.locateSharedLibrary = { nil }
        let again = try await service.relink(RelinkRequest(dryRun: true), context: context)
        XCTAssertFalse(again.searched.contains(f.shared.root.path))
    }

    /// Nobody picked the shared library, so a name alone isn't enough there.
    func testTheLibraryOnlyGivesFilesWhoseContentMatches() {
        let f = try! SharedFixture()
        var item = try! f.archive.item("med_loose", f.library("Stickers/Star.mov"), stored: "/Gone/Star.mov", role: .sticker)
        item.fingerprint = nil
        let (found, ambiguous) = MediaRelinker.search(for: [item], in: [f.video], then: [f.shared.root], folder: ProjectFolder(root: f.video))
        XCTAssertEqual(found, [])
        XCTAssertEqual(ambiguous, [])
        item = try! f.archive.item("med_known", f.library("Stickers/Star.mov"), stored: "/Gone/Star.mov", role: .sticker)
        XCTAssertEqual(MediaRelinker.search(for: [item], in: [f.video], then: [f.shared.root], folder: ProjectFolder(root: f.video)).found.map(\.mediaID), ["med_known"])
    }

    func testAnUndecidedFileIsntSettledByTheLibrary() {
        let f = try! SharedFixture()
        var item = try! f.archive.item("med_twice", f.library("Sound effects/Whoosh.wav"), stored: "/Gone/Whoosh.wav", kind: .audio, role: .sfx)
        item.fingerprint = nil
        let picked = f.archive.root.appendingPathComponent("picked", isDirectory: true)
        try! f.archive.make(picked.appendingPathComponent("a/Whoosh.wav"), seed: 40)
        try! f.archive.make(picked.appendingPathComponent("b/Whoosh.wav"), seed: 41)
        let (found, ambiguous) = MediaRelinker.search(for: [item], in: [picked], then: [f.shared.root], folder: ProjectFolder(root: f.video))
        XCTAssertEqual(found, [])
        XCTAssertEqual(ambiguous, ["/Gone/Whoosh.wav"])
    }
}

final class SegmentTests: XCTestCase {
    /// A video folder with an intro on the timeline: a card from the
    /// project's graphics folder with a look, a title, a whoosh, and a
    /// sticker used from the shared library.
    final class Intro {
        let f: SharedFixture
        let client: ProjectClient
        var store: SegmentStore

        init() throws {
            f = try SharedFixture()
            try f.archive.make(f.video.appendingPathComponent("graphics/card.mov"), seed: 21)
            try f.archive.make(f.video.appendingPathComponent("sfx/whoosh.wav"), seed: 22)
            try f.archive.make(f.video.appendingPathComponent("assets/lut/warm.cube"), bytes: 900, seed: 23)
            let look = Effect(id: "fx_look", type: "lut", params: ["path": .string("assets/lut/warm.cube"), "intensity": .number(0.7)])
            var project = Project.standard(name: "Video")
            project.id = "prj_intro"
            project.media = [
                try f.archive.item("med_card", f.video.appendingPathComponent("graphics/card.mov"), stored: "graphics/card.mov", role: .graphic),
                try f.archive.item("med_whoosh", f.video.appendingPathComponent("sfx/whoosh.wav"), stored: "sfx/whoosh.wav", kind: .audio, role: .sfx),
                try f.archive.item("med_star", f.library("Stickers/Star.mov"), role: .sticker)
            ]
            func track(_ name: String) -> (TrackKind, Int) {
                if let index = project.videoTracks.firstIndex(where: { $0.name == name }) { return (.video, index) }
                return (.audio, project.audioTracks.firstIndex { $0.name == name }!)
            }
            func add(_ clip: Clip, to name: String) {
                let (kind, index) = track(name)
                if kind == .video { project.videoTracks[index].clips.append(clip) } else { project.audioTracks[index].clips.append(clip) }
            }
            add(Clip(id: "clip_card", content: .media(mediaID: "med_card"), start: t(10), duration: t(3), sourceStart: t(1), linkGroup: "lnk_intro", video: VideoProperties(effects: [look])), to: "Graphics")
            add(Clip(id: "clip_title", name: "Title", content: .text(TextContent(text: "Welcome back", preset: "callout")), start: t(10.5), duration: t(2)), to: "Text")
            add(Clip(id: "clip_whoosh", content: .media(mediaID: "med_whoosh"), start: t(10), duration: t(1), audio: AudioProperties(gainDB: -15)), to: "SFX")
            add(Clip(id: "clip_star", content: .media(mediaID: "med_star"), start: t(11), duration: t(2)), to: "B-roll")
            try ProjectFile.save(project, revision: 1, to: f.projectURL)
            client = ProjectClient(projectURL: f.projectURL, author: "claude")
            store = SegmentStore(library: f.shared)
            store.discard = { try FileManager.default.removeItem(at: $0) }
        }

        var ids: [String] { ["clip_card", "clip_title", "clip_whoosh", "clip_star"] }

        func draft(fields: [SegmentMaker.Field] = [SegmentMaker.Field(clipID: "clip_title", label: "Title")]) throws -> SegmentMaker.Draft {
            let project = try ProjectFile.load(from: f.projectURL).project
            return try SegmentMaker.draft(name: "Intro", clipIDs: ids, in: project, folder: ProjectFolder(projectFile: f.projectURL), fields: fields, assetsRoot: f.assetsRoot)
        }

        /// A second video that uses the segment.
        func otherProject() throws -> URL {
            let folder = f.archive.root.appendingPathComponent("other video", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("Other.tandem")
            try ProjectFile.save(Project.standard(name: "Other"), revision: 1, to: url)
            return url
        }
    }

    func testSavingCopiesTheMediaBesideItAndInsertingUsesItFromTheLibrary() async throws {
        let intro = try Intro()
        // The fixture's "Intro" segment folder only has media; make room.
        try FileManager.default.removeItem(at: intro.f.library("Segments/Intro"))
        let saved = try intro.store.save(try intro.draft())

        let folder = intro.f.library("Segments/Intro")
        XCTAssertEqual(saved.folder, folder.standardizedFileURL)
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertEqual(files, ["segment.json", "card.mov", "whoosh.wav", "Star.mov", "warm.cube"])
        for (copy, source) in [("card.mov", intro.f.video.appendingPathComponent("graphics/card.mov")), ("Star.mov", intro.f.library("Stickers/Star.mov"))] {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(copy)), try Data(contentsOf: source), copy)
            XCTAssertEqual(FileCopier.milliseconds(FileCopier.fileInfo(folder.appendingPathComponent(copy))!.modified), FileCopier.milliseconds(FileCopier.fileInfo(source)!.modified), "dates kept, so fingerprints match")
        }
        let segment = saved.segment
        XCTAssertEqual(segment.template.duration, t(3))
        XCTAssertEqual(segment.template.clips.map(\.track), ["Text", "Graphics", "B-roll", "SFX"], "top to bottom as the app shows them")
        XCTAssertEqual(segment.template.clips.map(\.offset), [t(0.5), t(0), t(1), t(0)])
        XCTAssertEqual(Set(segment.media.map(\.path)), ["card.mov", "whoosh.wav", "Star.mov"])
        XCTAssertEqual(segment.template.clips.first { $0.track == "Graphics" }?.clip.video?.effects.first?.params["path"], .string("warm.cube"))
        XCTAssertEqual(segment.template.fields, [TemplateField(key: "title", label: "Title", defaultValue: "Welcome back")])
        guard case .text(let title)? = segment.template.clips.first(where: { $0.track == "Text" })?.clip.content else { return XCTFail("no title") }
        XCTAssertEqual(title.text, "{{title}}")
        XCTAssertEqual(segment.savedFrom, "Video")
        XCTAssertEqual(intro.store.list().segments.map(\.name), ["Intro"])

        // Into another video: the files are used where they are in the library.
        let other = try intro.otherProject()
        let session = try ProjectSession.open(other, owner: .cli)
        session.autosaveDelay = 3600
        let loaded = try intro.store.load("intro")
        let result = try session.coordinator.apply(loaded.insertBatch(at: t(20), values: ["title": "Hello again"]))
        let project = session.coordinator.project
        XCTAssertEqual(result.createdIDs.filter { $0.hasPrefix("clip_") }.count, 4)
        XCTAssertEqual(saved.segment.media.map(\.id), ["", "", ""], "no source IDs carried")
        let card = try XCTUnwrap(project.media.first { $0.path.hasSuffix("/Segments/Intro/card.mov") }, "\(project.media.map(\.path))")
        XCTAssertNotEqual(card.id, "med_card")
        XCTAssertTrue(card.id.hasPrefix("med_"))
        XCTAssertEqual(card.path, folder.appendingPathComponent("card.mov").standardizedFileURL.path)
        XCTAssertEqual(card.fingerprint, try ProjectFile.load(from: intro.f.projectURL).project.media("med_card")?.fingerprint)
        let placedCard = try XCTUnwrap(project.track(named: "Graphics")?.clips.first)
        XCTAssertEqual(placedCard.start, t(20))
        XCTAssertEqual(placedCard.sourceStart, t(1))
        XCTAssertEqual(placedCard.video?.effects.first?.params["path"], .string(folder.appendingPathComponent("warm.cube").standardizedFileURL.path))
        guard case .text(let filled)? = project.track(named: "Text")?.clips.first?.content else { return XCTFail("no title") }
        XCTAssertEqual(filled.text, "Hello again")
        XCTAssertEqual(project.track(named: "SFX")?.clips.first?.start, t(20))
        XCTAssertEqual(project.track(named: "B-roll")?.clips.first?.start, t(21))
        XCTAssertEqual(project.track(named: "SFX")?.clips.first?.audio?.gainDB, -15)
        XCTAssertEqual(Set(project.allTracks.flatMap(\.clips).compactMap(\.linkGroup)).count, 1, "one linked group")

        // Again: the same files, not new media.
        try session.coordinator.apply(loaded.insertBatch(at: t(40)))
        XCTAssertEqual(session.coordinator.project.media.count, 3)
        guard case .text(let defaulted)? = session.coordinator.project.track(named: "Text")?.clips.last?.content else { return XCTFail("no title") }
        XCTAssertEqual(defaulted.text, "Welcome back", "the words it was saved with")
        try session.save()
        session.close()

        // Archiving the video copies the segment's files in.
        let archiveSession = try ProjectSession.open(other, owner: .cli)
        archiveSession.autosaveDelay = 3600
        let archived = try ProjectArchiver(session: archiveSession, options: ArchiveOptions(author: "claude", fonts: StubFonts(), sharedLibrary: intro.f.shared, assetsRoot: intro.f.assetsRoot)).run()
        archiveSession.close()
        XCTAssertEqual(Set(archived.collected.map(\.path)), [
            "media/Tandem Library/Segments/Intro/card.mov", "media/Tandem Library/Segments/Intro/whoosh.wav",
            "media/Tandem Library/Segments/Intro/Star.mov", "assets/lut/warm.cube"
        ])
        let standalone = try ProjectFile.load(from: other).project
        XCTAssertTrue(standalone.media.allSatisfy { $0.path.hasPrefix("media/Tandem Library/Segments/Intro/") }, "\(standalone.media.map(\.path))")
        XCTAssertEqual(standalone.track(named: "Graphics")?.clips.first?.video?.effects.first?.params["path"], .string("assets/lut/warm.cube"))
    }

    /// Projects that inserted a segment play its files where they are, so
    /// replacing it keeps the files the new version drops, and a replace cut
    /// short puts the old one back.
    func testReplacingKeepsTheOldFilesAndRecoversFromACrash() throws {
        let intro = try Intro()
        try FileManager.default.removeItem(at: intro.f.library("Segments/Intro"))
        let discarded = DiscardLog()
        intro.store.discard = { url in
            discarded.add(url)
            try FileManager.default.removeItem(at: url)
        }
        try intro.store.save(try intro.draft())
        let folder = intro.f.library("Segments/Intro")
        let project = try ProjectFile.load(from: intro.f.projectURL).project
        let cardOnly = try SegmentMaker.draft(name: "Intro", clipIDs: ["clip_card"], in: project, folder: ProjectFolder(projectFile: intro.f.projectURL), assetsRoot: intro.f.assetsRoot)
        let replaced = try intro.store.save(cardOnly, replace: true)
        XCTAssertEqual(replaced.segment.media.map(\.path), ["card.mov"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["segment.json", "card.mov", "whoosh.wav", "Star.mov", "warm.cube"], "the old files stay for the projects that play them")
        XCTAssertEqual(discarded.urls.count, 1)
        XCTAssertTrue(discarded.urls.first?.lastPathComponent.hasPrefix(".Intro.tandem-replaced-") == true)

        // A replace that stopped after moving the old one aside.
        let aside = intro.store.folder.appendingPathComponent(".Intro.tandem-replaced-crashed", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: aside)
        XCTAssertThrowsError(try intro.store.save(cardOnly)) { error in
            XCTAssertTrue((error as? ServiceError)?.message.contains("already a segment") == true, "\(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("segment.json").path), "put back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
    }

    func testANameCantReachOutsideTheSegmentsFolder() throws {
        XCTAssertEqual(SegmentStore.folderName(for: ". .."), "")
        XCTAssertEqual(SegmentStore.folderName(for: ". ."), "")
        XCTAssertEqual(SegmentStore.folderName(for: ".."), "")
        XCTAssertEqual(SegmentStore.folderName(for: " . . Intro "), "Intro")
        XCTAssertEqual(SegmentStore.folderName(for: "a/../b"), "a-..-b")
        let intro = try Intro()
        let project = try ProjectFile.load(from: intro.f.projectURL).project
        XCTAssertThrowsError(try SegmentMaker.draft(name: ". ..", clipIDs: ["clip_card"], in: project, folder: ProjectFolder(projectFile: intro.f.projectURL)))
        var draft = try intro.draft()
        draft.segment.name = ". .."
        XCTAssertThrowsError(try intro.store.save(draft, replace: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: intro.f.library("README.txt").path), "the library is untouched")
    }

    func testTwoSegmentsWithOneNameAreNamedByFolder() throws {
        let intro = try Intro()
        try FileManager.default.removeItem(at: intro.f.library("Segments/Intro"))
        try intro.store.save(try intro.draft())
        var other = try intro.draft()
        other.segment.name = "Intro 2"
        try intro.store.save(other)
        // Renamed in Finder so both say "Intro".
        let second = intro.f.library("Segments/Intro 2/segment.json")
        var segment = try ServiceJSON.decoder().decode(Segment.self, from: Data(contentsOf: second))
        segment.name = "Intro"
        try ServiceJSON.encoder(pretty: true).encode(segment).write(to: second)
        XCTAssertEqual(try intro.store.load("Intro").id, "Intro", "the folder's name first")
        XCTAssertEqual(try intro.store.load("Intro 2").id, "Intro 2")
        XCTAssertEqual(try intro.store.load("intro 2").id, "Intro 2")
        try FileManager.default.moveItem(at: intro.f.library("Segments/Intro"), to: intro.f.library("Segments/First"))
        XCTAssertEqual(try intro.store.load("first").id, "First")
        XCTAssertThrowsError(try intro.store.load("Intro")) { error in
            XCTAssertTrue((error as? ServiceError)?.message.contains("Several segments are called") == true, "\(error)")
        }
    }

    func testSavingAgainNeedsReplaceAndPlaceholdersBecomeFields() throws {
        let intro = try Intro()
        try FileManager.default.removeItem(at: intro.f.library("Segments/Intro"))
        try intro.store.save(try intro.draft())
        XCTAssertThrowsError(try intro.store.save(try intro.draft())) { error in
            XCTAssertTrue((error as? ServiceError)?.message.contains("already a segment called \"Intro\"") == true, "\(error)")
        }
        var project = try ProjectFile.load(from: intro.f.projectURL).project
        let location = try XCTUnwrap(project.location(ofClip: "clip_title"))
        project[location.track].clips[location.index].content = .text(TextContent(text: "TIP {{number}}: {{title}}", preset: "callout"))
        let draft = try SegmentMaker.draft(name: "Intro", clipIDs: intro.ids, in: project, folder: ProjectFolder(projectFile: intro.f.projectURL), assetsRoot: intro.f.assetsRoot)
        XCTAssertEqual(draft.segment.template.fields.map(\.key), ["number", "title"])
        let replaced = try intro.store.save(draft, replace: true)
        XCTAssertEqual(replaced.segment.template.fields.map(\.key), ["number", "title"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: intro.store.folder.path).contains { $0.hasPrefix(".") }, "no leftovers")
    }

    func testTwoTracksWithOneNameStayApartAndTransitionsComeAlong() throws {
        var project = Project.standard(name: "Two texts")
        project.videoTracks.append(Track(id: "trk_text2", kind: .video, name: "Text", clips: [], rippleMode: .follow))
        let first = try XCTUnwrap(project.track(named: "Text"))
        let firstLocation = try XCTUnwrap(project.location(ofTrack: first.id))
        project[firstLocation].clips = [
            Clip(id: "clip_a", content: .text(TextContent(text: "A")), start: t(0), duration: t(1)),
            Clip(id: "clip_b", content: .text(TextContent(text: "B")), start: t(1), duration: t(1))
        ]
        project[firstLocation].clips.append(Clip(id: "clip_d", content: .text(TextContent(text: "D")), start: t(2), duration: t(1)))
        project[firstLocation].transitions = [
            Transition(id: "tr_in", type: .fadeFromBlack, duration: t(0.4), fromClipID: nil, toClipID: "clip_a"),
            Transition(id: "tr_ab", type: .dissolve, duration: t(0.5), fromClipID: "clip_a", toClipID: "clip_b"),
            Transition(id: "tr_bd", type: .dissolve, duration: t(0.5), fromClipID: "clip_b", toClipID: "clip_d")
        ]
        project.videoTracks[project.videoTracks.count - 1].clips = [Clip(id: "clip_c", content: .text(TextContent(text: "C")), start: t(0), duration: t(2))]
        let folder = TempFolder("segment-tracks")
        let draft = try SegmentMaker.draft(name: "Texts", clipIDs: ["clip_a", "clip_b", "clip_c"], in: project, folder: ProjectFolder(root: folder.url))
        let clips = draft.segment.template.clips
        XCTAssertEqual(Set(clips.map(\.track)), ["Text", "Text 2"])
        let a = try XCTUnwrap(clips.firstIndex { if case .text(let text) = $0.clip.content { return text.text == "A" } else { return false } })
        let b = try XCTUnwrap(clips.firstIndex { if case .text(let text) = $0.clip.content { return text.text == "B" } else { return false } })
        XCTAssertEqual(Set(draft.segment.template.transitions.map { "\($0.type.rawValue) \($0.from.map(String.init) ?? "-") \($0.to.map(String.init) ?? "-")" }),
                       ["fadeFromBlack - \(a)", "dissolve \(a) \(b)"])
        XCTAssertEqual(draft.segment.notes, ["A transition to a clip that isn't in the segment is left out."], "clip_d wasn't saved")
        XCTAssertTrue(draft.files.isEmpty)

        // They go in with it.
        let coordinator = ProjectCoordinator(project: Project.standard(name: "Other"))
        let stored = StoredSegment(id: "Texts", folder: folder.url, segment: draft.segment)
        try coordinator.apply(stored.insertBatch(at: t(10)))
        let text = try XCTUnwrap(coordinator.project.track(named: "Text"))
        XCTAssertEqual(Set(text.transitions.map(\.type)), [.fadeFromBlack, .dissolve])
        XCTAssertThrowsError(try SegmentMaker.draft(name: " ", clipIDs: ["clip_a"], in: project, folder: ProjectFolder(root: folder.url)))
        XCTAssertThrowsError(try SegmentMaker.draft(name: "x", clipIDs: ["clip_nope"], in: project, folder: ProjectFolder(root: folder.url)))
        XCTAssertEqual(SegmentStore.folderName(for: " Like/Subscribe: v2 "), "Like-Subscribe- v2")
        XCTAssertEqual(SegmentStore.folderName(for: "..hidden"), "hidden")
    }

    func testTheServiceSavesListsAndInsertsThroughTheProject() async throws {
        let intro = try Intro()
        try FileManager.default.removeItem(at: intro.f.library("Segments/Intro"))
        let library = try AssetLibrary(root: intro.f.assetsRoot, transport: OfflineTransport(), secrets: StaticSecretStore(), sharedLibrary: intro.f.shared.root)
        let assets = AssetService(library: library)
        // The sticker came from the shared library, as far as the credits know.
        try await library.rescanSharedLibrary()
        try library.catalog.recordUsage(AssetUsage(assetID: "shared:Stickers/Star.mov", projectID: "prj_intro", mediaID: "med_star", mediaPath: intro.f.library("Stickers/Star.mov").path))

        let saved = try await assets.saveSegment(SegmentSaveRequest(name: "Intro", from: t(10), to: t(13), fields: [SegmentMaker.Field.parse("clip_title=Title")]), project: intro.client)
        XCTAssertEqual(Set(saved.clipIDs), Set(intro.ids))
        XCTAssertEqual(Set(saved.copied), ["card.mov", "whoosh.wav", "Star.mov", "warm.cube"])
        XCTAssertTrue(saved.readableText.hasPrefix("Saved the segment \"Intro\" (3 s, 4 clips on "), saved.readableText)

        let list = assets.segments()
        XCTAssertEqual(list.segments.map(\.name), ["Intro"])
        XCTAssertEqual(list.segments.first?.fields.map(\.key), ["title"])
        XCTAssertTrue(list.readableText.contains("Intro  3 s, 4 clips"), list.readableText)

        let other = try intro.otherProject()
        let client = ProjectClient(projectURL: other, author: "claude")
        let inserted = try await assets.insertSegment(SegmentInsertRequest(name: "Intro", at: t(5), values: ["title": "Hi"]), project: client)
        XCTAssertEqual(inserted.applied.author, "claude")
        XCTAssertEqual(inserted.applied.label, "Add segment Intro")
        XCTAssertTrue(inserted.readableText.hasPrefix("Put the segment \"Intro\" at 00:05.000 as revision 2"), inserted.readableText)
        let otherProject = try ProjectFile.load(from: other).project
        XCTAssertEqual(otherProject.track(named: "Graphics")?.clips.first?.start, t(5))
        // Its sticker still shows up in the credits of the video it went into.
        XCTAssertEqual(otherProject.track(named: "B-roll")?.clips.first?.tags.filter { $0.hasPrefix("asset:") }, ["asset:shared:Stickers/Star.mov"])
        XCTAssertEqual(try library.credits(for: otherProject).assets.map(\.id), ["shared:Stickers/Star.mov"])

        do {
            _ = try await assets.insertSegment(SegmentInsertRequest(name: "Intro", at: t(5)), project: client)
            XCTFail("the tracks are taken there")
        } catch {
            XCTAssertEqual((error as? ServiceError)?.code, "overlap", "\(error)")
        }
        let over = try await assets.insertSegment(SegmentInsertRequest(name: "Intro", at: t(5), mode: .overwrite), project: client)
        XCTAssertEqual(over.applied.revision, 3)
        do {
            _ = try await assets.insertSegment(SegmentInsertRequest(name: "Intro", at: t(30), values: ["nope": "x"]), project: client)
            XCTFail("no such field")
        } catch {
            XCTAssertTrue((error as? ServiceError)?.message.contains("has no field \"nope\"") == true, "\(error)")
        }
        do {
            _ = try await assets.insertSegment(SegmentInsertRequest(name: "Outro", at: t(30)), project: client)
            XCTFail("no such segment")
        } catch {
            XCTAssertEqual((error as? ServiceError)?.code, "notFound")
        }
        // A file gone from the segment's folder stops it going in half made.
        try FileManager.default.removeItem(at: intro.f.library("Segments/Intro/whoosh.wav"))
        do {
            _ = try await assets.insertSegment(SegmentInsertRequest(name: "Intro", at: t(60)), project: client)
            XCTFail("a file is missing")
        } catch {
            XCTAssertTrue((error as? ServiceError)?.message.contains("is missing whoosh.wav") == true, "\(error)")
        }
    }

    func testRequestsReadFriendlyForms() throws {
        let save = try ServiceJSON.decodeRequest(SegmentSaveRequest.self, from: Data(#"{"name": "Outro", "clips": "clip_a, clip_b", "fields": ["clip_a=Title", "clip_b"]}"#.utf8))
        XCTAssertEqual(save.clipIDs, ["clip_a", "clip_b"])
        XCTAssertEqual(save.fields, [SegmentMaker.Field(clipID: "clip_a", label: "Title"), SegmentMaker.Field(clipID: "clip_b")])
        let objects = try ServiceJSON.decodeRequest(SegmentSaveRequest.self, from: Data(#"{"name": "Outro", "from": "0:10", "to": 12.5, "fields": [{"clipID": "clip_a", "key": "who"}]}"#.utf8))
        XCTAssertEqual(objects.from, t(10))
        XCTAssertEqual(objects.to, t(12.5))
        XCTAssertEqual(objects.fields?.first?.key, "who")
        let insert = try ServiceJSON.decodeRequest(SegmentInsertRequest.self, from: Data(#"{"name": "Outro", "at": "1:02", "values": {"who": "Mike"}, "mode": "insert"}"#.utf8))
        XCTAssertEqual(insert.at, t(62))
        XCTAssertEqual(insert.mode, .insert)
        XCTAssertThrowsError(try ServiceJSON.decodeRequest(SegmentInsertRequest.self, from: Data(#"{"name": "Outro"}"#.utf8)))
    }
}

/// `tandem segments` and archive, run as Mike and agents run them.
final class SegmentCLITests: XCTestCase {
    func testSegmentsFromTheCommandLine() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        let cli = CLITests()
        let intro = try Intro()
        try FileManager.default.removeItem(at: intro.f.library("Segments/Intro"))
        let env = ["TANDEM_LIBRARY": intro.f.shared.root.path, "TANDEM_ASSETS_ROOT": intro.f.assetsRoot.path, "TANDEM_ASSETS_OFFLINE": "1"]

        let empty = try cli.tandem("segments", in: intro.f.video, env: env)
        XCTAssertEqual(empty.status, 0, empty.stderr)
        XCTAssertTrue(empty.stdout.hasPrefix("No segments in"), empty.stdout)

        let saved = try cli.tandem("segments", "save", "Intro", "--clips", intro.ids.joined(separator: ","), "--field", "clip_title=Title", in: intro.f.video, env: env)
        XCTAssertEqual(saved.status, 0, saved.stderr)
        XCTAssertTrue(saved.stdout.contains("Copied beside it, so it stands on its own:"), saved.stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: intro.f.library("Segments/Intro/segment.json").path))

        let listed = try cli.tandem("segments", "list", "--json", in: intro.f.video, env: env)
        XCTAssertEqual(listed.status, 0, listed.stderr)
        let list = try ServiceJSON.decoder().decode(SegmentListResult.self, from: Data(listed.stdout.utf8))
        XCTAssertEqual(list.segments.map(\.name), ["Intro"])

        let other = try intro.otherProject()
        let inserted = try cli.tandem("segments", "insert", "Intro", "--at", "0:02", "--value", "title=Hello", "--author", "claude", in: other.deletingLastPathComponent(), env: env)
        XCTAssertEqual(inserted.status, 0, inserted.stderr)
        XCTAssertTrue(inserted.stdout.hasPrefix("Put the segment \"Intro\" at 00:02.000 as revision 2"), inserted.stdout)
        let history = try cli.tandem("history", in: other.deletingLastPathComponent())
        XCTAssertTrue(history.stdout.contains("Add segment Intro  (claude)"), history.stdout)

        // The archive knows where the library is from the environment.
        let dry = try cli.tandem("archive", "--dry-run", in: other.deletingLastPathComponent(), env: env)
        XCTAssertEqual(dry.status, 0, dry.stderr)
        XCTAssertTrue(dry.stdout.contains("media/Tandem Library/Segments/Intro/card.mov"), dry.stdout)

        let usage = try cli.tandem("segments", "save", "Outro", in: intro.f.video, env: env)
        XCTAssertEqual(usage.status, 2)
        XCTAssertTrue(usage.stderr.contains("needs the clips"), usage.stderr)
        let noAt = try cli.tandem("segments", "insert", "Intro", in: other.deletingLastPathComponent(), env: env)
        XCTAssertEqual(noAt.status, 2)
        XCTAssertTrue(noAt.stderr.contains("needs --at"), noAt.stderr)
        let help = try cli.tandem("help", "segments", in: intro.f.video)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: tandem segments list | save"), help.stdout)
    }

    /// A sound dropped into the shared library is found, and used where it
    /// is, with the app closed.
    func testSharedAssetsFromTheCommandLine() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        let cli = CLITests()
        let f = try SharedFixture()
        let pop = f.library("Sound effects/Pop.wav")
        try AssetFixtures.wav(at: pop)
        try ProjectFile.save(Project.standard(name: "Video"), revision: 1, to: f.projectURL)
        let env = ["TANDEM_LIBRARY": f.shared.root.path, "TANDEM_ASSETS_ROOT": f.assetsRoot.path, "TANDEM_ASSETS_OFFLINE": "1"]

        let search = try cli.tandem("assets", "search", "pop", "--provider", "shared", "--json", in: f.video, env: env)
        XCTAssertEqual(search.status, 0, search.stderr)
        let found = try ServiceJSON.decoder().decode(AssetSearchResult.self, from: Data(search.stdout.utf8))
        XCTAssertEqual(found.local.map(\.id), ["shared:Sound effects/Pop.wav"])
        XCTAssertEqual(found.local.first?.kind, .sfx)

        let use = try cli.tandem("assets", "use", "shared:Sound effects/Pop.wav", "--at", "1", in: f.video, env: env)
        XCTAssertEqual(use.status, 0, use.stderr)
        XCTAssertTrue(use.stdout.contains("It's the shared library's file, not a copy"), use.stdout)
        let project = try ProjectFile.load(from: f.projectURL).project
        XCTAssertEqual(project.media.first?.path, pop.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.video.appendingPathComponent("assets").path), "nothing copied")
    }

    typealias Intro = SegmentTests.Intro
}

/// What a segment store threw away, for tests.
final class DiscardLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []

    func add(_ url: URL) {
        lock.withLock { stored.append(url) }
    }

    var urls: [URL] { lock.withLock { stored } }
}

final class SharedFontTextTests: XCTestCase {
    func testASharedFontSaysItStaysInTheLibrary() {
        let result = AssetUseResult(
            asset: Asset(provider: "shared", providerID: "Fonts/TiltWarp.ttf", kind: .font, name: "Tilt Warp"),
            mediaID: nil, files: ["/Users/mike/Movies/Tandem Library/Fonts/TiltWarp.ttf"], referencedInPlace: true,
            role: .other, trackName: nil, gainDB: nil, at: nil, applied: nil, fonts: ["TiltWarp-Regular"], licence: nil
        )
        XCTAssertTrue(result.readableText.hasPrefix("Installed the font Tilt Warp"), result.readableText)
        XCTAssertTrue(result.readableText.contains("It stays in the shared library (/Users/mike/Movies/Tandem Library/Fonts/TiltWarp.ttf)"), result.readableText)
    }
}
