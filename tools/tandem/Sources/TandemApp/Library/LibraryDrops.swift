import Foundation
import TandemAPI
import TandemCore
import TandemRender

/// What happens when a transition, effect, title or template is dropped
/// on the timeline (or double-clicked, at the playhead).
enum LibraryDrops {
    /// A transition dropped near a cut: on the nearest cut on the track
    /// under the pointer (with no track, the top-most one with a cut in
    /// reach), playing `sound` (its type's, copied into the project). A cut
    /// that already has one gets the new type instead, and its sound
    /// follows the type (`TransitionSoundEdits`); `soundFor` says what
    /// each type plays.
    static func transition(
        _ type: TransitionType, at time: Time, trackID: String?, in project: Project, reach: Time = Time(seconds: 1), id: String = IDs.make("tr"),
        sound: TransitionSoundDefaults.Resolved? = nil,
        soundFor: (TransitionType) -> TransitionSoundDefaults.Sound? = TransitionSoundDefaults.builtIn
    ) -> EditBatch? {
        let tracks: [Track]
        if let trackID, let track = project.track(trackID) {
            tracks = [track]
        } else {
            tracks = project.videoTracks.reversed() + project.audioTracks
        }
        for track in tracks where !track.locked {
            guard let (left, right) = TimelineEdits.nearestCut(on: track, to: time, reach: reach) else { continue }
            if let existing = track.transitions.first(where: { $0.fromClipID == left.id && $0.toClipID == right.id }) {
                guard existing.type != type else { return nil }
                return EditBatch(label: "Change to \(type.displayName.lowercased())", commands: TransitionSoundEdits.typeChange(
                    existing, to: type, in: project, oldSound: soundFor(existing.type), newSound: soundFor(type), resolved: sound
                ))
            }
            let transition = Transition(id: id, type: type, duration: type.defaultDuration, fromClipID: left.id, toClipID: right.id)
            let prepared = sound?.prepared(for: project)
            return EditBatch(label: "Add \(type.displayName.lowercased())", commands: (prepared?.addMedia ?? []) + [
                .addTransition(trackID: track.id, transition: transition, sound: prepared?.sound)
            ])
        }
        return nil
    }

    /// An effect dropped on a clip, when it's the right kind: picture
    /// effects on video tracks, sound effects on audio tracks.
    static func effect(_ type: String, on clipID: String?, in project: Project, registry: EffectRegistry = .standard) -> EditBatch? {
        guard let clipID, let definition = registry.definition(type), let location = project.location(ofClip: clipID) else { return nil }
        let kind: TrackKind = definition.domain == .video ? .video : .audio
        guard location.track.kind == kind, !project[location.track].locked else { return nil }
        return EditBatch(label: "Add \(definition.name.lowercased())", commands: [.addEffect(clipID: clipID, effect: Effect(type: type))])
    }

    /// A title style dropped at `time`: a text clip in that style on the
    /// Text track, over whatever was there.
    /// A title dropped at `time`: on the video track it's dropped on, on a
    /// new top track above the tracks, and otherwise on the Text track.
    static func title(_ preset: TitlePreset, at time: Time, in project: Project, target: DropTarget = .track(nil), duration: Time = Time(seconds: 3)) -> EditBatch? {
        let clip = Clip(name: preset.name, content: .text(TextContent(text: TitleSamples.text(for: preset.id), preset: preset.id)), start: time, duration: duration)
        if target == .newVideoTrackOnTop {
            let trackID = IDs.make("trk")
            return EditBatch(label: "Add \(preset.name.lowercased()) on a new track", commands: [
                .addTrack(kind: .video, id: trackID),
                .insertClip(trackID: trackID, clip: clip, mode: .overwrite)
            ])
        }
        var dropped: Track?
        if case .track(let trackID?) = target, let track = project.track(trackID), track.kind == .video, !track.locked { dropped = track }
        guard let track = dropped ?? project.track(named: "Text", kind: .video) ?? project.videoTracks.last, !track.locked else { return nil }
        return EditBatch(label: "Add \(preset.name.lowercased())", commands: [.insertClip(trackID: track.id, clip: clip, mode: .overwrite)])
    }

    /// A template dropped at `time`, with its fields' default values.
    static func template(_ template: Template, at time: Time) -> EditBatch {
        EditBatch(label: "Add \(template.name.lowercased())", commands: [.insertTemplate(template: template, at: time, mode: .overwrite)])
    }
}

/// Text a new title starts with, in the spirit of each style.
enum TitleSamples {
    static func text(for presetID: String) -> String {
        switch presetID {
        case "label": return "Jamie's screen"
        case "callout": return "14 tips"
        case "sectionHeader": return "Tip 1\nCursor docs"
        case "version": return "v1.46.0"
        case "caption": return "Captions follow each word"
        default: return "Title"
        }
    }
}

