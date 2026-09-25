import XCTest
@testable import TandemApp
@testable import TandemCore

final class KeyframeEditsTests: XCTestCase {
    let tolerance = KeyframeEdits.tolerance(.fps30)

    private func keys(_ command: EditCommand?, file: StaticString = #filePath, line: UInt = #line) -> (parameter: String, keyframes: [Keyframe])? {
        guard case .setKeyframes(_, let parameter, let keyframes)? = command else {
            XCTFail("expected setKeyframes, got \(String(describing: command))", file: file, line: line)
            return nil
        }
        return (parameter, keyframes)
    }

    private func zoom(_ fixture: AppFixture) throws -> Clip {
        let camera = fixture.clip("Camera")
        try fixture.apply(EditBatch(label: "Zoom", commands: [
            .setKeyframes(clipID: camera.id, parameter: "video.transform.scale", keyframes: [
                Keyframe(time: t(1), value: .number(1), interpolation: .linear),
                Keyframe(time: t(3), value: .number(2), interpolation: .easeOut)
            ])
        ]))
        return fixture.clip("Camera")
    }

    func testValuesComeFromKeyframesWhenThereAreAny() throws {
        let fixture = try AppFixture()
        let still = fixture.clip("Camera")
        XCTAssertEqual(KeyframeEdits.value(of: "video.transform.scale", in: still, at: t(2)), .number(1))
        XCTAssertEqual(KeyframeEdits.value(of: "video.transform.position", in: still, at: t(2)), .point(Point(x: 0.5, y: 0.5)))
        XCTAssertEqual(KeyframeEdits.value(of: "audio.gainDB", in: fixture.clip("Music"), at: t(2)), .number(fixture.clip("Music").audio?.gainDB ?? 0))
        let zoomed = try zoom(fixture)
        XCTAssertEqual(KeyframeEdits.value(of: "video.transform.scale", in: zoomed, at: t(2)), .number(1.5), "halfway, linear")
        XCTAssertTrue(KeyframeEdits.isAnimated("video.transform.scale", in: zoomed))
        XCTAssertFalse(KeyframeEdits.isAnimated("video.opacity", in: zoomed))
    }

    func testSettingAValueOnAnAnimatedParameterKeysIt() throws {
        let fixture = try AppFixture()
        XCTAssertNil(KeyframeEdits.setValue(.number(1.5), for: "video.transform.scale", in: fixture.clip("Camera"), at: t(2), tolerance: tolerance),
                     "not animated: the caller patches the static value")
        let zoomed = try zoom(fixture)
        // On a keyframe (a few flicks off still counts): its value changes, its easing stays.
        guard let onKey = keys(KeyframeEdits.setValue(.number(2.5), for: "video.transform.scale", in: zoomed, at: t(3) + Time(flicks: 1_000), tolerance: tolerance)) else { return }
        XCTAssertEqual(onKey.keyframes.map(\.time), [t(1), t(3)])
        XCTAssertEqual(onKey.keyframes[1].value, .number(2.5))
        XCTAssertEqual(onKey.keyframes[1].interpolation, .easeOut)
        // Between keyframes: a new one, eased in and out.
        guard let between = keys(KeyframeEdits.setValue(.number(3), for: "video.transform.scale", in: zoomed, at: t(2), tolerance: tolerance)) else { return }
        XCTAssertEqual(between.keyframes.map(\.time), [t(1), t(2), t(3)])
        XCTAssertEqual(between.keyframes[1].value, .number(3))
        XCTAssertEqual(between.keyframes[1].interpolation, .easeInOut)
    }

    func testAddingAKeyframeKeepsTheCurrentValue() throws {
        let fixture = try AppFixture()
        guard let first = keys(KeyframeEdits.addKeyframe("video.opacity", in: fixture.clip("Camera"), at: t(4), tolerance: tolerance)) else { return }
        XCTAssertEqual(first.parameter, "video.opacity")
        XCTAssertEqual(first.keyframes, [Keyframe(time: t(4), value: .number(1))])
        let zoomed = try zoom(fixture)
        guard let added = keys(KeyframeEdits.addKeyframe("video.transform.scale", in: zoomed, at: t(2), tolerance: tolerance)) else { return }
        XCTAssertEqual(added.keyframes.map(\.time), [t(1), t(2), t(3)])
        XCTAssertEqual(added.keyframes[1].value, .number(1.5), "the curve doesn't change")
        XCTAssertNil(KeyframeEdits.addKeyframe("video.transform.scale", in: zoomed, at: t(3), tolerance: tolerance), "already one there")
    }

