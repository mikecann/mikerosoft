import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TandemAPI
@testable import TandemApp
import TandemAssets
@testable import TandemCore
import TandemMedia

/// The sounds transitions get in the app: Mike's picks in Settings over
/// Tandem's own, on drops and Cmd-D, and how a sound follows a new type.
@MainActor
final class TransitionSoundAppTests: XCTestCase {
    typealias Defaults = TransitionSoundDefaults

    /// The light swoosh as the library copies it into a project.
    let swoosh = MediaItem(
        id: AssetLibrary.mediaID(for: Defaults.lightSwoosh.assetID), path: "assets/sfx/a-quick-light-swoosh-sweeping-from-left--rgm8r7d7.wav",
        kind: .audio, role: .sfx, duration: t(1), hasAudio: true
    )
    let whoosh = MediaItem(id: "med_whoosh", path: "sfx/whoosh.wav", kind: .audio, role: .sfx, duration: t(1.2), hasAudio: true)

    var resolved: Defaults.Resolved {
        Defaults.Resolved(assetID: Defaults.lightSwoosh.assetID, name: "A quick light swoosh", media: swoosh,
                          sound: TransitionSound(mediaID: swoosh.id, gainDB: Defaults.lightSwoosh.gainDB, offset: t(Defaults.lightSwoosh.offset)))
    }

    // MARK: - Settings

    func testMikesPicksInSettingsWinOverTandems() throws {
        let suite = "tandem-transition-sounds-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = TransitionSoundSettings(store: store)
        XCTAssertEqual(settings.sound(for: .push, library: nil), Defaults.lightSwoosh, "Tandem's")
        XCTAssertNil(settings.sound(for: .dissolve, library: nil))
        XCTAssertNil(settings.choice(for: .push))

        settings.set("", for: .push)
        XCTAssertNil(settings.sound(for: .push, library: nil), "none")
        settings.set(Defaults.lightSwoosh.assetID, for: .dissolve)
        XCTAssertEqual(settings.sound(for: .dissolve, library: nil), Defaults.lightSwoosh)
        XCTAssertEqual(TransitionSoundSettings(store: store).choices, ["push": "", "dissolve": Defaults.lightSwoosh.assetID], "kept")
        settings.set(nil, for: .push)
        XCTAssertEqual(settings.sound(for: .push, library: nil), Defaults.lightSwoosh, "back to Tandem's")
        settings.set("import:sfx/Boom.wav", for: .zoom)
        XCTAssertNil(settings.sound(for: .zoom, library: nil), "a pick the library can't look up plays nothing")
    }

