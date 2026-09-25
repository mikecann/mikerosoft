import Foundation
import XCTest
@testable import TandemCore
@testable import TandemImport

final class ZipReaderTests: XCTestCase {
    func testReadsDeflatedAndStoredEntries() throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let content = folder.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: content.appendingPathComponent("ProjectFolder"), withIntermediateDirectories: true)
        let json = String(repeating: "{\"tlBegin\": 1234567890, \"name\": \"camera\"}\n", count: 200)
        try Data(json.utf8).write(to: content.appendingPathComponent("ProjectFolder/timeline.json"))
        try Data().write(to: content.appendingPathComponent("empty.txt"))
        for store in [false, true] {
            let archive = folder.appendingPathComponent(store ? "stored.zip" : "deflated.zip")
            try Fixtures.zip(content, to: archive, store: store)
            let zip = try ZipReader(url: archive)
            XCTAssertTrue(zip.contains("ProjectFolder/timeline.json"), "\(zip.names)")
            XCTAssertEqual(String(decoding: try zip.read("ProjectFolder/timeline.json"), as: UTF8.self), json)
            XCTAssertEqual(try zip.read("empty.txt"), Data())
            if !store {
                let entry = zip.entries.first { $0.name == "ProjectFolder/timeline.json" }!
                XCTAssertEqual(entry.method, 8, "the repetitive JSON should have been deflated")
            }
        }
    }

    func testRejectsNonZipData() {
        XCTAssertThrowsError(try ZipReader(data: Data("not a zip file at all, just text".utf8)))
        XCTAssertThrowsError(try ZipReader(data: Data()))
    }

    func testMissingEntryThrows() throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let content = folder.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: content.appendingPathComponent("a.txt"))
        let archive = folder.appendingPathComponent("a.zip")
        try Fixtures.zip(content, to: archive)
        XCTAssertThrowsError(try ZipReader(url: archive).read("b.txt"))
    }
}

final class JSONNodeTests: XCTestCase {
    func testForgivingAccessors() {
        let node = JSONNode(jsonString: #"{"a": 6673099980, "b": 1.5, "c": true, "d": "0.25", "e": [1, {"f": "g"}], "pip": "{\"Opacity\": 50.0}"}"# + "\u{0}\u{0}")
        XCTAssertEqual(node["a"].int64, 6_673_099_980)
        XCTAssertEqual(node["b"].double, 1.5)
        XCTAssertEqual(node["c"].bool, true)
        XCTAssertNil(node["c"].double, "a bool isn't a number")
        XCTAssertEqual(node["d"].double, 0.25)
        XCTAssertEqual(node["e"][1]["f"].string, "g")
        XCTAssertFalse(node["e"][5].exists)
        XCTAssertFalse(node["missing"]["deeper"].exists)
        XCTAssertEqual(node["pip"].embedded["Opacity"].double, 50)
        XCTAssertEqual(JSONNode(1).bool, true)
        XCTAssertEqual(JSONNode(0).bool, false)
    }
}

final class SnifferTests: XCTestCase {
    func testRecognisesContainersByContent() {
        XCTAssertEqual(FileSniffer.sniff(bytes: Array("ID3\u{3}\u{0}\u{0}\u{0}\u{0}".utf8))?.fileExtension, "mp3")
        XCTAssertEqual(FileSniffer.sniff(bytes: [0xFF, 0xFB, 0x90, 0x64])?.fileExtension, "mp3")
        XCTAssertEqual(FileSniffer.sniff(bytes: [0, 0, 0, 0x20] + Array("ftypM4A ".utf8))?.fileExtension, "m4a")
        XCTAssertEqual(FileSniffer.sniff(bytes: [0, 0, 0, 0x14] + Array("ftypqt  ".utf8))?.fileExtension, "mov")
        XCTAssertEqual(FileSniffer.sniff(bytes: Array("RIFF\u{0}\u{0}\u{0}\u{0}WAVE".utf8))?.fileExtension, "wav")
        XCTAssertEqual(FileSniffer.sniff(bytes: [0x1A, 0x45, 0xDF, 0xA3, 0, 0])?.fileExtension, "webm")
        XCTAssertEqual(FileSniffer.sniff(bytes: [0x89] + Array("PNG\r\n".utf8))?.kind, .image)
        XCTAssertNil(FileSniffer.sniff(bytes: Array("hello world".utf8)))
    }

