import Foundation
import TandemCore

/// JSON Schema (2020-12) for `EditBatch` and every `EditCommand`, written by
/// hand so each field has a useful description. MCP's `apply` tool uses it
/// as its input schema, `tandem schema` prints it, and the service checks
/// incoming commands against it so a misspelt field is an error rather than
/// silently ignored.
///
/// Tests keep it honest: every `CommandCase` has an entry, every example
/// validates and decodes, and fully populated model values validate.
public enum CommandSchema {
    public struct Entry: Sendable {
        public var command: CommandCase
        public var summary: String
        /// Schema of the command's arguments object.
        public var arguments: JSONValue
        /// A complete example, `{"<command>": {...}}`.
        public var example: String
    }

    /// Schema for one command: an object with exactly one key, the command.
    public static var editCommand: JSONValue {
        .object([
            "description": .string("One edit command: an object with a single key naming the command, for example {\"blade\": {\"at\": 12.5}}. Times are seconds."),
            "oneOf": .array(entries.map(commandSchema))
        ])
    }

    static func commandSchema(_ entry: Entry) -> JSONValue {
        S.object([entry.command.rawValue: entry.arguments], required: [entry.command.rawValue], entry.summary)
    }

    /// The properties of `apply`'s input.
    static var batchProperties: [String: JSONValue] {
        [
            "label": S.string("Shown in the undo menu and activity feed, like \"Tightened 14 pauses in section 4\". Defaults to a summary of the commands."),
            "author": S.string("Who made the edit, like \"claude\". Defaults to the connecting agent's name."),
            "commands": S.array(editCommand, "Edit commands, applied in order. If any fails, none are applied."),
            "expectedRevision": S.integer("Refuse the batch unless the project is at this revision (from status or timeline), so you never edit a timeline that changed under you."),
            "idempotencyKey": S.string("Retrying with the same key returns the first result instead of applying the batch twice."),
            "dryRun": S.boolean("Check the batch on a copy and report what it would do, without changing anything.")
        ]
    }

    /// Schema for `apply`'s input: a batch applied atomically as one undo
    /// step, with the shared model schemas under `$defs`.
    public static var batch: JSONValue {
        guard case .object(var fields) = S.object(batchProperties, required: ["commands"], "An edit batch.") else { return .null }
        fields["$defs"] = .object(definitions)
        return .object(fields)
    }

    /// The whole schema as `tandem schema` prints it.
    public static var document: JSONValue {
        var root = batch
        if case .object(var fields) = root {
            fields["$schema"] = .string("https://json-schema.org/draft/2020-12/schema")
            fields["title"] = .string("Tandem EditBatch")
            root = .object(fields)
        }
        return root
    }

    public static func entry(_ command: CommandCase) -> Entry? {
        entries.first { $0.command == command }
    }

    // MARK: - Validation

    /// Checks one command (already normalised) and returns readable
    /// problems, or none.
    /// `path` names the command in messages, like `commands[2]`.
    public static func validate(command value: JSONValue, path: String = "") -> [String] {
        let at = path.isEmpty ? "" : "\(path): "
        guard case .object(let fields) = value else {
            return ["\(at)an edit command is an object with one key, the command name, like {\"blade\": {\"at\": 12.5}}"]
        }
        guard fields.count == 1, let (name, arguments) = fields.first else {
            let keys = fields.keys.sorted().joined(separator: ", ")
            return ["\(at)an edit command has exactly one key, the command name, but this one has \(fields.count): \(keys)"]
        }
        guard let command = CommandCase(rawValue: name), let entry = entry(command) else {
            let known = CommandCase.allCases.map(\.rawValue)
            let hint = SchemaValidator.closest(name, in: known).map { " Did you mean \"\($0)\"?" } ?? ""
            return ["\(at)unknown command \"\(name)\".\(hint)"]
        }
        var problems: [String] = []
        SchemaValidator().validate(arguments, against: entry.arguments, path: path.isEmpty ? name : "\(path).\(name)", into: &problems)
        return problems
    }

    /// Checks a value against a schema, for tests and callers that build
    /// their own JSON.
    public static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "") -> [String] {
        var problems: [String] = []
        SchemaValidator().validate(value, against: schema, path: path, into: &problems)
        return problems
    }
}

// MARK: - Builders

