import Foundation
import XCTest
@testable import RecordItApp

final class ProjectCatalogTests: XCTestCase {
    func testInitialDestinationIsTheNewestProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let older = root.appendingPathComponent("older-project", isDirectory: true)
        let newer = root.appendingPathComponent("newer-project", isDirectory: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: newer.path
        )

        let catalog = ProjectCatalog(
            projectsRoot: root,
            fallbackOutputRoot: root.appendingPathComponent("fallback")
        )

        XCTAssertEqual(try catalog.initialDestination().displayName, "newer-project")
    }

    func testPreparingProjectDestinationCreatesItsSourceDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("ai-tips", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let destination = ProjectDestination.project(directory: project, date: Date())

        let outputDirectory = try prepareOutputDirectory(for: destination)

        XCTAssertEqual(outputDirectory, project.appendingPathComponent("source", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDirectory.path))
    }
}
