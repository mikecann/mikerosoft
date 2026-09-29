import XCTest
@testable import TandemApp
@testable import TandemCore
@testable import TandemMedia

final class ActivityLogTests: XCTestCase {
    func testMirrorsTheUndoAndRedoStacks() {
        var log = ActivityLog()
        log.record(.edit, revision: 1, label: "Cut", author: "user")
        log.record(.edit, revision: 2, label: "Tightened pauses", author: "claude")
        log.record(.edit, revision: 3, label: "Marker", author: "user")
        XCTAssertEqual(log.recent.map(\.label), ["Marker", "Tightened pauses", "Cut"])
        XCTAssertEqual(log.lastAgentEntry?.label, "Tightened pauses")
        XCTAssertEqual(log.undoSteps(through: 2), 2)

        log.record(.undo, revision: 4, label: "Marker", author: "user")
        XCTAssertEqual(log.recent.map(\.label), ["Tightened pauses", "Cut"])
        XCTAssertEqual(log.undone.map(\.label), ["Marker"])
        log.record(.redo, revision: 5, label: "Marker", author: "user")
        XCTAssertEqual(log.recent.first?.label, "Marker")

        log.record(.undo, revision: 6, label: "Marker", author: "user")
        log.record(.edit, revision: 7, label: "Blade", author: "user")
        XCTAssertTrue(log.undone.isEmpty, "a new edit clears redo")
        log.record(.reload, revision: 8, label: "Reload", author: "system")
        XCTAssertTrue(log.recent.isEmpty)
    }

    func testMatchesTheCoordinatorsHistory() throws {
        let f = try AppFixture()
        var log = ActivityLog()
        let token = f.coordinator.observe { event in
            log.record(event.kind, revision: event.revision, label: event.label, author: event.author)
        }
        defer { f.coordinator.removeObserver(token) }
        try f.coordinator.apply(EditBatch(label: "One", commands: [.addMarker(marker: Marker(time: t(1), name: "A"))]))
        try f.coordinator.apply(EditBatch(label: "Two", author: "claude", commands: [.addMarker(marker: Marker(time: t(2), name: "B"))]))
        f.coordinator.undo()
        XCTAssertEqual(log.recent.map(\.label), f.coordinator.history().map(\.label).filter { $0 != "Build" })
    }

    func testDisplayNames() {
        XCTAssertEqual(ActivityLog.displayName("user"), "You")
        XCTAssertEqual(ActivityLog.displayName("system"), "Tandem")
        XCTAssertEqual(ActivityLog.displayName("claude"), "Claude")
    }
}

final class RecentProjectsTests: XCTestCase {
    func testNewestFirstWithoutDuplicates() {
        var recent = RecentProjects()
        recent.add("/videos/a/A.tandem")
        recent.add("/videos/b/B.tandem")
        recent.add("/videos/a/./A.tandem")
        XCTAssertEqual(recent.paths, ["/videos/a/A.tandem", "/videos/b/B.tandem"])
        for index in 0..<20 { recent.add("/videos/\(index).tandem") }
        XCTAssertEqual(recent.paths.count, RecentProjects.limit)
        XCTAssertEqual(recent.existing { $0.hasSuffix("19.tandem") }.map(\.lastPathComponent), ["19.tandem"])
    }

    func testVersionNames() {
        XCTAssertEqual(VersionNaming.nextName(after: "Decision Models.tandem", existing: []), "Decision Models v2.tandem")
        XCTAssertEqual(VersionNaming.nextName(after: "Decision Models v2.tandem", existing: []), "Decision Models v3.tandem")
        XCTAssertEqual(VersionNaming.nextName(after: "Video.tandem", existing: ["Video v2.tandem", "video v3.tandem"]), "Video v4.tandem")
        XCTAssertEqual(VersionNaming.exportName(projectFile: "Video v3.tandem", preset: "", existing: []), "Video v3.mp4")
        XCTAssertEqual(VersionNaming.exportName(projectFile: "Video.tandem", preset: "Short 9:16", existing: ["Video (Short 9:16).mp4"]), "Video (Short 9:16) 2.mp4")
    }