/// Small helpers that build schema JSON.
enum S {
    static func object(_ properties: [String: JSONValue], required: [String] = [], _ description: String? = nil, closed: Bool = true) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { fields["required"] = .array(required.map(JSONValue.string)) }
        if closed { fields["additionalProperties"] = .bool(false) }
        if let description { fields["description"] = .string(description) }
        return .object(fields)
    }

    /// An object whose keys are free and whose values follow `values`.
    static func map(_ values: JSONValue, _ description: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("object"), "additionalProperties": values]
        if let description { fields["description"] = .string(description) }
        return .object(fields)
    }

    static func array(_ items: JSONValue, _ description: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("array"), "items": items]
        if let description { fields["description"] = .string(description) }
        return .object(fields)
    }

    static func string(_ description: String? = nil) -> JSONValue {
        typed("string", description)
    }

    static func enumeration(_ values: [String], _ description: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("string"), "enum": .array(values.map(JSONValue.string))]
        if let description { fields["description"] = .string(description) }
        return .object(fields)
    }

    static func number(_ description: String? = nil, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("number")]
        if let description { fields["description"] = .string(description) }
        if let minimum { fields["minimum"] = .number(minimum) }
        if let maximum { fields["maximum"] = .number(maximum) }
        return .object(fields)
    }

    static func integer(_ description: String? = nil) -> JSONValue {
        typed("integer", description)
    }

    static func boolean(_ description: String? = nil) -> JSONValue {
        typed("boolean", description)
    }

    static func time(_ description: String = "Seconds.") -> JSONValue {
        number(description)
    }

    static func ids(_ description: String) -> JSONValue {
        array(string(), description)
    }

    /// A JSON merge patch (RFC 7396) on a model object. The validator
    /// checks its keys against the model's schema; `null` removes a key.
    static func patch(of model: String, _ description: String) -> JSONValue {
        .object([
            "type": .string("object"),
            "description": .string(description + " JSON merge patch: only the fields you send change, null removes one."),
            "x-tandem-patch": .string(model)
        ])
    }

    /// A reference to a shared definition in `$defs`.
    static func ref(_ name: String) -> JSONValue {
        .object(["$ref": .string("#/$defs/\(name)")])
    }

    static func anyOf(_ options: [JSONValue], _ description: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["anyOf": .array(options)]
        if let description { fields["description"] = .string(description) }
        return .object(fields)
    }

    static func oneOf(_ options: [JSONValue], _ description: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["oneOf": .array(options)]
        if let description { fields["description"] = .string(description) }
        return .object(fields)
    }

    private static func typed(_ type: String, _ description: String?) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string(type)]
        if let description { fields["description"] = .string(description) }
        return .object(fields)
    }
}

// MARK: - Model schemas

extension CommandSchema {
    /// Shared model schemas, published under `$defs` and referred to with
    /// `{"$ref": "#/$defs/<Name>"}` so each is written out once.
    public static let definitions: [String: JSONValue] = [
        "Point": point, "Rect": rect, "Color": rgba, "FrameRate": frameRate, "ParamValue": paramValue,
        "Effect": effect, "Keyframe": keyframe, "Transform": transform, "Crop": crop, "Mask": mask,
        "Cutout": cutout, "FormatOverride": formatOverride, "VideoProperties": videoProperties,
        "AudioProperties": audioProperties, "TextStyle": textStyle, "TimedWord": timedWord,
        "TextContent": textContent, "GraphicContent": graphicContent, "ClipContent": clipContent,
        "Clip": clip, "MediaItem": mediaItem, "Transition": transition, "Marker": marker,
        "TemplateClip": templateClip, "Template": template, "TimeRange": timeRange
    ]

    /// Models only patches refer to, checked but not published.
    static let patchModels: [String: JSONValue] = [
        "Project": projectHeader,
        "ProjectSettings": projectSettings,
        "Track": track
    ]

    static let point = S.object(["x": S.number(), "y": S.number()], required: ["x", "y"], "Canvas units: (0, 0) top left, (1, 1) bottom right.")

    static let rect = S.object(
        ["x": S.number(), "y": S.number(), "width": S.number(), "height": S.number()],
        required: ["x", "y", "width", "height"],
        "Source units, 0...1 from the top left."
    )

    static let rgba = S.object(
        ["r": S.number(minimum: 0, maximum: 1), "g": S.number(minimum: 0, maximum: 1), "b": S.number(minimum: 0, maximum: 1), "a": S.number(minimum: 0, maximum: 1)],
        required: ["r", "g", "b"],
        "0...1 per channel; a defaults to 1."
    )

    static let frameRate = S.object(["numerator": S.integer(), "denominator": S.integer()], required: ["numerator", "denominator"])

    static let paramValue = S.anyOf([S.number(), S.boolean(), S.string(), S.ref("Color"), S.ref("Point")])

    static let effect = S.object([
        "id": S.string("Optional; set one to refer to it in the same batch."),
        "type": S.string("colorAdjust, hsl, vignette, sharpen, lut, dropShadow, border, roundedCorners, blur, pixelate or pitchShift (see `effects`)."),
        "enabled": S.boolean(),
        "params": S.map(S.ref("ParamValue"), "Missing ones use the defaults.")
    ], required: ["type"])

    static let keyframe = S.object([
        "time": S.time("Seconds from the clip's start."),
        "value": S.ref("ParamValue"),
        "interpolation": S.enumeration(["linear", "easeIn", "easeOut", "easeInOut", "hold"], "Default easeInOut.")
    ], required: ["time", "value"])

    static let transform = S.object([
        "position": S.ref("Point"),
        "scale": S.number("1 fits the canvas; Mike's PiP is 0.5."),
        "rotation": S.number("Degrees clockwise.")
    ])

    static let crop = S.object([
        "left": S.number(minimum: 0, maximum: 1), "top": S.number(minimum: 0, maximum: 1),
        "right": S.number(minimum: 0, maximum: 1), "bottom": S.number(minimum: 0, maximum: 1)
    ], "Fractions of the source hidden at each edge.")

    static let mask = S.object([
        "shape": S.enumeration(["rectangle", "roundedRectangle", "ellipse"]),
        "mode": S.enumeration(["include", "exclude"]),
        "rect": S.ref("Rect"),
        "cornerRadius": S.number(),
        "feather": S.number()
    ], required: ["rect"])

