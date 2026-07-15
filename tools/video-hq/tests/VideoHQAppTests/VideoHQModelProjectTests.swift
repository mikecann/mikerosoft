import Foundation
import XCTest
@testable import VideoHQApp

@MainActor
final class VideoHQModelProjectTests: XCTestCase {
    func testLaunchSelectsFirstProjectLoadsScriptAndFirstRootRender() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("AI Tips", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Script\n\nHello".write(
            to: project.appendingPathComponent("script.md"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: project.appendingPathComponent("B.mp4"))
        try Data().write(to: project.appendingPathComponent("A.mp4"))
        let configuration = VideoHQConfiguration(
            repoRoot: root,
            projectsRoot: root,
            openRouterAPIKey: nil,
            notionAPIKey: nil,
            credentialDotenvURL: root.appendingPathComponent(".env")
        )

        let model = VideoHQModel(configuration: configuration)

        XCTAssertEqual(model.projects.map(\.name), ["AI Tips"])
        XCTAssertEqual(model.selectedProject?.name, "AI Tips")
        XCTAssertEqual(model.projectScript, "# Script\n\nHello")
        XCTAssertEqual(model.videoURL?.lastPathComponent, "A.mp4")
        XCTAssertEqual(model.selectedPanel, .script)
    }
}
