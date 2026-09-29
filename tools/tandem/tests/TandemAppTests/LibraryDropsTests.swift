import XCTest
@testable import TandemApp
@testable import TandemCore
import TandemRender

final class LibraryDropsTests: XCTestCase {
    func testATransitionLandsOnTheNearestCutOnItsTrack() throws {
        let fixture = try AppFixture()
        try fixture.blade(at: [20])
        let camera = fixture.track("Camera")
        let batch = try XCTUnwrap(LibraryDrops.transition(.push, at: t(20.4), trackID: camera.id, in: fixture.project, id: "tr_drop"))
        guard case .addTransition(let trackID, let transition) = batch.commands.first else { return XCTFail("expected addTransition") }
        XCTAssertEqual(trackID, camera.id)
        XCTAssertEqual(transition.type, .push)
        XCTAssertEqual(transition.fromClipID, fixture.clip("Camera", 0).id)
        XCTAssertEqual(transition.toClipID, fixture.clip("Camera", 1).id)
        try fixture.apply(batch)

        // Dropping another type on it swaps the type; the same type does nothing.
        let swap = try XCTUnwrap(LibraryDrops.transition(.dissolve, at: t(19.8), trackID: camera.id, in: fixture.project))
        guard case .updateTransition(let id, _) = swap.commands.first else { return XCTFail("expected updateTransition") }
        XCTAssertEqual(id, "tr_drop")
        XCTAssertNil(LibraryDrops.transition(.push, at: t(20), trackID: camera.id, in: fixture.project))

        // Too far from any cut.
        XCTAssertNil(LibraryDrops.transition(.push, at: t(40), trackID: camera.id, in: fixture.project))
        // No track under the pointer: the top-most track with a cut in reach.
        let anywhere = try XCTUnwrap(LibraryDrops.transition(.wipe, at: t(20.2), trackID: nil, in: fixture.project))
        XCTAssertEqual(anywhere.commands.count, 1)
    }

    func testEffectsGoOnClipsOfTheirKind() throws {
        let fixture = try AppFixture()
        let camera = fixture.clip("Camera").id
        let batch = try XCTUnwrap(LibraryDrops.effect("vignette", on: camera, in: fixture.project))
        guard case .addEffect(let clipID, let effect, _) = batch.commands.first else { return XCTFail("expected addEffect") }
        XCTAssertEqual(clipID, camera)
        XCTAssertEqual(effect.type, "vignette")
        XCTAssertEqual(batch.label, "Add vignette")
        XCTAssertNil(LibraryDrops.effect("pitchShift", on: camera, in: fixture.project), "a sound effect on a picture")
        XCTAssertNotNil(LibraryDrops.effect("pitchShift", on: fixture.clip("Voice").id, in: fixture.project))
        XCTAssertNil(LibraryDrops.effect("vignette", on: nil, in: fixture.project))
        XCTAssertNil(LibraryDrops.effect("teleport", on: camera, in: fixture.project))
    }

    func testTitlesAndTemplatesLandWhereTheyAreDropped() throws {
        let fixture = try AppFixture()
        let preset = try XCTUnwrap(TitlePresets.preset("callout"))
        let batch = try XCTUnwrap(LibraryDrops.title(preset, at: t(7), in: fixture.project))
        guard case .insertClip(let trackID, let clip, let mode) = batch.commands.first else { return XCTFail("expected insertClip") }
        XCTAssertEqual(trackID, fixture.track("Text").id)
        XCTAssertEqual(clip.start, t(7))
        XCTAssertEqual(mode, .overwrite)
        guard case .text(let text) = clip.content else { return XCTFail("expected text") }
        XCTAssertEqual(text.preset, "callout")
        XCTAssertEqual(text.text, TitleSamples.text(for: "callout"))
        try fixture.apply(batch)

        for template in BuiltInTemplates.all {
            let dropped = LibraryDrops.template(template, at: t(30))
            guard case .insertTemplate(let inserted, let at, _, _) = dropped.commands.first else { return XCTFail("expected insertTemplate") }
            XCTAssertEqual(inserted.id, template.id)
            XCTAssertEqual(at, t(30))
            // Every built-in template goes in cleanly on Mike's usual tracks.
            let copy = ProjectCoordinator(project: fixture.project)
            XCTAssertNoThrow(try copy.apply(dropped), template.name)
            assertValid(copy.project)
        }
    }
}