    func testVersionsSavedElsewhereStillFindTheirMedia() {
        var project = Project.standard(name: "Video")
        project.media = [
            MediaItem(id: "m1", path: "source/take-camera.mov", kind: .video, role: .camera, hasVideo: true, hasAudio: true),
            MediaItem(id: "m2", path: "/Volumes/Footage/broll.mp4", kind: .video, role: .broll, hasVideo: true)
        ]
        let folder = URL(fileURLWithPath: "/videos/static-hosting")

        let beside = VersionNaming.relocated(project, from: folder, to: folder)
        XCTAssertEqual(beside.media.map(\.path), ["source/take-camera.mov", "/Volumes/Footage/broll.mp4"])

        let inside = VersionNaming.relocated(project, from: folder, to: folder.appendingPathComponent("versions"))
        XCTAssertEqual(inside.media.map(\.path), ["/videos/static-hosting/source/take-camera.mov", "/Volumes/Footage/broll.mp4"])

        let above = VersionNaming.relocated(project, from: folder, to: URL(fileURLWithPath: "/videos"))
        XCTAssertEqual(above.media.map(\.path), ["static-hosting/source/take-camera.mov", "/Volumes/Footage/broll.mp4"])
        XCTAssertEqual(above.media.map(\.id), ["m1", "m2"])
    }

    func testProjectNamesFromFolders() {
        XCTAssertEqual(ProjectDocuments.projectName(forFolder: "decision-models"), "Decision models")
        XCTAssertEqual(ProjectDocuments.projectName(forFolder: "static_hosting"), "Static hosting")
    }
}

