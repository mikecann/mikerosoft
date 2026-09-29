import XCTest
@testable import TandemAPI
@testable import TandemCore

/// Agents find the colour wheels where they find every effect: in
/// `tandem effects`, in the edit schema, and in edits that apply.
final class ColourWheelsCatalogTests: XCTestCase {
    func testTheEffectsCatalogueListsTheWheels() throws {
        XCTAssertTrue(try EffectsResult.catalog().effects.contains { $0.type == "colorWheels" })
        let wheels = try EffectsResult.catalog(type: "colorWheels")
        XCTAssertEqual(wheels.effects.map(\.type), ["colorWheels"])
        let text = wheels.readableText
        XCTAssertTrue(text.contains("colorWheels  video  Shadows, midtones and highlights wheels"), text)
        XCTAssertTrue(text.contains("shadowsHue: number 0...360 degrees, default 0"), text)
        XCTAssertTrue(text.contains("highlightsAmount: number 0...100 %, default 0"), text)
        XCTAssertTrue(text.contains("midtonesBrightness: number -100...100, default 0"), text)
    }

    func testTheSchemaNamesEveryEffectType() throws {
        let types = CommandSchema.effectTypes
        for definition in EffectRegistry.standard.sorted {
            XCTAssertTrue(types.contains(definition.type), definition.type)
        }
        XCTAssertTrue(types.hasSuffix(" or " + EffectRegistry.standard.sorted.last!.type))
        let schema = String(decoding: try JSONEncoder().encode(CommandSchema.effect), as: UTF8.self)
        XCTAssertTrue(schema.contains("colorWheels"))
    }

    func testAnAgentsGradeValidatesAndApplies() throws {
        let look = try json("""
        {"updateMedia": {"mediaID": "med_camera", "patch": {"look": [
          {"type": "colorAdjust", "params": {"contrast": 25, "temperature": -3}},
          {"type": "colorWheels", "params": {"shadowsHue": 200, "shadowsAmount": 12, "highlightsBrightness": 5}}
        ]}}}
        """)
        XCTAssertEqual(CommandSchema.validate(command: look), [])
        let clipGrade = try json("""
        {"addEffect": {"clipID": "clip_cam", "effect": {"type": "colorWheels", "params": {"midtonesHue": 120, "midtonesAmount": 20}}}}
        """)
        XCTAssertEqual(CommandSchema.validate(command: clipGrade), [])

        var project = Project.standard(name: "Wheels")
        project.media = [MediaItem(id: "med_camera", path: "a-camera.mov", kind: .video, role: .camera, duration: t(10), hasVideo: true)]
        let coordinator = ProjectCoordinator(project: project)
        try coordinator.apply(EditBatch(label: "Place", commands: [.placeMedia(mediaIDs: ["med_camera"], at: .zero)]))
        let camera = try XCTUnwrap(coordinator.project.track(named: "Camera")?.clips.first)
        let clipCommand = try CommandJSON.decode(try json("""
        {"addEffect": {"clipID": "\(camera.id)", "effect": {"type": "colorWheels", "params": {"midtonesHue": 120, "midtonesAmount": 20}}}}
        """))
        let result = try coordinator.apply(EditBatch(label: "Grade", commands: [try CommandJSON.decode(look), clipCommand]))
        XCTAssertEqual(result.warnings, [], "a known effect, so no warning")
        XCTAssertEqual(coordinator.project.media("med_camera")?.look.map(\.type), ["colorAdjust", "colorWheels"])
        XCTAssertEqual(coordinator.project.clip(camera.id)?.video?.effects.first?.params["midtonesAmount"], .number(20))
    }
}
