import Foundation
import TandemCore
import TandemRender

/// What happens when a transition, effect, title or template is dropped
/// on the timeline (or double-clicked, at the playhead).
enum LibraryDrops {
    /// A transition dropped near a cut: on the nearest cut on the track
    /// under the pointer (with no track, the top-most one with a cut in
    /// reach). A cut that already has one gets the new type instead.
    static func transition(_ type: TransitionType, at time: Time, trackID: String?, in project: Project, reach: Time = Time(seconds: 1), id: String = IDs.make("tr")) -> EditBatch? {
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
                return EditBatch(label: "Change to \(type.displayName.lowercased())", commands: [
                    .updateTransition(transitionID: existing.id, patch: .object(["type": .string(type.rawValue)]))
                ])
            }
            let transition = Transition(id: id, type: type, duration: type.defaultDuration, fromClipID: left.id, toClipID: right.id)
            return EditBatch(label: "Add \(type.displayName.lowercased())", commands: [.addTransition(trackID: track.id, transition: transition)])
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

    /// A built-in template, or a saved segment (`segment:<folder>`).
    static func template(_ id: String) -> Template? {
        all.first { $0.id == id } ?? SegmentShelf.shared.template(id)
    }

    /// A dark card behind a two-line section header.
    static let sectionCard = Template(
        id: "sectionCard",
        name: "Section card",
        duration: Time(seconds: 3.3),
        fields: [
            TemplateField(key: "number", label: "Number", defaultValue: "1"),
            TemplateField(key: "title", label: "Title", defaultValue: "The leaderboard")
        ],
        clips: [
            TemplateClip(track: "Graphics", clip: Clip(name: "Section card", content: .solid(color: RGBA(r: 0.07, g: 0.07, b: 0.08)), start: .zero, duration: Time(seconds: 3.3))),
            TemplateClip(track: "Text", offset: Time(seconds: 0.2), clip: Clip(
                name: "Section title",
                content: .text(TextContent(text: "Section {{number}}\n{{title}}", preset: "sectionHeader")),
                start: .zero,
                duration: Time(seconds: 3)
            ))
        ]
    )

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
