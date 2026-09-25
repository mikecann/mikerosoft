import AVFoundation
import XCTest
@testable import TandemApp
@testable import TandemCore

/// Builds a realistic project from real footage for looking at the app:
///
///     TANDEM_DEMO_OUT="/private/tmp/claude-501/tandem-app/Decision Models.tandem" \
///     TANDEM_DEMO_MEDIA=~/dev/convex/convex-videos/decision-models \
///     swift test --package-path tools/tandem --filter DemoProjectBuilder
///
/// Skipped unless `TANDEM_DEMO_OUT` is set. The media is only read.
final class DemoProjectBuilder: XCTestCase {
    func testBuildDemoProject() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let out = environment["TANDEM_DEMO_OUT"], !out.isEmpty else {
            throw XCTSkip("Set TANDEM_DEMO_OUT to build the demo project")
        }
        let root = URL(fileURLWithPath: NSString(string: environment["TANDEM_DEMO_MEDIA"] ?? "~/dev/convex/convex-videos/decision-models").expandingTildeInPath)
        let url = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        func probe(_ relative: String, role: MediaRole, id: String, take: String? = nil) async throws -> MediaItem {
            let file = root.appendingPathComponent(relative)
            let asset = AVURLAsset(url: file)
            let duration = try await asset.load(.duration)
            let video = try await asset.loadTracks(withMediaType: .video).first
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            var width: Int?
            var height: Int?
            var rate: FrameRate?
            if let video {
                let size = try await video.load(.naturalSize)
                width = Int(size.width.rounded())
                height = Int(size.height.rounded())
                let fps = try await video.load(.nominalFrameRate)
                rate = fps > 0 ? FrameRate(Int64(fps.rounded())) : nil
            }
            let ext = file.pathExtension.lowercased()
            let kind: MediaKind = video == nil ? .audio : (["png", "jpg", "jpeg"].contains(ext) ? .image : .video)
            return MediaItem(
                id: id, path: file.path, kind: kind, role: role, takeID: take, takeOffset: take == nil ? nil : .zero,
                duration: Time(seconds: duration.seconds), frameRate: rate, width: width, height: height,
                hasVideo: video != nil, hasAudio: audio != nil, variableFrameRate: role == .screen
            )
        }

        let camera = try await probe("edit/main-camera.mov", role: .camera, id: "med_camera", take: "take_main")
        let screen = try await probe("edit/main-screen.mov", role: .screen, id: "med_screen", take: "take_main")
        let music = try await probe("music/c1a.mp3", role: .music, id: "med_music")
        let music2 = try await probe("music/c3b.mp3", role: .music, id: "med_music2")
        let broll = try await probe("broll/hf-decider.mp4", role: .broll, id: "med_broll")
        let broll2 = try await probe("broll/hf-laya.mp4", role: .broll, id: "med_broll2")
        let graphic = try await probe("motion-graphics/out/clip-02-B.mp4", role: .graphic, id: "med_gfx1")
        let graphic2 = try await probe("motion-graphics/out/clip-07-A.mp4", role: .graphic, id: "med_gfx2")
        let swipe = try await probe("sfx/swipe.wav", role: .sfx, id: "med_swipe")
        let pop = try await probe("sfx/in.wav", role: .sfx, id: "med_pop")

        var project = Project.standard(name: "Decision Models")
        project.media = [camera, screen, music, music2, broll, broll2, graphic, graphic2, swipe, pop]
        let coordinator = ProjectCoordinator(project: project)
        func run(_ label: String, _ commands: [EditCommand]) throws {
            try coordinator.apply(EditBatch(label: label, commands: commands))
        }
        func track(_ name: String) -> Track { coordinator.project.track(named: name)! }
        func clip(_ name: String, at seconds: Double) -> Clip { track(name).clip(at: t(seconds))! }