    static let cutout = S.object([
        "enabled": S.boolean(),
        "mode": S.enumeration(["person", "personAndProps"]),
        "edgeFeather": S.number(),
        "choke": S.number(),
        "repairMasks": S.array(S.ref("Mask"))
    ], "The AI portrait cutout.")

    static let formatOverride = S.object(["transform": S.ref("Transform"), "crop": S.ref("Crop"), "hidden": S.boolean()])

    static let videoProperties = S.object([
        "transform": S.ref("Transform"),
        "crop": S.ref("Crop"),
        "opacity": S.number(minimum: 0, maximum: 1),
        "cutout": S.ref("Cutout"),
        "effects": S.array(S.ref("Effect")),
        "layoutPreset": S.string(),
        "formatOverrides": S.map(S.ref("FormatOverride"), "By format ID, like portrait.")
    ])

    static let audioProperties = S.object([
        "gainDB": S.number(),
        "fadeIn": S.time(),
        "fadeOut": S.time(),
        "muted": S.boolean(),
        "normalizeTo": S.number("Level to this loudness (LUFS)."),
        "voiceIsolation": S.number("0 original, 1 fully isolated voice.", minimum: 0, maximum: 1),
        "effects": S.array(S.ref("Effect"))
    ])

    static let textStyle = S.object([
        "font": S.string(), "size": S.number("Points at 1080p."), "weight": S.number(),
        "color": S.ref("Color"), "strokeColor": S.ref("Color"), "strokeWidth": S.number(), "backgroundColor": S.ref("Color"),
        "alignment": S.enumeration(["left", "center", "right"]), "uppercase": S.boolean(), "shadow": S.boolean(),
        "lineSpacing": S.number()
    ])

    static let timedWord = S.object(["text": S.string(), "start": S.time(), "end": S.time()], required: ["text", "start", "end"])

    static let textContent = S.object([
        "text": S.string(),
        "preset": S.string("A title preset, like callout, label or sectionHeader."),
        "style": S.ref("TextStyle"),
        "animationIn": S.string("Like popIn or slideUp."),
        "animationOut": S.string(),
        "animationDuration": S.time(),
        "words": S.array(S.ref("TimedWord"), "For word-by-word captions.")
    ])

    static let graphicContent = S.object([
        "template": S.string("Like remotion:BarChart."),
        "props": S.map(S.ref("ParamValue")),
        "propsJSON": S.string()
    ], required: ["template"])

    static let clipContent = S.oneOf([
        S.object(["media": S.object(["mediaID": S.string()], required: ["mediaID"])], required: ["media"]),
        S.object(["text": S.ref("TextContent")], required: ["text"]),
        S.object(["graphic": S.ref("GraphicContent")], required: ["graphic"]),
        S.object(["solid": S.object(["color": S.ref("Color")])], required: ["solid"]),
        S.object(["adjustment": S.object([:])], required: ["adjustment"])
    ], "One key: media, text, graphic, solid or adjustment.")

    /// `content` is required everywhere except template clips that name
    /// their file with `mediaPath`; Swift decoding reports it when missing.
    static let clip = S.object([
        "id": S.string("Optional; set one to refer to it in the same batch."),
        "name": S.string(),
        "content": S.ref("ClipContent"),
        "start": S.time("Timeline start."),
        "duration": S.time("Timeline length."),
        "sourceStart": S.time("Where playback starts in the media (media time)."),
        "speed": S.number(),
        "freezeFrame": S.boolean(),
        "enabled": S.boolean(),
        "linkGroup": S.string(),
        "video": S.ref("VideoProperties"),
        "audio": S.ref("AudioProperties"),
        "keyframes": S.map(S.array(S.ref("Keyframe")), "By parameter path, like video.transform.scale."),
        "tags": S.array(S.string())
    ], required: ["duration"], "A clip. content is required (except in a template clip with mediaPath).")

    static let mediaItem = S.object([
        "id": S.string("Optional."),
        "path": S.string("Relative to the project folder, or absolute."),
        "kind": S.enumeration(MediaKind.allCases.map(\.rawValue)),
        "role": S.enumeration(MediaRole.allCases.map(\.rawValue)),
        "takeID": S.string(), "takeOffset": S.time(),
        "duration": S.time(), "frameRate": S.ref("FrameRate"), "width": S.integer(), "height": S.integer(),
        "hasVideo": S.boolean(), "hasAudio": S.boolean(), "hasAlpha": S.boolean(), "variableFrameRate": S.boolean(),
        "fingerprint": S.string(),
        "look": S.array(S.ref("Effect"), "Colour grade for every clip of the file.")
    ], required: ["path"])

    static let transition = S.object([
        "id": S.string("Optional."),
        "type": S.enumeration(TransitionType.allCases.map(\.rawValue)),
        "direction": S.enumeration(["up", "down", "left", "right"]),
        "duration": S.time("Defaults to the type's usual length."),
        "fromClipID": S.string("Outgoing clip; leave out for a head transition."),
        "toClipID": S.string("Incoming clip; leave out for a tail transition.")
    ], required: ["type"])

    static let marker = S.object([
        "id": S.string("Optional."),
        "time": S.time(),
        "duration": S.time(),
        "name": S.string(),
        "kind": S.enumeration(["marker", "section", "chapter", "todo"]),
        "note": S.string()
    ], required: ["time"])

