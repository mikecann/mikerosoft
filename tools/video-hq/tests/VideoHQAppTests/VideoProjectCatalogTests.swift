import Foundation
import XCTest
@testable import VideoHQApp

final class VideoProjectCatalogTests: XCTestCase {
    func testDiscoverTreatsDirectFoldersAsProjectsAndFindsRootAssets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let alpha = root.appendingPathComponent("Alpha", isDirectory: true)
        let beta = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Alpha script".write(
            to: alpha.appendingPathComponent("script.md"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: alpha.appendingPathComponent("Final B.MP4"))
        try Data().write(to: alpha.appendingPathComponent("Final A.mp4"))
        let source = alpha.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("camera.mp4"))
        try "notes".write(
            to: beta.appendingPathComponent("video-script.txt"),
            atomically: true,
            encoding: .utf8
        )

        let projects = try VideoProjectCatalog(rootURL: root).discover()

        XCTAssertEqual(projects.map(\.name), ["Alpha", "beta"])
        XCTAssertEqual(projects[0].scriptURL?.lastPathComponent, "script.md")
        XCTAssertEqual(
            projects[0].renderedVideoURLs.map(\.lastPathComponent),
            ["Final A.mp4", "Final B.MP4"]
        )
        XCTAssertEqual(projects[1].scriptURL?.lastPathComponent, "video-script.txt")
    }
}