    func testRemovingTheLastKeyframeKeepsItsValue() throws {
        let fixture = try AppFixture()
        let zoomed = try zoom(fixture)
        let one = KeyframeEdits.removeKeyframes(in: zoomed, at: t(1), parameters: ["video.transform.scale"], tolerance: tolerance)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(keys(one.first)?.keyframes.map(\.time), [t(3)])

        try fixture.apply(EditBatch(label: "Drop one", commands: one))
        let last = KeyframeEdits.removeKeyframes(in: fixture.clip("Camera"), at: t(3), parameters: ["video.transform.scale"], tolerance: tolerance)
        XCTAssertEqual(last.count, 2)
        XCTAssertEqual(keys(last.first)?.keyframes, [])
        try fixture.apply(EditBatch(label: "Drop the last", commands: last))
        XCTAssertEqual(fixture.clip("Camera").video?.transform.scale, 2, "stays where the animation left it")
        XCTAssertTrue(fixture.clip("Camera").keyframes.isEmpty)
        XCTAssertTrue(KeyframeEdits.removeKeyframes(in: fixture.clip("Camera"), at: t(3), parameters: ["video.transform.scale"], tolerance: tolerance).isEmpty)
    }

    func testMovingKeyframesStaysInsideTheClip() throws {
        let fixture = try AppFixture()
        let zoomed = try zoom(fixture)
        guard let early = keys(KeyframeEdits.moveKeyframes(in: zoomed, from: t(1), to: t(-5), parameters: ["video.transform.scale"], tolerance: tolerance).first) else { return }
        XCTAssertEqual(early.keyframes.map(\.time), [.zero, t(3)])
        XCTAssertEqual(early.keyframes[0].interpolation, .linear, "the keyframe moves with its easing")
        guard let late = keys(KeyframeEdits.moveKeyframes(in: zoomed, from: t(3), to: t(500), parameters: ["video.transform.scale"], tolerance: tolerance).first) else { return }
        XCTAssertEqual(late.keyframes.last?.time, zoomed.duration)
        // Onto another keyframe: the one moved replaces it.
        guard let onto = keys(KeyframeEdits.moveKeyframes(in: zoomed, from: t(1), to: t(3), parameters: ["video.transform.scale"], tolerance: tolerance).first) else { return }
        XCTAssertEqual(onto.keyframes, [Keyframe(time: t(3), value: .number(1), interpolation: .linear)])
        XCTAssertTrue(KeyframeEdits.moveKeyframes(in: zoomed, from: t(1), to: t(1), parameters: ["video.transform.scale"], tolerance: tolerance).isEmpty)
    }

    func testEasingChangesOnlyTheKeyframesAtTheTime() throws {
        let fixture = try AppFixture()
        let zoomed = try zoom(fixture)
        guard let eased = keys(KeyframeEdits.setEasing(.hold, in: zoomed, at: t(1), parameters: ["video.transform.scale"], tolerance: tolerance).first) else { return }
        XCTAssertEqual(eased.keyframes.map(\.interpolation), [.hold, .easeOut])
        XCTAssertEqual(KeyframeEdits.easing(in: zoomed, at: t(3), tolerance: tolerance), .easeOut)
        XCTAssertNil(KeyframeEdits.easing(in: zoomed, at: t(2), tolerance: tolerance))
    }

    func testOptionKAddsOrRemovesKeyframesAtThePlayhead() throws {
        let fixture = try AppFixture()
        try fixture.apply(EditBatch(label: "PiP", commands: [.applyLayout(clipIDs: [fixture.clip("Camera").id], preset: .pipRight)]))
        let camera = fixture.clip("Camera")
        XCTAssertNotNil(camera.video?.layoutPreset)
        // Nothing animated yet: position and scale, as they are now.
        let start = try XCTUnwrap(KeyframeEdits.toggle(in: camera, at: t(5), trackKind: .video, tolerance: tolerance))
        try fixture.apply(start)
        let started = fixture.clip("Camera")
        XCTAssertEqual(Set(started.keyframes.keys), ["video.transform.position", "video.transform.scale"])
        XCTAssertEqual(started.keyframes["video.transform.scale"]?.first?.value, .number(camera.video!.transform.scale))
        XCTAssertNil(started.video?.layoutPreset, "an animated transform isn't a layout any more")
        // Animated: a keyframe for each animated parameter.
        try fixture.apply(XCTUnwrap(KeyframeEdits.toggle(in: started, at: t(9), trackKind: .video, tolerance: tolerance)))
        XCTAssertEqual(fixture.clip("Camera").keyframes["video.transform.position"]?.map(\.time), [t(5), t(9)])
        // On a keyframe: they go.
        try fixture.apply(XCTUnwrap(KeyframeEdits.toggle(in: fixture.clip("Camera"), at: t(9), trackKind: .video, tolerance: tolerance)))
        XCTAssertEqual(fixture.clip("Camera").keyframes["video.transform.scale"]?.map(\.time), [t(5)])
        // Sound: its gain.
        let music = fixture.clip("Music")
        let gain = try XCTUnwrap(KeyframeEdits.toggle(in: music, at: t(2), trackKind: .audio, tolerance: tolerance))
        guard let gainKeys = keys(gain.commands.first) else { return }
        XCTAssertEqual(gainKeys.parameter, "audio.gainDB")
    }