    static let templateClip = S.object([
        "track": S.string("Track name, created if missing."),
        "trackKind": S.enumeration(["video", "audio"]),
        "offset": S.time("Start relative to the template."),
        "clip": S.ref("Clip"),
        "mediaPath": S.string("For media clips: the path of a file in the project.")
    ], required: ["track", "clip"])

    static let template = S.object([
        "id": S.string(),
        "name": S.string(),
        "duration": S.time(),
        "fields": S.array(S.object(["key": S.string(), "label": S.string(), "defaultValue": S.string()], required: ["key"])),
        "clips": S.array(S.ref("TemplateClip"))
    ], required: ["id", "duration", "clips"])

    static let timeRange = S.object([
        "start": S.time(),
        "duration": S.time(),
        "end": S.time("Instead of duration.")
    ], required: ["start"], "start plus duration (or end), in seconds.")

    static let projectHeader = S.object(["name": S.string(), "metadata": S.map(S.string())])

    static let projectSettings = S.object([
        "width": S.integer(), "height": S.integer(), "frameRate": S.ref("FrameRate"), "sampleRate": S.integer(),
        "loudnessTarget": S.number(), "truePeakCeiling": S.number(), "colorSpace": S.string(),
        "alternateFormats": S.array(S.object(["id": S.string(), "name": S.string(), "width": S.integer(), "height": S.integer()], required: ["id", "name", "width", "height"]))
    ])

    static let track = S.object([
        "id": S.string(), "kind": S.enumeration(["video", "audio"]), "name": S.string(),
        "clips": S.array(S.ref("Clip")), "transitions": S.array(S.ref("Transition")),
        "muted": S.boolean(), "solo": S.boolean(), "locked": S.boolean(), "hidden": S.boolean(), "targeted": S.boolean(),
        "rippleMode": S.enumeration(RippleMode.allCases.map(\.rawValue))
    ])
}

// MARK: - Commands

extension CommandSchema {
    static let insertMode = S.enumeration(["place", "overwrite", "insert"], "place (default) fails if the range is taken, overwrite replaces what's there, insert pushes later clips right.")
    static let includeLinked = S.boolean("Also act on linked clips (default true).")

