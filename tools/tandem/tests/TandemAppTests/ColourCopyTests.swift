import XCTest
@testable import TandemApp
@testable import TandemCore

/// Copying a take's grade to the other files from the same shoot.
final class ColourCopyTests: XCTestCase {
    private let grade = [
        Effect(id: "fx_light", type: "colorAdjust", params: ["exposure": .number(0.3)]),
        Effect(id: "fx_wheels", type: "colorWheels", params: ["midtonesHue": .number(30), "midtonesAmount": .number(12)])
    ]

    private func project() -> Project {
        var project = Project.standard(name: "Grades")
        var graded = MediaItem(id: "med_a", path: "camera/take 1.mov", kind: .video, role: .camera, duration: t(60), hasVideo: true, hasAudio: true)
        graded.look = grade
        var matching = MediaItem(id: "med_c", path: "camera/take 3.mov", kind: .video, role: .camera, duration: t(60), hasVideo: true, hasAudio: true)
        matching.look = grade.map { var copy = $0; copy.id = "fx_other_\($0.id)"; return copy }
        project.media = [
            graded,
            MediaItem(id: "med_b", path: "camera/take 2.mov", kind: .video, role: .camera, duration: t(60), hasVideo: true, hasAudio: true),
            matching,
            MediaItem(id: "med_screen", path: "screen/take 1.mov", kind: .video, role: .screen, duration: t(60), hasVideo: true),
            MediaItem(id: "med_voice", path: "audio/voice.wav", kind: .audio, role: .camera, duration: t(60), hasAudio: true),
            MediaItem(id: "med_d", path: "camera/take 10.mov", kind: .video, role: .camera, duration: t(60), hasVideo: true, hasAudio: true)
        ]
        return project
    }

    func testOnlyFilesLikeThisOneAreOffered() throws {
        let project = project()
        let source = try XCTUnwrap(project.media("med_a"))
        XCTAssertEqual(
            ColourCopy.candidates(for: source, in: project).map(\.id), ["med_b", "med_c", "med_d"],
            "other camera files in name order; never a screen recording or a sound"
        )
        XCTAssertTrue(ColourCopy.hasSameLook(try XCTUnwrap(project.media("med_c")), as: source), "the same grade whatever its IDs")
        XCTAssertFalse(ColourCopy.hasSameLook(try XCTUnwrap(project.media("med_b")), as: source))
    }

    func testCopyingGivesEachFileItsOwnCopyOfTheGrade() throws {
        let project = project()
        let source = try XCTUnwrap(project.media("med_a"))
        var next = 0
        let batch = try XCTUnwrap(ColourCopy.copy(from: source, to: ColourCopy.candidates(for: source, in: project)) {
            next += 1
            return "fx_copy\(next)"
        })
        XCTAssertEqual(batch.label, "Copy grade to 2 files", "take 3 has it already")
        let coordinator = ProjectCoordinator(project: project)
        _ = try coordinator.apply(batch)
        assertValid(coordinator.project)
        for id in ["med_b", "med_d"] {
            let item = try XCTUnwrap(coordinator.project.media(id))
            XCTAssertTrue(ColourCopy.hasSameLook(item, as: source))
            XCTAssertTrue(Set(item.look.map(\.id)).isDisjoint(with: grade.map(\.id)), "its own effect IDs")
        }
        XCTAssertEqual(coordinator.project.media("med_c")?.look.map(\.id), ["fx_other_fx_light", "fx_other_fx_wheels"], "left alone")

        let one = try XCTUnwrap(ColourCopy.copy(from: source, to: [try XCTUnwrap(project.media("med_b"))]))
        XCTAssertEqual(one.label, "Copy grade to take 2.mov")
        XCTAssertNil(ColourCopy.copy(from: source, to: [try XCTUnwrap(project.media("med_c"))]), "nothing to change")
    }
}