    func testFrameRatesSnapToExactFractions() {
        XCTAssertEqual(AVFoundationProbe.frameRate(29.97003), FrameRate(30000, 1001))
        XCTAssertEqual(AVFoundationProbe.frameRate(29.9913), FrameRate(30))
        XCTAssertEqual(AVFoundationProbe.frameRate(25.0), FrameRate(25))
        XCTAssertEqual(AVFoundationProbe.frameRate(18.8), FrameRate(18800, 1000))
        XCTAssertNil(AVFoundationProbe.frameRate(0))
    }
}

final class ImportReportTests: XCTestCase {
    func testRepeatsAreGroupedWithTheirFirstTimes() {
        var report = ImportReport(source: "x.wfp", importer: "filmora", projectName: "X")
        for i in 0..<12 {
            report.add(.unsupported, "effect", "Mosaic isn't supported.", at: t(Double(i)))
        }
        report.add(.approximated, "transition", "Twirl played as a dissolve.", at: t(3))
        XCTAssertEqual(report.items.count, 2)
        XCTAssertEqual(report.items[0].count, 12)
        XCTAssertEqual(report.items[0].at.count, 8, "only the first few times are kept")
        XCTAssertEqual(report.count(.unsupported), 12)
        let text = report.text
        XCTAssertTrue(text.contains("Mosaic isn't supported. (x12) at 00:00.000"), text)
        XCTAssertTrue(text.contains("Approximated (1):"), text)
    }
}

final class MediaCatalogTests: XCTestCase {
    func testFindsMovedFilesAndKeepsMissingOnesOffline() async {
        let probe = FakeProbe(media: ["camera.mov": .video(60)], undecodable: ["sticker.webm"])
        let catalog = MediaCatalog(locating: MediaLocating(
            prober: probe,
            pathRewrites: [.init(from: "/Users/mikeysee/", to: "/Users/someone/")]
        ))
        var report = ImportReport(source: "x", importer: "test", projectName: "X")

        guard case .found(let camera) = await catalog.resolve("/Users/mikeysee/videos/camera.mov", report: &report) else {
            return XCTFail("camera should be found")
        }
        XCTAssertEqual(camera.path, "/Users/mikeysee/videos/camera.mov", "the fake finds it at its original path first")
        XCTAssertEqual(camera.role, .camera)
        XCTAssertEqual(camera.duration, t(60))
        XCTAssertTrue(camera.id.hasPrefix("med_"))

        guard case .offline(let music) = await catalog.resolve("/gone/bed.mp3", role: .music, fallback: .audio(120), report: &report) else {
            return XCTFail("missing media with known facts should stay offline")
        }
        XCTAssertEqual(music.duration, t(120))
        XCTAssertEqual(music.role, .music)

        guard case .unusable = await catalog.resolve("/lib/sticker.webm", report: &report) else {
            return XCTFail("an undecodable file is unusable")
        }
        guard case .unusable = await catalog.resolve("/gone/nothing.mov", report: &report) else {
            return XCTFail("missing media with no facts is unusable")
        }
        XCTAssertEqual(catalog.items.map(\.path), ["/Users/mikeysee/videos/camera.mov", "/gone/bed.mp3"])
        XCTAssertEqual(report.count(.missingMedia), 2)
        XCTAssertEqual(report.count(.unsupported), 1)

        // Asking again gives the same item and reports nothing new.
        guard case .found(let again) = await catalog.resolve("/Users/mikeysee/videos/camera.mov", report: &report) else {
            return XCTFail()
        }
        XCTAssertEqual(again.id, camera.id)
        XCTAssertEqual(report.items.reduce(0) { $0 + $1.count }, 3)
    }

