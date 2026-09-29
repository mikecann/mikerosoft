import CryptoKit
import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// Fonts for tests: nothing on this Mac is looked at.
struct StubFonts: FontLocating {
    var files: [String: [URL]] = [:]
    var system: Set<String> = ["Helvetica"]

    func locate(_ family: String) -> FontLookup {
        if system.contains(family) || ArchiveFonts.isSystemName(family) { return .system }
        if let urls = files[family] { return .files(urls) }
        return .notFound
    }
}

/// A video folder whose project uses files from a folder beside it:
///
///     <temp>/video/Video.tandem       the project
///     <temp>/video/broll/servers.mp4  used by a relative path
///     <temp>/video/sfx/whoosh.wav     used by an absolute path into the folder
///     <temp>/outside/source/take1-camera.mov, take1-screen.mov, take1.take.json
///     <temp>/outside/music/bed.m4a
///     <temp>/outside/luts/film.cube   a clip's LUT and the camera's look
///     <temp>/outside/fonts/TiltWarp.ttf  the caption preset's font (StubFonts)
///     <temp>/nowhere/gone.wav         missing
final class ArchiveFixture {
    let temp = TempFolder("tandem-archive")
    var root: URL { temp.url }
    var video: URL { root.appendingPathComponent("video", isDirectory: true) }
    var outside: URL { root.appendingPathComponent("outside", isDirectory: true) }
    var projectURL: URL { video.appendingPathComponent("Video.tandem") }
    var fonts: StubFonts { StubFonts(files: ["Tilt Warp": [outside.appendingPathComponent("fonts/TiltWarp.ttf")]]) }

    init(write: Bool = true) throws {
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        if write { try ProjectFile.save(try standardProject(), revision: 1, to: projectURL) }
    }

