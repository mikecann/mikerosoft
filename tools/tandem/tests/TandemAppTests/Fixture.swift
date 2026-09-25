import Foundation
import XCTest
@testable import TandemApp
@testable import TandemCore

func t(_ seconds: Double) -> Time { Time(seconds: seconds) }

/// Mike's usual timeline in miniature: a 60 s take (screen, camera and
/// camera sound, linked) from 0, a B-roll shot at 20 to 25, a music bed
/// under everything and a section marker at 30.
struct AppFixture {
    let coordinator: ProjectCoordinator

    var project: Project { coordinator.project }

    init() throws {
        let camera = MediaItem(
            id: "med_camera", path: "source/take1-camera.mov", kind: .video, role: .camera,
            takeID: "take1", takeOffset: t(0.5), duration: t(60), frameRate: .fps30,
            width: 3840, height: 2160, hasVideo: true, hasAudio: true
        )
        let screen = MediaItem(
            id: "med_screen", path: "source/take1-screen.mov", kind: .video, role: .screen,
            takeID: "take1", takeOffset: t(0), duration: t(61), frameRate: .fps30,
            width: 3200, height: 1800, hasVideo: true, hasAudio: true, variableFrameRate: true
        )
        let music = MediaItem(id: "med_music", path: "music/bed.mp3", kind: .audio, role: .music, duration: t(180), hasAudio: true)
        let broll = MediaItem(
            id: "med_broll", path: "broll/servers.mp4", kind: .video, role: .broll,
            duration: t(10), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true, hasAudio: true
        )
        var project = Project.standard(name: "Fixture")
        project.media = [camera, screen, music, broll]
        coordinator = ProjectCoordinator(project: project)
        try coordinator.apply(EditBatch(label: "Build", commands: [
            .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(60)),
            .placeMedia(mediaIDs: ["med_broll"], at: t(20), sourceStart: t(1), duration: t(5)),
            .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(60)),
            .addMarker(marker: Marker(id: "mk_s2", time: t(30), name: "Section 2", kind: .section))
        ]))
    }

    func track(_ name: String) -> Track { project.track(named: name)! }
    func clips(_ name: String) -> [Clip] { track(name).clips }
    func clip(_ name: String, _ index: Int = 0) -> Clip { clips(name)[index] }

    /// Cuts the take at the given times so tests have several clips a track.
    func blade(at times: [Double]) throws {
        try coordinator.apply(EditBatch(label: "Cuts", commands: times.map { .blade(at: t($0), clipIDs: [clip("Camera", 0).id]) }.reversed()))
    }

    @discardableResult
    func apply(_ batch: EditBatch?, file: StaticString = #filePath, line: UInt = #line) throws -> ProjectCoordinator.CommitResult {
        guard let batch else {
            XCTFail("expected an edit batch", file: file, line: line)
            throw EditError.invalid("no batch")
        }
        return try coordinator.apply(batch)
    }
}

func assertValid(_ project: Project, file: StaticString = #filePath, line: UInt = #line) {
    let errors = ProjectValidator.validate(project).filter { $0.severity == .error }
    if !errors.isEmpty {
        XCTFail("Project invalid: \(errors.map(\.message).joined(separator: "; "))", file: file, line: line)
    }
}
