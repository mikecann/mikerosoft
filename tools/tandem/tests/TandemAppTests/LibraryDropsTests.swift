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