final class MediaCatalogTests: XCTestCase {
    func project() -> Project {
        var project = Project.standard(name: "Catalog")
        project.media = [
            MediaItem(id: "m1", path: "source/2026-09-24_105238-camera.mov", kind: .video, role: .camera, takeID: "b", duration: t(97), hasVideo: true, hasAudio: true),
            MediaItem(id: "m2", path: "source/2026-09-24_105238-screen.mov", kind: .video, role: .screen, takeID: "b", duration: t(98), hasVideo: true),
            MediaItem(id: "m3", path: "source/2026-09-24_102826-camera.mov", kind: .video, role: .camera, takeID: "a", duration: t(654), hasVideo: true, hasAudio: true),
            MediaItem(id: "m4", path: "source/2026-09-24_102826-screen.mov", kind: .video, role: .screen, takeID: "a", duration: t(655), hasVideo: true),
            MediaItem(id: "m5", path: "motion-graphics/out/clip-07-A.mp4", kind: .video, role: .graphic, duration: t(15), hasVideo: true),
            MediaItem(id: "m6", path: "music/c3b.mp3", kind: .audio, role: .music, duration: t(124), hasAudio: true),
            MediaItem(id: "m7", path: "broll/hf-decider.mp4", kind: .video, role: .broll, duration: t(8), hasVideo: true),
            MediaItem(id: "m8", path: "sfx/whoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)
        ]
        return project
    }

    func testTakesArePairedAndNumberedInTimeOrder() {
        let groups = MediaCatalog.groups(for: project())
        XCTAssertEqual(groups.map(\.kind), [.recordings, .graphics, .broll, .music, .sfx])
        let takes = groups[0].entries
        XCTAssertEqual(takes.map(\.title), ["Take 1 · 10:28", "Take 2 · 10:52"])
        XCTAssertEqual(takes[0].subtitle, "10:55 · 2 files")
        XCTAssertEqual(takes[0].mediaIDs, ["m3", "m4"], "camera first, then the screen")
        XCTAssertEqual(takes[0].secondaryMediaID, "m4")
        XCTAssertEqual(groups[1].detail, "motion-graphics/out")
        XCTAssertEqual(groups[3].entries.first?.subtitle, "2:04")
    }

    func testSearchMatchesTitlesAndFileNames() {
        XCTAssertEqual(MediaCatalog.groups(for: project(), search: "decider").flatMap(\.entries).map(\.id), ["m7"])
        XCTAssertEqual(MediaCatalog.groups(for: project(), search: "take 2").flatMap(\.entries).map(\.id), ["b"])
        XCTAssertEqual(MediaCatalog.groups(for: project(), search: "102826").flatMap(\.entries).map(\.id), ["a"])
        XCTAssertTrue(MediaCatalog.groups(for: project(), search: "nothing like this").isEmpty)
        XCTAssertEqual(MediaCatalog.groups(for: project(), only: .music).map(\.kind), [.music])
    }

    func testJobsNameTakesByTheirTime() {
        let project = project()
        XCTAssertEqual(JobText.describe(JobStatus(id: "j1", kind: .proxy, mediaID: "m1", state: .running, progress: 0.23), in: project), "Proxy camera 10:52 · 23%")
        XCTAssertEqual(JobText.describe(JobStatus(id: "j2", kind: .transcript, mediaID: "m3", state: .running), in: project), "Transcribing camera 10:28")
        XCTAssertEqual(JobText.describe(JobStatus(id: "j3", kind: .waveform, mediaID: "m6", state: .running, progress: 0.5), in: project), "Waveform c3b · 50%")
    }

    func testFilesFromTheAssetLibraryReadByTheirName() {
        XCTAssertEqual(MediaCatalog.displayName(forPath: "assets/sticker/rocket-x3iqg3mw.mov"), "rocket")
        XCTAssertEqual(MediaCatalog.displayName(forPath: "assets/music/c3b-pv9cnei3.mp3"), "c3b")
        XCTAssertEqual(MediaCatalog.displayName(forPath: "/Users/mike/videos/talk/assets/sfx/big-whoosh-abcdefgh.wav"), "big-whoosh")
        // Only the library's own copies lose their code.
        XCTAssertEqual(MediaCatalog.displayName(forPath: "broll/servers-x3iqg3mw.mp4"), "servers-x3iqg3mw")
        XCTAssertEqual(MediaCatalog.displayName(forPath: "assets/sticker/x3iqg3mw.mov"), "x3iqg3mw", "nothing left but the code")
        XCTAssertEqual(MediaCatalog.displayName(forPath: "music/c1a.mp3"), "c1a")
    }

    @MainActor
    func testClipsFromTheLibraryShowTheAssetsName() {
        var project = Project.standard(name: "Names")
        project.media = [MediaItem(id: "med_r", path: "assets/sticker/rocket-x3iqg3mw.mov", kind: .video, role: .sticker, duration: t(1), hasVideo: true)]
        // placeMedia names a clip after its file.
        var clip = Clip(name: "rocket-x3iqg3mw", content: .media(mediaID: "med_r"), start: .zero, duration: t(1))
        XCTAssertEqual(ClipRenderer.name(of: clip, in: project), "rocket")
        clip.name = "Launch"
        XCTAssertEqual(ClipRenderer.name(of: clip, in: project), "Launch", "a name someone chose stays")
    }

    func testTimeOfDayFromRecordItNames() {
        XCTAssertEqual(MediaCatalog.timeOfDay(fromFileName: "2026-09-24_102826-camera.mov"), "10:28")
        XCTAssertNil(MediaCatalog.timeOfDay(fromFileName: "main-camera.mov"))
    }
}

final class AppURLCommandTests: XCTestCase {
    func testParsesCommands() {
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://screenshot?out=/tmp/a.png")!), .screenshot(out: "/tmp/a.png"))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://command?name=bladeAtPlayhead")!), .command(.bladeAtPlayhead))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://seek?t=12.5")!), .seek(t(12.5)))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://select?clips=clip_a,clip_b")!), .select(clipIDs: ["clip_a", "clip_b"]))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://panel?inspector=color&library=effects")!), .panels(library: .effects, inspector: .colour, exportSheet: nil))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://panel?sheet=none")!), .panels(library: nil, inspector: nil, exportSheet: false))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://zoom?pps=40")!), .zoom(pixelsPerSecond: 40, scrollSeconds: nil))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://tool?name=slip")!), .tool(.slip))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://inout?in=2&out=5")!), .inOut(start: t(2), end: t(5)))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://new?folder=/videos/static-hosting")!), .newProject(folder: "/videos/static-hosting"))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://version?out=/videos/a/Video%20v2.tandem")!), .saveVersion(out: "/videos/a/Video v2.tandem"))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://debug?out=/tmp/tree.txt")!), .debug(out: "/tmp/tree.txt"))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://debug?out=/tmp/tree.txt&reset=1")!), .debug(out: "/tmp/tree.txt", resetTimings: true))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://window?order=back")!), .windowOrder(toFront: false))
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://window?order=sideways")!))
        XCTAssertEqual(
            AppURLCommand.parse(URL(string: "tandem://simulate?scroll=900,1100,-12,0&steps=90&interval=16")!),
            .simulate(InputSimulator.Gesture(kind: .scroll(dx: -12, dy: 0, steps: 90), at: CGPoint(x: 900, y: 1_100), modifiers: [], interval: 0.016))
        )
        XCTAssertEqual(
            AppURLCommand.parse(URL(string: "tandem://simulate?scroll=900,1100,0,4&mods=option")!),
            .simulate(InputSimulator.Gesture(kind: .scroll(dx: 0, dy: 4, steps: 1), at: CGPoint(x: 900, y: 1_100), modifiers: .option))
        )
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://assets?section=icons&search=rocket&online=1")!), .assets(section: .icons, search: "rocket", scope: nil, online: true))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://assets?section=sfx&scope=recent")!), .assets(section: .sfx, search: nil, scope: .recent, online: false))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://assets?section=looks")!), .assets(section: .looks, search: nil, scope: nil, online: false))
        XCTAssertEqual(AssetSection.fonts.libraryTab, .text, "fonts are in the Text tab")
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://assets?section=trumpets")!))
    }