    public static let entries: [Entry] = [
        Entry(
            command: .updateProject,
            summary: "Changes the project's name or metadata.",
            arguments: S.object(["patch": S.patch(of: "Project", "Fields: name, metadata.")], required: ["patch"]),
            example: #"{"updateProject": {"patch": {"name": "Decision Models v2", "metadata": {"script": "script.md"}}}}"#
        ),
        Entry(
            command: .updateSettings,
            summary: "Changes canvas size, frame rate or loudness target.",
            arguments: S.object(["patch": S.patch(of: "ProjectSettings", "Fields: width, height, frameRate, sampleRate, loudnessTarget, truePeakCeiling, colorSpace, alternateFormats.")], required: ["patch"]),
            example: #"{"updateSettings": {"patch": {"loudnessTarget": -14}}}"#
        ),
        Entry(
            command: .addTrack,
            summary: "Adds a track.",
            arguments: S.object([
                "kind": S.enumeration(["video", "audio"]),
                "name": S.string(),
                "index": S.integer("Position among tracks of that kind; video counts from the bottom. Default: on top (video) or last (audio)."),
                "id": S.string("Optional ID to use.")
            ], required: ["kind"]),
            example: #"{"addTrack": {"kind": "video", "name": "Stickers"}}"#
        ),
        Entry(
            command: .removeTrack,
            summary: "Removes a track and everything on it.",
            arguments: S.object(["trackID": S.string()], required: ["trackID"]),
            example: #"{"removeTrack": {"trackID": "trk_stickers"}}"#
        ),
        Entry(
            command: .moveTrack,
            summary: "Moves a track to another position among tracks of its kind.",
            arguments: S.object(["trackID": S.string(), "index": S.integer()], required: ["trackID", "index"]),
            example: #"{"moveTrack": {"trackID": "trk_stickers", "index": 2}}"#
        ),
        Entry(
            command: .updateTrack,
            summary: "Changes a track's name, mute, solo, lock, hidden, targeted or ripple mode.",
            arguments: S.object(["trackID": S.string(), "patch": S.patch(of: "Track", "Fields: name, muted, solo, locked, hidden, targeted, rippleMode (cut, follow, off).")], required: ["trackID", "patch"]),
            example: #"{"updateTrack": {"trackID": "trk_music", "patch": {"muted": true}}}"#
        ),
        Entry(
            command: .addMedia,
            summary: "Adds a media file to the project (not the timeline). Usually `tandem media --refresh` does this for you.",
            arguments: S.object(["item": S.ref("MediaItem")], required: ["item"]),
            example: #"{"addMedia": {"item": {"path": "broll/servers.mp4", "kind": "video", "role": "broll", "duration": 12.5, "hasVideo": true}}}"#
        ),
        Entry(
            command: .updateMedia,
            summary: "Changes a media item, for example its role or colour look.",
            arguments: S.object(["mediaID": S.string(), "patch": S.patch(of: "MediaItem", "Any MediaItem field except id.")], required: ["mediaID", "patch"]),
            example: #"{"updateMedia": {"mediaID": "med_screen", "patch": {"role": "screen"}}}"#
        ),
        Entry(
            command: .removeMedia,
            summary: "Removes a media item. Fails while clips still use it.",
            arguments: S.object(["mediaID": S.string()], required: ["mediaID"]),
            example: #"{"removeMedia": {"mediaID": "med_unused"}}"#
        ),
        Entry(
            command: .placeMedia,
            summary: "Puts media on the timeline the way the app does: each file on the track for its role, camera sound on Voice, files from one take placed in sync and linked.",
            arguments: S.object([
                "mediaIDs": S.ids("One file, or the files of one take."),
                "at": S.time("Timeline time to place at."),
                "sourceStart": S.time("Where to start in the take (or file), in seconds. Default: where all files have started."),
                "duration": S.time("Default: all the media that's left."),
                "mode": insertMode,
                "videoTrackID": S.string("Force the video track (single file only)."),
                "audioTrackID": S.string("Force the audio track (single file only)."),
                "includeAudio": S.boolean("Place the file's sound too. Default depends on the role (camera, music, sfx: yes).")
            ], required: ["mediaIDs", "at"]),
            example: #"{"placeMedia": {"mediaIDs": ["med_camera", "med_screen"], "at": 0}}"#
        ),
        Entry(
            command: .insertClip,
            summary: "Adds one clip to a track: a text title, a solid, a graphic, an adjustment layer or part of a media file.",
            arguments: S.object(["trackID": S.string(), "clip": S.ref("Clip"), "mode": insertMode], required: ["trackID", "clip"]),
            example: #"{"insertClip": {"trackID": "trk_text", "clip": {"content": {"text": {"text": "TIP 1", "preset": "callout"}}, "start": 12, "duration": 3}}}"#
        ),
        Entry(
            command: .removeClips,
            summary: "Removes clips. Without ripple they leave a gap (lift); with ripple the gap closes like Shift-Delete.",
            arguments: S.object(["clipIDs": S.ids("Clips to remove."), "ripple": S.boolean(), "includeLinked": includeLinked], required: ["clipIDs"]),
            example: #"{"removeClips": {"clipIDs": ["clip_k3f9x2mq"], "ripple": true}}"#
        ),
        Entry(
            command: .rippleDeleteRange,
            summary: "Removes a stretch of time and closes it up: every cut track (screen, camera, voice) loses it and follow tracks (B-roll, music, titles) move with it. This is how pauses get tightened.",
            arguments: S.object(["range": S.ref("TimeRange"), "trackIDs": S.ids("Only cut these tracks (and ripple from them). Default: every cut track.")], required: ["range"]),
            example: #"{"rippleDeleteRange": {"range": {"start": 12.4, "duration": 0.8}}}"#
        ),
        Entry(
            command: .closeGap,
            summary: "Closes the gap on a track that contains a time. Fails if another cut track has content in that gap.",
            arguments: S.object(["trackID": S.string(), "at": S.time("Any time inside the gap.")], required: ["trackID", "at"]),
            example: #"{"closeGap": {"trackID": "trk_broll", "at": 27}}"#
        ),
        Entry(
            command: .insertTime,
            summary: "Opens up empty time, pushing everything later to the right.",
            arguments: S.object(["at": S.time(), "duration": S.time(), "trackIDs": S.ids("Default: every cut track, with the rest following.")], required: ["at", "duration"]),
            example: #"{"insertTime": {"at": 30, "duration": 2}}"#
        ),
        Entry(
            command: .insertTemplate,
            summary: "Expands a template (a section card, Like and Subscribe) into linked clips, filling {{field}} placeholders from values. Media it uses must already be in the project.",
            arguments: S.object([
                "template": S.ref("Template"),
                "at": S.time(),
                "values": S.map(S.string(), "Field values by key, like {\"title\": \"CURSOR DOCS\"}."),
                "mode": insertMode
            ], required: ["template", "at"]),
            example: #"{"insertTemplate": {"template": {"id": "sectionCard", "name": "Section card", "duration": 3, "fields": [{"key": "title", "label": "Title"}], "clips": [{"track": "Text", "clip": {"content": {"text": {"text": "{{title}}", "preset": "sectionHeader"}}, "duration": 3}}]}, "at": 60, "values": {"title": "CURSOR DOCS"}}}"#
        ),
        Entry(
            command: .blade,
            summary: "Cuts clips at a time. With clipIDs only those clips (and their linked partners); otherwise every clip under the time on the given tracks, or on all targeted tracks.",
            arguments: S.object(["at": S.time(), "trackIDs": S.ids("Only these tracks."), "clipIDs": S.ids("Only these clips.")], required: ["at"]),
            example: #"{"blade": {"at": 12.5}}"#
        ),
        Entry(
            command: .trim,
            summary: "Moves a clip edge to a timeline time. With ripple the clip keeps its place and everything after it moves instead.",
            arguments: S.object([
                "clipID": S.string(), "edge": S.enumeration(["start", "end"]), "to": S.time("The new edge time on the timeline."),
                "ripple": S.boolean(), "includeLinked": includeLinked
            ], required: ["clipID", "edge", "to"]),
            example: #"{"trim": {"clipID": "clip_k3f9x2mq", "edge": "end", "to": 42.2, "ripple": true}}"#
        ),
        Entry(
            command: .roll,
            summary: "Moves the cut between two adjacent clips, trimming both (and the same cut on linked tracks).",
            arguments: S.object(["leftClipID": S.string(), "rightClipID": S.string(), "delta": S.time("Seconds; negative moves the cut earlier.")], required: ["leftClipID", "rightClipID", "delta"]),
            example: #"{"roll": {"leftClipID": "clip_a", "rightClipID": "clip_b", "delta": 0.5}}"#
        ),
        Entry(
            command: .slip,
            summary: "Changes which part of the media a clip shows without moving it. delta is media time.",
            arguments: S.object(["clipID": S.string(), "delta": S.time("Seconds of media; negative shows earlier media."), "includeLinked": includeLinked], required: ["clipID", "delta"]),
            example: #"{"slip": {"clipID": "clip_k3f9x2mq", "delta": -1}}"#
        ),
        Entry(
            command: .slide,
            summary: "Moves a clip between its neighbours, trimming them to compensate.",
            arguments: S.object(["clipID": S.string(), "delta": S.time()], required: ["clipID", "delta"]),
            example: #"{"slide": {"clipID": "clip_k3f9x2mq", "delta": 2}}"#
        ),
        Entry(
            command: .setSpeed,
            summary: "Changes speed, keeping the same media, so the clip gets shorter or longer. Linked clips change with it.",
            arguments: S.object([
                "clipID": S.string(), "speed": S.number("2 plays twice as fast.", minimum: 0, maximum: 100),
                "ripple": S.boolean("Move later clips to fit."), "includeLinked": includeLinked
            ], required: ["clipID", "speed"]),
            example: #"{"setSpeed": {"clipID": "clip_k3f9x2mq", "speed": 1.5, "ripple": true}}"#
        ),
        Entry(
            command: .moveClips,
            summary: "Moves clips in time and optionally to another track.",
            arguments: S.object([
                "clipIDs": S.ids("Clips to move."), "delta": S.time("Seconds to move by."), "toTrackID": S.string("Another track (clips from one track only)."),
                "includeLinked": includeLinked, "mode": S.enumeration(["place", "overwrite"], "place (default) fails if the destination is taken.")
            ], required: ["clipIDs"]),
            example: #"{"moveClips": {"clipIDs": ["clip_k3f9x2mq"], "delta": 5, "toTrackID": "trk_graphics"}}"#
        ),
        Entry(
            command: .updateClip,
            summary: "Changes a clip's settings: transform, crop, opacity, cutout, audio gain and fades, text, speed...",
            arguments: S.object(["clipID": S.string(), "patch": S.patch(of: "Clip", "Any Clip field except id, like {\"video\": {\"transform\": {\"scale\": 0.5}}} or {\"audio\": {\"gainDB\": -3}}.")], required: ["clipID", "patch"]),
            example: #"{"updateClip": {"clipID": "clip_k3f9x2mq", "patch": {"video": {"opacity": 0.5}}}}"#
        ),
        Entry(
            command: .link,
            summary: "Links clips so they select, move, trim and cut together.",
            arguments: S.object(["clipIDs": S.ids("At least two clips.")], required: ["clipIDs"]),
            example: #"{"link": {"clipIDs": ["clip_a", "clip_b"]}}"#
        ),
        Entry(
            command: .unlink,
            summary: "Takes clips out of their link group.",
            arguments: S.object(["clipIDs": S.ids("Clips to unlink.")], required: ["clipIDs"]),
            example: #"{"unlink": {"clipIDs": ["clip_a"]}}"#
        ),
        Entry(
            command: .applyLayout,
            summary: "Sets a one-key layout on video clips: full, pipRight (50% with the cutout and shadow, bottom right), pipLeft, or split. Audio clips in the list are skipped.",
            arguments: S.object(["clipIDs": S.ids("Video clips."), "preset": S.enumeration(LayoutPreset.allCases.map(\.rawValue))], required: ["clipIDs", "preset"]),
            example: #"{"applyLayout": {"clipIDs": ["clip_cam1"], "preset": "pipRight"}}"#
        ),
        Entry(
            command: .zoomToRegion,
            summary: "Zooms a video clip into a rectangle of its source. Without at the zoom is static; with at it animates there over duration (default 0.5 s). Zoom back out with {x: 0, y: 0, width: 1, height: 1}.",
            arguments: S.object([
                "clipID": S.string(), "rect": S.ref("Rect"),
                "at": S.time("Timeline time the zoom starts."), "duration": S.time("How long the zoom takes. Default 0.5.")
            ], required: ["clipID", "rect"]),
            example: #"{"zoomToRegion": {"clipID": "clip_scr1", "rect": {"x": 0.5, "y": 0.25, "width": 0.5, "height": 0.5}, "at": 42, "duration": 0.5}}"#
        ),
        Entry(
            command: .addTransition,
            summary: "Adds a transition between two touching clips (needs spare media on both sides) or at one clip's head or tail.",
            arguments: S.object(["trackID": S.string(), "transition": S.ref("Transition")], required: ["trackID", "transition"]),
            example: #"{"addTransition": {"trackID": "trk_camera", "transition": {"type": "dissolve", "duration": 0.5, "fromClipID": "clip_a", "toClipID": "clip_b"}}}"#
        ),
        Entry(
            command: .updateTransition,
            summary: "Changes a transition's type, direction or duration.",
            arguments: S.object(["transitionID": S.string(), "patch": S.patch(of: "Transition", "Fields: type, direction, duration.")], required: ["transitionID", "patch"]),
            example: #"{"updateTransition": {"transitionID": "tr_x", "patch": {"duration": 0.8}}}"#
        ),
        Entry(
            command: .removeTransition,
            summary: "Removes a transition.",
            arguments: S.object(["transitionID": S.string()], required: ["transitionID"]),
            example: #"{"removeTransition": {"transitionID": "tr_x"}}"#
        ),
        Entry(
            command: .addEffect,
            summary: "Adds an effect to a clip's video or audio effects (by the effect's kind).",
            arguments: S.object(["clipID": S.string(), "effect": S.ref("Effect"), "index": S.integer("Position in the effect list. Default: last.")], required: ["clipID", "effect"]),
            example: #"{"addEffect": {"clipID": "clip_cam1", "effect": {"type": "dropShadow", "params": {"opacity": 40}}}}"#
        ),
        Entry(
            command: .updateEffect,
            summary: "Changes an effect's parameters or turns it on or off.",
            arguments: S.object(["clipID": S.string(), "effectID": S.string(), "patch": S.patch(of: "Effect", "Fields: enabled, params.")], required: ["clipID", "effectID", "patch"]),
            example: #"{"updateEffect": {"clipID": "clip_cam1", "effectID": "fx_s", "patch": {"params": {"blur": 8}}}}"#
        ),
        Entry(
            command: .removeEffect,
            summary: "Removes an effect and its animations.",
            arguments: S.object(["clipID": S.string(), "effectID": S.string()], required: ["clipID", "effectID"]),
            example: #"{"removeEffect": {"clipID": "clip_cam1", "effectID": "fx_s"}}"#
        ),
        Entry(
            command: .moveEffect,
            summary: "Moves an effect to another position in the clip's effect list.",
            arguments: S.object(["clipID": S.string(), "effectID": S.string(), "index": S.integer()], required: ["clipID", "effectID", "index"]),
            example: #"{"moveEffect": {"clipID": "clip_cam1", "effectID": "fx_s", "index": 0}}"#
        ),
        Entry(
            command: .setKeyframes,
            summary: "Replaces the keyframes of one parameter, like video.transform.scale, video.opacity, audio.gainDB or video.effects.<effectID>.<param>. An empty list removes the animation.",
            arguments: S.object([
                "clipID": S.string(),
                "parameter": S.string("Parameter path. See `tandem effects` for the list."),
                "keyframes": S.array(S.ref("Keyframe"), "Times are seconds from the clip's start.")
            ], required: ["clipID", "parameter", "keyframes"]),
            example: #"{"setKeyframes": {"clipID": "clip_scr1", "parameter": "video.transform.scale", "keyframes": [{"time": 0, "value": 1, "interpolation": "linear"}, {"time": 2, "value": 1.5}]}}"#
        ),
        Entry(
            command: .addMarker,
            summary: "Adds a marker (marker, section, chapter or todo).",
            arguments: S.object(["marker": S.ref("Marker")], required: ["marker"]),
            example: #"{"addMarker": {"marker": {"time": 95, "name": "Section 2", "kind": "section"}}}"#
        ),
        Entry(
            command: .updateMarker,
            summary: "Changes a marker.",
            arguments: S.object(["markerID": S.string(), "patch": S.patch(of: "Marker", "Fields: time, duration, name, kind, note.")], required: ["markerID", "patch"]),
            example: #"{"updateMarker": {"markerID": "mk_x", "patch": {"name": "Intro"}}}"#
        ),
        Entry(
            command: .removeMarker,
            summary: "Removes a marker.",
            arguments: S.object(["markerID": S.string()], required: ["markerID"]),
            example: #"{"removeMarker": {"markerID": "mk_x"}}"#
        )
    ]
}