    func testCandidatesIncludeRewritesAndSearchFolders() throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("source"), withIntermediateDirectories: true)
        let catalog = MediaCatalog(locating: MediaLocating(
            prober: FakeProbe(media: [:]),
            pathRewrites: [.init(from: "/Users/mikeysee/", to: "/Users/m5-mike/")],
            searchFolders: [folder]
        ))
        let paths = catalog.candidates(for: "/Users/mikeysee/dev/a-camera.mov").map(\.path)
        XCTAssertEqual(paths[0], "/Users/mikeysee/dev/a-camera.mov")
        XCTAssertEqual(paths[1], "/Users/m5-mike/dev/a-camera.mov")
        // Directory listings resolve /var to /private/var, so compare ends.
        let name = folder.lastPathComponent
        XCTAssertTrue(paths.contains { $0.hasSuffix("/\(name)/a-camera.mov") }, "\(paths)")
        XCTAssertTrue(paths.contains { $0.hasSuffix("/\(name)/source/a-camera.mov") }, "\(paths)")
    }

    func testLibraryFilesFromAnotherMachineAreLookedForInThisLibrary() {
        let library = URL(fileURLWithPath: "/Users/me/Library/Filmora")
        let catalog = MediaCatalog(locating: MediaLocating(prober: FakeProbe(media: [:]), filmoraLibrary: library))
        let windows = "/C:/Users/mikec/Documents/Wondershare/Wondershare Filmora/Download/Filmora/audio/6_Gundam_Dash_01_SFX/Data/Gundam Dash 01 - SFX.wav"
        XCTAssertTrue(catalog.candidates(for: windows).map(\.path).contains("/Users/me/Library/Filmora/Download/Filmora/audio/6_Gundam_Dash_01_SFX/Data/Gundam Dash 01 - SFX.wav"))
        let custom = "/C:/Users/mikec/Documents/Wondershare/Wondershare Filmora/CustomResource/Compound Clip 1_17/Data/Medias/x/a.webp"
        XCTAssertTrue(catalog.candidates(for: custom).map(\.path).contains("/Users/me/Library/Filmora/CustomResource/Compound Clip 1_17/Data/Medias/x/a.webp"))
    }

    func testMissingFilesTandemCantPlayAreNotKeptOffline() async {
        let catalog = MediaCatalog(locating: MediaLocating(prober: FakeProbe(media: [:])))
        var report = ImportReport(source: "x", importer: "test", projectName: "X")
        guard case .unusable = await catalog.resolve("/gone/Sticker.webm", fallback: .video(4), report: &report) else {
            return XCTFail("a missing WebM sticker can't be relinked into something playable")
        }
        XCTAssertEqual(report.count(.unsupported), 1)
    }

    func testLinksFilesWithMisleadingExtensions() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appendingPathComponent("46_suno_uptown_flow/Data")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let cof = library.appendingPathComponent("downloadCommonCfg.cof")
        try Data("ID3\u{3}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}".utf8).write(to: cof)
        let links = folder.appendingPathComponent("links")
        let catalog = MediaCatalog(locating: MediaLocating(
            prober: FakeProbe(media: ["downloadCommonCfg.cof": .audio(200)]),
            aliasFolder: links
        ))
        var report = ImportReport(source: "x", importer: "test", projectName: "X")
        guard case .found(let item) = await catalog.resolve(cof.path, role: .music, report: &report) else {
            return XCTFail("the library file should be found")
        }
        XCTAssertEqual(item.path, links.appendingPathComponent("46_suno_uptown_flow.mp3").path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: item.path), cof.path)
    }
}

final class ImportRequestTests: XCTestCase {
    func testImportsAndWritesAProjectWithItsReport() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = ImportRequest(
            source: .filmora(Fixtures.url("wfp/Mini")),
            output: folder,
            prober: FakeProbe(media: FilmoraImporterTests.media, undecodable: ["Subscribe Element.webm"])
        )
        let (url, result) = try await request.perform()
        XCTAssertEqual(url.path, folder.appendingPathComponent("Mini Filmora/Mini Filmora.tandem").path)
        let loaded = try ProjectFile.load(from: url)
        XCTAssertEqual(loaded.project, result.project)
        let report = try JSONDecoder().decode(ImportReport.self, from: Data(contentsOf: folder.appendingPathComponent("Mini Filmora/Mini Filmora.import.json")))
        XCTAssertEqual(report, result.report)
        let text = try String(contentsOf: folder.appendingPathComponent("Mini Filmora/Mini Filmora.import.txt"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("Imported \"Mini Filmora\""), text)
    }

    func miniImport(into folder: URL) -> ImportRequest {
        ImportRequest(
            source: .filmora(Fixtures.url("wfp/Mini")),
            output: folder,
            prober: FakeProbe(media: FilmoraImporterTests.media, undecodable: ["Subscribe Element.webm"])
        )
    }

