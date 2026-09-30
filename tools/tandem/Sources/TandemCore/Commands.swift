import Foundation

/// Every change to a project is one of these commands. The app, the CLI and
/// agents (over MCP) all submit the same commands to `ProjectCoordinator`,
/// so anything you can do by hand an agent can do too, and vice versa.
///
/// JSON form uses the case name as the key and leaves out anything optional,
/// for example `{"blade": {"at": 12.5}}` or
/// `{"updateClip": {"clipID": "clip_k3f9x2", "patch": {"video": {"opacity": 0.5}}}}`.
/// Times are seconds.
public enum EditCommand: Codable, Equatable, Sendable {
    // MARK: Project and tracks

    /// Merge patch on `name` and `metadata`.
    case updateProject(patch: JSONValue)
    case updateSettings(patch: JSONValue)
    case addTrack(kind: TrackKind, name: String? = nil, index: Int? = nil, id: String? = nil)
    /// Removes the track and everything on it.
    case removeTrack(trackID: String)
    case moveTrack(trackID: String, index: Int)
    /// JSON merge patch (RFC 7396) on the track, for example
    /// `{"muted": true}`. `id`, `kind`, `clips` and `transitions` can't change.
    case updateTrack(trackID: String, patch: JSONValue)

    // MARK: Media

    case addMedia(item: MediaItem)
    case updateMedia(mediaID: String, patch: JSONValue)
    /// Fails if any clip still uses the media.
    case removeMedia(mediaID: String)

    // MARK: Placing and removing clips

    /// Puts media on the timeline the way the app does when you drag it in.
    /// Each file goes to the track for its role (camera to "Camera", screen
    /// to "Screen", music to "Music"...) and a camera file's sound goes to
    /// "Voice" as a linked clip. Files from one take are placed in sync and
    /// linked. `sourceStart` is measured from the start of the take (or the
    /// file), and `duration` defaults to all the media that's left.
    case placeMedia(
        mediaIDs: [String],
        at: Time,
        sourceStart: Time? = nil,
        duration: Time? = nil,
        mode: InsertMode? = nil,
        videoTrackID: String? = nil,
        audioTrackID: String? = nil,
        includeAudio: Bool? = nil
    )
    /// `.place` (the default) fails if the range is occupied, `.overwrite`
    /// replaces what's there, `.insert` pushes later clips right.
    case insertClip(trackID: String, clip: Clip, mode: InsertMode? = nil)
    /// Without `ripple` the clips are lifted and leave a gap. With `ripple`
    /// the gap closes, like Shift-Delete. `includeLinked` defaults to true.
    case removeClips(clipIDs: [String], ripple: Bool? = nil, includeLinked: Bool? = nil)
    /// Removes a stretch of time and closes it up. This is how pauses get
    /// tightened. With no `trackIDs` every `.cut` track is cut and `.follow`
    /// tracks follow; named tracks are always cut.
    case rippleDeleteRange(range: TimeRange, trackIDs: [String]? = nil)
    /// Closes the gap on `trackID` that contains `at`. Fails if another
    /// `.cut` track has something in that gap.
    case closeGap(trackID: String, at: Time)
    /// Opens up empty time at `at`, pushing everything later to the right.
    case insertTime(at: Time, duration: Time, trackIDs: [String]? = nil)
    /// Expands a template (section card, call to action) into linked clips
    /// at `at`, filling `{{field}}` placeholders from `values`. Media the
    /// template uses is matched by path; a clip that carries its media item
    /// (a saved segment's do, and the section card tile's whooshes) adds it
    /// when the project doesn't have it.
    case insertTemplate(template: Template, at: Time, values: [String: String]? = nil, mode: InsertMode? = nil)
    /// Puts a numbered section card (the built-in `sectionCard` graphic) at
    /// every section marker after the start, or at `markerIDs`: numbered in
    /// time order, `total` the count, the title from the marker's name and
    /// the subtitle from its note. Each card hides the frame from its
    /// marker on, so the cut between sections isn't seen. A card already at
    /// a marker is renumbered and keeps its own words and length. Each new
    /// card is as long as its words need (`SectionCard.fittedDuration`,
    /// 3.2 to 6 s) unless `duration` is given. `mode` `overwrite` (the
    /// default) lays the cards over the timeline; `insert` also makes room,
    /// so the card is a pause and its wipes show the shots either side.
    /// `soundIn` and `soundOut` put a whoosh on SFX for each sweep.
    case addSectionCards(
        markerIDs: [String]? = nil,
        trackID: String? = nil,
        duration: Time? = nil,
        kicker: String? = nil,
        mode: InsertMode? = nil,
        soundIn: SectionCardSound? = nil,
        soundOut: SectionCardSound? = nil
    )

    // MARK: Cutting and trimming

    /// Splits clips at a time. With `clipIDs` only those clips (and their
    /// linked partners) are cut. Otherwise every clip under `at` on the given
    /// tracks, or on all targeted unlocked tracks.
    case blade(at: Time, trackIDs: [String]? = nil, clipIDs: [String]? = nil)
    /// Moves a clip edge to `to` (a timeline time). With `ripple` the clip
    /// keeps its place and everything after it moves instead.
    case trim(clipID: String, edge: ClipEdge, to: Time, ripple: Bool? = nil, includeLinked: Bool? = nil)
    /// Moves the cut between two adjacent clips, trimming both.
    case roll(leftClipID: String, rightClipID: String, delta: Time)
    /// Changes which part of the media a clip shows without moving it.
    /// `delta` is in media time.
    case slip(clipID: String, delta: Time, includeLinked: Bool? = nil)
    /// Moves a clip between its neighbours, trimming them to compensate.
    case slide(clipID: String, delta: Time)
    /// Changes speed but keeps the same media, so the clip gets shorter or
    /// longer. Linked clips change with it.
    case setSpeed(clipID: String, speed: Double, ripple: Bool? = nil, includeLinked: Bool? = nil)

