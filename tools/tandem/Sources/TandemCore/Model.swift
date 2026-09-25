import Foundation

// The Tandem project model. A project is one JSON file (`*.tandem`) that
// lives in the video's folder next to its media. Everything here is plain
// value types so an edit is "copy the project, change it, validate it", and
// undo is keeping the previous copy.
//
// Conventions:
// - IDs are short strings with a type prefix (`clip_`, `trk_`, `med_`...).
//   They never change once assigned, so agents can hold on to them.
// - Times are `Time` values, written to JSON as seconds.
// - Positions are normalised to the canvas: x and y run 0...1 from the top
//   left, and a scale of 1 means "fit the canvas". Mike's usual camera PiP is
//   scale 0.5 at (0.89, 0.80), the same numbers Filmora used.
// - Video tracks are ordered bottom to top: `videoTracks[0]` is V1 and draws
//   first, the last video track draws on top.

public struct Project: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var settings: ProjectSettings
    public var media: [MediaItem]
    public var videoTracks: [Track]
    public var audioTracks: [Track]
    public var markers: [Marker]
    /// Free-form notes for people and agents, for example the script source.
    public var metadata: [String: String]

    public init(
        id: String = IDs.make("prj"),
        name: String,
        settings: ProjectSettings = ProjectSettings(),
        media: [MediaItem] = [],
        videoTracks: [Track] = [],
        audioTracks: [Track] = [],
        markers: [Marker] = [],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = Project.currentSchemaVersion
        self.id = id
        self.name = name
        self.settings = settings
        self.media = media
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.markers = markers
        self.metadata = metadata
    }

    /// A new project with Mike's usual track layout: screen on V1, camera on
    /// V2, B-roll and graphics above, then voice, music and SFX.
    public static func standard(name: String) -> Project {
        Project(
            name: name,
            videoTracks: [
                Track(kind: .video, name: "Screen", rippleMode: .cut),
                Track(kind: .video, name: "Camera", rippleMode: .cut),
                Track(kind: .video, name: "B-roll", rippleMode: .follow),
                Track(kind: .video, name: "Graphics", rippleMode: .follow),
                Track(kind: .video, name: "Text", rippleMode: .follow)
            ],
            audioTracks: [
                Track(kind: .audio, name: "Voice", rippleMode: .cut),
                Track(kind: .audio, name: "Music", rippleMode: .follow),
                Track(kind: .audio, name: "SFX", rippleMode: .follow)
            ]
        )
    }

    public var allTracks: [Track] { videoTracks + audioTracks }

    /// The end of the last clip on any track.
    public var duration: Time {
        allTracks.flatMap(\.clips).map(\.end).max() ?? .zero
    }
}

public struct ProjectSettings: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public var sampleRate: Int
    /// Integrated loudness the master is normalised to, in LUFS.
    public var loudnessTarget: Double
    /// True peak ceiling for the master limiter, in dBTP.
    public var truePeakCeiling: Double
    /// Working colour space. V1 is SDR Rec.709 only.
    public var colorSpace: String
    /// Extra output formats cut from the same timeline, such as a 9:16
    /// short. Clips place themselves per format with `formatOverrides`.
    public var alternateFormats: [OutputFormat]

    public init(
        width: Int = 3840,
        height: Int = 2160,
        frameRate: FrameRate = .fps30,
        sampleRate: Int = 48_000,
        loudnessTarget: Double = -14,
        truePeakCeiling: Double = -1,
        colorSpace: String = "rec709",
        alternateFormats: [OutputFormat] = []
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.sampleRate = sampleRate
        self.loudnessTarget = loudnessTarget
        self.truePeakCeiling = truePeakCeiling
        self.colorSpace = colorSpace
        self.alternateFormats = alternateFormats
    }
}

public struct OutputFormat: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var width: Int
    public var height: Int

    public init(id: String, name: String, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
    }

    public static let portrait = OutputFormat(id: "portrait", name: "Short (9:16)", width: 1080, height: 1920)
}

// MARK: - Media

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case video, audio, image
}

/// What a file is for. Drives defaults (which track it lands on, whether it
/// gets a cutout matte or voice isolation) and the media browser grouping.
public enum MediaRole: String, Codable, Sendable, CaseIterable {
    case camera, screen, broll, graphic, sticker, music, sfx, image, other
}

