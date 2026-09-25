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

    public init(id: String, name: String, duration: Time, fields: [TemplateField] = [], clips: [TemplateClip]) {
        self.id = id
        self.name = name
        self.duration = duration
        self.fields = fields
        self.clips = clips
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(.name, or: id)
        duration = try c.decode(Time.self, forKey: .duration)
        fields = try c.decode(.fields, or: [])
        clips = try c.decode([TemplateClip].self, forKey: .clips)
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
    /// For media clips: the path of a file already added to the project.
    /// The clip's `mediaID` is looked up from it, so a template doesn't need
    /// to know the project's media IDs.
    public var mediaPath: String?

    public init(track: String, trackKind: TrackKind = .video, offset: Time = .zero, clip: Clip, mediaPath: String? = nil) {
        self.track = track
        self.trackKind = trackKind
        self.offset = offset
        self.clip = clip
        self.mediaPath = mediaPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = try c.decode(String.self, forKey: .track)
        trackKind = try c.decode(.trackKind, or: .video)
        offset = try c.decode(.offset, or: .zero)
        mediaPath = try c.decodeIfPresent(String.self, forKey: .mediaPath)
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
    /// Replaces `{{key}}` in every text clip with `values`, falling back to
    /// each field's default.
    func filled(with values: [String: String]) -> [TemplateClip] {
        var lookup = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.defaultValue) })
        for (key, value) in values { lookup[key] = value }
        return clips.map { item in
            var item = item
            if case .text(var text) = item.clip.content {
                for (key, value) in lookup {
                    text.text = text.text.replacingOccurrences(of: "{{\(key)}}", with: value)
                }
                item.clip.content = .text(text)
            }
            return item
        }
    }
}

extension Editing {
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
                guard let media = p.media.first(where: { $0.path == path }) else {
                    throw EditError.notFound("media \(path) for template \(template.id); add it to the project first")
                }
                clip.content = .media(mediaID: media.id)
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
    }
}
