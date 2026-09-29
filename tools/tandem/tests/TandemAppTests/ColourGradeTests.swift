import XCTest
@testable import TandemApp
@testable import TandemCore

/// The Colour tab's fixed sections over a look's or a clip's effects:
/// which effect backs each section, and what a change does to the list.
final class ColourGradeTests: XCTestCase {
    private var ids = 0
    private func newID() -> String {
        ids += 1
        return "fx_new\(ids)"
    }

    private func adjust(_ id: String, enabled: Bool = true, _ params: [String: Double]) -> Effect {
        Effect(id: id, type: "colorAdjust", enabled: enabled, params: params.mapValues { .number($0) })
    }

    // MARK: - Which effect backs which section

    func testAnUngradedListHasNoEffectsAndShowsNoChange() {
        let grade = ColourGrade([])
        for section in ColourSection.allCases {
            XCTAssertNil(grade.effect(section), section.rawValue)
            XCTAssertFalse(grade.isChanged(section), section.rawValue)
            XCTAssertTrue(grade.isOn(section), section.rawValue)
        }
        // The vignette and sharpen start at none, not Mike's usual amounts.
        XCTAssertEqual(grade.values(.vignette)["amount"], .number(0))
        XCTAssertEqual(grade.values(.vignette)["size"], .number(50))
        XCTAssertEqual(grade.values(.sharpen)["amount"], .number(0))
        XCTAssertEqual(grade.values(.lut)["intensity"], .number(1))
        XCTAssertEqual(grade.values(.mixer).count, 24)
        XCTAssertEqual(grade.values(.wheels).count, 9)
    }

    func testSectionsUseTheExistingEffectsAndKeys() {
        // Mike's Filmora grade, as the importer writes it.
        let look = [
            adjust("fx_c", ["contrast": 25, "blackLevel": 7, "temperature": -3]),
            Effect(id: "fx_h", type: "hsl", params: ["redSaturation": .number(-8)]),
            Effect(id: "fx_v", type: "vignette", params: ["amount": .number(-30)])
        ]
        let grade = ColourGrade(look)
        XCTAssertEqual(grade.effect(.light)?.id, "fx_c")
        XCTAssertEqual(grade.effect(.colour)?.id, "fx_c")
        XCTAssertTrue(grade.isShared(.light))
        XCTAssertEqual(grade.values(.light)["contrast"], .number(25))
        XCTAssertEqual(grade.values(.light)["exposure"], .number(0))
        XCTAssertEqual(grade.values(.colour)["temperature"], .number(-3))
        XCTAssertEqual(grade.effect(.mixer)?.id, "fx_h")
        XCTAssertEqual(grade.values(.mixer)["redSaturation"], .number(-8))
        XCTAssertEqual(grade.effect(.vignette)?.id, "fx_v")
        XCTAssertTrue(grade.isChanged(.light))
        XCTAssertTrue(grade.isChanged(.colour))
        XCTAssertTrue(grade.isChanged(.mixer))
        XCTAssertFalse(grade.isChanged(.wheels))
        XCTAssertTrue(grade.others.isEmpty)
    }

    func testEffectsNoSectionShowsAreListedAsTheyAre() {
        // A second HSL, and two colour effects that aren't cleanly split.
        let look = [
            adjust("fx_a", ["contrast": 10, "temperature": 5]),
            adjust("fx_b", ["exposure": 0.5]),
            Effect(id: "fx_h1", type: "hsl", params: ["redHue": .number(4)]),
            Effect(id: "fx_h2", type: "hsl", params: ["blueHue": .number(-4)]),
            Effect(id: "fx_pack", type: "filmGrain")
        ]
        let grade = ColourGrade(look)
        XCTAssertEqual(grade.effect(.light)?.id, "fx_a")
        XCTAssertEqual(grade.effect(.colour)?.id, "fx_a")
        XCTAssertEqual(grade.effect(.mixer)?.id, "fx_h1")
        XCTAssertEqual(grade.others.map(\.id), ["fx_b", "fx_h2", "fx_pack"])
    }