public struct MediaItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// Path relative to the project folder when the file is inside it,
    /// otherwise absolute.
    public var path: String
    public var kind: MediaKind
    public var role: MediaRole
    /// Camera and screen files from the same record-it take share a take ID.
    public var takeID: String?
    /// How long after the start of the take this file starts. The files of
    /// one take start a moment apart; placing a take uses this to keep them
    /// in sync.
    public var takeOffset: Time?
    public var duration: Time?
    public var frameRate: FrameRate?
    public var width: Int?
    public var height: Int?
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var hasAlpha: Bool
    /// True when the source uses variable frame durations (screen recordings).
    public var variableFrameRate: Bool
    /// Cheap identity check: size, modification time and a hash of the first
    /// and last megabyte. Used for cache keys and relinking.
    public var fingerprint: String?
    /// The source look: colour and sharpening applied to every clip of this
    /// file before the clip's own effects, so a camera grade is set once.
    public var look: [Effect]

    public init(
        id: String = IDs.make("med"),
        path: String,
        kind: MediaKind,
        role: MediaRole,
        takeID: String? = nil,
        takeOffset: Time? = nil,
        duration: Time? = nil,
        frameRate: FrameRate? = nil,
        width: Int? = nil,
        height: Int? = nil,
        hasVideo: Bool = false,
        hasAudio: Bool = false,
        hasAlpha: Bool = false,
        variableFrameRate: Bool = false,
        fingerprint: String? = nil,
        look: [Effect] = []
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.role = role
        self.takeID = takeID
        self.takeOffset = takeOffset
        self.duration = duration
        self.frameRate = frameRate
        self.width = width
        self.height = height
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.hasAlpha = hasAlpha
        self.variableFrameRate = variableFrameRate
        self.fingerprint = fingerprint
        self.look = look
    }
}

// MARK: - Tracks and clips

public enum TrackKind: String, Codable, Sendable {
    case video, audio
}

/// How a track reacts when a ripple edit (ripple delete, ripple trim, insert)
/// happens on a `.cut` track.
///
/// Edits on a `.follow` or `.off` track only ripple that track, so closing a
/// gap in the B-roll never touches the take.
public enum RippleMode: String, Codable, Sendable, CaseIterable {
    /// Removed time is cut out of this track too, so it stays in sync with the
    /// edit. For the tracks that hold the take: screen, camera and voice.
    case cut
    /// Clips move with the content under them but aren't cut. A music bed or
    /// B-roll shot that spans removed time loses that much from its tail.
    case follow
    /// Ripple edits elsewhere leave this track alone.
    case off
}

public struct Track: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: TrackKind
    public var name: String
    /// Sorted by start time and never overlapping. Commands keep this true.
    public var clips: [Clip]
    /// Transitions between clips on this track, or at a clip's head or tail.
    public var transitions: [Transition]
    public var muted: Bool
    public var solo: Bool
    public var locked: Bool
    /// Hidden video tracks don't render. Audio tracks use `muted`.
    public var hidden: Bool
    /// Targeted tracks receive inserts, pastes and blade-at-playhead.
    public var targeted: Bool
    /// What ripple edits on other tracks do here. See `RippleMode`.
    public var rippleMode: RippleMode

    public init(
        id: String = IDs.make("trk"),
        kind: TrackKind,
        name: String,
        clips: [Clip] = [],
        transitions: [Transition] = [],
        muted: Bool = false,
        solo: Bool = false,
        locked: Bool = false,
        hidden: Bool = false,
        targeted: Bool = true,
        rippleMode: RippleMode = .cut
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.clips = clips
        self.transitions = transitions
        self.muted = muted
        self.solo = solo
        self.locked = locked
        self.hidden = hidden
        self.targeted = targeted
        self.rippleMode = rippleMode
    }
}

/// What a clip shows or plays. In JSON it's an object with one key naming
/// the kind: `{"media": {"mediaID": "med_x"}}`, `{"text": {"text": "Hi"}}`,
/// `{"graphic": {...}}`, `{"solid": {"color": {...}}}` or `{"adjustment": {}}`.
public enum ClipContent: Equatable, Sendable {
    /// Part of a media file.
    case media(mediaID: String)
    /// A text layer drawn by Tandem.
    case text(TextContent)
    /// A graphic from a template (a Remotion component or a built-in),
    /// rendered to a cached file in the background.
    case graphic(GraphicContent)
    /// A solid colour, for example a black slug.
    case solid(color: RGBA)
    /// Applies its effects to everything on the tracks below it.
    case adjustment
}