    // MARK: Moving and editing clips

    /// Moves clips in time and optionally to another track. `mode` defaults
    /// to `.place`, which fails if the destination is occupied.
    case moveClips(
        clipIDs: [String],
        delta: Time? = nil,
        toTrackID: String? = nil,
        includeLinked: Bool? = nil,
        mode: MoveMode? = nil
    )
    /// JSON merge patch on the clip, for example
    /// `{"video": {"transform": {"scale": 0.5}}}` or `{"audio": {"gainDB": -3}}`.
    case updateClip(clipID: String, patch: JSONValue)
    case link(clipIDs: [String])
    case unlink(clipIDs: [String])
    /// Sets a one-key layout (full, PiP right, PiP left, split) on video
    /// clips. Audio clips in the list are skipped.
    case applyLayout(clipIDs: [String], preset: LayoutPreset)
    /// Zooms a video clip into a rectangle of its source (0...1 from the top
    /// left). Without `at` the zoom is static. With `at` (timeline time) it
    /// animates there over `duration` (default 0.5 s) with an ease; zoom back
    /// out later with the rectangle `{x: 0, y: 0, width: 1, height: 1}`.
    case zoomToRegion(clipID: String, rect: Rect, at: Time? = nil, duration: Time? = nil)
    /// Places video clips in an alternate output format (see
    /// `ProjectSettings.alternateFormats`), for example the top or bottom
    /// half of the 9:16 short. `cutout` turns the cutout on or off there.
    case setFormatLayout(clipIDs: [String], format: String, slot: PortraitSlot, cutout: Bool? = nil)
    /// A slow zoom or pan over the whole of each clip (the Ken Burns
    /// effect), for stills and photos. Starts from the clip's current
    /// placement (apply the `fill` layout first for a short). `amount`
    /// defaults to 1.12. Replaces the clip's position and scale animation.
    case addMotion(clipIDs: [String], style: MotionStyle, amount: Double? = nil)

    // MARK: Transitions

    case addTransition(trackID: String, transition: Transition)
    case updateTransition(transitionID: String, patch: JSONValue)
    case removeTransition(transitionID: String)

    // MARK: Effects and animation

    /// Adds to the clip's video or audio effects, depending on the effect.
    case addEffect(clipID: String, effect: Effect, index: Int? = nil)
    case updateEffect(clipID: String, effectID: String, patch: JSONValue)
    case removeEffect(clipID: String, effectID: String)
    case moveEffect(clipID: String, effectID: String, index: Int)
    /// Replaces the keyframes of one parameter, for example
    /// `video.transform.scale`. An empty list removes the animation.
    case setKeyframes(clipID: String, parameter: String, keyframes: [Keyframe])

    // MARK: Sound

    /// Levels every speech clip (camera and voice sound, and anything on a
    /// take track like Voice) to the project's speech level
    /// (`settings.speechLoudness`) and clears its clip gain, so the voice
    /// sits at one level whatever gains it came with. Music and sound
    /// effects keep theirs. JSON: `{"normalizeSpeech": {}}`.
    case normalizeSpeech

    // MARK: Markers

    case addMarker(marker: Marker)
    case updateMarker(markerID: String, patch: JSONValue)
    case removeMarker(markerID: String)
}

public enum InsertMode: String, Codable, Sendable {
    case place, overwrite, insert
}

public enum MoveMode: String, Codable, Sendable {
    /// Fails if the destination is occupied.
    case place
    /// Replaces whatever is at the destination.
    case overwrite
}

public enum ClipEdge: String, Codable, Sendable {
    case start, end
}

/// A group of commands applied atomically as one undo step.
public struct EditBatch: Codable, Equatable, Sendable {
    /// Shown in the undo menu and activity feed, for example
    /// "Claude: tightened 14 pauses in section 4".
    public var label: String
    /// `"user"` for edits made in the app, otherwise the agent name.
    public var author: String
    public var commands: [EditCommand]
    /// When set, the batch is rejected if the project has moved on since the
    /// caller last looked, so an agent never edits a stale timeline.
    public var expectedRevision: Int?
    /// Retrying a batch with the same key returns the first result instead of
    /// applying it twice.
    public var idempotencyKey: String?

    public init(
        label: String,
        author: String = "user",
        commands: [EditCommand],
        expectedRevision: Int? = nil,
        idempotencyKey: String? = nil
    ) {
        self.label = label
        self.author = author
        self.commands = commands
        self.expectedRevision = expectedRevision
        self.idempotencyKey = idempotencyKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(.label, or: "Edit")
        author = try c.decode(.author, or: "user")
        commands = try c.decode([EditCommand].self, forKey: .commands)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
        idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
    }
}

public enum EditError: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    case notFound(String)
    case overlap(String)
    case locked(String)
    case invalid(String)
    case staleRevision(expected: Int, actual: Int)
    case notImplemented(String)

    public var description: String {
        switch self {
        case .notFound(let what): return "Not found: \(what)"
        case .overlap(let what): return "Overlap: \(what)"
        case .locked(let what): return "Locked: \(what)"
        case .invalid(let what): return "Invalid edit: \(what)"
        case .staleRevision(let expected, let actual):
            return "The project changed (expected revision \(expected), now \(actual)). Re-read it and try again."
        case .notImplemented(let op): return "Not implemented yet: \(op)"
        }
    }

    public var errorDescription: String? { description }
}