    func testACleanSplitGivesLightAndColourAnEffectEach() {
        let grade = ColourGrade([adjust("fx_l", ["exposure": 0.5]), adjust("fx_c", enabled: false, ["tint": 12])])
        XCTAssertEqual(grade.effect(.light)?.id, "fx_l")
        XCTAssertEqual(grade.effect(.colour)?.id, "fx_c")
        XCTAssertFalse(grade.isShared(.light))
        XCTAssertTrue(grade.isOn(.light))
        XCTAssertFalse(grade.isOn(.colour))
        XCTAssertTrue(grade.others.isEmpty)
    }

    func testAWheelHueWithoutAnAmountIsNoChange() {
        let wheels = Effect(id: "fx_w", type: "colorWheels", params: ["shadowsHue": .number(200)])
        XCTAssertFalse(ColourGrade([wheels]).isChanged(.wheels))
        let tinted = Effect(id: "fx_w", type: "colorWheels", params: ["shadowsHue": .number(200), "shadowsAmount": .number(10)])
        XCTAssertTrue(ColourGrade([tinted]).isChanged(.wheels))
    }

    // MARK: - Changes

    func testTheFirstChangeAddsTheSectionsEffect() throws {
        let change = try XCTUnwrap(ColourGrade([]).setting(.light, ["exposure": .number(0.35)], label: "Exposure", newID: newID))
        XCTAssertEqual(change.effects, [Effect(id: "fx_new1", type: "colorAdjust", params: ["exposure": .number(0.35)])])
        XCTAssertEqual(change.label, "Exposure")
        XCTAssertEqual(change.sets, [ColourChange.SetValue(effectID: "fx_new1", key: "exposure", value: .number(0.35))])
    }

    func testLightAndColourShareOneEffectUntilOneIsTurnedOff() throws {
        let first = try XCTUnwrap(ColourGrade([]).setting(.light, ["contrast": .number(20)], label: "Contrast", newID: newID))
        let second = try XCTUnwrap(ColourGrade(first.effects).setting(.colour, ["temperature": .number(-10)], label: "Temperature", newID: newID))
        XCTAssertEqual(second.effects.count, 1, "one colorAdjust holds both, like Filmora imports")
        XCTAssertEqual(second.effects[0].params, ["contrast": .number(20), "temperature": .number(-10)])

        // Turning Light off splits Colour out, so only Light goes off.
        let off = try XCTUnwrap(ColourGrade(second.effects).toggling(.light, newID: newID))
        XCTAssertEqual(off.label, "Turn off light")
        XCTAssertEqual(off.effects, [
            Effect(id: "fx_new1", type: "colorAdjust", enabled: false, params: ["contrast": .number(20)]),
            Effect(id: "fx_new2", type: "colorAdjust", enabled: true, params: ["temperature": .number(-10)])
        ])
        let split = ColourGrade(off.effects)
        XCTAssertFalse(split.isOn(.light))
        XCTAssertTrue(split.isOn(.colour))
        XCTAssertEqual(split.values(.colour)["temperature"], .number(-10))

        // And back on: no more splitting.
        let on = try XCTUnwrap(split.toggling(.light, newID: newID))
        XCTAssertEqual(on.label, "Turn on light")
        XCTAssertEqual(on.effects.map(\.enabled), [true, true])
        XCTAssertEqual(on.effects.count, 2)
    }

    func testTurningColourOffKeepsLightOn() throws {
        let shared = [adjust("fx_c", ["contrast": 25, "temperature": -3])]
        let off = try XCTUnwrap(ColourGrade(shared).toggling(.colour, newID: newID))
        XCTAssertEqual(off.effects.map(\.id), ["fx_c", "fx_new1"])
        XCTAssertEqual(off.effects.map(\.enabled), [true, false])
        XCTAssertEqual(off.effects[1].params, ["temperature": .number(-3)])
    }

    func testTurningOffASectionWithNothingInTheOtherDoesntSplit() throws {
        let change = try XCTUnwrap(ColourGrade([adjust("fx_c", ["contrast": 25])]).toggling(.light, newID: newID))
        XCTAssertEqual(change.effects, [adjust("fx_c", enabled: false, ["contrast": 25])])
        XCTAssertNil(ColourGrade([]).toggling(.vignette), "nothing to turn off")
    }