/// Drops land on the track under the pointer, and above the top video
/// track or below the last track they make a track for what's dropped, as
/// Filmora does.
final class DropTargetTests: XCTestCase {
    func testWhereTheDropLands() throws {
        let f = try AppFixture()
        let layout = TimelineLayout.make(project: f.project, showTranscript: true)
        let tracks = layout.lanes.filter { $0.trackID != nil }
        let topVideo = try XCTUnwrap(tracks.first { $0.kind == .video })
        let last = try XCTUnwrap(tracks.last)
        XCTAssertEqual(DropTarget.at(y: topVideo.y - 2, in: layout), .newVideoTrackOnTop, "the transcript lane and above")
        XCTAssertEqual(DropTarget.at(y: topVideo.midY, in: layout), .track(topVideo.trackID))
        XCTAssertEqual(DropTarget.at(y: last.maxY + 10, in: layout), .newAudioTrackAtBottom)
        let broll = try XCTUnwrap(layout.lane(forTrack: f.track("B-roll").id))
        XCTAssertEqual(DropTarget.at(y: broll.midY, in: layout), .track(broll.trackID))
    }

    func testMediaOnANewVideoTrackGoesOnTop() throws {
        let f = try AppFixture()
        let before = f.project.videoTracks.count
        let batch = try XCTUnwrap(TimelineEdits.placeMediaOnNewTrack(f.project, mediaIDs: ["med_broll"], at: t(40), kind: .video, insert: false, trackID: "trk_new"))
        _ = try f.apply(batch)
        XCTAssertEqual(f.project.videoTracks.count, before + 1)
        XCTAssertEqual(f.project.videoTracks.last?.id, "trk_new", "on top of the video tracks")
        XCTAssertEqual(f.project.track("trk_new")?.clips.first?.mediaID, "med_broll")
        XCTAssertNil(TimelineEdits.placeMediaOnNewTrack(f.project, mediaIDs: ["med_music"], at: t(40), kind: .video, insert: false), "music has no picture")
    }

    func testSoundOnANewAudioTrackGoesAtTheBottom() throws {
        let f = try AppFixture()
        let batch = try XCTUnwrap(TimelineEdits.placeMediaOnNewTrack(f.project, mediaIDs: ["med_music"], at: t(70), kind: .audio, insert: false, trackID: "trk_sound"))
        _ = try f.apply(batch)
        XCTAssertEqual(f.project.audioTracks.last?.id, "trk_sound", "below the other audio tracks")
        XCTAssertEqual(f.project.track("trk_sound")?.clips.first?.mediaID, "med_music")
    }

    /// A title goes on the video track it's dropped on, not always Text.
    func testTitlesGoWhereTheyreDropped() throws {
        let f = try AppFixture()
        let preset = try XCTUnwrap(TitlePresets.builtIn.first)
        let broll = f.track("B-roll")
        _ = try f.apply(try XCTUnwrap(LibraryDrops.title(preset, at: t(40), in: f.project, target: .track(broll.id))))
        XCTAssertTrue(f.track("B-roll").clips.contains { if case .text = $0.content { return true } else { return false } })

        let tracks = f.project.videoTracks.count
        _ = try f.apply(try XCTUnwrap(LibraryDrops.title(preset, at: t(44), in: f.project, target: .newVideoTrackOnTop)))
        XCTAssertEqual(f.project.videoTracks.count, tracks + 1)
        guard case .text = f.project.videoTracks.last?.clips.first?.content else { return XCTFail("the title on the new top track") }

        // Dropped on a sound track, a title falls back to the Text track.
        let voice = try XCTUnwrap(f.project.audioTracks.first)
        let fallback = try XCTUnwrap(LibraryDrops.title(preset, at: t(50), in: f.project, target: .track(voice.id)))
        guard case .insertClip(let trackID, _, _) = fallback.commands.first else { return XCTFail("expected insertClip") }
        XCTAssertEqual(f.project.track(trackID)?.kind, .video)
    }
}

final class ClickPlayheadTests: XCTestCase {
    /// Clicking a clip takes the playhead to its start, unless the playhead
    /// is on it already.
    func testClickMovesThePlayheadToTheClip() {
        let clip = Clip(id: "clip_a", content: .solid(color: RGBA(r: 0, g: 0, b: 0)), start: t(10), duration: t(5))
        XCTAssertEqual(TimelineEdits.playheadForClick(on: clip, playhead: t(2)), t(10))
        XCTAssertEqual(TimelineEdits.playheadForClick(on: clip, playhead: t(15)), t(10), "the end belongs to the next clip")
        XCTAssertNil(TimelineEdits.playheadForClick(on: clip, playhead: t(12)))
        XCTAssertNil(TimelineEdits.playheadForClick(on: clip, playhead: t(10)))
    }
}
