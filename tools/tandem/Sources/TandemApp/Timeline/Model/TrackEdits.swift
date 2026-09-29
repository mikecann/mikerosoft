import Foundation
import TandemCore

/// Adding, removing, renaming and reordering tracks from the headers. Each
/// is one of the core track commands, so it undoes like any other edit.
///
/// "Above" and "below" are as the timeline shows tracks: video tracks top
/// down from the highest index (they draw bottom to top), then audio tracks
/// in index order.
enum TrackEdits {
    enum Side {
        case above, below
    }

    /// A new track of `kind` beside `reference`, or with no reference, on
    /// top of the video tracks or under the audio ones. New tracks follow
    /// ripple edits: they hold overlays and extra sound, which should move
    /// with the talking rather than be cut by pause tightening.
    static func add(_ kind: TrackKind, beside reference: String? = nil, side: Side = .above, in project: Project, id: String = IDs.make("trk")) -> EditBatch {
        let tracks = kind == .video ? project.videoTracks : project.audioTracks
        var index = tracks.count
        if let reference, let at = tracks.firstIndex(where: { $0.id == reference }) {
            switch (kind, side) {
            case (.video, .above), (.audio, .below): index = at + 1
            case (.video, .below), (.audio, .above): index = at
            }
        }
        return EditBatch(label: kind == .video ? "Add video track" : "Add audio track", commands: [
            .addTrack(kind: kind, name: name(for: kind, in: project), index: index, id: id),
            .updateTrack(trackID: id, patch: .object(["rippleMode": .string(RippleMode.follow.rawValue)]))
        ])
    }

    /// "Video 6", or the next number that no track uses.
    static func name(for kind: TrackKind, in project: Project) -> String {
        let taken = Set(project.allTracks.map { $0.name.lowercased() })
        let base = kind == .video ? "Video" : "Audio"
        var number = (kind == .video ? project.videoTracks.count : project.audioTracks.count) + 1
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    /// Removes a track and everything on it. Clips elsewhere that were
    /// linked only to clips on it are unlinked, so no link is left with one
    /// clip. Nil for a locked track.
    static func remove(_ trackID: String, in project: Project) -> EditBatch? {
        guard let track = project.track(trackID), !track.locked else { return nil }
        let removed = Set(track.clips.map(\.id))
        var groups: [String: [String]] = [:]
        for clip in project.allTracks.flatMap(\.clips) where !removed.contains(clip.id) {
            if let group = clip.linkGroup { groups[group, default: []].append(clip.id) }
        }
        let orphaned = Set(track.clips.compactMap(\.linkGroup)).compactMap { groups[$0] }.filter { $0.count == 1 }.flatMap { $0 }
        var commands: [EditCommand] = [.removeTrack(trackID: trackID)]
        if !orphaned.isEmpty { commands.append(.unlink(clipIDs: orphaned.sorted())) }
        return EditBatch(label: removeTitle(for: track), commands: commands)
    }

    /// "Delete track", or with what goes with it: "Delete track and its 3 clips".
    static func removeTitle(for track: Track) -> String {
        switch track.clips.count {
        case 0: return "Delete track"
        case 1: return "Delete track and its clip"
        default: return "Delete track and its \(track.clips.count) clips"
        }
    }

    /// One place up or down the timeline, among tracks of its kind. Nil at
    /// the end.
    static func move(_ trackID: String, up: Bool, in project: Project) -> EditBatch? {
        guard let track = project.track(trackID) else { return nil }
        let tracks = track.kind == .video ? project.videoTracks : project.audioTracks
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return nil }
        let target = track.kind == .video ? (up ? index + 1 : index - 1) : (up ? index - 1 : index + 1)
        guard tracks.indices.contains(target) else { return nil }
        return EditBatch(label: up ? "Move track up" : "Move track down", commands: [.moveTrack(trackID: trackID, index: target)])
    }

    /// Dropped after a drag: `position` is where it now shows among the
    /// tracks of its kind, 0 the top one. Nil when that's where it was.
    static func move(_ trackID: String, toPosition position: Int, in project: Project) -> EditBatch? {
        guard let track = project.track(trackID) else { return nil }
        let tracks = track.kind == .video ? project.videoTracks : project.audioTracks
        guard let current = tracks.firstIndex(where: { $0.id == trackID }) else { return nil }
        let clamped = min(max(position, 0), tracks.count - 1)
        let index = track.kind == .video ? tracks.count - 1 - clamped : clamped
        guard index != current else { return nil }
        return EditBatch(label: "Move track", commands: [.moveTrack(trackID: trackID, index: index)])
    }

    /// Where a dragged track would show if dropped at `y`: how many of the
    /// other tracks of its kind sit above that point. `lanes` are the
    /// timeline's, top down.
    static func position(forDropAt y: CGFloat, dragging trackID: String, kind: TrackKind, lanes: [TimelineLane]) -> Int {
        lanes.filter { $0.kind == kind && $0.trackID != nil && $0.trackID != trackID && $0.midY < y }.count
    }

    /// A new name. Nil when it's empty or unchanged.
    static func rename(_ trackID: String, to name: String, in project: Project) -> EditBatch? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let track = project.track(trackID), !trimmed.isEmpty, trimmed != track.name else { return nil }
        return EditBatch(label: "Rename track", commands: [.updateTrack(trackID: trackID, patch: .object(["name": .string(trimmed)]))])
    }
}

extension EditorModel {
    /// Adds a track (see `TrackEdits.add`) and opens its name for typing.
    @discardableResult
    func addTrack(_ kind: TrackKind, beside reference: String? = nil, side: TrackEdits.Side = .above) -> Bool {
        let id = IDs.make("trk")
        guard apply(TrackEdits.add(kind, beside: reference, side: side, in: project, id: id)) != nil else { return false }
        timeline.renamingTrackID = id
        return true
    }
}