    func testChangingASectionThatsOffTurnsItBackOn() throws {
        let off = [Effect(id: "fx_v", type: "vignette", enabled: false, params: ["amount": .number(-30)])]
        let change = try XCTUnwrap(ColourGrade(off).setting(.vignette, ["amount": .number(-25)], label: "Vignette amount", newID: newID))
        XCTAssertEqual(change.effects, [Effect(id: "fx_v", type: "vignette", enabled: true, params: ["amount": .number(-25)])])
    }

    func testChangingColourWhileLightIsOffGivesColourItsOwnEffect() throws {
        // Light was turned off; the shared effect has both.
        let shared = [adjust("fx_c", enabled: false, ["contrast": 25, "temperature": -3])]
        let change = try XCTUnwrap(ColourGrade(shared).setting(.colour, ["tint": .number(5)], label: "Tint", newID: newID))
        XCTAssertEqual(change.effects, [
            adjust("fx_c", enabled: false, ["contrast": 25]),
            adjust("fx_new1", ["temperature": -3, "tint": 5])
        ])
    }

    func testResettingASharedSectionTakesOnlyItsValues() throws {
        let shared = [adjust("fx_c", ["contrast": 25, "blackLevel": 7, "temperature": -3])]
        let light = try XCTUnwrap(ColourGrade(shared).resetting(.light))
        XCTAssertEqual(light.label, "Reset light")
        XCTAssertEqual(light.effects, [adjust("fx_c", ["temperature": -3])])
        // With nothing of the other's left, the effect goes.
        let colour = try XCTUnwrap(ColourGrade(light.effects).resetting(.colour))
        XCTAssertEqual(colour.effects, [])
        XCTAssertNil(ColourGrade([]).resetting(.mixer), "nothing to reset")
    }

    func testResettingASectionRemovesItsEffect() throws {
        let look = [Effect(id: "fx_h", type: "hsl", params: ["redSaturation": .number(-8)]), Effect(id: "fx_v", type: "vignette")]
        let change = try XCTUnwrap(ColourGrade(look).resetting(.vignette))
        XCTAssertEqual(change.effects.map(\.id), ["fx_h"])
    }

    func testAddingAVignetteOnlyChangesWhatWasAsked() throws {
        // Moving the size first mustn't bring in the default -30 amount.
        let change = try XCTUnwrap(ColourGrade([]).setting(.vignette, ["size": .number(70)], label: "Vignette size", newID: newID))
        XCTAssertEqual(change.effects[0].params, ["amount": .number(0), "size": .number(70)])
        let sharpen = try XCTUnwrap(ColourGrade([]).setting(.sharpen, ["amount": .number(3)], label: "Sharpen", newID: newID))
        XCTAssertEqual(sharpen.effects[0].params, ["amount": .number(3)])
    }

    func testNewEffectsGoInTheTabsOrder() throws {
        let look = [Effect(id: "fx_h", type: "hsl"), Effect(id: "fx_v", type: "vignette")]
        let grade = ColourGrade(look)
        XCTAssertEqual(grade.insertionIndex(for: .light), 0)
        XCTAssertEqual(grade.insertionIndex(for: .wheels), 0)
        XCTAssertEqual(grade.insertionIndex(for: .sharpen), 2)
        XCTAssertEqual(grade.insertionIndex(for: .lut), 2)
        let wheels = try XCTUnwrap(grade.setting(.wheels, ["midtonesAmount": .number(10)], label: "Midtones wheel", newID: newID))
        XCTAssertEqual(wheels.effects.map(\.type), ["colorWheels", "hsl", "vignette"])
        // A clip's style effects stay where they are.
        let clipEffects = [Effect(id: "fx_s", type: "dropShadow")]
        XCTAssertEqual(ColourGrade(clipEffects).insertionIndex(for: .light), 0)
    }

    func testSettingWhatsThereChangesNothing() {
        let look = [adjust("fx_c", ["contrast": 25])]
        XCTAssertNil(ColourGrade(look).setting(.light, ["contrast": .number(25)], label: "Contrast", newID: newID))
    }