    /// Writes a file with made-up content (different for each seed).
    @discardableResult
    func make(_ url: URL, bytes: Int = 6000, seed: Int = 1) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed &* 7 &+ ($0 >> 8)) }).write(to: url)
        return url
    }

    func outside(_ path: String) -> URL { outside.appendingPathComponent(path) }
    func inVideo(_ path: String) -> URL { video.appendingPathComponent(path) }

    /// A media item for a file, fingerprinted and probed the way a scan
    /// leaves one, stored as `stored` (the absolute path by default).
    func item(_ id: String, _ url: URL, stored: String? = nil, kind: MediaKind = .video, role: MediaRole = .broll) throws -> MediaItem {
        var item = MediaItem(
            id: id, path: stored ?? url.path, kind: kind, role: role, duration: t(60), frameRate: kind == .audio ? nil : .fps30,
            width: kind == .audio ? nil : 1920, height: kind == .audio ? nil : 1080, hasVideo: kind != .audio, hasAudio: kind != .image
        )
        if FileManager.default.fileExists(atPath: url.path) {
            item.fingerprint = try Fingerprint.compute(for: url).description
        }
        return item
    }

    func standardProject() throws -> Project {
        try make(outside("source/take1-camera.mov"), seed: 1)
        try make(outside("source/take1-screen.mov"), seed: 2)
        try Data(#"{"version": 1, "files": [{"role": "camera", "startHostTime": 10.5}, {"role": "screen", "startHostTime": 10.0}]}"#.utf8).write(to: outside("source/take1.take.json"))
        try make(outside("music/bed.m4a"), seed: 3)
        try make(outside("luts/film.cube"), bytes: 900, seed: 4)
        try make(outside("fonts/TiltWarp.ttf"), bytes: 700, seed: 5)
        try make(inVideo("broll/servers.mp4"), seed: 6)
        try make(inVideo("sfx/whoosh.wav"), seed: 7)

        var camera = try item("med_cam", outside("source/take1-camera.mov"), role: .camera)
        camera.look = [Effect(id: "fx_look", type: "lut", params: ["path": .string(outside("luts/film.cube").path)])]
        let lut = Effect(id: "fx_lut", type: "lut", params: ["path": .string(outside("luts/film.cube").path), "intensity": .number(0.8)])
        var project = Project(id: "prj_archive", name: "Video")
        project.media = [
            camera,
            try item("med_scr", outside("source/take1-screen.mov"), role: .screen),
            try item("med_bed", outside("music/bed.m4a"), kind: .audio, role: .music),
            try item("med_brl", inVideo("broll/servers.mp4"), stored: "broll/servers.mp4"),
            try item("med_whoosh", inVideo("sfx/whoosh.wav"), kind: .audio, role: .sfx),
            try item("med_gone", root.appendingPathComponent("nowhere/gone.wav"), kind: .audio, role: .sfx)
        ]
        project.videoTracks = [
            Track(id: "trk_screen", kind: .video, name: "Screen", clips: [
                Clip(id: "clip_scr", content: .media(mediaID: "med_scr"), start: t(0), duration: t(10))
            ], rippleMode: .cut),
            Track(id: "trk_camera", kind: .video, name: "Camera", clips: [
                Clip(id: "clip_cam", content: .media(mediaID: "med_cam"), start: t(0), duration: t(10), video: VideoProperties(effects: [lut]))
            ], locked: true, rippleMode: .cut),
            Track(id: "trk_broll", kind: .video, name: "B-roll", clips: [
                Clip(id: "clip_brl", content: .media(mediaID: "med_brl"), start: t(2), duration: t(3))
            ], rippleMode: .follow),
            Track(id: "trk_text", kind: .video, name: "Text", clips: [
                Clip(id: "clip_cap", content: .text(TextContent(text: "hi there", preset: "caption")), start: t(1), duration: t(2)),
                Clip(id: "clip_title", content: .text(TextContent(text: "TIP 1", preset: "callout")), start: t(4), duration: t(2))
            ], rippleMode: .follow)
        ]
        project.audioTracks = [
            Track(id: "trk_music", kind: .audio, name: "Music", clips: [
                Clip(id: "clip_bed", content: .media(mediaID: "med_bed"), start: t(0), duration: t(10))
            ], rippleMode: .follow),
            Track(id: "trk_sfx", kind: .audio, name: "SFX", clips: [
                Clip(id: "clip_whoosh", content: .media(mediaID: "med_whoosh"), start: t(3), duration: t(1)),
                Clip(id: "clip_gone", content: .media(mediaID: "med_gone"), start: t(5), duration: t(1))
            ], rippleMode: .follow)
        ]
        return project
    }

    /// Opens the project, archives it and closes it again.
    @discardableResult
    func archive(to destination: URL? = nil, withCache: Bool = false, dryRun: Bool = false, clone: Bool = true, fonts: StubFonts? = nil, project: URL? = nil,
                 control: ArchiveControl = ArchiveControl(), progress: ((ArchiveProgress) -> Void)? = nil) throws -> ArchiveResult {
        let session = try ProjectSession.open(project ?? projectURL, owner: .cli)
        session.autosaveDelay = 3600
        defer { session.close() }
        var options = ArchiveOptions(destination: destination, withCache: withCache, dryRun: dryRun, author: "claude", fonts: fonts ?? self.fonts)
        options.clone = clone
        return try ProjectArchiver(session: session, options: options, control: control, progress: progress).run()
    }

    func load(_ url: URL? = nil) throws -> (project: Project, revision: Int) {
        try ProjectFile.load(from: url ?? projectURL)
    }

    /// Every file under a folder (hidden ones too) and its content, or
    /// where it links to.
    static func tree(_ folder: URL, skip: (String) -> Bool = { _ in false }) -> [String: Data] {
        var files: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [:] }
        let prefixes = [folder.path, ProjectArchiver.realPath(folder) ?? folder.path].map { $0 + "/" }
        for case let url as URL in enumerator {
            guard let prefix = prefixes.first(where: { url.path.hasPrefix($0) }) else { continue }
            let relative = String(url.path.dropFirst(prefix.count))
            guard !skip(relative) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                files[relative] = Data(((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "").utf8)
            } else if values?.isRegularFile == true {
                files[relative] = (try? Data(contentsOf: url)) ?? Data()
            }
        }
        return files
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

final class ArchiveTests: XCTestCase {
    func testConsolidatingBringsOutsideFilesInAndPointsTheProjectAtThem() throws {
        let f = try ArchiveFixture()
        let fingerprint = try f.load().project.media("med_cam")?.fingerprint
        let result = try f.archive()

        XCTAssertEqual(result.mode, .consolidate)
        XCTAssertFalse(result.dryRun)
        let collected = Dictionary(uniqueKeysWithValues: result.collected.map { ($0.path, $0) })
        XCTAssertEqual(Set(collected.keys), [
            "media/source/take1-camera.mov", "media/source/take1-screen.mov", "media/source/take1.take.json",
            "media/music/bed.m4a", "assets/lut/film.cube", "assets/font/TiltWarp.ttf"
        ])
        XCTAssertEqual(collected["media/source/take1.take.json"]?.kind, .sidecar)
        XCTAssertEqual(collected["assets/font/TiltWarp.ttf"]?.usedBy, ["Tilt Warp"])
        for file in result.collected {
            XCTAssertTrue([.cloned, .copied].contains(file.outcome), "\(file.path) \(file.outcome)")
            let copy = f.video.appendingPathComponent(file.path)
            XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: URL(fileURLWithPath: file.original)), file.path)
            XCTAssertEqual(file.sha256, try ArchiveFixture.sha256(copy))
            // Dates survive, so fingerprints (and the analysis cache) do.
            XCTAssertEqual(FileCopier.milliseconds(FileCopier.fileInfo(copy)!.modified), FileCopier.milliseconds(FileCopier.fileInfo(URL(fileURLWithPath: file.original))!.modified))
        }
        XCTAssertEqual(result.madeRelative, 1, "the absolute path into the folder")
        XCTAssertEqual(result.missing.map(\.path), [f.root.appendingPathComponent("nowhere/gone.wav").path])
        XCTAssertEqual(result.missing.first?.clips, 1)
        XCTAssertEqual(result.fonts.first { $0.family == "Tilt Warp" }?.status, .collected)
        XCTAssertEqual(result.fonts.first { $0.family == "SF Pro Display" }?.status, .system)
        XCTAssertEqual(result.revision, 2)

        let (project, revision) = try f.load()
        XCTAssertEqual(revision, 2, "saved after one edit")
        XCTAssertEqual(project.media("med_cam")?.path, "media/source/take1-camera.mov")
        XCTAssertEqual(project.media("med_scr")?.path, "media/source/take1-screen.mov")
        XCTAssertEqual(project.media("med_bed")?.path, "media/music/bed.m4a")
        XCTAssertEqual(project.media("med_brl")?.path, "broll/servers.mp4")
        XCTAssertEqual(project.media("med_whoosh")?.path, "sfx/whoosh.wav")
        XCTAssertEqual(project.media("med_gone")?.path, f.root.appendingPathComponent("nowhere/gone.wav").path, "missing files keep their paths")
        XCTAssertEqual(project.media("med_cam")?.look.first?.params["path"], .string("assets/lut/film.cube"))
        let clip = try XCTUnwrap(project.clip("clip_cam"))
        XCTAssertEqual(clip.video?.effects.first?.params["path"], .string("assets/lut/film.cube"))
        XCTAssertEqual(clip.video?.effects.first?.params["intensity"], .number(0.8))
        XCTAssertTrue(project.track(named: "Camera")?.locked ?? false, "the locked track is locked again")
        XCTAssertEqual(project.media("med_cam")?.fingerprint, fingerprint)

        // Nothing is left hidden, and the outside files are where they were.
        let hidden = ArchiveFixture.tree(f.video).keys.filter { $0.hasSuffix(FileCopier.temporarySuffix) }
        XCTAssertEqual(Array(hidden), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.outside("music/bed.m4a").path))

        let manifest = try XCTUnwrap(try ArchiveManifest.load(from: f.video))
        XCTAssertEqual(result.manifest, ArchiveManifest.url(in: f.video).path)
        XCTAssertEqual(manifest.project, .init(id: "prj_archive", name: "Video", file: "Video.tandem"))
        XCTAssertEqual(manifest.runs.map(\.mode), [.consolidate])
        XCTAssertEqual(manifest.runs.first?.complete, true)
        let bed = try XCTUnwrap(manifest.entry(for: "media/music/bed.m4a"))
        XCTAssertEqual(bed.original, ProjectArchiver.realPath(f.outside("music/bed.m4a")))
        XCTAssertEqual(bed.sha256, try ArchiveFixture.sha256(f.outside("music/bed.m4a")))
        XCTAssertEqual(manifest.missing.map(\.kind), [.media])
        XCTAssertTrue(result.readableText.contains("is standalone: brought in 6 files"), result.readableText)
        XCTAssertTrue(result.readableText.contains("nowhere/gone.wav"), result.readableText)
    }

    func testTheEditIsOneUndoStepCreditedToTheCaller() throws {
        let h = try ArchiveHarness()
        defer { h.close() }
        let result = try h.run()
        XCTAssertEqual(result.revision, 2)
        XCTAssertEqual(h.session.coordinator.undoLabel, "Bring 6 files into the project folder")
        XCTAssertEqual(h.session.coordinator.history(limit: 1).first?.author, "claude")
        h.session.coordinator.undo()
        XCTAssertEqual(h.session.coordinator.project.media("med_cam")?.path, h.fixture.outside("source/take1-camera.mov").path)
        XCTAssertTrue(h.session.coordinator.project.track(named: "Camera")?.locked ?? false)
    }

    func testTheSameFileIsCopiedOnce() throws {
        let f = try ArchiveFixture(write: false)
        var project = try f.standardProject()
        // The same music file by another spelling, and the same LUT on a
        // second clip.
        let aside = f.root.appendingPathComponent("link-to-outside")
        try FileManager.default.createSymbolicLink(at: aside, withDestinationURL: f.outside)
        project.media.append(try f.item("med_bed2", f.outside("music/bed.m4a"), stored: aside.appendingPathComponent("music/bed.m4a").path, kind: .audio, role: .music))
        project.media.append(try f.item("med_bed3", f.outside("music/bed.m4a"), stored: "../outside/music/bed.m4a", kind: .audio, role: .music))
        let second = Effect(id: "fx_lut2", type: "lut", params: ["path": .string("../outside/luts/film.cube")])
        project.videoTracks[2].clips[0].video = VideoProperties(effects: [second])
        try ProjectFile.save(project, revision: 1, to: f.projectURL)

        let result = try f.archive()
        XCTAssertEqual(result.collected.filter { $0.kind == .media }.map(\.path).sorted(), ["media/music/bed.m4a", "media/source/take1-camera.mov", "media/source/take1-screen.mov"])
        XCTAssertEqual(result.collected.filter { $0.kind == .lut }.count, 1)
        XCTAssertEqual(Set(result.collected.first { $0.path == "media/music/bed.m4a" }?.usedBy ?? []), ["med_bed", "med_bed2", "med_bed3"])
        let saved = try f.load().project
        XCTAssertEqual(saved.media("med_bed2")?.path, "media/music/bed.m4a")
        XCTAssertEqual(saved.media("med_bed3")?.path, "media/music/bed.m4a")
        XCTAssertEqual(saved.clip("clip_brl")?.video?.effects.first?.params["path"], .string("assets/lut/film.cube"))
        let music = try FileManager.default.contentsOfDirectory(atPath: f.inVideo("media/music").path)
        XCTAssertEqual(music, ["bed.m4a"])
    }

    func testANameThatsTakenGetsACopyBesideIt() throws {
        let f = try ArchiveFixture(write: false)
        var project = try f.standardProject()
        // Another bed.m4a from another music folder, and a different file
        // already sitting where the first would go.
        try f.make(f.root.appendingPathComponent("elsewhere/music/bed.m4a"), seed: 40)
        project.media.append(try f.item("med_bed2", f.root.appendingPathComponent("elsewhere/music/bed.m4a"), kind: .audio, role: .music))
        let mine = try f.make(f.inVideo("media/music/bed.m4a"), bytes: 100, seed: 41)
        let mineBefore = try Data(contentsOf: mine)
        // A file already there with the same content is used as it is.
        try FileManager.default.createDirectory(at: f.inVideo("media/source"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.outside("source/take1-screen.mov"), to: f.inVideo("media/source/take1-screen.mov"))
        try ProjectFile.save(project, revision: 1, to: f.projectURL)

        let planned = try f.archive(dryRun: true)
        XCTAssertEqual(Set(planned.collected.filter { $0.path.hasPrefix("media/music") }.map(\.path)), ["media/music/bed 2.m4a", "media/music/bed 3.m4a"])

        let result = try f.archive()
        let beds = result.collected.filter { $0.path.hasPrefix("media/music") }
        XCTAssertEqual(Set(beds.map(\.path)), ["media/music/bed 2.m4a", "media/music/bed 3.m4a"])
        XCTAssertEqual(try Data(contentsOf: mine), mineBefore, "never written over")
        XCTAssertEqual(result.collected.first { $0.path == "media/source/take1-screen.mov" }?.outcome, .reused)
        XCTAssertEqual(result.reusedFiles, 1)
        let saved = try f.load().project
        XCTAssertEqual(try Data(contentsOf: f.inVideo(saved.media("med_bed")!.path)), try Data(contentsOf: f.outside("music/bed.m4a")))
        XCTAssertEqual(try Data(contentsOf: f.inVideo(saved.media("med_bed2")!.path)), try Data(contentsOf: f.root.appendingPathComponent("elsewhere/music/bed.m4a")))
        XCTAssertEqual(saved.media("med_scr")?.path, "media/source/take1-screen.mov")
    }

    func testMissingFilesAreReportedAndTheRestIsArchived() throws {
        let f = try ArchiveFixture(write: false)
        var project = try f.standardProject()
        project.videoTracks[2].clips[0].video = VideoProperties(effects: [Effect(id: "fx_gone", type: "lut", params: ["path": .string("/nowhere/at/all.cube")])])
        project.videoTracks[3].clips.append(Clip(id: "clip_odd", content: .text(TextContent(text: "odd", style: TextStyle(font: "Nope Sans"))), start: t(7), duration: t(1)))
        try ProjectFile.save(project, revision: 1, to: f.projectURL)

        let result = try f.archive()
        XCTAssertEqual(Set(result.missing.map(\.kind)), [.media, .lut, .font])
        XCTAssertEqual(result.missing.first { $0.kind == .lut }?.usedBy, ["clip_brl"])
        XCTAssertEqual(result.missing.first { $0.kind == .font }?.path, "Nope Sans")
        XCTAssertEqual(result.fonts.first { $0.family == "Nope Sans" }?.status, .missing)
        XCTAssertEqual(result.collected.count, 6, "everything else still came in")
        let saved = try f.load().project
        XCTAssertEqual(saved.clip("clip_brl")?.video?.effects.first?.params["path"], .string("/nowhere/at/all.cube"))
        XCTAssertTrue(result.readableText.contains("font \"Nope Sans\" isn't installed here"), result.readableText)
        XCTAssertEqual(Set(try XCTUnwrap(try ArchiveManifest.load(from: f.video)).missing.map(\.kind)), [.media, .lut, .font])
    }

    func testADryRunChangesNothing() throws {
        let f = try ArchiveFixture()
        let shelf = f.root.appendingPathComponent("shelf")
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        let session = try ProjectSession.open(f.projectURL, owner: .cli)
        session.autosaveDelay = 3600
        let skipLock: (String) -> Bool = { $0.hasSuffix(".lock") }
        let before = ArchiveFixture.tree(f.root, skip: skipLock)
        var options = ArchiveOptions(dryRun: true, fonts: f.fonts)
        let planned = try ProjectArchiver(session: session, options: options).run()
        options.destination = shelf
        let plannedArchive = try ProjectArchiver(session: session, options: options).run()
        XCTAssertEqual(session.coordinator.revision, 1)
        session.close()

        XCTAssertTrue(planned.dryRun)
        XCTAssertEqual(ArchiveFixture.tree(f.root, skip: skipLock), before, "nothing written anywhere")
        XCTAssertEqual(planned.collected.count, 6)
        XCTAssertTrue(planned.collected.allSatisfy { $0.outcome == .planned })
        XCTAssertEqual(planned.collected.first { $0.path == "media/music/bed.m4a" }?.bytes, 6000)
        XCTAssertEqual(planned.copiedBytes, planned.collected.reduce(0) { $0 + $1.bytes })
        XCTAssertNil(planned.manifest)
        XCTAssertTrue(planned.readableText.hasPrefix("Dry run, nothing changed."), planned.readableText)

        XCTAssertEqual(plannedArchive.mode, .archive)
        XCTAssertEqual(plannedArchive.folder, f.root.appendingPathComponent("shelf/video").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plannedArchive.folder))
        XCTAssertEqual(plannedArchive.folderFiles, 2, "the project folder's broll and sfx")
        XCTAssertEqual(try f.load().revision, 1)
    }

    func testArchivingElsewhereLeavesTheOriginalAloneAndTheCopyOpensOnItsOwn() async throws {
        let f = try ArchiveFixture()
        try f.make(f.inVideo("exports/Video r1.mp4"), seed: 20)
        try Data("notes".utf8).write(to: f.inVideo("notes.md"))
        let camera = try XCTUnwrap(try f.load().project.media("med_cam"))
        try Self.cacheEntries(for: camera, in: f.video)
        let shelf = f.root.appendingPathComponent("shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        let skipLock: (String) -> Bool = { $0.hasSuffix(".lock") }
        let sourceBefore = ArchiveFixture.tree(f.video, skip: skipLock)
        let outsideBefore = ArchiveFixture.tree(f.outside)

        let result = try f.archive(to: shelf, clone: false)
        let archived = shelf.appendingPathComponent("video", isDirectory: true)
        XCTAssertEqual(result.mode, .archive)
        XCTAssertEqual(result.folder, archived.path)
        XCTAssertEqual(result.projectFile, archived.appendingPathComponent("Video.tandem").path)
        XCTAssertTrue(result.collected.allSatisfy { $0.outcome == .copied }, "no clones asked for")
        XCTAssertEqual(ArchiveFixture.tree(f.video, skip: skipLock), sourceBefore, "the original folder is as it was")
        XCTAssertEqual(ArchiveFixture.tree(f.outside), outsideBefore)
        XCTAssertEqual(try f.load().project.media("med_cam")?.path, f.outside("source/take1-camera.mov").path)

        for path in ["broll/servers.mp4", "sfx/whoosh.wav", "exports/Video r1.mp4", "notes.md", "media/music/bed.m4a", "assets/lut/film.cube", "assets/font/TiltWarp.ttf", "archive.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: archived.appendingPathComponent(path).path), path)
        }
        let manifest = try XCTUnwrap(try ArchiveManifest.load(from: archived))
        XCTAssertEqual(manifest.runs.last?.complete, true)
        XCTAssertEqual(manifest.runs.last?.from, f.video.path)
        XCTAssertNotNil(manifest.entry(for: "notes.md")?.sha256, "the folder's own files are listed with checksums")
        XCTAssertNil(manifest.entry(for: ".tandem/cache/transcript"), "the cache isn't")

        // Take the original and everything outside away, as on another Mac.
        try FileManager.default.moveItem(at: f.video, to: f.root.appendingPathComponent("video-gone"))
        try FileManager.default.moveItem(at: f.outside, to: f.root.appendingPathComponent("outside-gone"))
        let session = try ProjectSession.open(result.projectFile.url, owner: .cli)
        defer { session.close() }
        let project = session.coordinator.project
        XCTAssertTrue(project.media.filter { $0.id != "med_gone" }.allSatisfy { ProjectArchiver.isPlainRelative($0.path) }, "\(project.media.map(\.path))")
        XCTAssertEqual(MediaRelinker.missing(in: project, folder: session.folder).map(\.id), ["med_gone"])
        XCTAssertEqual(project.clip("clip_cam")?.video?.effects.first?.params["path"], .string("assets/lut/film.cube"))
        // The transcript made for the camera file is found from the copy.
        let archivedCamera = try XCTUnwrap(project.media("med_cam"))
        XCTAssertEqual(archivedCamera.fingerprint, camera.fingerprint)
        XCTAssertTrue(MediaAnalysis(folder: session.folder).isCached(.transcript, for: archivedCamera))
        XCTAssertFalse(MediaAnalysis(folder: session.folder).isCached(.proxy, for: archivedCamera), "proxies are left out")
        let scan = try await MediaScanner.scan(session.folder, known: project.media)
        XCTAssertEqual(scan.first { $0.id == "med_cam" }?.fingerprint, camera.fingerprint, "dates kept, so the scan doesn't see a changed file")
    }

    func testTheCacheIsLeftOutUnlessAsked() throws {
        let f = try ArchiveFixture()
        let camera = try XCTUnwrap(try f.load().project.media("med_cam"))
        try Self.cacheEntries(for: camera, in: f.video)
        let scratch = f.inVideo(".tandem/cache/proxy/.tmp-abc-123")
        try f.make(scratch.appendingPathComponent("proxy.mov"), bytes: 10)
        let shelf = f.root.appendingPathComponent("shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)

        let lean = try f.archive(to: shelf)
        let kinds = { (folder: URL) -> Set<String> in
            Set((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".tandem/cache").path)) ?? [])
        }
        let leanFolder = URL(fileURLWithPath: lean.folder)
        XCTAssertEqual(kinds(leanFolder), ["transcript", "waveform", "loudness", "converted"])
        XCTAssertEqual(Set(lean.leftOut.map(\.path)), [".tandem/cache/proxy", ".tandem/cache/matte", ".tandem/cache/thumbnails", ".tandem/cache/isolatedVoice"])
        XCTAssertTrue(lean.leftOut.allSatisfy { $0.bytes > 0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: leanFolder.appendingPathComponent(".tandem/Video.lock").path))
        XCTAssertTrue(lean.readableText.contains("Left out .tandem/cache/proxy"), lean.readableText)

        let full = try f.archive(to: shelf, withCache: true)
        let fullFolder = URL(fileURLWithPath: full.folder)
        XCTAssertEqual(fullFolder, leanFolder, "this project's archive is brought up to date")
        XCTAssertEqual(kinds(fullFolder), Set(AnalysisKind.allCases.map(\.rawValue)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fullFolder.appendingPathComponent(".tandem/cache/proxy/.tmp-abc-123").path), "temporaries aren't copied")
        XCTAssertEqual(full.leftOut, [])
    }

    func testAnInterruptedConsolidationPicksUpWhereItStopped() throws {
        let f = try ArchiveFixture()
        // As if a run had moved a copy into place and stopped before
        // pointing the project at it, and left another half written.
        try FileManager.default.createDirectory(at: f.inVideo("media/music"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.outside("music/bed.m4a"), to: f.inVideo("media/music/bed.m4a"))
        try f.make(f.inVideo("media/source/.take1-camera.mov.tandem-copy"), bytes: 123, seed: 9)

        let control = ArchiveControl()
        XCTAssertThrowsError(try f.archive(control: control, progress: { progress in
            if progress.filesDone >= 2 { control.cancel() }
        })) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let (stopped, revision) = try f.load()
        XCTAssertEqual(revision, 1, "nothing in the project changed")
        XCTAssertEqual(stopped.media("med_scr")?.path, f.outside("source/take1-screen.mov").path)
        let visible = ArchiveFixture.tree(f.inVideo("media")).keys.filter { !($0 as NSString).lastPathComponent.hasPrefix(".") }
        XCTAssertEqual(visible, ["music/bed.m4a"], "copies wait under hidden names until they're all done")

        let result = try f.archive()
        XCTAssertEqual(result.collected.first { $0.path == "media/music/bed.m4a" }?.outcome, .reused)
        XCTAssertEqual(try Data(contentsOf: f.inVideo("media/source/take1-camera.mov")), try Data(contentsOf: f.outside("source/take1-camera.mov")))
        let names = ArchiveFixture.tree(f.inVideo("media")).keys.sorted()
        XCTAssertEqual(names, ["music/bed.m4a", "source/take1-camera.mov", "source/take1-screen.mov", "source/take1.take.json"], "nothing beside, nothing hidden")
        let (project, finished) = try f.load()
        XCTAssertEqual(finished, 2)
        XCTAssertEqual(project.media("med_scr")?.path, "media/source/take1-screen.mov")

        // Running it again finds nothing to do.
        let again = try f.archive()
        XCTAssertEqual(again.copiedFiles, 0)
        XCTAssertTrue(again.collected.allSatisfy { $0.outcome == .reused }, "\(again.collected)")
        XCTAssertEqual(try f.load().revision, 2)
        XCTAssertEqual(try XCTUnwrap(try ArchiveManifest.load(from: f.video)).runs.count, 2)
    }

    func testAnInterruptedArchiveIsFinishedInTheSameFolder() throws {
        let f = try ArchiveFixture()
        let shelf = f.root.appendingPathComponent("shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        let control = ArchiveControl()
        XCTAssertThrowsError(try f.archive(to: shelf, clone: false, control: control) { progress in
            if progress.filesDone >= 3 { control.cancel() }
        })
        let archived = shelf.appendingPathComponent("video", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archived.appendingPathComponent("Video.tandem").path), "no project until everything's in")
        XCTAssertEqual(try ArchiveManifest.load(from: archived)?.runs.last?.complete, false)

        let result = try f.archive(to: shelf, clone: false)
        XCTAssertEqual(result.folder, archived.path)
        XCTAssertGreaterThan(result.reusedFiles, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.projectFile))
        XCTAssertEqual(try ArchiveManifest.load(from: archived)?.runs.map(\.complete), [false, true])
        let names = ArchiveFixture.tree(archived).keys
        XCTAssertFalse(names.contains { $0.contains(" 2.") || $0.hasSuffix(FileCopier.temporarySuffix) }, "\(names.sorted())")
    }

    func testOtherVersionsInTheFolderComeAlong() throws {
        let f = try ArchiveFixture()
        var older = Project(id: "prj_older", name: "Video v1")
        older.media = [try f.item("med_old_bed", f.outside("music/bed.m4a"), kind: .audio, role: .music)]
        let olderURL = f.inVideo("Video v1.tandem")
        try ProjectFile.save(older, revision: 4, to: olderURL)
        let shelf = f.root.appendingPathComponent("shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)

        let archived = try f.archive(to: shelf)
        XCTAssertEqual(archived.otherProjects, [OtherProjectFile(file: "Video v1.tandem", rewritten: 1, note: nil)])
        let copy = try ProjectFile.load(from: URL(fileURLWithPath: archived.folder).appendingPathComponent("Video v1.tandem"))
        XCTAssertEqual(copy.project.media.first?.path, "media/music/bed.m4a")
        XCTAssertEqual(copy.revision, 4)
        XCTAssertEqual(try ProjectFile.load(from: olderURL).project.media.first?.path, f.outside("music/bed.m4a").path, "the original is untouched")

        let consolidated = try f.archive()
        XCTAssertEqual(consolidated.otherProjects, [OtherProjectFile(file: "Video v1.tandem", rewritten: 1, note: nil)])
        XCTAssertEqual(try ProjectFile.load(from: olderURL).project.media.first?.path, "media/music/bed.m4a")
    }

    func testAVersionOpenSomewhereElseIsLeftAsItIs() throws {
        let f = try ArchiveFixture()
        var older = Project(id: "prj_older", name: "Video v1")
        older.media = [try f.item("med_old_bed", f.outside("music/bed.m4a"), kind: .audio, role: .music)]
        let olderURL = f.inVideo("Video v1.tandem")
        try ProjectFile.save(older, revision: 4, to: olderURL)
        let open = try ProjectSession.open(olderURL, owner: .app)
        defer { open.close() }
        let result = try f.archive()
        XCTAssertEqual(result.otherProjects.first?.file, "Video v1.tandem")
        XCTAssertEqual(result.otherProjects.first?.rewritten, 0)
        XCTAssertTrue(result.otherProjects.first?.note?.contains("open somewhere else") ?? false, "\(result.otherProjects)")
    }

    func testFontsFoundOnThisMac() {
        let fonts = InstalledFonts(libraryRoot: nil, sharedLibrary: nil)
        XCTAssertEqual(fonts.locate("SF Pro Display"), .system)
        XCTAssertEqual(fonts.locate("Helvetica"), .system)
        XCTAssertEqual(fonts.locate("Helvetica-Bold"), .system, "PostScript names work too")
        XCTAssertEqual(fonts.locate("Surely No Font Is Called This 7"), .notFound)
        XCTAssertEqual(ArchiveFonts.family(of: TextContent(text: "x", preset: "caption")), "Tilt Warp")
        XCTAssertEqual(ArchiveFonts.family(of: TextContent(text: "x", preset: "caption", style: TextStyle(font: "Kanit"))), "Kanit")
        XCTAssertEqual(ArchiveFonts.family(of: TextContent(text: "x")), "SF Pro Display")
    }

    func testFontsTheProjectCarriesStay() throws {
        // A real font file standing in for one the project carries.
        let arial = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: arial.path), "no Arial to stand in")
        let f = try ArchiveFixture(write: false)
        var project = try f.standardProject()
        project.videoTracks[3].clips[0].content = .text(TextContent(text: "hi", style: TextStyle(font: "Arial")))
        try ProjectFile.save(project, revision: 1, to: f.projectURL)
        try FileManager.default.createDirectory(at: f.inVideo("assets/font"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: arial, to: f.inVideo("assets/font/Arial.ttf"))
        let result = try f.archive(dryRun: true, fonts: StubFonts(system: []))
        XCTAssertEqual(result.fonts.first { $0.family == "Arial" }?.status, .inProject)
        XCTAssertFalse(result.collected.contains { $0.kind == .font })
    }

    func testBadPlacesAndSomeoneElsesManifestAreRefused() throws {
        let f = try ArchiveFixture()
        assertServiceError(.notFound) { try f.archive(to: f.root.appendingPathComponent("not-mounted")) }
        assertServiceError(.invalid) { try f.archive(to: f.inVideo("broll")) }
        // The folder the project is in makes a copy beside it.
        let beside = try f.archive(to: f.root, dryRun: true)
        XCTAssertEqual(beside.folder, f.root.appendingPathComponent("video 2").path)
        try Data(#"{"something": "else"}"#.utf8).write(to: f.inVideo("archive.json"))
        assertServiceError(.invalid) { try f.archive(dryRun: true) }
    }

    func testAnArchiveWhoseCopyIsOpenIsRefused() throws {
        let f = try ArchiveFixture()
        let shelf = f.root.appendingPathComponent("shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        let first = try f.archive(to: shelf)
        let open = try ProjectSession.open(URL(fileURLWithPath: first.projectFile), owner: .app)
        defer { open.close() }
        assertServiceError(.locked) { try f.archive(to: shelf) }
    }

    func testTheServiceArchivesThroughItsOwnEdits() async throws {
        let f = try ArchiveFixture(write: false)
        var project = try f.standardProject()
        project.videoTracks[3].clips[0].content = .text(TextContent(text: "hi", style: TextStyle(font: "Helvetica")))
        try ProjectFile.save(project, revision: 1, to: f.projectURL)
        let session = try ProjectSession.open(f.projectURL, owner: .cli)
        session.autosaveDelay = 3600
        let service = TandemService(session: session, mode: .headless, analysis: FakeAnalysis(), renderer: FakeRenderer())
        service.locateSharedLibrary = { nil }
        defer {
            service.shutdown()
            session.close()
        }
        let planned = try await service.archive(ArchiveRequest(dryRun: true), context: CallContext(author: "codex"))
        XCTAssertTrue(planned.dryRun)
        let body = try await service.handle(.archive, body: Data(#"{"label": "Archive for Bruce"}"#.utf8), context: CallContext(author: "codex"))
        let done = try ServiceJSON.decoder().decode(ArchiveResult.self, from: body)
        XCTAssertEqual(done.revision, 2)
        XCTAssertEqual(service.coordinator.undoLabel, "Archive for Bruce")
        XCTAssertEqual(service.history(limit: 5).undo.first?.author, "codex")
    }

    // MARK: - Helpers

    /// One committed cache entry of every kind for `item`.
    static func cacheEntries(for item: MediaItem, in folder: URL) throws {
        let cache = AnalysisCache(folder: ProjectFolder(root: folder))
        let fingerprint = try XCTUnwrap(item.fingerprint)
        for kind in AnalysisKind.allCases {
            let settings = AnalysisSettings.standard.canonical(for: kind)
            let key = AnalysisCache.key(fingerprint: fingerprint, kind: kind, algorithmVersion: kind.algorithmVersion, settings: settings)
            let pending = try cache.begin(kind: kind, key: key)
            try Data(repeating: 7, count: 2048).write(to: pending.folder.appendingPathComponent("result.bin"))
            try cache.commit(pending, fingerprint: fingerprint, algorithmVersion: kind.algorithmVersion, settings: settings, source: item.path)
        }
    }
}

/// An open fixture project with an archiver over it.
final class ArchiveHarness {
    let fixture: ArchiveFixture
    let session: ProjectSession

    init() throws {
        fixture = try ArchiveFixture()
        session = try ProjectSession.open(fixture.projectURL, owner: .cli)
        session.autosaveDelay = 3600
    }

    func run(_ configure: (inout ArchiveOptions) -> Void = { _ in }) throws -> ArchiveResult {
        var options = ArchiveOptions(author: "claude", fonts: fixture.fonts)
        configure(&options)
        return try ProjectArchiver(session: session, options: options).run()
    }

    func close() {
        session.close()
    }
}

extension String {
    var url: URL { URL(fileURLWithPath: self) }
}

final class RelinkTests: XCTestCase {
    func testMissingMediaIsFoundByNameAndContent() async throws {
        let f = try ArchiveFixture(write: false)
        _ = try f.standardProject()
        // The project remembers files that have since moved.
        var project = Project(id: "prj_relink", name: "Moved")
        let camera = try f.item("med_cam", f.outside("source/take1-camera.mov"), stored: "source/take1-camera.mov", role: .camera)
        let bed = try f.item("med_bed", f.outside("music/bed.m4a"), stored: "/Volumes/Gone/music/bed.m4a", kind: .audio, role: .music)
        var loose = try f.item("med_loose", f.outside("luts/film.cube"), stored: "/Volumes/Gone/loose.wav", kind: .audio, role: .sfx)
        loose.fingerprint = nil
        var twice = try f.item("med_twice", f.outside("luts/film.cube"), stored: "/Volumes/Gone/twice.wav", kind: .audio, role: .sfx)
        twice.fingerprint = nil
        project.media = [camera, bed, loose, twice]
        try ProjectFile.save(project, revision: 1, to: f.projectURL)
        // The camera file inside the project folder under media/, the bed in
        // a folder Mike picks, next to an impostor with the same name.
        try FileManager.default.createDirectory(at: f.inVideo("media/source"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.outside("source/take1-camera.mov"), to: f.inVideo("media/source/take1-camera.mov"))
        let picked = f.root.appendingPathComponent("picked", isDirectory: true)
        try f.make(picked.appendingPathComponent("a/bed.m4a"), seed: 77)
        try FileManager.default.createDirectory(at: picked.appendingPathComponent("b"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.outside("music/bed.m4a"), to: picked.appendingPathComponent("b/bed.m4a"))
        try f.make(picked.appendingPathComponent("loose.wav"), seed: 5)
        try f.make(picked.appendingPathComponent("x/twice.wav"), seed: 6)
        try f.make(picked.appendingPathComponent("y/twice.wav"), seed: 7)

        let session = try ProjectSession.open(f.projectURL, owner: .cli)
        session.autosaveDelay = 3600
        let service = TandemService(session: session, mode: .hosted, analysis: FakeAnalysis(), renderer: FakeRenderer())
        // Mike's real shared library stays out of it.
        service.locateSharedLibrary = { nil }
        defer {
            service.shutdown()
            session.close()
        }
        let context = CallContext(author: "claude")

        let inFolder = try await service.relink(RelinkRequest(dryRun: true), context: context)
        XCTAssertEqual(inFolder.relinked.map(\.to), ["media/source/take1-camera.mov"])
        XCTAssertEqual(service.coordinator.revision, 1, "a dry run changes nothing")

        let result = try await service.relink(RelinkRequest(search: [picked.path]), context: context)
        let found = Dictionary(uniqueKeysWithValues: result.relinked.map { ($0.mediaID, $0.to) })
        XCTAssertEqual(found["med_cam"], "media/source/take1-camera.mov")
        XCTAssertEqual(found["med_bed"], picked.appendingPathComponent("b/bed.m4a").path, "the one with the same content")
        XCTAssertEqual(found["med_loose"], picked.appendingPathComponent("loose.wav").path, "the only file of that name")
        XCTAssertEqual(result.missing.map(\.mediaID), ["med_twice"])
        XCTAssertEqual(result.missing.first?.ambiguous, true)
        XCTAssertEqual(result.applied?.label, "Relink 3 missing files")
        XCTAssertEqual(service.coordinator.project.media("med_bed")?.path, picked.appendingPathComponent("b/bed.m4a").path)
        XCTAssertTrue(result.readableText.contains("Relinked 3 of 4 missing files"), result.readableText)
        XCTAssertTrue(result.readableText.contains("several files have that name"), result.readableText)

        let nothing = try await service.relink(RelinkRequest(search: [picked.path]), context: context)
        XCTAssertEqual(nothing.relinked, [])
        do {
            _ = try await service.relink(RelinkRequest(search: [f.root.appendingPathComponent("nope").path]), context: context)
            XCTFail("a folder that isn't there")
        } catch {
            XCTAssertEqual((error as? ServiceError)?.code, "notFound", "\(error)")
        }
    }
}

/// `tandem archive` and `tandem relink`, run as Mike and agents run them.
final class ArchiveCLITests: XCTestCase {
    func testArchiveAndRelinkFromTheCommandLine() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        let cli = CLITests()
        let f = try ArchiveFixture(write: false)
        var project = try f.standardProject()
        // A font every Mac has, so nothing on this Mac is looked for.
        project.videoTracks[3].clips[0].content = .text(TextContent(text: "hi", style: TextStyle(font: "Helvetica")))
        try ProjectFile.save(project, revision: 1, to: f.projectURL)
        let env = ["TANDEM_ASSETS_ROOT": f.root.appendingPathComponent("library").path]

        let dry = try cli.tandem("archive", "--dry-run", in: f.video, env: env)
        XCTAssertEqual(dry.status, 0, dry.stderr)
        XCTAssertTrue(dry.stdout.hasPrefix("Dry run, nothing changed."), dry.stdout)
        XCTAssertTrue(dry.stdout.contains("media/music/bed.m4a"), dry.stdout)
        XCTAssertEqual(try f.load().revision, 1)

        let misuse = try cli.tandem("archive", "--with-cache", in: f.video, env: env)
        XCTAssertEqual(misuse.status, 2)
        XCTAssertTrue(misuse.stderr.contains("--with-cache keeps proxies and mattes in a copy made with --to"), misuse.stderr)

        let shelf = f.root.appendingPathComponent("shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        let archived = try cli.tandem("archive", f.projectURL.path, "--to", "../shelf", "--json", in: f.video, env: env)
        XCTAssertEqual(archived.status, 0, archived.stderr)
        let copy = try ServiceJSON.decoder().decode(ArchiveResult.self, from: Data(archived.stdout.utf8))
        XCTAssertEqual(copy.mode, .archive)
        XCTAssertTrue(copy.folder.hasSuffix("/shelf/video"), copy.folder)
        XCTAssertEqual(try ProjectFile.load(from: URL(fileURLWithPath: copy.projectFile)).project.media.first { $0.id == "med_bed" }?.path, "media/music/bed.m4a")
        XCTAssertEqual(try f.load().revision, 1, "the original is left alone")

        let consolidated = try cli.tandem("archive", "--author", "claude", in: f.video, env: env)
        XCTAssertEqual(consolidated.status, 0, consolidated.stderr)
        XCTAssertTrue(consolidated.stdout.hasPrefix("Video.tandem is standalone: brought in 5 files"), consolidated.stdout)
        let history = try cli.tandem("history", in: f.video)
        XCTAssertTrue(history.stdout.contains("Bring 5 files into the project folder  (claude)"), history.stdout)

        // Tidied away by hand, then found again.
        let elsewhere = f.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: f.inVideo("media/music/bed.m4a"), to: elsewhere.appendingPathComponent("bed.m4a"))
        let relinked = try cli.tandem("relink", "--search", "../elsewhere", in: f.video)
        XCTAssertEqual(relinked.status, 0, relinked.stderr)
        XCTAssertTrue(relinked.stdout.contains("Relinked 1 of 2 missing files"), relinked.stdout)
        XCTAssertTrue(relinked.stdout.contains("med_gone"), relinked.stdout)
        let relinkedPath = try XCTUnwrap(try f.load().project.media("med_bed")?.path)
        XCTAssertEqual(ProjectArchiver.realPath(URL(fileURLWithPath: relinkedPath)), ProjectArchiver.realPath(elsewhere.appendingPathComponent("bed.m4a")))

        let help = try cli.tandem("help", "archive", in: f.video)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: tandem archive [<project>] [--to <folder>] [--with-cache] [--dry-run]"), help.stdout)
    }
}