public struct Clip: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var content: ClipContent
    /// Where the clip starts on the timeline.
    public var start: Time
    /// How long the clip lasts on the timeline.
    public var duration: Time
    /// Where playback starts inside the media, in media time.
    public var sourceStart: Time
    /// Playback speed. 2 plays twice as fast. Audio is pitch corrected.
    public var speed: Double
    /// Holds the frame at `sourceStart` for the whole clip.
    public var freezeFrame: Bool
    public var enabled: Bool
    /// Clips that share a link group are selected, moved, trimmed and cut
    /// together: a camera clip, its audio and the matching screen clip.
    public var linkGroup: String?
    public var video: VideoProperties?
    public var audio: AudioProperties?
    /// Animated parameters. Keys are parameter paths such as
    /// `video.transform.scale`, `video.opacity` or `audio.gainDB`. Keyframe
    /// times are relative to the clip start, so they move with the clip.
    public var keyframes: [String: [Keyframe]]
    /// Free-form tags, for example `"bleeps"` or `"agent:claude"`.
    public var tags: [String]

    public init(
        id: String = IDs.make("clip"),
        name: String? = nil,
        content: ClipContent,
        start: Time,
        duration: Time,
        sourceStart: Time = .zero,
        speed: Double = 1,
        freezeFrame: Bool = false,
        enabled: Bool = true,
        linkGroup: String? = nil,
        video: VideoProperties? = nil,
        audio: AudioProperties? = nil,
        keyframes: [String: [Keyframe]] = [:],
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.start = start
        self.duration = duration
        self.sourceStart = sourceStart
        self.speed = speed
        self.freezeFrame = freezeFrame
        self.enabled = enabled
        self.linkGroup = linkGroup
        self.video = video
        self.audio = audio
        self.keyframes = keyframes
        self.tags = tags
    }

    public var end: Time { start + duration }
    public var range: TimeRange { TimeRange(start: start, duration: duration) }

    /// How much media the clip consumes (duration times speed).
    public var sourceDuration: Time {
        freezeFrame ? .zero : duration.scaled(by: speed)
    }

    public var sourceEnd: Time { sourceStart + sourceDuration }

    public var mediaID: String? {
        if case .media(let id) = content { return id }
        return nil
    }

    /// Converts a timeline time inside this clip to media time.
    public func sourceTime(atTimelineTime time: Time) -> Time {
        if freezeFrame { return sourceStart }
        return sourceStart + (time - start).scaled(by: speed)
    }
}

public struct VideoProperties: Codable, Equatable, Sendable {
    public var transform: Transform
    /// Crop in normalised units of the source frame: 0.1 on `left` trims 10%
    /// of the source width from the left.
    public var crop: Crop
    public var opacity: Double
    public var cutout: Cutout?
    /// Applied in order, after the transform. See `EffectRegistry`.
    public var effects: [Effect]
    /// Name of a layout preset this clip was last set to (for example
    /// `"corner"`), shown in the inspector.
    public var layoutPreset: String?
    /// Placement in other output formats, keyed by format ID (for example
    /// `"portrait"` for the 9:16 short). Formats without an entry use the
    /// main transform.
    public var formatOverrides: [String: FormatOverride]

    public init(
        transform: Transform = Transform(),
        crop: Crop = Crop(),
        opacity: Double = 1,
        cutout: Cutout? = nil,
        effects: [Effect] = [],
        layoutPreset: String? = nil,
        formatOverrides: [String: FormatOverride] = [:]
    ) {
        self.transform = transform
        self.crop = crop
        self.opacity = opacity
        self.cutout = cutout
        self.effects = effects
        self.layoutPreset = layoutPreset
        self.formatOverrides = formatOverrides
    }
}

/// A clip's placement in an alternate output format.
public struct FormatOverride: Codable, Equatable, Sendable {
    public var transform: Transform?
    public var crop: Crop?
    public var hidden: Bool

    public init(transform: Transform? = nil, crop: Crop? = nil, hidden: Bool = false) {
        self.transform = transform
        self.crop = crop
        self.hidden = hidden
    }
}

