import Foundation

/// A reusable group of clips, like Mike's section card (three text layers
/// over an animated background with four sound effects), Like and Subscribe,
/// or Comment Below. Templates live in packs as JSON. Inserting one expands
/// it into ordinary linked clips, so nothing downstream needs to know about
/// templates.
public struct Template: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var duration: Time
    /// Values the template asks for, like the section title.
    public var fields: [TemplateField]
    public var clips: [TemplateClip]
    /// Transitions between its clips, or at a clip's head or tail.
    public var transitions: [TemplateTransition]

    public init(id: String, name: String, duration: Time, fields: [TemplateField] = [], clips: [TemplateClip], transitions: [TemplateTransition] = []) {
        self.id = id
        self.name = name
        self.duration = duration
        self.fields = fields
        self.clips = clips
        self.transitions = transitions
    }

    enum CodingKeys: String, CodingKey {
        case id, name, duration, fields, clips, transitions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(.name, or: id)
        duration = try c.decode(Time.self, forKey: .duration)
        fields = try c.decode(.fields, or: [])
        clips = try c.decode([TemplateClip].self, forKey: .clips)
        transitions = try c.decode(.transitions, or: [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(duration, forKey: .duration)
        try c.encode(fields, forKey: .fields)
        try c.encode(clips, forKey: .clips)
        if !transitions.isEmpty { try c.encode(transitions, forKey: .transitions) }
    }
}

/// A transition in a template, naming its clips by their place in
/// `clips`: between two clips on one track, or at one clip's head (no
/// `from`) or tail (no `to`), like a fade from black on an intro card.
public struct TemplateTransition: Codable, Equatable, Sendable {
    /// The outgoing clip's index in the template's clips.
    public var from: Int?
    /// The incoming clip's index.
    public var to: Int?
    public var type: TransitionType
    public var direction: Direction?
    public var duration: Time
    /// The index of the clip (on an audio track) that plays its sound,
    /// tied to it once the template goes in (`Transition.soundClipID`).
    public var sound: Int?

    public init(from: Int?, to: Int?, type: TransitionType, direction: Direction? = nil, duration: Time, sound: Int? = nil) {
        self.from = from
        self.to = to
        self.type = type
        self.direction = direction
        self.duration = duration
        self.sound = sound
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decodeIfPresent(Int.self, forKey: .from)
        to = try c.decodeIfPresent(Int.self, forKey: .to)
        type = try c.decode(TransitionType.self, forKey: .type)
        direction = try c.decodeIfPresent(Direction.self, forKey: .direction)
        duration = try c.decode(.duration, or: type.defaultDuration)
        sound = try c.decodeIfPresent(Int.self, forKey: .sound)
    }
}

public struct TemplateField: Codable, Equatable, Sendable {
    public var key: String
    public var label: String
    public var defaultValue: String

    public init(key: String, label: String, defaultValue: String = "") {
        self.key = key
        self.label = label
        self.defaultValue = defaultValue
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(.label, or: key)
        defaultValue = try c.decode(.defaultValue, or: "")
    }
}

public struct TemplateClip: Codable, Equatable, Sendable {
    /// Name of the track to use, created if the project doesn't have it.
    public var track: String
    public var trackKind: TrackKind
    /// Start, relative to where the template is inserted.
    public var offset: Time
    /// The clip to create. Its `start` and `id` are replaced. Text may use
    /// `{{field}}` placeholders.
    public var clip: Clip
    /// For media clips: the path of the file, as the project has it. The
    /// clip's `mediaID` is looked up from it, so a template doesn't need to
    /// know the project's media IDs.
    public var mediaPath: String?
    /// For media clips: the media item to add when the project has nothing
    /// at `mediaPath` yet (its path becomes `mediaPath`, and is used when
    /// `mediaPath` is left out). A saved segment carries the items for its
    /// files, and the section card tile its whooshes, so inserting them adds
    /// them; without one, the file must already be in the project.
    public var media: MediaItem?

    public init(track: String, trackKind: TrackKind = .video, offset: Time = .zero, clip: Clip, mediaPath: String? = nil, media: MediaItem? = nil) {
        self.track = track
        self.trackKind = trackKind
        self.offset = offset
        self.clip = clip
        self.mediaPath = mediaPath ?? media?.path
        self.media = media
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = try c.decode(String.self, forKey: .track)
        trackKind = try c.decode(.trackKind, or: .video)
        offset = try c.decode(.offset, or: .zero)
        media = try c.decodeIfPresent(MediaItem.self, forKey: .media)
        mediaPath = try c.decodeIfPresent(String.self, forKey: .mediaPath) ?? media?.path
        // Media clips name their file with `mediaPath`, so let them leave
        // `content` out.
        var raw = try c.decode(JSONValue.self, forKey: .clip)
        if mediaPath != nil, case .object(var fields) = raw, fields["content"] == nil {
            fields["content"] = .object(["media": .object(["mediaID": .string("")])])
            raw = .object(fields)
        }
        clip = try raw.decode(as: Clip.self)
    }
}

extension Template {
    /// Replaces `{{key}}` in every text clip, and in a graphic's text
    /// props, with `values`, falling back to each field's default.
    func filled(with values: [String: String]) -> [TemplateClip] {
        var lookup = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.defaultValue) })
        for (key, value) in values { lookup[key] = value }
        func fill(_ text: String) -> String {
            lookup.reduce(text) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
        }
        return clips.map { item in
            var item = item
            switch item.clip.content {
            case .text(var text):
                text.text = fill(text.text)
                item.clip.content = .text(text)
            case .graphic(var graphic):
                for (key, value) in graphic.props {
                    if case .string(let text) = value { graphic.props[key] = .string(fill(text)) }
                }
                item.clip.content = .graphic(graphic)
            default:
                break
            }
            return item
        }
    }
}