        // Six minutes of the take from 4:00 in, cut into sections.
        try run("Place take", [.placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, sourceStart: t(240), duration: t(360))])
        let cuts: [Double] = [38, 92, 150, 205, 262, 318]
        try run("Cut sections", cuts.reversed().map { .blade(at: t($0), clipIDs: [clip("Camera", at: 1).id]) })
        // Tighten a couple of pauses like an agent would.
        try coordinator.apply(EditBatch(label: "Tightened 2 pauses in §2", author: "claude", commands: [
            .rippleDeleteRange(range: TimeRange(start: t(120), end: t(121.2))),
            .rippleDeleteRange(range: TimeRange(start: t(70), end: t(70.8)))
        ]))
        try run("Layouts", [
            .applyLayout(clipIDs: [clip("Camera", at: 1).id], preset: .full),
            .applyLayout(clipIDs: [clip("Camera", at: 50).id], preset: .pipRight),
            .applyLayout(clipIDs: [clip("Camera", at: 100).id], preset: .pipRight),
            .applyLayout(clipIDs: [clip("Camera", at: 160).id], preset: .full),
            .applyLayout(clipIDs: [clip("Camera", at: 220).id], preset: .pipLeft),
            .applyLayout(clipIDs: [clip("Camera", at: 280).id], preset: .pipRight),
            .applyLayout(clipIDs: [clip("Camera", at: 330).id], preset: .split),
            .applyLayout(clipIDs: [clip("Screen", at: 330).id], preset: .split)
        ])
        try run("Zoom into the leaderboard", [
            .zoomToRegion(clipID: clip("Screen", at: 100).id, rect: Rect(x: 0.1, y: 0.2, width: 0.6, height: 0.6), at: t(100), duration: t(0.6)),
            .zoomToRegion(clipID: clip("Screen", at: 100).id, rect: Rect(x: 0, y: 0, width: 1, height: 1), at: t(114), duration: t(0.6))
        ])
        try run("Dissolves", [
            .addTransition(trackID: track("Camera").id, transition: Transition(id: "tr_a", type: .dissolve, duration: t(0.5), fromClipID: clip("Camera", at: 147).id, toClipID: clip("Camera", at: 149).id)),
            .addTransition(trackID: track("Camera").id, transition: Transition(id: "tr_b", type: .cutSlide, duration: t(0.57), fromClipID: clip("Camera", at: 37).id, toClipID: clip("Camera", at: 39).id))
        ])
        try run("B-roll and graphics", [
            .placeMedia(mediaIDs: ["med_broll"], at: t(44), sourceStart: t(1), duration: t(6)),
            .placeMedia(mediaIDs: ["med_broll2"], at: t(236), sourceStart: t(0.5), duration: t(5)),
            .placeMedia(mediaIDs: ["med_gfx1"], at: t(88), duration: t(5)),
            .placeMedia(mediaIDs: ["med_gfx2"], at: t(170), duration: t(12))
        ])
        try run("Titles", [
            .insertClip(trackID: track("Text").id, clip: Clip(name: "Section card", content: .text(TextContent(text: "Decision evals", preset: "section", style: TextStyle(size: 72))), start: t(38.5), duration: t(3))),
            .insertClip(trackID: track("Text").id, clip: Clip(name: "Like + subscribe", content: .text(TextContent(text: "Like + subscribe", preset: "label", style: TextStyle(size: 44, color: RGBA(r: 0.05, g: 0.05, b: 0.06), backgroundColor: RGBA(r: 1, g: 0.7, b: 0.14)))), start: t(262.5), duration: t(2.5)))
        ])
        try run("Music and sound", [
            .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: music.duration.map { min($0, t(92)) }),
            .placeMedia(mediaIDs: ["med_music2"], at: t(150), duration: music2.duration.map { min($0, t(100)) }),
            .placeMedia(mediaIDs: ["med_swipe"], at: t(37.6)),
            .placeMedia(mediaIDs: ["med_pop"], at: t(88)),
            .placeMedia(mediaIDs: ["med_swipe"], at: t(170))
        ])
        let musicClip = clip("Music", at: 10)
        try run("Music fades", [
            .updateClip(clipID: musicClip.id, patch: .object(["audio": .object(["fadeIn": .number(1.5), "fadeOut": .number(3)])]))
        ])
        try run("Sections", [
            .addMarker(marker: Marker(id: "mk_1", time: .zero, name: "§1 The hook", kind: .section)),
            .addMarker(marker: Marker(id: "mk_2", time: t(38), name: "§2 Decision evals", kind: .section)),
            .addMarker(marker: Marker(id: "mk_3", time: t(148), name: "§3 The leaderboard", kind: .section)),
            .addMarker(marker: Marker(id: "mk_4", time: t(260), name: "§4 What it means", kind: .section))
        ])
        try coordinator.apply(EditBatch(label: "Moved the section card 0.4 s later", author: "claude", commands: [
            .moveClips(clipIDs: [clip("Text", at: 39).id], delta: t(0.4))
        ]))
        let errors = ProjectValidator.validate(coordinator.project).filter { $0.severity == .error }
        XCTAssertEqual(errors, [])
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try ProjectFile.save(coordinator.project, revision: coordinator.revision, to: url)
        print("Demo project written to \(url.path)")
    }
}
