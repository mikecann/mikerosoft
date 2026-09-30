import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

/// The timeline with a push on the B-roll track, drawn offscreen, to look
/// at:
///
///     TANDEM_TRANSITION_UI_OUT=~/dev/me/tandem-research/transitions/ui \
///     swift test --package-path tools/tandem --filter TransitionSnapshots
///
/// Without the variable it still draws them, so a timeline that can't be
/// drawn fails here rather than in the app.
@MainActor
final class TransitionSnapshots: XCTestCase {
    private var model: EditorModel!
    private var window: NSWindow!
    private var folder: URL!

    /// A take (camera, screen and voice) from 0 to 20 s with a fade from
    /// black at its head and a dissolve at 16 s; two B-roll shots meeting
    /// at 10 s with a 0.7 s push playing the light swoosh on SFX; a music
    /// bed. 100 points a second from 5 s, so the push is 70 points wide at
    /// 500.
    private func showTimeline(pixelsPerSecond: Double = 100, scroll: Double = 5) throws {
        guard NSScreen.screens.first != nil else { throw XCTSkip("no screen") }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-transition-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Transitions.tandem"), name: "Transitions", owner: .app)
        let model = EditorModel(session: session)
        self.model = model
        let fixture = try AppFixture()
        let swoosh = MediaItem(id: "med_swoosh", path: "assets/sfx/a-quick-light-swoosh-sweeping-from-left--rgm8r7d7.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)
        model.apply(EditBatch(label: "Media", commands: (fixture.project.media + [swoosh]).map { .addMedia(item: $0) }))
        model.apply(EditBatch(label: "Build", commands: [
            .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(20)),
            .placeMedia(mediaIDs: ["med_broll"], at: t(6), sourceStart: t(1), duration: t(4)),
            .placeMedia(mediaIDs: ["med_broll"], at: t(10), sourceStart: t(5), duration: t(4)),
            .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(20))
        ]))
        let camera = model.project.track(named: "Camera")!
        model.apply(EditBatch(label: "Cut", commands: [.blade(at: t(16), clipIDs: [camera.clips[0].id])]))
        let pieces = model.project.track(named: "Camera")!.clips
        let broll = model.project.track(named: "B-roll")!
        model.apply(EditBatch(label: "Transitions", commands: [
            .addTransition(trackID: broll.id, transition: Transition(id: "tr_push", type: .push, duration: t(0.7), fromClipID: broll.clips[0].id, toClipID: broll.clips[1].id),
                           sound: TransitionSound(mediaID: swoosh.id, gainDB: -23.3, offset: t(-0.39))),
            .addTransition(trackID: camera.id, transition: Transition(id: "tr_fade", type: .fadeFromBlack, duration: t(1), fromClipID: nil, toClipID: pieces[0].id)),
            .addTransition(trackID: camera.id, transition: Transition(id: "tr_dissolve", type: .dissolve, duration: t(0.5), fromClipID: pieces[0].id, toClipID: pieces[1].id))
        ]))
        model.timeline.fitPending = false
        model.timeline.scale = TimelineScale(pixelsPerSecond: pixelsPerSecond, scrollSeconds: scroll)
        window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1_400, height: 430), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = TimelineContainerView(model: model)
        window.orderBack(nil)
        settle()
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        model?.tearDown()
        _ = model?.session.close()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func settle() {
        for _ in 0..<12 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            CATransaction.flush()
        }
    }

    private var timeline: TimelineContainerView { window.contentView as! TimelineContainerView }

    private func snapshot(_ name: String) throws {
        settle()
        let view = timeline
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        XCTAssertGreaterThan(image.width, 1_000)
        guard let out = ProcessInfo.processInfo.environment["TANDEM_TRANSITION_UI_OUT"], !out.isEmpty else { return }
        let dir = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
        let view = timeline.lanes
        guard let event = NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }

    func testThePushOnTheTimeline() throws {
        try showTimeline()
        try snapshot("timeline-push")
        model.selectedTransitionID = "tr_push"
        try snapshot("timeline-push-selected")

        // Its right edge dragged 35 points: about 0.35 s more each side,
        // the length beside the pointer.
        let lane = try XCTUnwrap(timeline.layoutCache.lane(forTrack: model.project.track(named: "B-roll")!.id))
        let press = CGPoint(x: 534, y: lane.y + 4 - timeline.contentOrigin.y)
        mouse(.leftMouseDown, at: press)
        mouse(.leftMouseDragged, at: CGPoint(x: press.x + 20, y: press.y))
        mouse(.leftMouseDragged, at: CGPoint(x: press.x + 35, y: press.y))
        try snapshot("timeline-push-dragging")
        mouse(.leftMouseUp, at: CGPoint(x: press.x + 35, y: press.y))
        // 0.35 s is 11 frames at 30 fps: 22 either side of the cut.
        XCTAssertEqual(model.project.track(named: "B-roll")?.transitions.first?.duration, Time.frames(44, at: .fps30))
        try snapshot("timeline-push-longer")
    }

    func testThePushZoomedOut() throws {
        try showTimeline(pixelsPerSecond: 30, scroll: 0)
        try snapshot("timeline-push-zoomed-out")
    }
}
