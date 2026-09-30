import Foundation
import TandemAPI
import TandemCore

/// Builds the edit batches behind timeline actions: keys, menu items and the
/// end of each drag. Pure functions of the project and the request, so
/// every action is testable without a window. A nil result means there was
/// nothing to do.
///
/// The selection passed in is already what the user sees selected, linked
/// partners included or not, so edits use `includeLinked: false` unless the
/// action is about "the clip under the playhead".
enum TimelineEdits {
    // MARK: - Moving

    /// Moves clips by `delta`. With `toTrackID` the clips (which must all be
    /// on one track) also change track. Moves overwrite whatever they land
    /// on, like Premiere. With `insert` (Cmd-drag) the clips leave a gap
    /// where they were and push later clips at the destination to the right.
    static func move(
        _ project: Project,
        clipIDs: [String],
        delta: Time,
        toTrackID: String? = nil,
        insert: Bool = false
    ) -> EditBatch? {
        let clips = clipIDs.compactMap { id in project.location(ofClip: id).map { (id, $0) } }
        guard !clips.isEmpty else { return nil }
        let sourceTracks = Set(clips.map { project[$0.1.track].id })
        let destination = sourceTracks.count == 1 && toTrackID != sourceTracks.first ? toTrackID : nil
        guard delta != .zero || destination != nil else { return nil }
        let ids = clips.map(\.0)
        let label = ids.count == 1 ? "Move clip" : "Move \(ids.count) clips"
        guard insert else {
            return EditBatch(label: label, commands: [
                .moveClips(clipIDs: ids, delta: delta, toTrackID: destination, includeLinked: false, mode: .overwrite)
            ])
        }
        var moved: [(trackID: String, clip: Clip)] = []
        for (_, location) in clips {
            var clip = project[location.track].clips[location.index]
            clip.start += delta
            moved.append((destination ?? project[location.track].id, clip))
        }
        guard let start = moved.map(\.clip.start).min(), let end = moved.map(\.clip.end).max(), start >= .zero else { return nil }
        var commands: [EditCommand] = [.removeClips(clipIDs: ids, ripple: false, includeLinked: false)]
        let destinationTracks = Array(Set(moved.map(\.trackID))).sorted()
        commands.append(.insertTime(at: start, duration: end - start, trackIDs: destinationTracks))
        for item in moved.sorted(by: { $0.clip.start < $1.clip.start }) {
            commands.append(.insertClip(trackID: item.trackID, clip: item.clip, mode: .place))
        }
        return EditBatch(label: ids.count == 1 ? "Insert clip" : "Insert \(ids.count) clips", commands: commands)
    }

    /// Nudges the selection by whole frames, overwriting like a drag.
    static func nudge(_ project: Project, clipIDs: Set<String>, frames: Int64) -> EditBatch? {
        let ids = ordered(clipIDs, in: project)
        guard !ids.isEmpty, frames != 0 else { return nil }
        var delta = Time.frames(frames, at: project.settings.frameRate)
        if let earliest = ids.compactMap({ project.clip($0)?.start }).min(), earliest + delta < .zero {
            delta = -earliest
        }
        guard delta != .zero else { return nil }
        return EditBatch(label: frames > 0 ? "Nudge right" : "Nudge left", commands: [
            .moveClips(clipIDs: ids, delta: delta, includeLinked: false, mode: .overwrite)
        ])
    }

    // MARK: - Removing

    /// Delete lifts, Shift-Delete ripple deletes.
    static func remove(_ project: Project, clipIDs: Set<String>, ripple: Bool) -> EditBatch? {
        let ids = ordered(clipIDs, in: project)
        guard !ids.isEmpty else { return nil }
        let noun = ids.count == 1 ? "clip" : "\(ids.count) clips"
        return EditBatch(label: ripple ? "Ripple delete \(noun)" : "Delete \(noun)", commands: [
            .removeClips(clipIDs: ids, ripple: ripple, includeLinked: false)
        ])
    }

    /// Tracks the in and out edits act on: every unlocked track.
    static func unlockedTrackIDs(_ project: Project) -> [String] {
        project.allTracks.filter { !$0.locked }.map(\.id)
    }

    /// `;` in Premiere: clears the range on every unlocked track and leaves
    /// a gap. Built from a ripple delete that's opened up again, so clips
    /// crossing the edges are split exactly like an overwrite. Markers
    /// inside the range stay where they were.
    static func liftRange(_ project: Project, range: TimeRange) -> EditBatch? {
        guard !range.isEmpty, range.start >= .zero else { return nil }
        let tracks = unlockedTrackIDs(project)
        guard !tracks.isEmpty, project.allTracks.contains(where: { !$0.clips(intersecting: range).isEmpty }) else { return nil }
        var commands: [EditCommand] = [
            .rippleDeleteRange(range: range, trackIDs: tracks),
            .insertTime(at: range.start, duration: range.duration, trackIDs: tracks)
        ]
        for marker in project.markers where marker.time > range.start && marker.time < range.end {
            commands.append(.updateMarker(markerID: marker.id, patch: .object(["time": .number(marker.time.seconds)])))
        }
        return EditBatch(label: "Lift in to out", commands: commands)
    }