    func testTimesMergeWithinHalfAFrame() throws {
        let fixture = try AppFixture()
        let camera = fixture.clip("Camera")
        try fixture.apply(EditBatch(label: "Keys", commands: [
            .setKeyframes(clipID: camera.id, parameter: "video.transform.scale", keyframes: [Keyframe(time: t(1), value: .number(1)), Keyframe(time: t(2), value: .number(2))]),
            .setKeyframes(clipID: camera.id, parameter: "video.opacity", keyframes: [Keyframe(time: t(1) + Time(flicks: 500), value: .number(1))])
        ]))
        let keyed = fixture.clip("Camera")
        XCTAssertEqual(KeyframeEdits.times(in: keyed, tolerance: tolerance), [t(1), t(2)])
        XCTAssertEqual(Set(KeyframeEdits.parameters(in: keyed, keyedAt: t(1), tolerance: tolerance)), ["video.transform.scale", "video.opacity"])
        XCTAssertEqual(KeyframeEdits.parameters(in: keyed, keyedAt: t(2), tolerance: tolerance), ["video.transform.scale"])
        // Navigation, in timeline time.
        XCTAssertEqual(KeyframeEdits.next(after: .zero, in: keyed, tolerance: tolerance), keyed.start + t(1))
        XCTAssertEqual(KeyframeEdits.next(after: keyed.start + t(1), in: keyed, tolerance: tolerance), keyed.start + t(2))
        XCTAssertNil(KeyframeEdits.next(after: keyed.start + t(2), in: keyed, tolerance: tolerance))
        XCTAssertEqual(KeyframeEdits.previous(before: keyed.start + t(2), in: keyed, tolerance: tolerance), keyed.start + t(1))
        XCTAssertNil(KeyframeEdits.previous(before: keyed.start + t(1), in: keyed, tolerance: tolerance))
    }

    func testNames() throws {
        XCTAssertEqual(KeyframeEdits.name(of: "video.transform.scale"), "Scale")
        XCTAssertEqual(KeyframeEdits.name(of: "video.crop.left"), "Crop left")
        XCTAssertEqual(KeyframeEdits.name(of: "audio.gainDB"), "Gain")
        var clip = Clip(content: .solid(color: RGBA(r: 0, g: 0, b: 0)), start: .zero, duration: t(1))
        clip.video = VideoProperties(effects: [Effect(id: "fx_v", type: "vignette")])
        XCTAssertEqual(KeyframeEdits.name(of: "video.effects.fx_v.amount", in: clip), "Vignette amount")
        XCTAssertEqual(KeyframeEdits.summary(of: ["video.transform.position", "video.transform.scale"]), "Position and scale")
        XCTAssertEqual(KeyframeEdits.summary(of: ["video.transform.position", "video.transform.scale", "video.opacity"]), "Position, scale and opacity")
    }

    func testEffectParametersAnimateToo() throws {
        let fixture = try AppFixture()
        let camera = fixture.clip("Camera")
        try fixture.apply(EditBatch(label: "Vignette", commands: [.addEffect(clipID: camera.id, effect: Effect(id: "fx_v", type: "vignette"))]))
        let withEffect = fixture.clip("Camera")
        XCTAssertEqual(KeyframeEdits.value(of: "video.effects.fx_v.amount", in: withEffect, at: t(1)), .number(-30), "the registry default")
        let added = try XCTUnwrap(KeyframeEdits.addKeyframe("video.effects.fx_v.amount", in: withEffect, at: t(1), tolerance: tolerance))
        try fixture.apply(EditBatch(label: "Key", commands: [added]))
        let removal = KeyframeEdits.removeKeyframes(in: fixture.clip("Camera"), at: t(1), parameters: ["video.effects.fx_v.amount"], tolerance: tolerance)
        XCTAssertEqual(removal.count, 2)
        guard case .updateEffect(_, "fx_v", _)? = removal.last else { return XCTFail("expected the effect to keep its value, got \(removal)") }
    }
}