public struct Transform: Codable, Equatable, Sendable {
    /// Centre of the layer on the canvas, 0...1 from the top left.
    public var position: Point
    /// 1 fits the source inside the canvas. 0.5 is Mike's PiP size.
    public var scale: Double
    /// Degrees clockwise.
    public var rotation: Double

    public init(position: Point = Point(x: 0.5, y: 0.5), scale: Double = 1, rotation: Double = 0) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
    }
}

public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Crop: Codable, Equatable, Sendable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var isIdentity: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
}

/// AI portrait cutout settings. The matte itself is made in the background
/// and cached; these settings are applied live when compositing.
public struct Cutout: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// `personAndProps` blends the person mask with the person-instance mask
    /// so a handheld mic is kept. `person` is the plain person mask.
    public var mode: CutoutMode
    /// Softens the matte edge, in pixels at 1080p.
    public var edgeFeather: Double
    /// Shrinks (positive) or grows (negative) the matte, in pixels at 1080p.
    public var choke: Double
    /// Manual masks that force areas in or out, for fixing bad frames.
    public var repairMasks: [Mask]

    public init(
        enabled: Bool = true,
        mode: CutoutMode = .personAndProps,
        edgeFeather: Double = 2,
        choke: Double = 0,
        repairMasks: [Mask] = []
    ) {
        self.enabled = enabled
        self.mode = mode
        self.edgeFeather = edgeFeather
        self.choke = choke
        self.repairMasks = repairMasks
    }
}

public enum CutoutMode: String, Codable, Sendable {
    case person, personAndProps
}

public struct Mask: Codable, Equatable, Sendable {
    public enum Shape: String, Codable, Sendable { case rectangle, roundedRectangle, ellipse }
    public enum Mode: String, Codable, Sendable { case include, exclude }

    public var shape: Shape
    public var mode: Mode
    /// Normalised rectangle in source coordinates.
    public var rect: Rect
    public var cornerRadius: Double
    public var feather: Double

    public init(shape: Shape, mode: Mode = .include, rect: Rect, cornerRadius: Double = 0, feather: Double = 0) {
        self.shape = shape
        self.mode = mode
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.feather = feather
    }
}

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct AudioProperties: Codable, Equatable, Sendable {
    /// Clip gain in dB, applied after normalisation.
    public var gainDB: Double
    public var fadeIn: Time
    public var fadeOut: Time
    public var muted: Bool
    /// When set, the clip is levelled to this loudness (LUFS) using the
    /// measurement made in the background. Dialogue from one take should be
    /// levelled as a whole, not per cut, so this uses the take's loudness.
    public var normalizeTo: Double?
    /// 0 is the original audio, 1 is fully isolated voice. Mixed live from
    /// the cached isolated track.
    public var voiceIsolation: Double
    /// Audio effects in order, for example a pitch shift.
    public var effects: [Effect]

    public init(
        gainDB: Double = 0,
        fadeIn: Time = .zero,
        fadeOut: Time = .zero,
        muted: Bool = false,
        normalizeTo: Double? = nil,
        voiceIsolation: Double = 0,
        effects: [Effect] = []
    ) {
        self.gainDB = gainDB
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.muted = muted
        self.normalizeTo = normalizeTo
        self.voiceIsolation = voiceIsolation
        self.effects = effects
    }
}

// MARK: - Effects, keyframes and transitions

/// An effect instance. `type` names a definition in `EffectRegistry`, which
/// lists its parameters, ranges and defaults. Unknown types are kept as they
/// are (and shown as unresolved) so a project never loses data.
public struct Effect: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var enabled: Bool
    public var params: [String: ParamValue]

    public init(id: String = IDs.make("fx"), type: String, enabled: Bool = true, params: [String: ParamValue] = [:]) {
        self.id = id
        self.type = type
        self.enabled = enabled
        self.params = params
    }
}

/// A parameter value. Encoded as plain JSON: a number, a bool, a string, or
/// an object with x/y (point) or r/g/b/a (colour).
public enum ParamValue: Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)
    case point(Point)
    case color(RGBA)

    public var number: Double? {
        if case .number(let v) = self { return v }
        return nil
    }
}

