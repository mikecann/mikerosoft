import XCTest
@testable import TandemApp
@testable import TandemCore

final class TrackEditsTests: XCTestCase {
    private func names(_ tracks: [Track]) -> [String] { tracks.map(\.name) }

    func testNewTracksGoBesideTheOneClickedAndFollowTheEdit() throws {
        let fixture = try AppFixture()
        // Video tracks show top down from the last: Text, Graphics, B-roll, Camera, Screen.
        let above = TrackEdits.add(.video, beside: fixture.track("Camera").id, side: .above, in: fixture.project, id: "trk_above")
        try fixture.apply(above)
        XCTAssertEqual(names(fixture.project.videoTracks), ["Screen", "Camera", "Video 6", "B-roll", "Graphics", "Text"])
        let added = try XCTUnwrap(fixture.project.track("trk_above"))
        XCTAssertEqual(added.rippleMode, .follow, "overlays follow the edit")
        XCTAssertEqual(above.label, "Add video track")

        try fixture.apply(TrackEdits.add(.video, beside: fixture.track("Screen").id, side: .below, in: fixture.project, id: "trk_below"))
        XCTAssertEqual(fixture.project.videoTracks.first?.id, "trk_below", "below the bottom track is the new bottom")

        try fixture.apply(TrackEdits.add(.audio, beside: fixture.track("Voice").id, side: .below, in: fixture.project, id: "trk_voice2"))
        XCTAssertEqual(names(fixture.project.audioTracks), ["Voice", "Audio 4", "Music", "SFX"])
        XCTAssertEqual(fixture.project.track("trk_voice2")?.rippleMode, .follow)

        // With nothing clicked: video on top, audio at the bottom.
        try fixture.apply(TrackEdits.add(.video, in: fixture.project, id: "trk_top"))
        try fixture.apply(TrackEdits.add(.audio, in: fixture.project, id: "trk_bottom"))
        XCTAssertEqual(fixture.project.videoTracks.last?.id, "trk_top")
        XCTAssertEqual(fixture.project.audioTracks.last?.id, "trk_bottom")
        assertValid(fixture.project)
    }

    func testNewNamesDontRepeat() {
        var project = Project.standard(name: "Names")
        XCTAssertEqual(TrackEdits.name(for: .video, in: project), "Video 6")
        project.videoTracks.append(Track(kind: .video, name: "video 6"))
        XCTAssertEqual(TrackEdits.name(for: .video, in: project), "Video 7", "skips a name in use, whatever its case")
        XCTAssertEqual(TrackEdits.name(for: .audio, in: project), "Audio 4")
    }

    func testDeletingATrackTakesItsClipsAndLeavesNoLonelyLinks() throws {
        let fixture = try AppFixture()
        let screen = fixture.track("Screen")
        let batch = try XCTUnwrap(TrackEdits.remove(screen.id, in: fixture.project))
        XCTAssertEqual(batch.label, "Delete track and its clip")
        XCTAssertEqual(batch.commands.count, 1, "the camera and voice are still linked to each other")
        try fixture.apply(batch)
        XCTAssertNil(fixture.project.track(screen.id))

        let voice = try XCTUnwrap(TrackEdits.remove(fixture.track("Voice").id, in: fixture.project))
        try fixture.apply(voice)
        XCTAssertNil(fixture.clip("Camera").linkGroup, "the camera clip isn't left in a link of one")
        XCTAssertFalse(ProjectValidator.validate(fixture.project).contains { $0.message.contains("only one clip") })

        // Undo brings the track and its clips back.
        fixture.coordinator.undo()
        XCTAssertNotNil(fixture.project.track(named: "Voice"))
        XCTAssertNotNil(fixture.clip("Camera").linkGroup)

        try fixture.apply(EditBatch(label: "Lock", commands: [.updateTrack(trackID: fixture.track("Music").id, patch: .object(["locked": .bool(true)]))]))
        XCTAssertNil(TrackEdits.remove(fixture.track("Music").id, in: fixture.project), "locked tracks stay")
        XCTAssertEqual(TrackEdits.removeTitle(for: Track(kind: .audio, name: "Empty")), "Delete track")
    }

    func testTracksMoveUpAndDownAsTheTimelineShowsThem() throws {
        let fixture = try AppFixture()
        try fixture.apply(TrackEdits.move(fixture.track("B-roll").id, up: true, in: fixture.project))
        XCTAssertEqual(names(fixture.project.videoTracks), ["Screen", "Camera", "Graphics", "B-roll", "Text"])
        XCTAssertNil(TrackEdits.move(fixture.track("Text").id, up: true, in: fixture.project), "already on top")
        try fixture.apply(TrackEdits.move(fixture.track("Music").id, up: true, in: fixture.project))
        XCTAssertEqual(names(fixture.project.audioTracks), ["Music", "Voice", "SFX"])
        XCTAssertNil(TrackEdits.move(fixture.track("SFX").id, up: false, in: fixture.project), "already at the bottom")

        // Dragging: position 0 is the top track of the kind.
        try fixture.apply(TrackEdits.move(fixture.track("Screen").id, toPosition: 0, in: fixture.project))
        XCTAssertEqual(fixture.project.videoTracks.last?.name, "Screen")
        XCTAssertNil(TrackEdits.move(fixture.track("Screen").id, toPosition: 0, in: fixture.project), "no edit when it doesn't move")
        try fixture.apply(TrackEdits.move(fixture.track("Voice").id, toPosition: 2, in: fixture.project))
        XCTAssertEqual(names(fixture.project.audioTracks), ["Music", "SFX", "Voice"])
        assertValid(fixture.project)
    }

    func testDropPositionsCountTheTracksAbove() throws {
        let fixture = try AppFixture()
        let layout = TimelineLayout.make(project: fixture.project, showTranscript: true)
        let camera = fixture.track("Camera").id
        let broll = try XCTUnwrap(layout.lane(forTrack: fixture.track("B-roll").id))
        let text = try XCTUnwrap(layout.lane(forTrack: fixture.track("Text").id))
        XCTAssertEqual(TrackEdits.position(forDropAt: text.y + 1, dragging: camera, kind: .video, lanes: layout.lanes), 0, "over the top half of the top track")
        XCTAssertEqual(TrackEdits.position(forDropAt: broll.maxY, dragging: camera, kind: .video, lanes: layout.lanes), 3, "under B-roll")
        let music = try XCTUnwrap(layout.lane(forTrack: fixture.track("Music").id))
        XCTAssertEqual(TrackEdits.position(forDropAt: music.maxY + 40, dragging: fixture.track("Voice").id, kind: .audio, lanes: layout.lanes), 2)
    }

    func testRenamesAreTrimmedAndSkippedWhenUnchanged() throws {
        let fixture = try AppFixture()
        let music = fixture.track("Music")
        XCTAssertNil(TrackEdits.rename(music.id, to: "  Music ", in: fixture.project))
        XCTAssertNil(TrackEdits.rename(music.id, to: "   ", in: fixture.project))
        try fixture.apply(TrackEdits.rename(music.id, to: " Music bed ", in: fixture.project))
        XCTAssertEqual(fixture.project.track(music.id)?.name, "Music bed")
    }
}