    /// `'` in Premiere: removes the range from every unlocked track and
    /// closes the gap.
    static func extractRange(_ project: Project, range: TimeRange) -> EditBatch? {
        guard !range.isEmpty, range.start >= .zero else { return nil }
        let tracks = unlockedTrackIDs(project)
        guard !tracks.isEmpty else { return nil }
        return EditBatch(label: "Extract in to out", commands: [.rippleDeleteRange(range: range, trackIDs: tracks)])
    }

    // MARK: - Cutting and trimming

    /// Cmd-B. Cuts the selected clips under the playhead when there are
    /// any, otherwise everything under it on targeted tracks.
    static func bladeAtPlayhead(_ project: Project, playhead: Time, selection: Set<String>) -> EditBatch? {
        let selected = ordered(selection, in: project).filter { id in
            guard let clip = project.clip(id) else { return false }
            return clip.start < playhead && playhead < clip.end
        }
        if !selected.isEmpty {
            return EditBatch(label: "Blade", commands: [.blade(at: playhead, clipIDs: selected)])
        }
        let hasTarget = project.allTracks.contains { track in
            track.targeted && !track.locked && track.clips.contains { $0.start < playhead && playhead < $0.end }
        }
        guard hasTarget else { return nil }
        return EditBatch(label: "Blade", commands: [.blade(at: playhead)])
    }

    /// A blade tool click: cuts the clip (and its linked partners) at `time`.
    /// With `allTracks` it cuts every targeted track instead.
    static func blade(_ project: Project, clipID: String, at time: Time, allTracks: Bool) -> EditBatch? {
        guard let clip = project.clip(clipID), clip.start < time, time < clip.end else { return nil }
        if allTracks { return EditBatch(label: "Blade all tracks", commands: [.blade(at: time)]) }
        return EditBatch(label: "Blade", commands: [.blade(at: time, clipIDs: [clipID])])
    }

    static func trim(_ project: Project, clipID: String, edge: ClipEdge, to time: Time, ripple: Bool, includeLinked: Bool) -> EditBatch? {
        guard let clip = project.clip(clipID) else { return nil }
        let current = edge == .start ? clip.start : clip.end
        guard time != current else { return nil }
        return EditBatch(label: ripple ? "Ripple trim" : "Trim", commands: [
            .trim(clipID: clipID, edge: edge, to: time, ripple: ripple, includeLinked: includeLinked)
        ])
    }

    /// What Q and W work on: a selected clip under the playhead, else the
    /// take (the first `cut` track with a clip there, top video track
    /// first), else any targeted track. When the take has an edit right at
    /// the playhead there's nothing to trim, so nothing is returned.
    static func clipForPlayheadTrim(_ project: Project, playhead: Time, selection: Set<String>) -> Clip? {
        func inside(_ clip: Clip) -> Bool { clip.start < playhead && playhead < clip.end }
        if let selected = ordered(selection, in: project).compactMap({ project.clip($0) }).first(where: inside) {
            return selected
        }
        let tracks = project.videoTracks.reversed() + project.audioTracks
        let take = tracks.filter { $0.rippleMode == .cut && !$0.locked }.compactMap { $0.clip(at: playhead) }
        if !take.isEmpty { return take.first(where: inside) }
        return tracks.filter { $0.targeted && !$0.locked }.compactMap { $0.clip(at: playhead) }.first(where: inside)
    }

    /// Q (`.start`) and W (`.end`): ripple trims the clip under the playhead
    /// to it, closing the gap. Returns where the playhead should go: Q
    /// leaves it on the new edit point, which is the clip's start.
    static func rippleTrimToPlayhead(_ project: Project, playhead: Time, edge: ClipEdge, selection: Set<String>) -> (batch: EditBatch, playhead: Time)? {
        guard let clip = clipForPlayheadTrim(project, playhead: playhead, selection: selection) else { return nil }
        let partners = project.linkedClipIDs(of: clip.id)
        let includeLinked = selection.isEmpty || selection.isSuperset(of: partners) || !selection.contains(clip.id)
        let batch = EditBatch(label: edge == .start ? "Ripple trim start to playhead" : "Ripple trim end to playhead", commands: [
            .trim(clipID: clip.id, edge: edge, to: playhead, ripple: true, includeLinked: includeLinked)
        ])
        return (batch, edge == .start ? clip.start : playhead)
    }