// MARK: - Validator

/// Checks JSON against the subset of JSON Schema the command schema uses:
/// type, properties, required, additionalProperties, items, enum, oneOf,
/// anyOf, minimum and maximum, plus `x-tandem-patch` for merge patches.
struct SchemaValidator {
    /// In a merge patch every field is optional and null removes one.
    var patch = false

    func validate(_ value: JSONValue, against schema: JSONValue, path: String, into problems: inout [String]) {
        guard case .object(let rules) = schema else { return }
        let at = path.isEmpty ? "" : "\(path): "

        if patch, case .null = value { return }

        if case .string(let reference)? = rules["$ref"] {
            let name = reference.replacingOccurrences(of: "#/$defs/", with: "")
            if let definition = CommandSchema.definitions[name] ?? CommandSchema.patchModels[name] {
                validate(value, against: definition, path: path, into: &problems)
            }
            return
        }

        if case .string(let model)? = rules["x-tandem-patch"] {
            guard case .object = value else {
                problems.append("\(at)a patch must be a JSON object")
                return
            }
            if let modelSchema = CommandSchema.definitions[model] ?? CommandSchema.patchModels[model] {
                SchemaValidator(patch: true).validate(value, against: modelSchema, path: path, into: &problems)
            }
            return
        }

        if case .array(let options)? = rules["oneOf"] ?? rules["anyOf"] {
            validateAlternatives(value, options, path: path, into: &problems)
            return
        }

        if let type = rules["type"], !matches(value, type) {
            problems.append("\(at)expected \(describe(type)), got \(kind(of: value))")
            return
        }

        if case .array(let allowed)? = rules["enum"], !allowed.contains(value) {
            let names = allowed.compactMap { v -> String? in if case .string(let s) = v { return s }; return nil }
            problems.append("\(at)\(render(value)) isn't allowed; use one of \(names.joined(separator: ", "))")
            return
        }

        if case .number(let number) = value {
            if case .number(let minimum)? = rules["minimum"], number < minimum {
                problems.append("\(at)\(CommandSchemaNumber.text(number)) is below the minimum \(CommandSchemaNumber.text(minimum))")
            }
            if case .number(let maximum)? = rules["maximum"], number > maximum {
                problems.append("\(at)\(CommandSchemaNumber.text(number)) is above the maximum \(CommandSchemaNumber.text(maximum))")
            }
        }

        if case .object(let fields) = value {
            let properties: [String: JSONValue]
            if case .object(let p)? = rules["properties"] { properties = p } else { properties = [:] }
            // A misspelt required field reads better as one problem ("did you
            // mean") than two, so a missing field that an unknown one is
            // probably meant to be isn't reported on its own.
            var meant = Set<String>()
            if case .bool(false)? = rules["additionalProperties"] {
                for key in fields.keys where properties[key] == nil {
                    if let guess = Self.closest(key, in: Array(properties.keys)) { meant.insert(guess) }
                }
            }
            if !patch, case .array(let required)? = rules["required"] {
                for case .string(let key) in required where fields[key] == nil && !meant.contains(key) {
                    problems.append("\(at)missing \"\(key)\"")
                }
            }
            for key in fields.keys.sorted() {
                let child = path.isEmpty ? key : "\(path).\(key)"
                if let propertySchema = properties[key] {
                    validate(fields[key]!, against: propertySchema, path: child, into: &problems)
                } else if let additional = rules["additionalProperties"] {
                    if case .bool(false) = additional {
                        let hint = Self.closest(key, in: Array(properties.keys)).map { " (did you mean \"\($0)\"?)" } ?? ""
                        let allowed = properties.keys.sorted().joined(separator: ", ")
                        problems.append("\(at)unknown field \"\(key)\"\(hint). Allowed: \(allowed)")
                    } else if case .object = additional {
                        validate(fields[key]!, against: additional, path: child, into: &problems)
                    }
                }
            }
        }

        if case .array(let items) = value, let itemSchema = rules["items"] {
            for (index, item) in items.enumerated() {
                validate(item, against: itemSchema, path: "\(path)[\(index)]", into: &problems)
            }
        }
    }