    func testEveryExistingKeyIsStillAKeyOfItsEffect() {
        // The tab only ever writes parameters the registry defines.
        for section in ColourSection.allCases {
            let definition = EffectRegistry.standard.definition(section.effectType)
            XCTAssertNotNil(definition, section.rawValue)
            for key in section.keys {
                XCTAssertNotNil(definition?.param(key), "\(section.rawValue).\(key)")
            }
        }
        XCTAssertEqual(Set(ColourSection.light.keys + ColourSection.colour.keys), Set(EffectRegistry.standard.definition("colorAdjust")!.params.map(\.key)))
        XCTAssertEqual(Set(ColourSection.mixer.keys), Set(EffectRegistry.standard.definition("hsl")!.params.map(\.key)))
    }

    // MARK: - As a clip's edit commands

    private func clipWith(_ effects: [Effect], keyframes: [String: [Keyframe]] = [:]) -> Clip {
        Clip(id: "clip_c", content: .media(mediaID: "med_camera"), start: t(10), duration: t(10), video: VideoProperties(effects: effects), keyframes: keyframes)
    }

    func testAClipsFirstChangeIsOneAddEffect() throws {
        let clip = clipWith([Effect(id: "fx_s", type: "dropShadow")])
        let change = try XCTUnwrap(ColourGrade(clip: clip).setting(.light, ["exposure": .number(0.5)], label: "Exposure", newID: newID))
        let commands = ColourEdits.clipCommands(clip, change, at: t(1), tolerance: t(0.01))
        XCTAssertEqual(commands, [.addEffect(clipID: "clip_c", effect: Effect(id: "fx_new1", type: "colorAdjust", params: ["exposure": .number(0.5)]), index: 0)])
    }

    func testAClipsChangesPatchOnlyWhatChanged() throws {
        let clip = clipWith([adjust("fx_c", enabled: false, ["contrast": 25])])
        let change = try XCTUnwrap(ColourGrade(clip: clip).setting(.light, ["contrast": .number(30)], label: "Contrast", newID: newID))
        let commands = ColourEdits.clipCommands(clip, change, at: t(1), tolerance: t(0.01))
        XCTAssertEqual(commands, [.updateEffect(clipID: "clip_c", effectID: "fx_c", patch: .object([
            "enabled": .bool(true), "params": .object(["contrast": .number(30)])
        ]))])
        let reset = try XCTUnwrap(ColourGrade(clip: clip).resetting(.light))
        XCTAssertEqual(ColourEdits.clipCommands(clip, reset, at: t(1), tolerance: t(0.01)), [.removeEffect(clipID: "clip_c", effectID: "fx_c")])
    }

    func testAnAnimatedValueIsSetAsAKeyframeAtThePlayhead() throws {
        let path = "video.effects.fx_c.contrast"
        let clip = clipWith([adjust("fx_c", ["contrast": 0])], keyframes: [path: [
            Keyframe(time: t(0), value: .number(0)), Keyframe(time: t(4), value: .number(40))
        ]])
        let grade = ColourGrade(clip: clip)
        XCTAssertEqual(grade.animated, ["fx_c": ["contrast"]])
        let change = try XCTUnwrap(grade.setting(.light, ["contrast": .number(20)], label: "Contrast", newID: newID))
        let commands = ColourEdits.clipCommands(clip, change, at: t(2), tolerance: t(0.01))
        XCTAssertEqual(commands, [.setKeyframes(clipID: "clip_c", parameter: path, keyframes: [
            Keyframe(time: t(0), value: .number(0)), Keyframe(time: t(2), value: .number(20)), Keyframe(time: t(4), value: .number(40))
        ])])
    }

