import XCTest
@testable import TandemAPI
@testable import TandemCore

/// Keeps the hand-written command schema honest.
final class SchemaTests: XCTestCase {
    func testEveryCommandHasOneSchemaEntry() {
        let listed = CommandSchema.entries.map(\.command)
        XCTAssertEqual(listed.count, Set(listed).count, "duplicate schema entries")
        XCTAssertEqual(Set(listed), Set(CommandCase.allCases), "every EditCommand case needs a schema entry")
    }

    func testEveryExampleValidatesAndDecodesToItsCommand() throws {
        for entry in CommandSchema.entries {
            let value = try json(entry.example)
            XCTAssertEqual(CommandSchema.validate(command: value), [], "\(entry.command) example doesn't match its schema")
            let command = try JSONDecoder().decode(EditCommand.self, from: Data(entry.example.utf8))
            XCTAssertEqual(command.commandCase, entry.command)
            // Examples leave IDs out, so each decode makes fresh ones; compare the kind.
            XCTAssertEqual(try CommandJSON.decode(value).commandCase, entry.command)
            // What Swift encodes for the command must validate too.
            let encoded = try JSONValue.from(command)
            XCTAssertEqual(CommandSchema.validate(command: encoded), [], "\(entry.command) encoded form doesn't match its schema")
        }
    }