    static func roll(leftClipID: String, rightClipID: String, delta: Time) -> EditBatch? {
        guard delta != .zero else { return nil }
        return EditBatch(label: "Roll edit", commands: [.roll(leftClipID: leftClipID, rightClipID: rightClipID, delta: delta)])
    }

    /// Slipping by a timeline distance: dragging right reveals earlier
    /// media, like pulling the film strip under a fixed window.
    static func slip(_ project: Project, clipID: String, timelineDelta: Time, includeLinked: Bool) -> EditBatch? {
        guard let clip = project.clip(clipID), timelineDelta != .zero, !clip.freezeFrame else { return nil }
        let mediaDelta = -timelineDelta.scaled(by: clip.speed)
        return EditBatch(label: "Slip", commands: [.slip(clipID: clipID, delta: mediaDelta, includeLinked: includeLinked)])
    }

    static func slide(clipID: String, delta: Time) -> EditBatch? {
        guard delta != .zero else { return nil }
        return EditBatch(label: "Slide", commands: [.slide(clipID: clipID, delta: delta)])
    }

    // MARK: - Layout, links, markers, transitions

    /// Which clips keys 1 to 4 act on: selected video clips, or the camera
    /// clip under the playhead (else the top media clip there).
    static func layoutTargets(_ project: Project, playhead: Time, selection: Set<String>) -> [String] {
        let selectedVideo = ordered(selection, in: project).filter { project.location(ofClip: $0)?.track.kind == .video }
        if !selectedVideo.isEmpty { return selectedVideo }
        let underPlayhead = project.videoTracks.reversed().compactMap { $0.clip(at: playhead) }
        func role(_ clip: Clip) -> MediaRole? { clip.mediaID.flatMap { project.media($0)?.role } }
        if let camera = underPlayhead.first(where: { role($0) == .camera }) { return [camera.id] }
        if let media = underPlayhead.first(where: { $0.mediaID != nil }) { return [media.id] }
        return underPlayhead.first.map { [$0.id] } ?? []
    }

    static func applyLayout(_ project: Project, preset: LayoutPreset, playhead: Time, selection: Set<String>) -> EditBatch? {
        let targets = layoutTargets(project, playhead: playhead, selection: selection)
        guard !targets.isEmpty else { return nil }
        return EditBatch(label: "Layout: \(preset.name)", commands: [.applyLayout(clipIDs: targets, preset: preset)])
    }

    /// Cmd-L: links the selection, or unlinks it when it's already one group.
    static func toggleLink(_ project: Project, selection: Set<String>) -> EditBatch? {
        let ids = ordered(selection, in: project)
        guard !ids.isEmpty else { return nil }
        let groups = Set(ids.map { project.clip($0)?.linkGroup })
        if groups.count == 1, let group = groups.first, group != nil {
            return EditBatch(label: ids.count == 1 ? "Unlink clip" : "Unlink \(ids.count) clips", commands: [.unlink(clipIDs: ids)])
        }
        guard ids.count > 1 else { return nil }
        return EditBatch(label: "Link \(ids.count) clips", commands: [.link(clipIDs: ids)])
    }

    static func addMarker(_ project: Project, at time: Time, id: String = IDs.make("mk")) -> EditBatch {
        let number = project.markers.count + 1
        return EditBatch(label: "Add marker", commands: [
            .addMarker(marker: Marker(id: id, time: time, name: "Marker \(number)"))
        ])
    }

