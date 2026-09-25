import Foundation
import XCTest
@testable import TandemCore
@testable import TandemImport

final class CutComparisonTests: XCTestCase {
    /// A project with one camera file and voice clips at (timeline start, source start, length).
    func cut(_ voice: [(Double, Double, Double)]) throws -> Project {
        var project = Project.standard(name: "Cut")
        project.media = [MediaItem(id: "med_cam", path: "/v/take-camera.mov", kind: .video, role: .camera, duration: t(100), hasVideo: true, hasAudio: true)]
        let coordinator = ProjectCoordinator(project: project)
        try coordinator.apply(EditBatch(label: "Place", commands: voice.map { start, source, length in
            .placeMedia(mediaIDs: ["med_cam"], at: t(start), sourceStart: t(source), duration: t(length))
        }))
        return coordinator.project
    }

    func testMatchesVoiceBySourceRangeAndFindsAnchors() throws {
        let a = try cut([(0, 10, 5), (5, 20, 4), (9, 40, 2)])
        let b = try cut([(0, 10, 5), (5, 30, 3), (8, 40, 2)])
        let comparison = CutComparison.compare(a, named: "rebuild", b, named: "original", anchors: [
            ("second part", "/v/take-camera.mov", 20),
            ("third part", "/v/take-camera.mov", 40.5)
        ])
        XCTAssertEqual(comparison.matchedVoice, 2)
        XCTAssertEqual(comparison.voiceOnlyInA.map(\.sourceStart), [20])
        XCTAssertEqual(comparison.voiceOnlyInB.map(\.sourceStart), [30])
        XCTAssertEqual(comparison.a.duration, 11)
        XCTAssertEqual(comparison.b.duration, 10)
        XCTAssertEqual(comparison.drift.map(\.aMinusB), [0, 1], "the last shared clip sits a second later in the rebuild")
        XCTAssertEqual(comparison.anchors[0].a, 5)
        XCTAssertNil(comparison.anchors[0].b)
        XCTAssertEqual(comparison.anchors[1].a, 9.5)
        XCTAssertEqual(comparison.anchors[1].b, 8.5)
        XCTAssertEqual(comparison.anchors[1].delta, 1)
        XCTAssertTrue(comparison.text.contains("2 of 3"), comparison.text)
    }
}