    func testFullyPopulatedValuesValidate() throws {
        // Every field set, so a field added to the model without a schema
        // entry fails here.
        let effect = Effect(id: "fx_a", type: "dropShadow", enabled: false, params: [
            "distance": .number(4), "on": .bool(true), "path": .string("a.cube"), "color": .color(RGBA(r: 1, g: 0, b: 0, a: 0.5)), "point": .point(Point(x: 0.1, y: 0.2))
        ])
        let clip = Clip(
            id: "clip_full", name: "Full", content: .text(TextContent(
                text: "Hi", preset: "callout",
                style: TextStyle(strokeColor: .black, strokeWidth: 2, backgroundColor: .white, uppercase: true, shadow: true, lineSpacing: 0.2),
                animationIn: "popIn", animationOut: "fadeOut", animationDuration: t(0.5),
                words: [TimedWord(text: "Hi", start: t(0), end: t(0.4))]
            )),
            start: t(1), duration: t(2), sourceStart: t(0.5), speed: 1.5, freezeFrame: true, enabled: false, linkGroup: "lnk_x",
            video: VideoProperties(
                transform: Transform(position: Point(x: 0.2, y: 0.3), scale: 0.5, rotation: 10),
                crop: Crop(left: 0.1, top: 0.1, right: 0.1, bottom: 0.1),
                opacity: 0.5,
                cutout: Cutout(enabled: true, mode: .person, edgeFeather: 3, choke: 1, repairMasks: [
                    Mask(shape: .ellipse, mode: .exclude, rect: Rect(x: 0, y: 0, width: 0.5, height: 0.5), cornerRadius: 4, feather: 2)
                ]),
                effects: [effect],
                layoutPreset: "pipRight",
                formatOverrides: ["portrait": FormatOverride(transform: Transform(), crop: Crop(left: 0.2), hidden: true)]
            ),
            audio: AudioProperties(gainDB: -3, fadeIn: t(0.2), fadeOut: t(0.3), muted: true, normalizeTo: -14, voiceIsolation: 0.5, effects: [Effect(type: "pitchShift")]),
            keyframes: ["video.opacity": [Keyframe(time: t(0), value: .number(0), interpolation: .linear), Keyframe(time: t(1), value: .number(1))]],
            tags: ["agent:claude"]
        )
        let media = MediaItem(
            id: "med_full", path: "a.mov", kind: .video, role: .camera, takeID: "take", takeOffset: t(0.5), duration: t(10),
            frameRate: .fps30, width: 1920, height: 1080, hasVideo: true, hasAudio: true, hasAlpha: true, variableFrameRate: true,
            undecodableCodec: "rle ", fingerprint: "abc", look: [effect], livePhotoVideo: "photos/a.mov"
        )
        let template = Template(id: "card", name: "Card", duration: t(3), fields: [TemplateField(key: "title", label: "Title", defaultValue: "X")], clips: [
            TemplateClip(track: "SFX", trackKind: .audio, offset: t(0.2), clip: clip, mediaPath: "sfx/whoosh.wav")
        ])
        let commands: [EditCommand] = [
            .insertClip(trackID: "trk_a", clip: clip, mode: .overwrite),
            .insertClip(trackID: "trk_a", clip: Clip(content: .graphic(GraphicContent(template: "remotion:Bar", props: ["n": .number(2)], propsJSON: "{}")), start: t(0), duration: t(1)), mode: .insert),
            .insertClip(trackID: "trk_a", clip: Clip(content: .solid(color: .black), start: t(0), duration: t(1))),
            .insertClip(trackID: "trk_a", clip: Clip(content: .adjustment, start: t(0), duration: t(1))),
            .insertClip(trackID: "trk_a", clip: Clip(content: .media(mediaID: "med_a"), start: t(0), duration: t(1))),
            .addMedia(item: media),
            .addTransition(trackID: "trk_a", transition: Transition(id: "tr_a", type: .push, direction: .left, duration: t(0.7), fromClipID: "clip_a", toClipID: "clip_b")),
            .addMarker(marker: Marker(id: "mk_a", time: t(3), duration: t(1), name: "A", kind: .todo, note: "fix")),
            .insertTemplate(template: template, at: t(5), values: ["title": "T"], mode: .overwrite),
            .placeMedia(mediaIDs: ["med_a"], at: t(1), sourceStart: t(2), duration: t(3), mode: .insert, videoTrackID: "trk_v", audioTrackID: "trk_a", includeAudio: false),
            .moveClips(clipIDs: ["clip_a"], delta: t(1), toTrackID: "trk_b", includeLinked: false, mode: .overwrite),
            .trim(clipID: "clip_a", edge: .start, to: t(2), ripple: false, includeLinked: false),
            .setSpeed(clipID: "clip_a", speed: 2, ripple: true, includeLinked: false),
            .addTrack(kind: .audio, name: "X", index: 1, id: "trk_x"),
            .rippleDeleteRange(range: TimeRange(start: t(1), duration: t(2)), trackIDs: ["trk_a"]),
            .blade(at: t(1), trackIDs: ["trk_a"], clipIDs: ["clip_a"]),
            .zoomToRegion(clipID: "clip_a", rect: Rect(x: 0, y: 0, width: 1, height: 1), at: t(1), duration: t(0.5)),
            .setKeyframes(clipID: "clip_a", parameter: "video.transform.position", keyframes: [Keyframe(time: t(0), value: .point(Point(x: 0.5, y: 0.5)), interpolation: .hold)]),
            .updateClip(clipID: "clip_a", patch: try JSONValue.from(clip)),
            .updateMedia(mediaID: "med_a", patch: try JSONValue.from(media)),
            .updateTrack(trackID: "trk_a", patch: try JSONValue.from(Track(kind: .video, name: "V", clips: [clip], muted: true, solo: true, locked: true, hidden: true, targeted: false, rippleMode: .off))),
            .updateSettings(patch: try JSONValue.from(ProjectSettings(alternateFormats: [.portrait]))),
            .updateMarker(markerID: "mk_a", patch: try JSONValue.from(Marker(time: t(1), name: "B"))),
            .updateTransition(transitionID: "tr_a", patch: try JSONValue.from(Transition(type: .wipe, direction: .up, duration: t(1), fromClipID: "a", toClipID: nil))),
            .updateEffect(clipID: "clip_a", effectID: "fx_a", patch: try JSONValue.from(effect))
        ]
        for command in commands {
            let value = try JSONValue.from(command)
            XCTAssertEqual(CommandSchema.validate(command: value), [], "\(command.commandCase)")
        }
    }