    func testRejectsNonsense() {
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://command?name=launchRockets")!))
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://screenshot")!))
        XCTAssertNil(AppURLCommand.parse(URL(string: "https://example.com/screenshot?out=/tmp/a.png")!))
    }

    /// Any app or web page can open a tandem:// link, so commands that write
    /// files only write the kind of file they're for, at an absolute path.
    func testFileWritesStayInTheirLane() {
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://screenshot?out=/Users/mike/.zshrc")!))
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://screenshot?out=shot.png")!))
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://debug?out=/tmp/tree.png")!))
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://version?out=/tmp/Video.json")!))
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://version?out=Video%20v2.tandem")!))
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://new?folder=videos")!))
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://simulate?menu=10,10&out=/Users/mike/.zshrc")!))
        XCTAssertNotNil(AppURLCommand.parse(URL(string: "tandem://simulate?menu=10,10&out=/tmp/menu.txt")!))
        XCTAssertEqual(
            AppURLCommand.parse(URL(string: "tandem://simulate?drop=tandem-effect:vignette&at=600,700")!),
            .simulate(InputSimulator.Gesture(kind: .drop(payload: "tandem-effect:vignette"), at: CGPoint(x: 600, y: 700), modifiers: []))
        )
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://simulate?drop=hello&at=600,700")!), "only library payloads")
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://screenshot?out=/tmp/Shot.PNG")!), .screenshot(out: "/tmp/Shot.PNG"))
        XCTAssertEqual(AppURLCommand.parse(URL(string: "tandem://window?width=900&height=620")!), .windowSize(width: 900, height: 620))
        XCTAssertNil(AppURLCommand.parse(URL(string: "tandem://window?width=0&height=620")!))
        XCTAssertEqual(
            AppURLCommand.parse(URL(string: "tandem://simulate?type=Guest%20mic%0A")!),
            .simulate(InputSimulator.Gesture(kind: .type("Guest mic\n"), at: .zero, modifiers: []))
        )
        XCTAssertEqual(
            AppURLCommand.parse(URL(string: "tandem://simulate?menu=30,640&choose=Move%20up")!),
            .simulate(InputSimulator.Gesture(kind: .choose("Move up"), at: CGPoint(x: 30, y: 640), modifiers: []))
        )
    }
}

final class PauseTighteningTests: XCTestCase {
    /// Words at 0-1, 1.1-2, then a 1.5 s pause, then 3.5-4.
    func transcript() -> Transcript {
        Transcript(language: "en", engine: "test", words: [
            TranscriptWord(text: "we", start: t(0), end: t(1)),
            TranscriptWord(text: "have", start: t(1.1), end: t(2)),
            TranscriptWord(text: "evals", start: t(3.5), end: t(4)),
            TranscriptWord(text: "here", start: t(10.2), end: t(11))
        ])
    }

    func testFindsLongPausesInTimelineTime() throws {
        let f = try AppFixture()
        // The voice clip shows the camera file from 0, at timeline 0.
        let ranges = PauseTightening.ranges(in: f.project, transcript: { $0.id == "med_camera" ? self.transcript() : nil }, minimum: t(1), keep: t(0.2))
        XCTAssertEqual(ranges, [TimeRange(start: t(2.2), end: t(3.3)), TimeRange(start: t(4.2), end: t(10))])
        let batch = try XCTUnwrap(PauseTightening.batch(ranges))
        XCTAssertEqual(batch.commands.first, .rippleDeleteRange(range: TimeRange(start: t(4.2), end: t(10))), "latest first")
        try f.apply(batch)
        XCTAssertEqual(f.clips("Camera").map(\.range).last?.end, t(60) - t(1.1) - t(5.8))
        assertValid(f.project)
    }