extension ParamValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(RGBA.self) {
            self = .color(value)
        } else if let value = try? container.decode(Point.self) {
            self = .point(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported parameter value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .point(let v): try container.encode(v)
        case .color(let v): try container.encode(v)
        }
    }
}

public struct RGBA: Codable, Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let white = RGBA(r: 1, g: 1, b: 1)
}

public enum Interpolation: String, Codable, Sendable {
    case linear, easeIn, easeOut, easeInOut, hold
}

public struct Keyframe: Codable, Equatable, Sendable {
    /// Relative to the clip start.
    public var time: Time
    public var value: ParamValue
    /// How the value moves from this keyframe to the next one.
    public var interpolation: Interpolation

    public init(time: Time, value: ParamValue, interpolation: Interpolation = .easeInOut) {
        self.time = time
        self.value = value
        self.interpolation = interpolation
    }
}

public enum TransitionType: String, Codable, Sendable, CaseIterable {
    case dissolve
    case fadeToBlack
    case fadeFromBlack
    case push
    case slide
    /// Filmora's "Cut Slide": the incoming shot slides in over a short move.
    case cutSlide
    case wipe
    case zoom
}

public enum Direction: String, Codable, Sendable {
    case up, down, left, right
}

/// A transition on one track. Between two clips, both need enough media
/// beyond the cut (handles) to cover half the duration each; commands
/// reject transitions without handles instead of freezing frames.
public struct Transition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: TransitionType
    public var direction: Direction?
    public var duration: Time
    /// The outgoing clip. Nil for a transition at the head of `toClipID`.
    public var fromClipID: String?
    /// The incoming clip. Nil for a transition at the tail of `fromClipID`.
    public var toClipID: String?

    public init(
        id: String = IDs.make("tr"),
        type: TransitionType,
        direction: Direction? = nil,
        duration: Time,
        fromClipID: String?,
        toClipID: String?
    ) {
        self.id = id
        self.type = type
        self.direction = direction
        self.duration = duration
        self.fromClipID = fromClipID
        self.toClipID = toClipID
    }
}

// MARK: - Text and graphics

public struct TextContent: Codable, Equatable, Sendable {
    public var text: String
    /// A title preset from a pack (for example `"callout"`), which supplies
    /// the style and animations. `style` holds this clip's overrides.
    public var preset: String?
    public var style: TextStyle
    /// Named in and out animations, for example `"popIn"` or `"slideUp"`.
    public var animationIn: String?
    public var animationOut: String?
    public var animationDuration: Time
    /// Word timings for captions that highlight word by word, relative to
    /// the clip start.
    public var words: [TimedWord]?

    public init(
        text: String,
        preset: String? = nil,
        style: TextStyle = TextStyle(),
        animationIn: String? = nil,
        animationOut: String? = nil,
        animationDuration: Time = Time(seconds: 0.4),
        words: [TimedWord]? = nil
    ) {
        self.text = text
        self.preset = preset
        self.style = style
        self.animationIn = animationIn
        self.animationOut = animationOut
        self.animationDuration = animationDuration
        self.words = words
    }
}

public struct TimedWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Time
    public var end: Time

    public init(text: String, start: Time, end: Time) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct TextStyle: Codable, Equatable, Sendable {
    public var font: String
    /// Points at 1080p. Scaled with the canvas.
    public var size: Double
    public var weight: Double
    public var color: RGBA
    public var strokeColor: RGBA?
    public var strokeWidth: Double
    public var backgroundColor: RGBA?
    public var alignment: String
    public var uppercase: Bool
    public var shadow: Bool
    /// Extra space between lines, as a multiple of the font size.
    public var lineSpacing: Double

    public init(
        font: String = "SF Pro Display",
        size: Double = 64,
        weight: Double = 800,
        color: RGBA = .white,
        strokeColor: RGBA? = nil,
        strokeWidth: Double = 0,
        backgroundColor: RGBA? = nil,
        alignment: String = "center",
        uppercase: Bool = false,
        shadow: Bool = false,
        lineSpacing: Double = 0
    ) {
        self.font = font
        self.size = size
        self.weight = weight
        self.color = color
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.backgroundColor = backgroundColor
        self.alignment = alignment
        self.uppercase = uppercase
        self.shadow = shadow
        self.lineSpacing = lineSpacing
    }
}

