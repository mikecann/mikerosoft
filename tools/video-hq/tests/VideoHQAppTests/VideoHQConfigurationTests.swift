import Foundation
import XCTest
@testable import VideoHQApp

final class VideoHQConfigurationTests: XCTestCase {
    func testConfigurationLoadsQuotedOpenRouterKeyFromRepoDotenv() throws {
        let repoRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        try """
        # local tool credentials
        SOMETHING_ELSE=ignored
        OPENROUTER_API_KEY="sk-test-value"
        """.write(
            to: repoRoot.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )

        let configuration = try VideoHQConfiguration.load(
            repoRoot: repoRoot,
            environment: [:]
        )

        XCTAssertEqual(configuration.openRouterAPIKey, "sk-test-value")
        XCTAssertEqual(
            configuration.transcribeExecutableURL,
            repoRoot.appendingPathComponent("tools/transcribe/transcribe")
        )
    }

    func testConfigurationFallsBackToPrimaryCheckoutDotenv() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let worktree = directory.appendingPathComponent("worktree", isDirectory: true)
        let primary = directory.appendingPathComponent("primary", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let primaryDotenv = primary.appendingPathComponent(".env")
        try "OPENROUTER_API_KEY=sk-primary\n".write(
            to: primaryDotenv,
            atomically: true,
            encoding: .utf8
        )

        let configuration = try VideoHQConfiguration.load(
            repoRoot: worktree,
            fallbackDotenvURL: primaryDotenv,
            environment: [:]
        )

        XCTAssertEqual(configuration.openRouterAPIKey, "sk-primary")
    }
}