    func testRespectsTheInOutRange() throws {
        let f = try AppFixture()
        let ranges = PauseTightening.ranges(in: f.project, transcript: { _ in self.transcript() }, minimum: t(1), keep: t(0.2), within: TimeRange(start: t(0), end: t(5)))
        XCTAssertEqual(ranges, [TimeRange(start: t(2.2), end: t(3.3)), TimeRange(start: t(4.2), end: t(5))])
    }
}

final class CanvasGeometryTests: XCTestCase {
    let canvas = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testFullAndPictureInPicture() {
        let full = CanvasGeometry.frame(source: CGSize(width: 3840, height: 2160), transform: Transform(), canvas: canvas)
        XCTAssertEqual(full, canvas)
        let pip = CanvasGeometry.frame(source: CGSize(width: 3840, height: 2160), transform: Transform(position: LayoutPreset.pipRightPosition, scale: 0.5), canvas: canvas)
        XCTAssertEqual(pip.width, 800)
        XCTAssertEqual(pip.midX, 1392, accuracy: 0.001)
        XCTAssertEqual(pip.midY, 693, accuracy: 0.001)
    }

    func testAspectFitAndCrop() {
        // A 16:10 screen recording on a 16:9 canvas fits by height.
        let screen = CanvasGeometry.frame(source: CGSize(width: 3200, height: 2000), transform: Transform(), canvas: canvas)
        XCTAssertEqual(screen.height, 900)
        XCTAssertEqual(screen.width, 1440)
        let cropped = CanvasGeometry.cropped(canvas, crop: Crop(left: 0.25, top: 0, right: 0.25, bottom: 0.1))
        XCTAssertEqual(cropped, CGRect(x: 400, y: 0, width: 800, height: 810))
    }

    func testCanvasFitsThePanel() {
        let rect = CanvasGeometry.canvasRect(in: CGRect(x: 0, y: 0, width: 882, height: 477), width: 3840, height: 2160)
        XCTAssertEqual(rect.height, 449)
        XCTAssertEqual(rect.midX, 441, accuracy: 1)
    }