    func testImportingAgainNeverReplacesAnEditedProject() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (url, first) = try await miniImport(into: folder).perform()
        // Mike edits the import in Tandem, then runs the import again.
        var edited = first.project
        edited.markers.append(Marker(id: "mk_mike", time: t(1), name: "Mike's"))
        try ProjectFile.save(edited, revision: 12, to: url)

        do {
            _ = try await miniImport(into: folder).perform()
            XCTFail("an edited project must not be replaced")
        } catch {
            XCTAssertTrue("\(error)".contains("--name"), "says how to import beside it: \(error)")
        }
        let kept = try ProjectFile.load(from: url)
        XCTAssertEqual(kept.revision, 12)
        XCTAssertEqual(kept.project, edited)
    }

    func testImportingAgainNeverReplacesUnsavedEdits() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (url, first) = try await miniImport(into: folder).perform()
        // Edits made in a session that died before saving: still revision
        // 0 on disk, the edit only in the journal.
        let batch = EditBatch(label: "Marker", commands: [.addMarker(marker: Marker(id: "mk_mike", time: t(1), name: "Mike's"))])
        ProjectJournal.forProject(at: url).append(batch: batch, revision: 1, seed: 1)

        do {
            _ = try await miniImport(into: folder).perform()
            XCTFail("a project with unsaved edits must not be replaced")
        } catch {}
        XCTAssertEqual(try ProjectFile.load(from: url).project, first.project)
        XCTAssertEqual(ProjectJournal.forProject(at: url).entries(after: 0).count, 1)
    }

    func testAnUntouchedImportIsReplacedWithoutItsOldHistory() async throws {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (url, _) = try await miniImport(into: folder).perform()
        // Left over from an earlier project of this name that was deleted:
        // replayed on the new import, it would bring the old one back.
        var old = Project.standard(name: "Old")
        old.markers = [Marker(id: "mk_old", time: t(1), name: "Old")]
        try FileManager.default.removeItem(at: url)
        ProjectJournal.forProject(at: url).appendSnapshot(project: old, revision: 5, reason: "undo")

        let (again, result) = try await miniImport(into: folder).perform()
        XCTAssertEqual(again, url)
        XCTAssertEqual(ProjectJournal.forProject(at: url).entries(after: 0).count, 0)
        XCTAssertEqual(try ProjectFile.load(from: url).project, result.project)
    }

    func testNamesAreSafeForFiles() {
        XCTAssertEqual(ImportRequest.fileName("Decision Models v14"), "Decision Models v14")
        XCTAssertEqual(ImportRequest.fileName("a/b:c"), "a-b-c")
        XCTAssertEqual(ImportRequest.fileName("  "), "Imported")
    }
}

final class ProjectBuilderTests: XCTestCase {
    func testARejectedBatchStillAppliesItsGoodCommands() {
        var project = Project.standard(name: "Build")
        project.media = [MediaItem(id: "med_a", path: "/a.mov", kind: .video, role: .camera, duration: t(10), hasVideo: true, hasAudio: true)]
        let builder = ProjectBuilder(project: project, report: ImportReport(source: "x", importer: "test", projectName: "Build"))
        let camera = project.track(named: "Camera")!.id
        let failed = builder.apply("Place", [
            .init(.insertClip(trackID: camera, clip: Clip(id: "clip_a", content: .media(mediaID: "med_a"), start: t(0), duration: t(4))), "first"),
            .init(.insertClip(trackID: camera, clip: Clip(id: "clip_b", content: .media(mediaID: "med_a"), start: t(2), duration: t(4))), "overlapping", at: t(2)),
            .init(.insertClip(trackID: camera, clip: Clip(id: "clip_c", content: .media(mediaID: "med_a"), start: t(5), duration: t(4))), "third")
        ])
        XCTAssertEqual(failed, [1])
        XCTAssertEqual(builder.project.clips(on: "Camera").map(\.id), ["clip_a", "clip_c"])
        XCTAssertEqual(builder.report.count(.failed), 1)
        XCTAssertEqual(builder.report.items(.failed).first?.at, [2])
    }