    /// oneOf/anyOf. Tagged unions (objects with one required key, like
    /// clip content) report the errors of the branch the value picked.
    private func validateAlternatives(_ value: JSONValue, _ options: [JSONValue], path: String, into problems: inout [String]) {
        let at = path.isEmpty ? "" : "\(path): "
        var branchProblems: [[String]] = []
        for option in options {
            var found: [String] = []
            validate(value, against: option, path: path, into: &found)
            if found.isEmpty { return }
            branchProblems.append(found)
        }
        if case .object(let fields) = value, fields.count == 1, let key = fields.keys.first {
            for (index, option) in options.enumerated() {
                if case .object(let rules) = option, case .array(let required)? = rules["required"],
                   required == [.string(key)] {
                    problems.append(contentsOf: branchProblems[index])
                    return
                }
            }
        }
        let forms = options.compactMap { option -> String? in
            guard case .object(let rules) = option else { return nil }
            if case .array(let required)? = rules["required"], required.count == 1, case .string(let key) = required[0] { return "{\"\(key)\": ...}" }
            if let type = rules["type"] { return describe(type) }
            return nil
        }
        problems.append("\(at)\(render(value)) doesn't match any allowed form (\(forms.joined(separator: ", ")))")
    }

    private func matches(_ value: JSONValue, _ type: JSONValue) -> Bool {
        switch type {
        case .string(let name): return matches(value, name)
        case .array(let names): return names.contains { if case .string(let n) = $0 { return matches(value, n) }; return false }
        default: return true
        }
    }