    func testDragsAndZoomRectangles() {
        let moved = CanvasGeometry.moved(Transform(), by: CGSize(width: 160, height: -90), canvas: canvas)
        XCTAssertEqual(moved.position.x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(moved.position.y, 0.4, accuracy: 1e-9)
        let scaled = CanvasGeometry.scaled(Transform(scale: 0.5), centre: CGPoint(x: 800, y: 450), from: CGPoint(x: 1000, y: 450), to: CGPoint(x: 1200, y: 450))
        XCTAssertEqual(scaled.scale, 1, accuracy: 1e-9)
        let rect = CanvasGeometry.sourceRect(for: CGRect(x: 400, y: 225, width: 800, height: 450), clipFrame: canvas)
        XCTAssertEqual(rect, Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertNil(CanvasGeometry.sourceRect(for: CGRect(x: 5000, y: 0, width: 10, height: 10), clipFrame: canvas))
    }
}

final class SmallPieceTests: XCTestCase {
    func testTranscriptPhrasesBreakAtPauses() {
        let words: [(text: String, start: Time, end: Time)] = [
            ("so", t(0), t(0.2)), ("here", t(0.25), t(0.5)), ("we", t(1.5), t(1.6)), ("go", t(1.62), t(1.9))
        ]
        let phrases = TranscriptPhrase.group(words)
        XCTAssertEqual(phrases.map(\.text), ["so here", "we go"])
        XCTAssertEqual(phrases[1].start, t(1.5))
    }

    func testZoomedOutTranscriptShowsEveryFewPhrases() {
        // A phrase every 2 s; at 10 px a second each is 20 px wide.
        let phrases = (0..<10).map { TranscriptPhrase(text: "phrase \($0)", start: t(Double($0) * 2), end: t(Double($0) * 2 + 1.5)) }
        let groups = TranscriptPhrase.readableGroups(phrases, minWidth: 70) { CGFloat($0.seconds * 10) }
        // Each shown phrase gets at least 70 px before the next one shown.
        XCTAssertEqual(groups, [0..<4, 4..<8, 8..<10])
        // Zoomed in, every phrase has room of its own.
        let wide = TranscriptPhrase.readableGroups(phrases, minWidth: 70) { CGFloat($0.seconds * 100) }
        XCTAssertEqual(wide.count, 10)
        XCTAssertTrue(TranscriptPhrase.readableGroups([], minWidth: 70) { CGFloat($0.seconds) }.isEmpty)
    }

    func testMediaDragPayload() {
        XCTAssertEqual(MediaDrag.ids(from: MediaDrag.payload(["med_a", "med_b"])), ["med_a", "med_b"])
        XCTAssertEqual(MediaDrag.ids(from: "hello"), [])
    }

    func testInspectorPatchesApply() throws {
        let f = try AppFixture()
        let camera = f.clip("Camera")
        try f.apply(InspectorEdits.transform(camera.id, Transform(position: Point(x: 0.3, y: 0.4), scale: 0.7, rotation: 5), label: "Transform"))
        XCTAssertEqual(f.clip("Camera").video?.transform, Transform(position: Point(x: 0.3, y: 0.4), scale: 0.7, rotation: 5))
        try f.apply(InspectorEdits.shadowOpacity(f.clip("Camera"), percent: 40, newID: "fx_shadow"))
        XCTAssertEqual(f.clip("Camera").video?.effects.first?.params["opacity"], .number(40))
        try f.apply(InspectorEdits.shadowOpacity(f.clip("Camera"), percent: 70))
        XCTAssertEqual(f.clip("Camera").video?.effects.count, 1, "the second change edits the same shadow")
        XCTAssertEqual(f.clip("Camera").video?.effects.first?.params["opacity"], .number(70))
        try f.apply(InspectorEdits.audio([f.clip("Voice").id], ["gainDB": .number(-3)], label: "Gain"))
        XCTAssertEqual(f.clip("Voice").audio?.gainDB, -3)
        XCTAssertEqual(f.clip("Voice").audio?.normalizeTo, -20, "untouched fields stay")
        let look = [Effect(id: "fx_look", type: "colorAdjust", params: ["contrast": .number(8)])]
        try f.apply(InspectorEdits.look("med_camera", look, label: "Look"))
        let item = try XCTUnwrap(f.project.media("med_camera"))
        try f.apply(InspectorEdits.lookParam(item, effectID: "fx_look", key: "contrast", value: .number(12), label: "Look"))
        XCTAssertEqual(f.project.media("med_camera")?.look.first?.params["contrast"], .number(12))
    }

    func testParamFormatting() {
        let definition = EffectRegistry.standard.definition("dropShadow")!
        XCTAssertEqual(ParamFormatting.format(60, definition.param("opacity")!), "60%")
        XCTAssertEqual(ParamFormatting.format(4, definition.param("distance")!), "4 px")
        let colour = EffectRegistry.standard.definition("colorAdjust")!
        XCTAssertEqual(ParamFormatting.format(0.1, colour.param("exposure")!), "+0.10")
        XCTAssertEqual(ParamFormatting.format(-8, colour.param("contrast")!), "−8")
    }

    func testLowercasedFirstKeepsAcronyms() {
        XCTAssertEqual("Move clip".lowercasedFirst, "move clip")
        XCTAssertEqual("PiP right".lowercasedFirst, "PiP right")
    }
}

final class AgentPresenceTests: XCTestCase {
    func testChipFollowsTheLastContact() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(AgentChipState.of(nil, serving: true, now: now), .idle(serving: true))
        XCTAssertEqual(AgentChipState.of(nil, serving: true, now: now).detail, "not connected")
        XCTAssertEqual(AgentChipState.of(nil, serving: false, now: now).detail, "API off")

        // A screenshot a minute ago.
        var presence = AgentPresence(author: "claude", lastSeen: now.addingTimeInterval(-60))
        XCTAssertEqual(AgentChipState.of(presence, serving: true, now: now), .connected(name: "Claude"))

        presence.edited(by: "claude", section: "§4", at: now.addingTimeInterval(-5))
        let editing = AgentChipState.of(presence, serving: true, now: now)
        XCTAssertEqual(editing, .editing(name: "Claude", section: "§4"))
        XCTAssertEqual(editing.name, "Claude")
        XCTAssertEqual(editing.detail, "is editing §4")
        XCTAssertTrue(editing.isActive)

        // An edit that lands nowhere in particular keeps the last section.
        presence.edited(by: "claude", section: nil, at: now)
        XCTAssertEqual(presence.section, "§4")

        XCTAssertEqual(AgentChipState.of(presence, serving: true, now: now.addingTimeInterval(120)), .connected(name: "Claude"))
        let later = AgentChipState.of(presence, serving: true, now: now.addingTimeInterval(3_600))
        XCTAssertEqual(later, .edited(name: "Claude", at: now))
        XCTAssertFalse(later.isActive)

        // Only looked, long ago.
        let looked = AgentPresence(author: "codex", lastSeen: now.addingTimeInterval(-3_600))
        XCTAssertEqual(AgentChipState.of(looked, serving: true, now: now), .idle(serving: true))
    }

    func testMCPConfigPointsAtTheProject() throws {
        let text = ActivityFeed.mcpConfig(for: URL(fileURLWithPath: "/videos/a/Video v2.tandem"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let server = try XCTUnwrap((object["mcpServers"] as? [String: Any])?["tandem"] as? [String: Any])
        XCTAssertEqual(server["args"] as? [String], ["mcp", "--project", "/videos/a/Video v2.tandem"])
        XCTAssertEqual((server["command"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }, "tandem")
    }

    func testAnyCallOrOpenWatchCountsAsConnected() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var presence = AgentPresence(author: "cli", lastSeen: now.addingTimeInterval(-3_600))
        XCTAssertEqual(AgentChipState.of(presence, serving: true, now: now), .idle(serving: true))
        // A status read a moment ago.
        presence.looked(by: "claude", at: now.addingTimeInterval(-2))
        XCTAssertEqual(AgentChipState.of(presence, serving: true, now: now), .connected(name: "Claude"))
        // An hour later it's gone quiet, unless it keeps a watch stream open.
        let later = now.addingTimeInterval(3_600)
        XCTAssertEqual(AgentChipState.of(presence, serving: true, now: later), .idle(serving: true))
        XCTAssertEqual(AgentChipState.of(presence, serving: true, watching: true, now: later), .connected(name: "Claude"))
        // Nobody has called yet, but something is watching.
        XCTAssertEqual(AgentChipState.of(nil, serving: true, watching: true, now: now), .connected(name: "Agent"))
    }

    func testNamesForAgentsAndTools() {
        XCTAssertEqual(ActivityLog.displayName("claude"), "Claude")
        XCTAssertEqual(ActivityLog.displayName("cli"), "CLI")
        XCTAssertEqual(ActivityLog.displayName("mcp"), "MCP")
        XCTAssertEqual(ActivityLog.displayName("user"), "You")
        XCTAssertEqual(ActivityLog.displayName("system"), "Tandem")
    }

    func testChangeRegionNamesTheSection() throws {
        let fixture = try AppFixture()
        try fixture.coordinator.apply(EditBatch(label: "Sections", commands: [
            .addMarker(marker: Marker(id: "mk_s1", time: .zero, name: "§1 The hook", kind: .section))
        ]))
        let before = fixture.project
        XCTAssertNil(ChangeRegion.between(before, before))

        try fixture.coordinator.apply(EditBatch(label: "Remove B-roll", commands: [.removeClips(clipIDs: [fixture.clip("B-roll").id])]))
        let removed = try XCTUnwrap(ChangeRegion.between(before, fixture.project))
        XCTAssertEqual(removed, TimeRange(start: t(20), end: t(25)))
        XCTAssertEqual(ChangeRegion.section(at: removed.start, in: fixture.project), "§1")

        let beforeCut = fixture.project
        try fixture.coordinator.apply(EditBatch(label: "Cut", commands: [.blade(at: t(40), clipIDs: [fixture.clip("Camera").id])]))
        let cut = try XCTUnwrap(ChangeRegion.between(beforeCut, fixture.project))
        XCTAssertEqual(cut, TimeRange(start: .zero, end: t(60)))
        XCTAssertEqual(ChangeRegion.section(at: t(31), in: fixture.project), "Section 2")

        var bare = fixture.project
        bare.markers = []
        XCTAssertNil(ChangeRegion.section(at: t(31), in: bare))
    }
}

final class JobChangesTests: XCTestCase {
    func job(_ id: String, _ kind: AnalysisKind, _ state: JobState) -> JobStatus {
        JobStatus(id: id, kind: kind, mediaID: "med_" + id, state: state)
    }

    func testReportsJobsAsTheyFinish() {
        let before = [job("a", .thumbnails, .running), job("b", .proxy, .queued), job("c", .waveform, .done)]
        let after = [job("b", .proxy, .running), job("a", .thumbnails, .done), job("c", .waveform, .done)]
        let finished = JobChanges.newlyDone(old: before, new: after)
        XCTAssertEqual(finished.map(\.id), ["a"])
        XCTAssertTrue(JobChanges.affectsArtwork(finished))
        XCTAssertFalse(JobChanges.affectsPlayback(finished))

        let later = [job("b", .proxy, .done), job("a", .thumbnails, .done), job("c", .waveform, .done)]
        let proxy = JobChanges.newlyDone(old: after, new: later)
        XCTAssertEqual(proxy.map(\.id), ["b"])
        XCTAssertTrue(JobChanges.affectsPlayback(proxy))
        XCTAssertFalse(JobChanges.affectsArtwork(proxy))

        // Failed and cancelled jobs change nothing on screen.
        XCTAssertTrue(JobChanges.newlyDone(old: later, new: later + [job("d", .matte, .failed)]).isEmpty)
    }
}

final class PreviewWarningTests: XCTestCase {
    func testWarningsNameFilesNotPaths() {
        let media = [
            MediaItem(id: "m1", path: "/Users/mike/videos/decision-models/edit/main-camera.mov", kind: .video, role: .camera),
            MediaItem(id: "m2", path: "music/c1a.mp3", kind: .audio, role: .music),
            MediaItem(id: "m3", path: "/Users/mike/videos/decision-models/source/2026-09-24_105434-camera.mov", kind: .video, role: .camera)
        ]
        XCTAssertEqual(
            PreviewWarnings.short("No cutout matte for /Users/mike/videos/decision-models/edit/main-camera.mov yet, showing the full frame.", media: media),
            "No cutout matte for main-camera yet, showing the full frame."
        )
        XCTAssertEqual(PreviewWarnings.short("No loudness measurement for music/c1a.mp3 yet, so it isn't normalised.", media: media),
                       "No loudness measurement for c1a yet, so it isn't normalised.")
        XCTAssertEqual(PreviewWarnings.short("No cutout matte for /Users/mike/videos/decision-models/source/2026-09-24_105434-camera.mov yet, showing the full frame.", media: media),
                       "No cutout matte for camera 10:54 yet, showing the full frame.")
        XCTAssertEqual(PreviewWarnings.summary(["One.", "Two.", "Three."], media: []), "One. (+2 more)")
        XCTAssertNil(PreviewWarnings.summary([], media: []))
    }
}

final class PreviewSizeTests: XCTestCase {
    func testProxyPlaybackCompositesAt1080p() {
        XCTAssertEqual(PlaybackController.previewSize(for: CGSize(width: 3840, height: 2160)), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(PlaybackController.previewSize(for: CGSize(width: 2560, height: 1440)), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(PlaybackController.previewSize(for: CGSize(width: 2160, height: 3840)), CGSize(width: 1080, height: 1920))
        // Already small enough: the project's own size.
        XCTAssertNil(PlaybackController.previewSize(for: CGSize(width: 1920, height: 1080)))
        XCTAssertNil(PlaybackController.previewSize(for: CGSize(width: 1080, height: 1920)))
    }
}

final class ViewerZoomTests: XCTestCase {
    /// Zooming about the pointer keeps the spot under it where it was, in
    /// and out of fit.
    func testZoomKeepsThePointOverTheSamePartOfThePicture() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let point = CGPoint(x: 700, y: 200)
        for (from, to) in [(1.0, 2.0), (1.0, 0.5), (2.0, 0.25), (0.5, 3.0)] as [(CGFloat, CGFloat)] {
            let before = CanvasGeometry.canvasRect(in: bounds, width: 3840, height: 2160, zoom: from, pan: CGPoint(x: 30, y: -10))
            let spot = CGPoint(x: (point.x - before.minX) / before.width, y: (point.y - before.minY) / before.height)
            let pan = CanvasGeometry.pan(keeping: point, in: bounds, width: 3840, height: 2160, from: from, to: to, pan: CGPoint(x: 30, y: -10))
            let after = CanvasGeometry.canvasRect(in: bounds, width: 3840, height: 2160, zoom: to, pan: pan)
            XCTAssertEqual(after.minX + spot.x * after.width, point.x, accuracy: 1.5, "\(from) to \(to)")
            XCTAssertEqual(after.minY + spot.y * after.height, point.y, accuracy: 1.5, "\(from) to \(to)")
        }
    }
}