    func testFreeTrackAddsTracksToAFamilyAsNeeded() {
        let builder = ProjectBuilder(project: Project.standard(name: "Build"), report: ImportReport(source: "x", importer: "test", projectName: "Build"))
        let first = builder.freeTrack(.audio, family: "SFX", range: TimeRange(start: t(0), end: t(1)))
        XCTAssertEqual(first, builder.project.track(named: "SFX")?.id, "an empty track of the family is used first")
        let text = builder.freeTrack(.video, family: "Text", range: TimeRange(start: t(0), end: t(1)))!
        builder.apply("Title", [.init(.insertClip(trackID: text, clip: Clip(content: .text(TextContent(text: "A")), start: t(0), duration: t(1))), "title")])
        let second = builder.freeTrack(.video, family: "Text", range: TimeRange(start: t(0.5), end: t(2)))
        XCTAssertNotEqual(second, text)
        XCTAssertEqual(builder.project.track(second!)?.name, "Text 2")
        XCTAssertEqual(builder.project.track(second!)?.rippleMode, .follow)
        let textIndex = builder.project.location(ofTrack: text)!.index
        XCTAssertEqual(builder.project.location(ofTrack: second!)!.index, textIndex + 1, "the new lane sits just above")
    }
}

final class FilmoraLaneTests: XCTestCase {
    /// Writes a one-track Filmora project whose clips are given as
    /// (begin, end, in) seconds, with ends in the form Filmora saves them.
    func project(clips: [(Double, Double, Double)], inclusiveEnds: Bool) throws -> URL {
        let folder = try Fixtures.temporaryFolder().appendingPathComponent("Lanes.wfp.dir")
        let medias = folder.appendingPathComponent("ProjectFolder/Medias/TL")
        try FileManager.default.createDirectory(at: medias, withIntermediateDirectories: true)
        let ticks = 10_000_000.0
        let clipJSON = clips.enumerated().map { index, clip in
            let end = Int64(clip.1 * ticks) - (inclusiveEnds ? 1 : 0)
            return """
            {"type": 1, "tlBegin": \(Int64(clip.0 * ticks)), "tlEnd": \(end), "inPoint": \(Int64(clip.2 * ticks)), "outPoint": \(Int64((clip.2 + clip.1 - clip.0) * ticks)), "thisUId": "c\(index)", "sourceUuid": "cam", "filename": "file://FIXTURE/take-camera.mov"}
            """
        }.joined(separator: ",")
        let timeline = """
        {"currentTimelineId": 1, "resources": [{"sourceUuid": "cam", "filename": "file://FIXTURE/take-camera.mov", "mediaLength": 1200000000, "streamType": 2, "videoStreamCount": 1}],
         "timelineInfos": [{"timelineId": 1, "trackInfos": [{"trackType": 1, "clipList": [\(clipJSON)]}]}]}
        """
        try Data(timeline.utf8).write(to: medias.appendingPathComponent("timeline.wesproj"))
        try Data(#"{"timeline_mediaId": "TL", "project_timeline_framerate": [30, 1], "project_timeline_resolution": [1920, 1080]}"#.utf8)
            .write(to: folder.appendingPathComponent("ProjectFolder/project_info.json"))
        return folder
    }

    func importLanes(_ url: URL) async throws -> ImportResult {
        try await FilmoraImporter(locating: MediaLocating(prober: FakeProbe(media: ["take-camera.mov": .video(120)]))).importProject(at: url)
    }

    func testClipsThatMeetStillMeetWhateverTheEndConvention() async throws {
        for inclusive in [true, false] {
            let url = try project(clips: [(0, 1.00001, 10), (1.00001, 2.5, 20), (2.5, 4, 30)], inclusiveEnds: inclusive)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let clips = try await importLanes(url).project.videoTracks[0].clips
            XCTAssertEqual(clips.count, 3)
            XCTAssertEqual(clips[0].end, clips[1].start, "inclusive: \(inclusive)")
            XCTAssertEqual(clips[1].end, clips[2].start, "inclusive: \(inclusive)")
        }
    }

    func testRealOverlapsGoToAnExtraTrack() async throws {
        let url = try project(clips: [(0, 3, 10), (2, 5, 20), (5, 6, 30)], inclusiveEnds: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = try await importLanes(url)
        assertValid(result.project)
        XCTAssertEqual(result.project.videoTracks.map(\.name), ["Camera", "Camera extra"])
        XCTAssertEqual(result.project.videoTracks.map { $0.clips.count }, [2, 1])
        XCTAssertEqual(result.report.count(.note) > 0, true)
    }
}
