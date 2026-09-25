import XCTest
@testable import TandemCore

final class TimeTests: XCTestCase {
    func testSecondsRoundTripThroughJSON() throws {
        for seconds in [0, 1.5, 12.345678, 3600.5, 0.000_021] {
            let time = Time(seconds: seconds)
            let data = try JSONEncoder().encode(time)
            XCTAssertEqual(try JSONDecoder().decode(Time.self, from: data), time)
        }
    }

    func testFramesAreExact() {
        XCTAssertEqual(Time.frames(30, at: .fps30), Time(seconds: 1))
        XCTAssertEqual(Time.frames(25, at: .fps25), Time(seconds: 1))
        XCTAssertEqual(Time(seconds: 1.51).frameIndex(at: .fps30), 45)
        XCTAssertEqual(Time(seconds: 1.51).roundedToFrame(.fps30), Time.frames(45, at: .fps30))
    }

    func testDescription() {
        XCTAssertEqual(Time(seconds: 83.25).description, "01:23.250")
        XCTAssertEqual(Time(seconds: 3723).description, "1:02:03.000")
    }

    func testRangeUnionMergesTouchingRanges() {
        let merged = TimeRange.union([
            TimeRange(start: t(5), end: t(8)),
            TimeRange(start: t(0), end: t(2)),
            TimeRange(start: t(2), end: t(3)),
            TimeRange(start: t(7), end: t(9))
        ])
        XCTAssertEqual(merged, [TimeRange(start: t(0), end: t(3)), TimeRange(start: t(5), end: t(9))])
    }
}

final class JSONTests: XCTestCase {
    func testMergePatch() throws {
        let target = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a": 1, "b": {"c": 2, "d": 3}}"#.utf8))
        let patch = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"b": {"c": null, "e": 4}, "f": "x"}"#.utf8))
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a": 1, "b": {"d": 3, "e": 4}, "f": "x"}"#.utf8))
        XCTAssertEqual(patch.mergePatch(into: target), expected)
    }

    func testMergePatchBetweenTwoValues() throws {
        func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        let old = try json(#"{"id": "med_a", "path": "/x/a.wav", "role": "sfx", "rate": {"n": 30, "d": 1}, "takeID": "t1"}"#)
        let new = try json(#"{"id": "med_a", "path": "a.wav", "role": "sfx", "rate": {"n": 25, "d": 1}, "fingerprint": "f"}"#)
        let patch = try XCTUnwrap(JSONValue.mergePatch(from: old, to: new))
        XCTAssertEqual(patch, try json(#"{"path": "a.wav", "rate": {"n": 25}, "fingerprint": "f", "takeID": null}"#))
        XCTAssertEqual(patch.mergePatch(into: old), new)
        XCTAssertNil(JSONValue.mergePatch(from: old, to: old))
        // Laid over a value changed since, it keeps that change.
        let since = try json(#"{"id": "med_a", "path": "/x/a.wav", "role": "music", "rate": {"n": 30, "d": 1}, "takeID": "t1"}"#)
        XCTAssertEqual(patch.mergePatch(into: since), try json(#"{"id": "med_a", "path": "a.wav", "role": "music", "rate": {"n": 25, "d": 1}, "fingerprint": "f"}"#))
    }

    func testMinimalClipJSONDecodesWithDefaults() throws {
        let json = #"{"content": {"media": {"mediaID": "med_x"}}, "start": 3, "duration": 2}"#
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        XCTAssertTrue(clip.id.hasPrefix("clip_"))
        XCTAssertEqual(clip.mediaID, "med_x")
        XCTAssertEqual(clip.start, t(3))
        XCTAssertEqual(clip.speed, 1)
        XCTAssertTrue(clip.enabled)
    }

    func testClipContentRoundTrips() throws {
        let contents: [ClipContent] = [
            .media(mediaID: "med_a"),
            .text(TextContent(text: "TIP 1", preset: "sectionHeader")),
            .graphic(GraphicContent(template: "remotion:BarChart", props: ["value": .number(14)])),
            .solid(color: .black),
            .adjustment
        ]
        for content in contents {
            let data = try JSONEncoder().encode(content)
            XCTAssertEqual(try JSONDecoder().decode(ClipContent.self, from: data), content)
        }
        let text = String(data: try JSONEncoder().encode(ClipContent.text(TextContent(text: "Hi"))), encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix(#"{"text":{"#), text)
    }

    func testCommandsDecodeFromShortJSON() throws {
        let json = #"""
        {"label": "Agent cut", "author": "claude", "commands": [
          {"blade": {"at": 12.5}},
          {"removeClips": {"clipIDs": ["clip_a"], "ripple": true}},
          {"updateClip": {"clipID": "clip_b", "patch": {"video": {"opacity": 0.5}}}}
        ]}
        """#
        let batch = try JSONDecoder().decode(EditBatch.self, from: Data(json.utf8))
        XCTAssertEqual(batch.author, "claude")
        XCTAssertEqual(batch.commands[0], .blade(at: t(12.5)))
        XCTAssertEqual(batch.commands[1], .removeClips(clipIDs: ["clip_a"], ripple: true))
    }

    func testProjectRoundTripsThroughFile() throws {
        let (fixture, _) = try Fixture.edited()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("video.tandem")
        try ProjectFile.save(fixture.project, revision: 7, to: url)
        try ProjectFile.save(fixture.project, revision: 8, to: url)
        let loaded = try ProjectFile.load(from: url)
        XCTAssertEqual(loaded.project, fixture.project)
        XCTAssertEqual(loaded.revision, 8)
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".tandem/backups").path)
        XCTAssertEqual(backups.count, 1)
    }
}

final class KeyframeTests: XCTestCase {
    func testLinearAndHold() {
        let frames = [
            Keyframe(time: t(0), value: .number(1), interpolation: .linear),
            Keyframe(time: t(2), value: .number(2), interpolation: .hold),
            Keyframe(time: t(4), value: .number(5))
        ]
        XCTAssertEqual(frames.value(at: t(-1)), .number(1))
        XCTAssertEqual(frames.value(at: t(1)), .number(1.5))
        XCTAssertEqual(frames.value(at: t(3)), .number(2))
        XCTAssertEqual(frames.value(at: t(9)), .number(5))
    }

    func testResolvedVideoAppliesKeyframes() {
        var clip = Clip(content: .solid(color: .black), start: t(10), duration: t(4))
        clip.keyframes["video.transform.scale"] = [
            Keyframe(time: t(0), value: .number(1), interpolation: .linear),
            Keyframe(time: t(2), value: .number(1.5))
        ]
        XCTAssertEqual(clip.resolvedVideo(at: t(1)).transform.scale, 1.25, accuracy: 1e-9)
        XCTAssertEqual(clip.resolvedVideo(at: t(3)).transform.scale, 1.5, accuracy: 1e-9)
    }

    func testSplitKeepsTheCurve() {
        var clip = Clip(id: "clip_a", content: .solid(color: .black), start: t(0), duration: t(10))
        clip.keyframes["video.opacity"] = [
            Keyframe(time: t(0), value: .number(0), interpolation: .linear),
            Keyframe(time: t(8), value: .number(1), interpolation: .linear)
        ]
        let (left, right) = clip.split(at: t(4), rightID: "clip_b")!
        XCTAssertEqual(left.resolvedVideo(at: t(2)).opacity, 0.25, accuracy: 1e-6)
        XCTAssertEqual(right.resolvedVideo(at: t(0)).opacity, 0.5, accuracy: 1e-6)
        XCTAssertEqual(right.resolvedVideo(at: t(2)).opacity, 0.75, accuracy: 1e-6)
    }
}
