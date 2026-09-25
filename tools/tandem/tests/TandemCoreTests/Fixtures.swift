import Foundation
@testable import TandemCore

func t(_ seconds: Double) -> Time { Time(seconds: seconds) }

/// A small version of Mike's usual timeline: a 60 s take (screen, camera and
/// camera audio, linked) with a B-roll shot, a music bed and a marker.
struct Fixture {
    var project: Project
    let camera: MediaItem
    let screen: MediaItem
    let music: MediaItem
    let broll: MediaItem

    init() {
        camera = MediaItem(
            id: "med_camera", path: "source/take1-camera.mov", kind: .video, role: .camera,
            takeID: "take1", takeOffset: t(0.5), duration: t(60), frameRate: .fps30,
            width: 3840, height: 2160, hasVideo: true, hasAudio: true
        )
        screen = MediaItem(
            id: "med_screen", path: "source/take1-screen.mov", kind: .video, role: .screen,
            takeID: "take1", takeOffset: t(0), duration: t(61), frameRate: .fps30,
            width: 3840, height: 2160, hasVideo: true, hasAudio: true, variableFrameRate: true
        )
        music = MediaItem(id: "med_music", path: "music/bed.m4a", kind: .audio, role: .music, duration: t(180), hasAudio: true)
        broll = MediaItem(
            id: "med_broll", path: "broll/servers.mp4", kind: .video, role: .broll,
            duration: t(10), frameRate: .fps30, hasVideo: true, hasAudio: true
        )
        project = Project.standard(name: "Fixture")
        project.media = [camera, screen, music, broll]
    }

    func track(_ name: String) -> Track { project.track(named: name)! }

    func clips(_ name: String) -> [Clip] { track(name).clips }

    /// Places the take at 0 (60 s), B-roll at 20...25 and music under it all.
    static func edited() throws -> (Fixture, ProjectCoordinator) {
        var fixture = Fixture()
        let coordinator = ProjectCoordinator(project: fixture.project)
        try coordinator.apply(EditBatch(label: "Build", commands: [
            .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(60)),
            .placeMedia(mediaIDs: ["med_broll"], at: t(20), sourceStart: t(1), duration: t(5)),
            .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(60)),
            .addMarker(marker: Marker(id: "mk_s2", time: t(30), name: "Section 2", kind: .section))
        ]))
        fixture.project = coordinator.project
        return (fixture, coordinator)
    }
}

extension ProjectCoordinator {
    @discardableResult
    func run(_ label: String = "Test", _ commands: EditCommand...) throws -> CommitResult {
        try apply(EditBatch(label: label, commands: commands))
    }

    func clips(_ trackName: String) -> [Clip] {
        project.track(named: trackName)!.clips
    }
}

func assertValid(_ project: Project, file: StaticString = #filePath, line: UInt = #line) {
    let errors = ProjectValidator.validate(project).filter { $0.severity == .error }
    if !errors.isEmpty {
        XCTFail("Project invalid: \(errors.map(\.message).joined(separator: "; "))", file: file, line: line)
    }
}

import XCTest