    /// A pick from the library plays at its own level and moment.
    func testAPickFromTheLibraryIsLevelledAndTimed() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-transition-picks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let library = try AssetLibrary(root: temp, previewFolder: temp.appendingPathComponent("previews"), transport: OfflineTransport(), secrets: StaticSecretStore())
        var boom = Asset(provider: "import", providerID: "sfx/Boom.wav", kind: .sfx, name: "Boom", duration: 1, loudness: Loudness(integratedLUFS: -20, truePeakDBTP: -2, loudnessRange: 0))
        boom.state = .normalised
        try library.catalog.upsert(boom)
        let suite = "tandem-transition-picks-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = TransitionSoundSettings(store: store)
        settings.set(boom.id, for: .zoom)
        XCTAssertEqual(settings.sound(for: .zoom, library: library), Defaults.Sound(assetID: boom.id, gainDB: -15, offset: 0), "-35 LUFS wanted from -20; no waveform, so from its start")
    }

    // MARK: - Adding

    func cut(_ f: AppFixture) throws {
        try f.blade(at: [20])
    }

    func testADroppedPushPlaysItsSwoosh() throws {
        let f = try AppFixture()
        try cut(f)
        let camera = f.track("Camera")
        let batch = try XCTUnwrap(LibraryDrops.transition(.push, at: t(20.2), trackID: camera.id, in: f.project, id: "tr_p", sound: resolved))
        XCTAssertEqual(batch.commands.first, .addMedia(item: swoosh), "the file first")
        try f.apply(batch)
        let transition = try XCTUnwrap(f.track("Camera").transitions.first)
        let clip = try XCTUnwrap(transition.soundClipID.flatMap { f.project.clip($0) })
        XCTAssertEqual(clip.start, t(19.61))
        XCTAssertEqual(clip.audio?.gainDB, -23.3, "the fixture's speech is at -20")
        XCTAssertEqual(f.project.track(containingClip: clip.id)?.name, "SFX")
        // Once the file's there, the next drop doesn't add it again.
        XCTAssertEqual(LibraryDrops.transition(.push, at: t(40), trackID: nil, in: f.project, sound: resolved), nil, "no cut at 40")
        try f.apply(EditBatch(label: "Cut", commands: [.blade(at: t(40), clipIDs: [f.clip("Camera", 1).id])]))
        let again = try XCTUnwrap(LibraryDrops.transition(.push, at: t(40), trackID: camera.id, in: f.project, sound: resolved))
        XCTAssertEqual(again.commands.count, 1)
    }

    func testCmdDAddsTheDissolvesSoundWhenItHasOne() throws {
        let f = try AppFixture()
        try cut(f)
        let silent = try XCTUnwrap(TimelineEdits.addDefaultTransition(f.project, playhead: t(20), selection: []))
        guard case .addTransition(_, _, let none)? = silent.commands.last else { return XCTFail("expected addTransition") }
        XCTAssertNil(none)
        let loud = try XCTUnwrap(TimelineEdits.addDefaultTransition(f.project, playhead: t(20), selection: [], sound: resolved))
        guard case .addTransition(_, let transition, let sound)? = loud.commands.last else { return XCTFail("expected addTransition") }
        XCTAssertEqual(transition.type, .dissolve)
        XCTAssertEqual(sound?.mediaID, swoosh.id)
    }

    // MARK: - A new type

    func testTheSoundFollowsTheType() throws {
        let f = try AppFixture()
        try cut(f)
        let camera = f.track("Camera")
        try f.apply(EditBatch(label: "Media", commands: [.addMedia(item: swoosh), .addMedia(item: whoosh)]))
        try f.apply(EditBatch(label: "Dissolve", commands: [.addTransition(trackID: camera.id, transition: TandemCore.Transition(id: "tr_x", type: .dissolve, duration: t(0.5), fromClipID: f.clip("Camera", 0).id, toClipID: f.clip("Camera", 1).id))]))
        func transition() -> TandemCore.Transition { f.track("Camera").transitions[0] }
        func become(_ type: TransitionType) throws {
            try f.apply(EditBatch(label: "Type", commands: TransitionSoundEdits.typeChange(
                transition(), to: type, in: f.project,
                oldSound: Defaults.builtIn(transition().type), newSound: Defaults.builtIn(type), resolved: Defaults.builtIn(type) == nil ? nil : resolved
            )))
        }
        // A dropped push on it: the dissolve had no sound, the push brings its swoosh.
        let dropped = try XCTUnwrap(LibraryDrops.transition(.push, at: t(20), trackID: camera.id, in: f.project, sound: resolved))
        try f.apply(dropped)
        XCTAssertEqual(transition().type, .push)
        let swooshClip = try XCTUnwrap(transition().soundClipID)
        XCTAssertEqual(f.project.clip(swooshClip)?.mediaID, swoosh.id)

        // Push to slide: the same sound, left as it is (a gain Mike set stays).
        try f.apply(EditBatch(label: "Quieter", commands: [.updateTransition(transitionID: "tr_x", patch: .object(["sound": .object(["gainDB": .number(-30)])]))]))
        try become(.slide)
        XCTAssertEqual(transition().soundClipID, swooshClip)
        XCTAssertEqual(f.project.clip(swooshClip)?.audio?.gainDB, -30)

        // To a zoom, which plays nothing: its old type's sound goes.
        try become(.zoom)
        XCTAssertNil(transition().soundClipID)
        XCTAssertNil(f.project.clip(swooshClip))

        // A sound Mike picked stays whatever the type.
        try f.apply(EditBatch(label: "Own", commands: [.updateTransition(transitionID: "tr_x", patch: .object(["sound": .object(["mediaID": .string("med_whoosh")])]))]))
        try become(.push)
        XCTAssertEqual(transition().soundClipID.flatMap { f.project.clip($0) }?.mediaID, "med_whoosh")
        try become(.dissolve)
        XCTAssertEqual(transition().soundClipID.flatMap { f.project.clip($0) }?.mediaID, "med_whoosh")
    }

    /// A type whose sound couldn't be brought in leaves the sound alone.
    func testASoundThatCouldntComeLeavesItAlone() throws {
        let f = try AppFixture()
        try cut(f)
        try f.apply(EditBatch(label: "Push", commands: [
            .addMedia(item: swoosh),
            .addTransition(trackID: f.track("Camera").id, transition: TandemCore.Transition(id: "tr_x", type: .push, duration: t(0.7), fromClipID: f.clip("Camera", 0).id, toClipID: f.clip("Camera", 1).id), sound: TransitionSound(mediaID: swoosh.id))
        ]))
        let commands = TransitionSoundEdits.typeChange(f.track("Camera").transitions[0], to: .zoom, in: f.project, oldSound: Defaults.lightSwoosh, newSound: Defaults.Sound(assetID: "import:gone.wav", gainDB: -15, offset: 0), resolved: nil)
        XCTAssertEqual(commands, [.updateTransition(transitionID: "tr_x", patch: .object(["type": .string("zoom")]))])
    }

    func testASoundIsKnownByItsFileWhereverItCameFrom() throws {
        var project = Project.standard(name: "Sounds")
        project.media = [swoosh, MediaItem(id: "med_watched", path: "assets/sfx/a-quick-light-swoosh-sweeping-from-left--rgm8r7d7 2.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true), whoosh]
        func clip(_ mediaID: String) -> Clip { Clip(content: .media(mediaID: mediaID), start: .zero, duration: t(1)) }
        XCTAssertTrue(TransitionSoundEdits.plays(clip(swoosh.id), Defaults.lightSwoosh.assetID, in: project))
        XCTAssertFalse(TransitionSoundEdits.plays(clip("med_watched"), Defaults.lightSwoosh.assetID, in: project), "a copy beside it is another file")
        project.media[1].path = "assets/sfx/light-swoosh-rgm8r7d7.wav"
        XCTAssertTrue(TransitionSoundEdits.plays(clip("med_watched"), Defaults.lightSwoosh.assetID, in: project), "added by the folder watcher under its own ID")
        XCTAssertFalse(TransitionSoundEdits.plays(clip(whoosh.id), Defaults.lightSwoosh.assetID, in: project))
        XCTAssertFalse(TransitionSoundEdits.plays(nil, Defaults.lightSwoosh.assetID, in: project))
    }

    func testTheTilesSayWhatTheyPlay() {
        XCTAssertTrue(TransitionSoundText.tileTip(.push).hasPrefix("Push, 0.70 s with light swoosh."), TransitionSoundText.tileTip(.push))
        XCTAssertTrue(TransitionSoundText.tileTip(.dissolve).hasPrefix("Dissolve, 0.50 s. Double-click"), TransitionSoundText.tileTip(.dissolve))
        XCTAssertEqual(TransitionSoundText.name(of: "", choices: []), "none")
    }
}

/// The transition inspector with its sound, and the Settings rows, drawn
/// offscreen to look at (`TANDEM_TRANSITION_UI_OUT`, as
/// `TransitionSnapshots`).
@MainActor
final class TransitionSoundSnapshots: XCTestCase {
    private func render<V: View>(_ view: V, size: CGSize, _ name: String) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top).background(Theme.panel.color))
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.display()
        settleMainThread()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()
        let image = try XCTUnwrap(rep.cgImage)
        XCTAssertGreaterThan(image.height, 100)
        guard let out = ProcessInfo.processInfo.environment["TANDEM_TRANSITION_UI_OUT"], !out.isEmpty else { return }
        let dir = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(dir.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testTheInspectorsSoundRows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-transition-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Inspector.tandem"), name: "Inspector", owner: .app)
        let model = EditorModel(session: session)
        defer {
            model.tearDown()
            _ = model.session.close()
        }
        let fixture = try AppFixture()
        let swoosh = MediaItem(id: "med_swoosh", path: "assets/sfx/a-quick-light-swoosh-sweeping-from-left--rgm8r7d7.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true)
        model.apply(EditBatch(label: "Media", commands: (fixture.project.media + [swoosh]).map { .addMedia(item: $0) }))
        model.apply(EditBatch(label: "Shots", commands: [
            .placeMedia(mediaIDs: ["med_broll"], at: t(6), sourceStart: t(1), duration: t(4)),
            .placeMedia(mediaIDs: ["med_broll"], at: t(10), sourceStart: t(5), duration: t(4))
        ]))
        let broll = model.project.track(named: "B-roll")!
        model.apply(EditBatch(label: "Push", commands: [.addTransition(
            trackID: broll.id, transition: TandemCore.Transition(id: "tr_push", type: .push, duration: t(0.7), fromClipID: broll.clips[0].id, toClipID: broll.clips[1].id),
            sound: TransitionSound(mediaID: swoosh.id, gainDB: -23.3, offset: t(-0.39))
        )]))
        let location = try XCTUnwrap(model.project.location(ofTransition: "tr_push"))
        let panel = VStack(alignment: .leading, spacing: 0) {
            TransitionInspector(model: model, transition: model.project[location.track].transitions[location.index], track: model.project[location.track])
        }
        try render(panel, size: CGSize(width: 330, height: 330), "inspector-push-sound")
    }

    func testTheSettingsRows() throws {
        try render(TransitionSoundSettingsView().padding(22), size: CGSize(width: 520, height: 430), "settings-transition-sounds")
    }
}