public struct GraphicContent: Codable, Equatable, Sendable {
    /// Template identifier, for example `"remotion:BarChart"`.
    public var template: String
    public var props: [String: ParamValue]
    /// Structured props that don't fit `ParamValue` (tables, lists), as JSON.
    public var propsJSON: String?

    public init(template: String, props: [String: ParamValue] = [:], propsJSON: String? = nil) {
        self.template = template
        self.props = props
        self.propsJSON = propsJSON
    }
}

// MARK: - Markers

public enum MarkerKind: String, Codable, Sendable {
    case marker, section, chapter, todo
}

public struct Marker: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var time: Time
    public var duration: Time
    public var name: String
    public var kind: MarkerKind
    public var note: String?

    public init(
        id: String = IDs.make("mk"),
        time: Time,
        duration: Time = .zero,
        name: String,
        kind: MarkerKind = .marker,
        note: String? = nil
    ) {
        self.id = id
        self.time = time
        self.duration = duration
        self.name = name
        self.kind = kind
        self.note = note
    }
}

// MARK: - IDs

public enum IDs {
    private static let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")

    /// A short random ID with a readable prefix, for example `clip_k3f9x2mq`.
    public static func make(_ prefix: String) -> String {
        var generator = SystemRandomNumberGenerator()
        return make(prefix, using: &generator)
    }

    public static func make<G: RandomNumberGenerator>(_ prefix: String, using generator: inout G) -> String {
        let body = String((0..<8).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
        return "\(prefix)_\(body)"
    }
}

/// A small seedable generator. Edits draw new IDs from one seeded per batch,
/// so replaying a batch from the journal recreates the same IDs.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Lenient decoding
//
// Every model type decodes with defaults for missing keys. Agents can send
// the fields they care about (`{"content": {...}, "start": 3, "duration": 2}`)
// and project files written by older versions keep loading when fields are
// added.

extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

extension Project {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(.schemaVersion, or: Project.currentSchemaVersion)
        id = try c.decode(.id, or: IDs.make("prj"))
        name = try c.decode(.name, or: "Untitled")
        settings = try c.decode(.settings, or: ProjectSettings())
        media = try c.decode(.media, or: [])
        videoTracks = try c.decode(.videoTracks, or: [])
        audioTracks = try c.decode(.audioTracks, or: [])
        markers = try c.decode(.markers, or: [])
        metadata = try c.decode(.metadata, or: [:])
    }
}

extension ProjectSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProjectSettings()
        width = try c.decode(.width, or: d.width)
        height = try c.decode(.height, or: d.height)
        frameRate = try c.decode(.frameRate, or: d.frameRate)
        sampleRate = try c.decode(.sampleRate, or: d.sampleRate)
        loudnessTarget = try c.decode(.loudnessTarget, or: d.loudnessTarget)
        truePeakCeiling = try c.decode(.truePeakCeiling, or: d.truePeakCeiling)
        colorSpace = try c.decode(.colorSpace, or: d.colorSpace)
        alternateFormats = try c.decode(.alternateFormats, or: [])
    }
}

extension MediaItem {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: IDs.make("med"))
        path = try c.decode(String.self, forKey: .path)
        kind = try c.decode(.kind, or: .video)
        role = try c.decode(.role, or: .other)
        takeID = try c.decodeIfPresent(String.self, forKey: .takeID)
        takeOffset = try c.decodeIfPresent(Time.self, forKey: .takeOffset)
        duration = try c.decodeIfPresent(Time.self, forKey: .duration)
        frameRate = try c.decodeIfPresent(FrameRate.self, forKey: .frameRate)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        hasVideo = try c.decode(.hasVideo, or: kind != .audio)
        hasAudio = try c.decode(.hasAudio, or: kind == .audio)
        hasAlpha = try c.decode(.hasAlpha, or: false)
        variableFrameRate = try c.decode(.variableFrameRate, or: false)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        look = try c.decode(.look, or: [])
    }
}

extension Track {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: IDs.make("trk"))
        kind = try c.decode(TrackKind.self, forKey: .kind)
        name = try c.decode(.name, or: kind == .video ? "Video" : "Audio")
        clips = try c.decode(.clips, or: [])
        transitions = try c.decode(.transitions, or: [])
        muted = try c.decode(.muted, or: false)
        solo = try c.decode(.solo, or: false)
        locked = try c.decode(.locked, or: false)
        hidden = try c.decode(.hidden, or: false)
        targeted = try c.decode(.targeted, or: true)
        rippleMode = try c.decode(.rippleMode, or: .cut)
    }
}