    func testMistakesGetHelpfulErrors() throws {
        func problems(_ text: String) throws -> [String] { CommandSchema.validate(command: try json(text), path: "commands[0]") }
        XCTAssertEqual(try problems(#"{"blde": {"at": 1}}"#), [#"commands[0]: unknown command "blde". Did you mean "blade"?"#])
        XCTAssertEqual(try problems(#"{"trim": {"clipID": "c", "edge": "end", "to": 5, "rippel": true}}"#),
                       [#"commands[0].trim: unknown field "rippel" (did you mean "ripple"?). Allowed: clipID, edge, includeLinked, ripple, to"#])
        XCTAssertEqual(try problems(#"{"trim": {"clipID": "c", "edge": "middle", "to": 5}}"#),
                       [#"commands[0].trim.edge: "middle" isn't allowed; use one of start, end"#])
        XCTAssertEqual(try problems(#"{"blade": {}}"#), [#"commands[0].blade: missing "at""#])
        XCTAssertEqual(try problems(#"{"blade": {"at": 1}, "trim": {}}"#).count, 1)
        XCTAssertEqual(try problems(#"{"updateClip": {"clipID": "c", "patch": {"video": {"opactiy": 0.5}}}}"#),
                       [#"commands[0].updateClip.patch.video: unknown field "opactiy" (did you mean "opacity"?). Allowed: crop, cutout, effects, formatOverrides, layoutPreset, opacity, transform"#])
        XCTAssertEqual(try problems(#"{"updateClip": {"clipID": "c", "patch": {"video": {"cutout": null}, "name": null}}}"#), [], "null removes a key in a patch")
        XCTAssertEqual(try problems(#"{"insertClip": {"trackID": "t", "clip": {"content": {"text": {"txt": "Hi"}}, "duration": 2}}}"#),
                       [#"commands[0].insertClip.clip.content.text: unknown field "txt" (did you mean "text"?). Allowed: animationDuration, animationIn, animationOut, preset, style, text, words"#])
    }

    func testFriendlyFormsAreAccepted() throws {
        let range = try CommandJSON.decode(try json(#"{"rippleDeleteRange": {"range": {"start": "00:12.400", "end": 13.2}}}"#))
        XCTAssertEqual(range, .rippleDeleteRange(range: TimeRange(start: t(12.4), end: t(13.2))))
        let blade = try CommandJSON.decode(try json(#"{"blade": {"at": "1:02.5"}}"#))
        XCTAssertEqual(blade, .blade(at: t(62.5)))
        // Free-form values that look like times stay strings.
        let metadata = try CommandJSON.decode(try json(#"{"updateProject": {"patch": {"metadata": {"time": "12"}}}}"#))
        XCTAssertEqual(metadata, .updateProject(patch: .object(["metadata": .object(["time": .string("12")])])))
    }

    func testEveryReferenceResolves() {
        func refs(_ value: JSONValue) -> [String] {
            switch value {
            case .object(let fields):
                var found: [String] = []
                if case .string(let ref)? = fields["$ref"] { found.append(ref) }
                for (_, child) in fields { found += refs(child) }
                return found
            case .array(let items):
                return items.flatMap(refs)
            default:
                return []
            }
        }
        let all = refs(CommandSchema.document) + CommandSchema.patchModels.values.flatMap(refs)
        XCTAssertFalse(all.isEmpty)
        for ref in Set(all) {
            XCTAssertTrue(ref.hasPrefix("#/$defs/"), ref)
            XCTAssertNotNil(CommandSchema.definitions[String(ref.dropFirst("#/$defs/".count))], "\(ref) isn't defined")
        }
        guard case .object(let root) = CommandSchema.document, case .object(let defs)? = root["$defs"] else {
            return XCTFail("the document needs $defs at its root")
        }
        XCTAssertEqual(Set(defs.keys), Set(CommandSchema.definitions.keys))
    }

    func testBatchSchemaDocument() throws {
        let data = try ServiceJSON.encoder(pretty: true).encode(CommandSchema.document)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"$schema\" : \"https://json-schema.org/draft/2020-12/schema\""))
        for command in CommandCase.allCases {
            XCTAssertTrue(text.contains("\"\(command.rawValue)\""), command.rawValue)
        }
        let batch = try json(#"{"label": "Cut", "commands": [{"blade": {"at": 12}}], "expectedRevision": 3, "dryRun": true}"#)
        XCTAssertEqual(CommandSchema.validate(batch, against: CommandSchema.batch), [])
        let bad = try json(#"{"commands": [{"blade": {"at": 12}}], "expectedRevison": 3}"#)
        XCTAssertEqual(CommandSchema.validate(bad, against: CommandSchema.batch).count, 1)
    }
}