/// Templates that ship with the app until a template pack does: a group
/// of clips that go in together, linked. The text is edited in the
/// inspector afterwards.
enum BuiltInTemplates {
    static let all: [Template] = [sectionCard, likeAndSubscribe, commentBelow]

    /// A built-in template, or a saved segment (`segment:<folder>`). The
    /// section card comes with its whooshes when a drag of its tile has
    /// copied them into the project (see `SectionCardSoundCache`).
    static func template(_ id: String) -> Template? {
        if id == sectionCard.id, let sounds = SectionCardSoundCache.shared.latest { return makeSectionCard(sounds: sounds) }
        return all.first { $0.id == id } ?? SegmentShelf.shared.template(id)
    }

    /// Mike's section card, silent.
    static let sectionCard = makeSectionCard(sounds: nil)

    /// Mike's section card: the built-in `sectionCard` graphic on Graphics
    /// (Convex's bands wipe in, the card holds the number, title, subtitle
    /// and progress, the bands wipe out) and, given the whooshes, one on
    /// SFX for each sweep. As long as its words need; they're edited in the
    /// inspector, where Fit to text sets the length for new ones.
    static func makeSectionCard(sounds: SectionCardSounds.Resolved?) -> Template {
        let fields = [
            TemplateField(key: "number", label: "Number", defaultValue: "01"),
            TemplateField(key: "title", label: "Title", defaultValue: "The leaderboard"),
            TemplateField(key: "subtitle", label: "Subtitle", defaultValue: "Who's on top")
        ]
        let words = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.defaultValue) })
        let length = SectionCard.fittedDuration(for: SectionCard.Props(title: words["title"] ?? "", subtitle: words["subtitle"] ?? "", number: words["number"] ?? ""))
        let props: [String: ParamValue] = [
            SectionCard.Key.number: .string("{{number}}"),
            SectionCard.Key.title: .string("{{title}}"),
            SectionCard.Key.subtitle: .string("{{subtitle}}")
        ]
        var clips = [
            // Inserting gives clips new IDs; fixed ones here keep the
            // template the same every time it's made.
            TemplateClip(track: "Graphics", clip: Clip(
                id: "clip_sectioncard",
                content: .graphic(GraphicContent(template: SectionCard.template, props: props)),
                start: .zero,
                duration: length
            ))
        ]
        if let sounds, sounds.media.count == 2 {
            let motion = SectionCard.Motion(duration: length.seconds)
            let sweeps: [(MediaItem, SectionCardSound, Time)] = [
                (sounds.media[0], sounds.soundIn, Time(seconds: motion.inStart(0)) + (sounds.soundIn.offset ?? SectionCard.soundInOffset)),
                (sounds.media[1], sounds.soundOut, Time(seconds: motion.outStart(0)) + (sounds.soundOut.offset ?? .zero))
            ]
            for (index, (item, sound, offset)) in sweeps.enumerated() {
                clips.append(TemplateClip(
                    track: "SFX", trackKind: .audio, offset: offset,
                    clip: Clip(
                        id: index == 0 ? "clip_sectioncardin" : "clip_sectioncardout",
                        content: .media(mediaID: item.id),
                        start: .zero,
                        duration: item.duration ?? Time(seconds: 1),
                        audio: AudioProperties(gainDB: sound.gainDB ?? SectionCard.soundGainDB)
                    ),
                    media: item
                ))
            }
        }
        return Template(
            id: "sectionCard",
            name: "Section card",
            duration: length,
            fields: fields,
            clips: clips
        )
    }

    /// The pop callout low in the frame.
    static let likeAndSubscribe = Template(
        id: "likeAndSubscribe",
        name: "Like and subscribe",
        duration: Time(seconds: 2.5),
        clips: [
            TemplateClip(track: "Text", clip: Clip(
                name: "Like and subscribe",
                content: .text(TextContent(text: "Like and subscribe", preset: "callout")),
                start: .zero,
                duration: Time(seconds: 2.5),
                video: lowThird
            ))
        ]
    )

    static let commentBelow = Template(
        id: "commentBelow",
        name: "Comment below",
        duration: Time(seconds: 2.5),
        clips: [
            TemplateClip(track: "Text", clip: Clip(
                name: "Comment below",
                content: .text(TextContent(text: "Comment below", preset: "callout")),
                start: .zero,
                duration: Time(seconds: 2.5),
                video: lowThird
            ))
        ]
    )

    private static let lowThird = VideoProperties(transform: Transform(position: Point(x: 0.5, y: 0.84), scale: 0.7))
}
