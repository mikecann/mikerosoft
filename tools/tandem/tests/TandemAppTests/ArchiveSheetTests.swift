import AppKit
import SwiftUI
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

@MainActor
final class ArchiveSheetTests: XCTestCase {
    /// The sheet opens on a dry run, and making the folder standalone
    /// points the open project at the copies.
    func testTheSheetPlansThenMakesTheProjectStandalone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-sheet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bed = root.appendingPathComponent("outside/music/bed.m4a")
        try FileManager.default.createDirectory(at: bed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 5000).write(to: bed)
        let video = root.appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        var project = Project.standard(name: "Sheet")
        project.media = [MediaItem(id: "med_bed", path: bed.path, kind: .audio, role: .music, duration: Time(seconds: 30), hasAudio: true)]
        project.audioTracks[1].clips = [Clip(id: "clip_bed", content: .media(mediaID: "med_bed"), start: .zero, duration: Time(seconds: 10))]
        let url = video.appendingPathComponent("Sheet.tandem")
        try ProjectFile.save(project, revision: 1, to: url)
        let session = try ProjectSession.open(url, owner: .app)
        session.autosaveDelay = 3600
        defer { session.close() }

        let model = ArchiveSheetModel(session: session, projectName: "Sheet")
        model.destination = nil
        try await waitUntil { model.stage == .ready }
        XCTAssertEqual(model.mode, .copy)
        XCTAssertEqual(model.plan?.collected.map(\.path), ["media/music/bed.m4a"])
        XCTAssertFalse(model.canStart, "a copy needs somewhere to go")

        let shelf = root.appendingPathComponent("shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        model.destination = shelf
        try await waitUntil { model.stage == .ready }
        XCTAssertTrue(model.canStart)
        XCTAssertEqual(model.plan?.folder, shelf.appendingPathComponent("video").path)

        model.mode = .consolidate
        try await waitUntil { model.stage == .ready }
        XCTAssertTrue(model.canStart)
        let view = NSHostingView(rootView: ArchiveSheetView(model: model))
        XCTAssertEqual(view.fittingSize.width, 640)
        XCTAssertGreaterThan(view.fittingSize.height, 150)

        var finished: ArchiveResult?
        model.onFinished = { finished = $0 }
        model.start()
        try await waitUntil { model.stage == .done }
        XCTAssertEqual(finished?.mode, .consolidate)
        XCTAssertEqual(session.coordinator.project.media("med_bed")?.path, "media/music/bed.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.appendingPathComponent("media/music/bed.m4a").path))
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