    /// The two touching clips on `trackID` whose cut is nearest `time`,
    /// within `reach`.
    static func nearestCut(on track: Track, to time: Time, reach: Time) -> (left: Clip, right: Clip)? {
        var best: (Clip, Clip, Int64)?
        for (left, right) in zip(track.clips, track.clips.dropFirst()) where left.end == right.start {
            let distance = abs(left.end.flicks - time.flicks)
            guard distance <= reach.flicks else { continue }
            if best == nil || distance < best!.2 { best = (left, right, distance) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Cmd-D: a dissolve on the cut nearest the playhead, on the selected
    /// clip's track or else the first track (top down) with a cut in reach,
    /// playing `sound` (its type's, copied into the project) if it has one.
    static func addDefaultTransition(_ project: Project, playhead: Time, selection: Set<String>, type: TransitionType = .dissolve, id: String = IDs.make("tr"), sound: TransitionSoundDefaults.Resolved? = nil) -> EditBatch? {
        let reach = Time(seconds: 1)
        var tracks: [Track] = ordered(selection, in: project).compactMap { project.track(containingClip: $0) }
        tracks += project.videoTracks.reversed() + project.audioTracks
        for track in tracks where !track.locked {
            guard let (left, right) = nearestCut(on: track, to: playhead, reach: reach) else { continue }
            if track.transitions.contains(where: { $0.fromClipID == left.id || $0.toClipID == right.id }) { continue }
            let transition = Transition(id: id, type: type, duration: type.defaultDuration, fromClipID: left.id, toClipID: right.id)
            let prepared = sound?.prepared(for: project)
            return EditBatch(label: "Add \(type.displayName.lowercased())", commands: (prepared?.addMedia ?? []) + [
                .addTransition(trackID: track.id, transition: transition, sound: prepared?.sound)
            ])
        }
        return nil
    }

    // MARK: - Placing media

    /// Dropping media from the browser. A single file dropped on a track
    /// goes to that track; takes and multiple files route by role.
    static func placeMedia(
        _ project: Project,
        mediaIDs: [String],
        at time: Time,
        trackID: String?,
        insert: Bool
    ) -> EditBatch? {
        let ids = mediaIDs.filter { project.media($0) != nil }
        guard !ids.isEmpty else { return nil }
        var videoTrackID: String?
        var audioTrackID: String?
        if ids.count == 1, let trackID, let track = project.track(trackID), let item = project.media(ids[0]) {
            if track.kind == .video && (item.hasVideo || item.kind == .image) { videoTrackID = trackID }
            if track.kind == .audio && item.hasAudio { audioTrackID = trackID }
        }
        let name = ids.count == 1 ? project.media(ids[0]).map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent } ?? "media" : "\(ids.count) files"
        return EditBatch(label: insert ? "Insert \(name)" : "Place \(name)", commands: [
            .placeMedia(
                mediaIDs: ids, at: max(.zero, time), mode: insert ? .insert : .overwrite,
                videoTrackID: videoTrackID, audioTrackID: audioTrackID
            )
        ])
    }

    /// Media placed on a track made for it in the same edit: a video track
    /// on top for picture, or an audio track at the bottom for sound. Nil
    /// when the media has nothing for that kind of track.
    static func placeMediaOnNewTrack(
        _ project: Project,
        mediaIDs: [String],
        at time: Time,
        kind: TrackKind,
        insert: Bool,
        trackID: String = IDs.make("trk")
    ) -> EditBatch? {
        let items = mediaIDs.compactMap { project.media($0) }
        let fits = kind == .video ? items.contains { $0.hasVideo || $0.kind == .image } : items.contains(where: \.hasAudio)
        guard fits, let place = placeMedia(project, mediaIDs: items.map(\.id), at: time, trackID: nil, insert: insert) else { return nil }
        return EditBatch(label: place.label + (kind == .video ? " on a new video track" : " on a new audio track"), commands: [
            .addTrack(kind: kind, id: trackID),
            .placeMedia(
                mediaIDs: items.map(\.id), at: max(.zero, time), mode: insert ? .insert : .overwrite,
                videoTrackID: kind == .video ? trackID : nil, audioTrackID: kind == .audio ? trackID : nil
            )
        ])
    }

    /// Where a click on a clip puts the playhead: its start, unless the
    /// playhead is on the clip already. Nil leaves it where it is.
    static func playheadForClick(on clip: Clip, playhead: Time) -> Time? {
        clip.start <= playhead && playhead < clip.end ? nil : clip.start
    }

    // MARK: - Helpers

    /// IDs that exist, in timeline order, so batches read the same way twice.
    static func ordered(_ ids: Set<String>, in project: Project) -> [String] {
        project.allTracks.flatMap(\.clips).map(\.id).filter(ids.contains)
    }
}

extension TransitionType {
    /// Sentence-case names for menus and labels.
    var displayName: String {
        switch self {
        case .dissolve: return "Dissolve"
        case .fadeToBlack: return "Fade to black"
        case .fadeFromBlack: return "Fade from black"
        case .push: return "Push"
        case .slide: return "Slide"
        case .cutSlide: return "Cut slide"
        case .wipe: return "Wipe"
        case .zoom: return "Zoom"
        }
    }
}

/// Where a drop lands among the tracks. On a lane it's that track. Above the
/// top video track, or below the last track, it makes a track for what's
/// dropped, as Filmora does, instead of picking one of the existing ones.
enum DropTarget: Equatable {
    /// The track under the pointer, or nil on the transcript lane's gaps.
    case track(String?)
    case newVideoTrackOnTop
    case newAudioTrackAtBottom

    static func at(y: CGFloat, in layout: TimelineLayout) -> DropTarget {
        let tracks = layout.lanes.filter { $0.trackID != nil }
        if let top = tracks.first(where: { $0.kind == .video }) ?? tracks.first, y < top.y { return .newVideoTrackOnTop }
        if let last = tracks.last, y >= last.maxY { return .newAudioTrackAtBottom }
        return .track(layout.lane(atY: y)?.trackID)
    }
}
