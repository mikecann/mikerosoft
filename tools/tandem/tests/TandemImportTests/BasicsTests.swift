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