extension Editing {
    /// The media at `path`, adding the item a template clip carries when the
    /// project has nothing there yet. The carried item keeps its ID unless
    /// the project already uses it.
    static func mediaID(for path: String, carried: MediaItem?, in p: inout Project, template: String, _ context: inout EditContext) throws -> String {
        if let media = p.media.first(where: { $0.path == path }) { return media.id }
        guard var item = carried else {
            throw EditError.notFound("media \(path) for template \(template); add it to the project first")
        }
        item.path = path
        if item.id.isEmpty || p.allIDs.contains(item.id) { item.id = context.makeID("med") }
        try addMedia(&p, item)
        return item.id
    }

    static func insertTemplate(_ p: inout Project, _ template: Template, at: Time, values: [String: String], mode: InsertMode, _ context: inout EditContext) throws {
        guard at >= .zero else { throw EditError.invalid("templates can't start before 0") }
        guard !template.clips.isEmpty else { throw EditError.invalid("template \(template.id) has no clips") }
        let items = template.filled(with: values)
        let group = items.count > 1 ? context.makeID("lnk") : nil
        var planned: [(TrackLocation, Clip)] = []
        for item in items {
            let location: TrackLocation
            if let track = p.track(named: item.track, kind: item.trackKind), let found = p.location(ofTrack: track.id) {
                location = found
            } else {
                try addTrack(&p, kind: item.trackKind, name: item.track, index: nil, id: nil, &context)
                location = TrackLocation(kind: item.trackKind, index: (item.trackKind == .video ? p.videoTracks.count : p.audioTracks.count) - 1)
            }
            var clip = item.clip
            clip.id = context.makeID("clip")
            clip.start = at + item.offset
            clip.linkGroup = group
            if !clip.tags.contains("template:\(template.id)") { clip.tags.append("template:\(template.id)") }
            if let path = item.mediaPath {
                clip.content = .media(mediaID: try mediaID(for: path, carried: item.media, in: &p, template: template.id, &context))
            }
            try requireUnlocked(p[location])
            try checkContent(clip, fits: p[location], in: p)
            try checkSource(clip, in: p)
            planned.append((location, clip))
        }
        switch mode {
        case .place:
            for (location, clip) in planned where !p[location].isFree(clip.range) {
                throw EditError.overlap("\"\(p[location].name)\" already has a clip between \(clip.start) and \(clip.end)")
            }
        case .overwrite:
            for (location, clip) in planned { p[location].clear(clip.range, context: &context) }
        case .insert:
            let edited = Set(planned.map { p[$0.0].id })
            try rippleOpen(&p, at: at, duration: template.duration, edited: edited, &context)
        }
        for (location, clip) in planned {
            p[location].add(clip)
            context.createdIDs.append(clip.id)
        }
        for item in template.transitions {
            func clip(at index: Int?) throws -> (TrackLocation, Clip)? {
                guard let index else { return nil }
                guard planned.indices.contains(index) else {
                    throw EditError.invalid("template \(template.id) has a transition on clip \(index), which it doesn't have")
                }
                return planned[index]
            }
            let from = try clip(at: item.from)
            let to = try clip(at: item.to)
            guard let location = (from ?? to)?.0 else {
                throw EditError.invalid("template \(template.id) has a transition with no clip")
            }
            if let from, let to, from.0 != to.0 {
                throw EditError.invalid("template \(template.id) has a transition between clips on different tracks")
            }
            var transition = Transition(id: context.makeID("tr"), type: item.type, direction: item.direction, duration: item.duration, fromClipID: from?.1.id, toClipID: to?.1.id)
            if let sound = try clip(at: item.sound) {
                guard sound.0.kind == .audio else {
                    throw EditError.invalid("template \(template.id) gives a transition a sound that isn't on an audio track")
                }
                transition.soundClipID = sound.1.id
            }
            try addTransition(&p, trackID: p[location].id, transition, &context)
        }
    }
}