    private func matches(_ value: JSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null), ("number", .number):
            return true
        case ("integer", .number(let n)):
            return n == n.rounded()
        default:
            return false
        }
    }

    private func describe(_ type: JSONValue) -> String {
        switch type {
        case .string(let name): return article(name)
        case .array(let names): return names.compactMap { if case .string(let n) = $0 { return article(n) }; return nil }.joined(separator: " or ")
        default: return "a value"
        }
    }

    private func article(_ type: String) -> String {
        switch type {
        case "object": return "an object"
        case "array": return "an array"
        case "integer": return "a whole number"
        case "boolean": return "true or false"
        case "null": return "null"
        default: return "a \(type)"
        }
    }

    private func kind(of value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "true/false"
        case .number(let n): return CommandSchemaNumber.text(n)
        case .string(let s): return "\"\(s)\""
        case .array: return "an array"
        case .object: return "an object"
        }
    }

    private func render(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return CommandSchemaNumber.text(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array: return "this array"
        case .object: return "this object"
        }
    }

    /// The closest name within an edit distance of 2, for "did you mean".
    static func closest(_ word: String, in candidates: [String]) -> String? {
        let lower = word.lowercased()
        var best: (String, Int)?
        for candidate in candidates {
            let distance = editDistance(lower, candidate.lowercased())
            if distance <= 2, distance < (best?.1 ?? Int.max) { best = (candidate, distance) }
        }
        return best?.0
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

enum CommandSchemaNumber {
    static func text(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}
