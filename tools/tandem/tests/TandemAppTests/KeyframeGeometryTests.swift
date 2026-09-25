import XCTest
@testable import TandemApp
@testable import TandemCore

final class KeyframeGeometryTests: XCTestCase {
    let tolerance = KeyframeEdits.tolerance(.fps30)

    func testDiamondsSitUnderTheirKeyframes() {
        var clip = Clip(content: .solid(color: RGBA(r: 0, g: 0, b: 0)), start: t(10), duration: t(10))
        clip.keyframes = [
            "video.transform.scale": [Keyframe(time: t(1), value: .number(1)), Keyframe(time: t(3), value: .number(2))],
            "video.transform.position": [Keyframe(time: t(1), value: .point(Point(x: 0.5, y: 0.5)))]
        ]
        let scale = TimelineScale(pixelsPerSecond: 10)
        let rect = CGRect(x: 100, y: 40, width: 100, height: 48)
        let diamonds = KeyframeGeometry.diamonds(for: clip, rect: rect, isAudio: false, scale: scale, tolerance: tolerance)
        XCTAssertEqual(diamonds.map(\.centre.x), [110, 130])
        XCTAssertEqual(diamonds.map(\.parameters), [["video.transform.position", "video.transform.scale"], ["video.transform.scale"]])
        XCTAssertEqual(diamonds.map(\.time), [t(1), t(3)])
        let row = KeyframeGeometry.rowY(in: rect)
        XCTAssertEqual(diamonds[0].centre.y, row)
        XCTAssertGreaterThan(row, rect.midY, "along the bottom, clear of the label")
        XCTAssertEqual(KeyframeGeometry.hit(CGPoint(x: 112, y: row + 2), in: diamonds)?.time, t(1))
        XCTAssertNil(KeyframeGeometry.hit(CGPoint(x: 120, y: row), in: diamonds))
        XCTAssertNil(KeyframeGeometry.hit(CGPoint(x: 110, y: rect.minY + 4), in: diamonds), "only the diamond row")
        XCTAssertTrue(KeyframeGeometry.diamonds(for: Clip(content: .solid(color: RGBA(r: 0, g: 0, b: 0)), start: .zero, duration: t(1)), rect: rect, isAudio: false, scale: scale, tolerance: tolerance).isEmpty)
    }

    func testGainKeyframesSitOnTheVolumeLine() {
        var clip = Clip(content: .solid(color: RGBA(r: 0, g: 0, b: 0)), start: .zero, duration: t(10))
        clip.keyframes = ["audio.gainDB": [
            Keyframe(time: .zero, value: .number(-60)), Keyframe(time: t(2), value: .number(6)), Keyframe(time: t(4), value: .number(-21))
        ]]
        let rect = CGRect(x: 0, y: 100, width: 100, height: 40)
        let diamonds = KeyframeGeometry.diamonds(for: clip, rect: rect, isAudio: true, scale: TimelineScale(pixelsPerSecond: 10), tolerance: tolerance)
        XCTAssertEqual(diamonds.count, 3)
        XCTAssertTrue(diamonds.allSatisfy(\.onVolumeLine))
        XCTAssertEqual(diamonds[0].centre.y, rect.maxY - 3, "−60 dB at the bottom")
        XCTAssertEqual(diamonds[1].centre.y, rect.minY + 3, "+6 dB at the top")
        XCTAssertEqual(KeyframeGeometry.gain(atY: diamonds[2].centre.y, in: rect), -21, accuracy: 0.001)
        XCTAssertEqual(KeyframeGeometry.gain(atY: rect.minY - 50, in: rect), 6, "kept in range")
    }

    func testTheHitTesterFindsKeyframesBeforeClips() throws {
        let fixture = try AppFixture()
        let camera = fixture.clip("Camera")
        try fixture.apply(EditBatch(label: "Keys", commands: [
            .setKeyframes(clipID: camera.id, parameter: "video.transform.scale", keyframes: [Keyframe(time: t(2), value: .number(1)), Keyframe(time: t(5), value: .number(1.5))])
        ]))
        let tester = TimelineHitTester(project: fixture.project, layout: TimelineLayout.make(project: fixture.project, showTranscript: true), scale: TimelineScale(pixelsPerSecond: 10))
        let lane = try XCTUnwrap(tester.layout.lane(forTrack: fixture.track("Camera").id))
        let rowY = KeyframeGeometry.rowY(in: CGRect(x: 0, y: lane.y, width: 10, height: lane.height))
        let found = try XCTUnwrap(tester.keyframe(at: CGPoint(x: 51, y: rowY)))
        XCTAssertEqual(found.clipID, camera.id)
        XCTAssertEqual(found.diamond.time, t(5))
        XCTAssertNil(tester.keyframe(at: CGPoint(x: 51, y: lane.y + 4)), "the top of the clip is the clip")
        XCTAssertNil(tester.keyframe(at: CGPoint(x: 35, y: rowY)))
        XCTAssertNil(tester.keyframe(at: CGPoint(x: 51, y: tester.layout.lane(forTrack: fixture.track("B-roll").id)!.midY)))
    }
}