/// The whole way in the app, with a scratch asset library (never Mike's):
/// a push dropped on a cut brings the light swoosh into the project's
/// assets/sfx through the library and goes in with it as one edit.
@MainActor
final class TransitionSoundActionsTests: XCTestCase {
    func testADroppedPushBringsItsSwooshInAsOneEdit() async throws {
        guard AssetLibraryHost.shared.library == nil else { throw XCTSkip("the asset library is already open in this run") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-transition-actions-\(UUID().uuidString)", isDirectory: true)
        let root = temp.appendingPathComponent("assets", isDirectory: true)
        let video = temp.appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        setenv("TANDEM_ASSETS_ROOT", root.path, 1)
        setenv("TANDEM_ASSETS_OFFLINE", "1", 1)
        defer {
            unsetenv("TANDEM_ASSETS_ROOT")
            unsetenv("TANDEM_ASSETS_OFFLINE")
        }

        // The swoosh under its real ID, as a quiet second of sine.
        let library = try AssetLibrary(root: root, previewFolder: root.appendingPathComponent("previews"), transport: OfflineTransport(), secrets: StaticSecretStore())
        var asset = Asset(provider: "elevenlabs", providerID: "sfx_2ybnc2tu", kind: .sfx, name: "A quick light swoosh sweeping from left to right", duration: 1)
        try Self.wav(at: library.folder(for: asset).appendingPathComponent("original.wav"), seconds: 1)
        asset.state = .normalised
        asset.files = AssetFiles(original: "original.wav")
        try library.catalog.upsert(asset)

        let session = try ProjectSession.create(at: video.appendingPathComponent("Drop.tandem"), name: "Drop", owner: .app)
        let model = EditorModel(session: session)
        defer {
            model.tearDown()
            _ = model.session.close()
        }
        let fixture = try AppFixture()
        model.apply(EditBatch(label: "Media", commands: fixture.project.media.map { .addMedia(item: $0) }))
        model.apply(EditBatch(label: "Take", commands: [.placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(40))]))
        let camera = try XCTUnwrap(model.project.track(named: "Camera"))
        model.apply(EditBatch(label: "Cut", commands: [.blade(at: t(20), clipIDs: [camera.clips[0].id])]))
        let revision = model.revision
        let undoDepth = model.session.coordinator.history().count

        TransitionSoundActions.add(.push, at: t(20.1), trackID: camera.id, in: model)
        for _ in 0..<300 where model.revision == revision {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let transition = try XCTUnwrap(model.project.track(named: "Camera")?.transitions.first)
        XCTAssertEqual(transition.type, .push)
        let sound = try XCTUnwrap(transition.soundClipID.flatMap { model.project.clip($0) })
        XCTAssertEqual(sound.start, t(19.61), "loudest on the cut")
        XCTAssertEqual(sound.audio?.gainDB, -23.3, "15 LU under speech at -20")
        let item = try XCTUnwrap(sound.mediaID.flatMap { model.project.media($0) })
        XCTAssertTrue(item.path.hasPrefix("assets/sfx/"), item.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.appendingPathComponent(item.path).path), "copied into the project")
        XCTAssertEqual(model.session.coordinator.history().count, undoDepth + 1, "one edit")
        XCTAssertEqual(model.undoLabel, "Add push")
        XCTAssertEqual(model.selectedTransitionID, transition.id, "picked, so the inspector shows it")
        XCTAssertEqual(try library.search(.inProject(model.project.id, kinds: [.sfx])).map(\.id), [asset.id], "the use is recorded, for credits")
    }

    /// A 16-bit PCM WAV of a quiet sine.
    static func wav(at url: URL, seconds: Double) throws {
        let frames = Int(seconds * 48_000)
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(36 + frames * 2)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(48_000)); append(UInt32(96_000)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(frames * 2))
        for index in 0..<frames { append(Int16(3000 * sin(Double(index) * 2 * .pi * 440 / 48_000))) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
