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
        XCTAssertEqual(model.scriptDisplayMode, .raw)
        model.scriptDisplayMode = .preview
        XCTAssertEqual(model.scriptDisplayMode, .preview)
        XCTAssertEqual(model.selectedProject?.name, "AI Tips")
        XCTAssertEqual(model.projectScript, "# Script\n\nHello")
        XCTAssertEqual(model.videoURL?.lastPathComponent, "A.mp4")
        XCTAssertEqual(model.selectedPanel, .script)
    }

    func testLaunchLoadsNotionSourceWithoutShowingFrontMatter() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("AI Tips", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        ---
        notion_page_id: b55c9c91-384d-452b-81db-d1ef79372b75
        ---

        # Script

        Hello
        """.write(
            to: project.appendingPathComponent("script.md"),
            atomically: true,
            encoding: .utf8
        )
        let configuration = VideoHQConfiguration(
            repoRoot: root,
            projectsRoot: root,
            openRouterAPIKey: nil,
            notionAPIKey: nil,
            credentialDotenvURL: root.appendingPathComponent(".env")
        )

        let model = VideoHQModel(configuration: configuration)

        XCTAssertEqual(model.projectScript, "# Script\n\nHello")
        XCTAssertEqual(model.projectNotionPageID, "b55c9c91-384d-452b-81db-d1ef79372b75")
        XCTAssertEqual(model.notionScriptActionTitle, "Sync from Notion")
    }

    func testLaunchRestoresLastSelectedProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let aiTips = root.appendingPathComponent("AI Tips", isDirectory: true)
        let remembered = root.appendingPathComponent("Remember Me", isDirectory: true)
        try FileManager.default.createDirectory(at: aiTips, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remembered, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "video-hq-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = makeConfiguration(root: root)
        let preferences = VideoHQPreferences(defaults: defaults)

        let firstLaunch = VideoHQModel(configuration: configuration, preferences: preferences)
        firstLaunch.selectProject(remembered)
        let secondLaunch = VideoHQModel(configuration: configuration, preferences: preferences)

        XCTAssertEqual(secondLaunch.selectedProject?.name, "Remember Me")
    }

    func testLaunchFallsBackToFirstProjectWhenRememberedFolderIsGone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let aiTips = root.appendingPathComponent("AI Tips", isDirectory: true)
        try FileManager.default.createDirectory(at: aiTips, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "video-hq-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = VideoHQPreferences(defaults: defaults)
        preferences.lastSelectedProjectURL = root.appendingPathComponent("Deleted Project", isDirectory: true)

        let model = VideoHQModel(
            configuration: makeConfiguration(root: root),
            preferences: preferences
        )

        XCTAssertEqual(model.selectedProject?.name, "AI Tips")
        XCTAssertEqual(preferences.lastSelectedProjectURL, aiTips)
    }

    private func makeConfiguration(root: URL) -> VideoHQConfiguration {
        VideoHQConfiguration(
            repoRoot: root,
            projectsRoot: root,
            openRouterAPIKey: nil,
            notionAPIKey: nil,
            credentialDotenvURL: root.appendingPathComponent(".env")
        )
    }
}