extension ClipContent: Codable {
    private enum Kind: String, CodingKey {
        case media, text, graphic, solid, adjustment
    }

    private enum MediaKeys: String, CodingKey { case mediaID }
    private enum SolidKeys: String, CodingKey { case color }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Kind.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Clip content needs one of: media, text, graphic, solid, adjustment"
            ))
        }
        switch key {
        case .media:
            let m = try c.nestedContainer(keyedBy: MediaKeys.self, forKey: .media)
            self = .media(mediaID: try m.decode(String.self, forKey: .mediaID))
        case .text:
            self = .text(try c.decode(TextContent.self, forKey: .text))
        case .graphic:
            self = .graphic(try c.decode(GraphicContent.self, forKey: .graphic))
        case .solid:
            let s = try c.nestedContainer(keyedBy: SolidKeys.self, forKey: .solid)
            self = .solid(color: try s.decode(.color, or: .black))
        case .adjustment:
            self = .adjustment
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Kind.self)
        switch self {
        case .media(let mediaID):
            var m = c.nestedContainer(keyedBy: MediaKeys.self, forKey: .media)
            try m.encode(mediaID, forKey: .mediaID)
        case .text(let text):
            try c.encode(text, forKey: .text)
        case .graphic(let graphic):
            try c.encode(graphic, forKey: .graphic)
        case .solid(let color):
            var s = c.nestedContainer(keyedBy: SolidKeys.self, forKey: .solid)
            try s.encode(color, forKey: .color)
        case .adjustment:
            _ = c.nestedContainer(keyedBy: SolidKeys.self, forKey: .adjustment)
        }
    }
}

extension Clip {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: IDs.make("clip"))
        name = try c.decodeIfPresent(String.self, forKey: .name)
        content = try c.decode(ClipContent.self, forKey: .content)
        start = try c.decode(.start, or: .zero)
        duration = try c.decode(Time.self, forKey: .duration)
        sourceStart = try c.decode(.sourceStart, or: .zero)
        speed = try c.decode(.speed, or: 1)
        freezeFrame = try c.decode(.freezeFrame, or: false)
        enabled = try c.decode(.enabled, or: true)
        linkGroup = try c.decodeIfPresent(String.self, forKey: .linkGroup)
        video = try c.decodeIfPresent(VideoProperties.self, forKey: .video)
        audio = try c.decodeIfPresent(AudioProperties.self, forKey: .audio)
        keyframes = try c.decode(.keyframes, or: [:])
        tags = try c.decode(.tags, or: [])
    }
}

extension VideoProperties {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transform = try c.decode(.transform, or: Transform())
        crop = try c.decode(.crop, or: Crop())
        opacity = try c.decode(.opacity, or: 1)
        cutout = try c.decodeIfPresent(Cutout.self, forKey: .cutout)
        effects = try c.decode(.effects, or: [])
        layoutPreset = try c.decodeIfPresent(String.self, forKey: .layoutPreset)
        formatOverrides = try c.decode(.formatOverrides, or: [:])
    }
}

extension FormatOverride {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transform = try c.decodeIfPresent(Transform.self, forKey: .transform)
        crop = try c.decodeIfPresent(Crop.self, forKey: .crop)
        hidden = try c.decode(.hidden, or: false)
    }
}

extension Transform {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(.position, or: Point(x: 0.5, y: 0.5))
        scale = try c.decode(.scale, or: 1)
        rotation = try c.decode(.rotation, or: 0)
    }
}

extension Crop {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decode(.left, or: 0)
        top = try c.decode(.top, or: 0)
        right = try c.decode(.right, or: 0)
        bottom = try c.decode(.bottom, or: 0)
    }
}

extension Cutout {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Cutout()
        enabled = try c.decode(.enabled, or: d.enabled)
        mode = try c.decode(.mode, or: d.mode)
        edgeFeather = try c.decode(.edgeFeather, or: d.edgeFeather)
        choke = try c.decode(.choke, or: d.choke)
        repairMasks = try c.decode(.repairMasks, or: [])
    }
}