    func testSplittingMovesColourAnimationsToTheNewEffect() throws {
        let temperature = "video.effects.fx_c.temperature"
        let keys = [Keyframe(time: t(0), value: .number(-10)), Keyframe(time: t(3), value: .number(10))]
        let clip = clipWith([adjust("fx_c", ["contrast": 25, "temperature": -10])], keyframes: [temperature: keys])
        let change = try XCTUnwrap(ColourGrade(clip: clip).toggling(.light, newID: newID))
        XCTAssertEqual(change.moves, [ColourChange.Move(key: "temperature", from: "fx_c", to: "fx_new1")])
        let commands = ColourEdits.clipCommands(clip, change, at: t(1), tolerance: t(0.01))
        XCTAssertEqual(commands, [
            .updateEffect(clipID: "clip_c", effectID: "fx_c", patch: .object(["enabled": .bool(false), "params": .object(["temperature": .null])])),
            .addEffect(clipID: "clip_c", effect: adjust("fx_new1", ["temperature": -10]), index: 1),
            .setKeyframes(clipID: "clip_c", parameter: temperature, keyframes: []),
            .setKeyframes(clipID: "clip_c", parameter: "video.effects.fx_new1.temperature", keyframes: keys)
        ])
        // Through the coordinator, on a real clip, it does that.
        let fixture = try AppFixture()
        let camera = fixture.clip("Camera")
        try fixture.apply(EditBatch(label: "Grade", commands: [
            .addEffect(clipID: camera.id, effect: clip.video!.effects[0], index: nil),
            .setKeyframes(clipID: camera.id, parameter: temperature, keyframes: keys)
        ]))
        let graded = fixture.clip("Camera")
        let turnOff = try XCTUnwrap(ColourGrade(clip: graded).toggling(.light, newID: newID))
        try fixture.apply(EditBatch(label: turnOff.label, commands: ColourEdits.clipCommands(graded, turnOff, at: t(1), tolerance: t(0.01))))
        let result = fixture.clip("Camera")
        XCTAssertEqual(result.video?.effects.map(\.id), ["fx_c", "fx_new2"])
        XCTAssertEqual(result.keyframes.keys.sorted(), ["video.effects.fx_new2.temperature"])
        let after = ColourGrade(clip: result)
        XCTAssertFalse(after.isOn(.light))
        XCTAssertTrue(after.isOn(.colour))
        XCTAssertEqual(after.effect(.colour)?.id, "fx_new2")
        XCTAssertEqual(after.values(.colour)["temperature"], .number(-10))
        XCTAssertNil(after.effect(.light)?.params["temperature"])
    }

    func testResettingASharedSectionDropsItsAnimations() throws {
        let path = "video.effects.fx_c.contrast"
        let clip = clipWith([adjust("fx_c", ["temperature": 5])], keyframes: [path: [Keyframe(time: t(0), value: .number(10))]])
        let change = try XCTUnwrap(ColourGrade(clip: clip).resetting(.light))
        XCTAssertEqual(ColourEdits.clipCommands(clip, change, at: t(1), tolerance: t(0.01)), [
            .setKeyframes(clipID: "clip_c", parameter: path, keyframes: [])
        ])
    }

    // MARK: - Words

    func testSummariesAndLabelsReadWell() {
        let values = ColourGrade([adjust("fx_c", ["contrast": 25, "blackLevel": -7, "exposure": 0.35])]).values(.light)
        XCTAssertEqual(ColourSummary.text(.light, values), "Exposure +0.35 EV, contrast +25, black level −7")
        let mixer = ColourGrade([Effect(type: "hsl", params: ["redSaturation": .number(-8), "orangeHue": .number(4)])]).values(.mixer)
        XCTAssertEqual(ColourSummary.text(.mixer, mixer), "Reds and oranges")
        let wheels = ColourGrade([Effect(type: "colorWheels", params: ["shadowsAmount": .number(8), "highlightsBrightness": .number(5)])]).values(.wheels)
        XCTAssertEqual(ColourSummary.text(.wheels, wheels), "Shadows and highlights")
        XCTAssertEqual(ColourSummary.text(.lut, ["path": .string("luts/Kodak 2383.cube")]), "Kodak 2383.cube")

        let hue = ColourSliderSpec.mixer("red")[0]
        XCTAssertEqual(hue.format(50), "+15°")
        XCTAssertEqual(hue.format(-7), "−2.1°")
        XCTAssertEqual(hue.parse("15°") ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(ColourSliderSpec.mixer("red")[1].format(-8), "−8%")
        XCTAssertEqual(ColourSliderSpec.specs(.lut)[0].format(1), "100%")
        XCTAssertEqual(ColourSliderSpec.specs(.lut)[0].parse("50%") ?? 0, 0.5, accuracy: 1e-12)
        XCTAssertEqual(ColourSliderSpec.specs(.light)[0].format(0), "0.00 EV")
        XCTAssertEqual(ColourSliderSpec.mixer("aqua")[0].undo, "Aqua hue")
    }
}
