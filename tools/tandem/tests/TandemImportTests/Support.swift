import Foundation
import XCTest
@testable import TandemCore
@testable import TandemImport

func t(_ seconds: Double) -> Time { Time(seconds: seconds) }

/// A prober that knows media by file name, so tests need no media files.
struct FakeProbe: MediaProbing {
    var media: [String: ProbedMedia]
    /// Names that exist on "disk" but can't be decoded, like WebM stickers.
    var undecodable: Set<String> = []

    func exists(_ url: URL) -> Bool {
        media[url.lastPathComponent] != nil || undecodable.contains(url.lastPathComponent)
    }

    func probe(_ url: URL) async throws -> ProbedMedia {
        if undecodable.contains(url.lastPathComponent) {
            throw ImportError.unreadable("\(url.lastPathComponent) (fake: undecodable)")
        }
        guard let found = media[url.lastPathComponent] else {
            throw ImportError.unreadable("\(url.lastPathComponent) (fake: no such file)")
        }
        return found
    }
}

enum Fixtures {
    static var folder: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    static func url(_ relative: String) -> URL {
        folder.appendingPathComponent(relative)
    }

    /// A fresh temporary folder, removed by the caller.
    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Zips `folder`'s contents with /usr/bin/zip. `store` keeps entries
    /// uncompressed, as some Filmora versions do.
    static func zip(_ folder: URL, to archive: URL, store: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folder
        process.arguments = ["-q", "-r", store ? "-0" : "-9", archive.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip failed")
    }
}

func assertValid(_ project: Project, file: StaticString = #filePath, line: UInt = #line) {
    let errors = ProjectValidator.validate(project).filter { $0.severity == .error }
    if !errors.isEmpty {
        XCTFail("Project invalid: \(errors.prefix(10).map(\.message).joined(separator: "; "))", file: file, line: line)
    }
}

extension Project {
    func clips(on trackName: String) -> [Clip] {
        track(named: trackName)?.clips ?? []
    }
}

func XCTAssertTime(_ actual: Time?, _ expected: Double, accuracy: Double = 0.0005, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else {
        XCTFail("nil time, expected \(expected) \(message)", file: file, line: line)
        return
    }
    XCTAssertEqual(actual.seconds, expected, accuracy: accuracy, message, file: file, line: line)
}