extension Mask {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decode(.shape, or: .rectangle)
        mode = try c.decode(.mode, or: .include)
        rect = try c.decode(Rect.self, forKey: .rect)
        cornerRadius = try c.decode(.cornerRadius, or: 0)
        feather = try c.decode(.feather, or: 0)
    }
}

extension AudioProperties {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gainDB = try c.decode(.gainDB, or: 0)
        fadeIn = try c.decode(.fadeIn, or: .zero)
        fadeOut = try c.decode(.fadeOut, or: .zero)
        muted = try c.decode(.muted, or: false)
        normalizeTo = try c.decodeIfPresent(Double.self, forKey: .normalizeTo)
        voiceIsolation = try c.decode(.voiceIsolation, or: 0)
        effects = try c.decode(.effects, or: [])
    }
}

extension Effect {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: IDs.make("fx"))
        type = try c.decode(String.self, forKey: .type)
        enabled = try c.decode(.enabled, or: true)
        params = try c.decode(.params, or: [:])
    }
}

extension Keyframe {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Time.self, forKey: .time)
        value = try c.decode(ParamValue.self, forKey: .value)
        interpolation = try c.decode(.interpolation, or: .easeInOut)
    }
}

extension Transition {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: IDs.make("tr"))
        type = try c.decode(TransitionType.self, forKey: .type)
        direction = try c.decodeIfPresent(Direction.self, forKey: .direction)
        duration = try c.decode(.duration, or: type.defaultDuration)
        fromClipID = try c.decodeIfPresent(String.self, forKey: .fromClipID)
        toClipID = try c.decodeIfPresent(String.self, forKey: .toClipID)
    }
}

extension TextContent {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(.text, or: "")
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        style = try c.decode(.style, or: TextStyle())
        animationIn = try c.decodeIfPresent(String.self, forKey: .animationIn)
        animationOut = try c.decodeIfPresent(String.self, forKey: .animationOut)
        animationDuration = try c.decode(.animationDuration, or: Time(seconds: 0.4))
        words = try c.decodeIfPresent([TimedWord].self, forKey: .words)
    }
}

extension TextStyle {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TextStyle()
        font = try c.decode(.font, or: d.font)
        size = try c.decode(.size, or: d.size)
        weight = try c.decode(.weight, or: d.weight)
        color = try c.decode(.color, or: d.color)
        strokeColor = try c.decodeIfPresent(RGBA.self, forKey: .strokeColor)
        strokeWidth = try c.decode(.strokeWidth, or: d.strokeWidth)
        backgroundColor = try c.decodeIfPresent(RGBA.self, forKey: .backgroundColor)
        alignment = try c.decode(.alignment, or: d.alignment)
        uppercase = try c.decode(.uppercase, or: d.uppercase)
        shadow = try c.decode(.shadow, or: d.shadow)
        lineSpacing = try c.decode(.lineSpacing, or: d.lineSpacing)
    }
}

extension GraphicContent {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = try c.decode(String.self, forKey: .template)
        props = try c.decode(.props, or: [:])
        propsJSON = try c.decodeIfPresent(String.self, forKey: .propsJSON)
    }
}

extension RGBA {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        r = try c.decode(Double.self, forKey: .r)
        g = try c.decode(Double.self, forKey: .g)
        b = try c.decode(Double.self, forKey: .b)
        a = try c.decode(.a, or: 1)
    }
}

extension Marker {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: IDs.make("mk"))
        time = try c.decode(Time.self, forKey: .time)
        duration = try c.decode(.duration, or: .zero)
        name = try c.decode(.name, or: "")
        kind = try c.decode(.kind, or: .marker)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

extension TransitionType {
    /// Mike's Filmora medians: Cut Slide 0.57 s, Push 0.68 to 0.84 s,
    /// Dissolve 0.48 s and the closing fade to black 1.12 s.
    public var defaultDuration: Time {
        switch self {
        case .dissolve: return Time(seconds: 0.5)
        case .fadeToBlack, .fadeFromBlack: return Time(seconds: 1.1)
        case .push: return Time(seconds: 0.7)
        case .slide: return Time(seconds: 0.7)
        case .cutSlide: return Time(seconds: 0.57)
        case .wipe: return Time(seconds: 0.6)
        case .zoom: return Time(seconds: 0.5)
        }
    }
}
