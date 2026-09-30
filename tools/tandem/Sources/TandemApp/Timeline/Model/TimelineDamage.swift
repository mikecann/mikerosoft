import CoreGraphics
import TandemCore

/// The model's state as the timeline draws it, copied out whenever it
/// changes. The ruler, headers and lanes draw from this rather than the
/// model: AppKit redraws a whole view when any @Observable value its
/// `draw(_:)` read changes, which undid every careful invalidation. The
/// transcript highlight read the playhead, so the lanes redrew in full 60
/// times a second while playing.
struct TimelineDrawState {
    /// The committed project (a drag's preview lives in the lanes view).
    var project: Project
    var revision: Int
    var scale: TimelineScale
    var verticalOffset: CGFloat
    var trackHeights: [String: CGFloat]
    var showTranscript: Bool
    var selection: Set<String>
    var selectedTransitionID: String?
    var selectedKeyframe: KeyframeRef?
    var inPoint: Time?
    var outPoint: Time?
    var renamingTrackID: String?
    var artworkRevision: Int

    var frameRate: FrameRate { project.settings.frameRate }
}

@MainActor
extension TimelineDrawState {
    init(model: EditorModel) {
        self.init(
            project: model.project, revision: model.revision, scale: model.timeline.scale,
            verticalOffset: model.timeline.verticalOffset, trackHeights: model.timeline.trackHeights,
            showTranscript: model.showTranscript, selection: model.selection,
            selectedTransitionID: model.selectedTransitionID, selectedKeyframe: model.selectedKeyframe,
            inPoint: model.inPoint, outPoint: model.outPoint, renamingTrackID: model.timeline.renamingTrackID,
            artworkRevision: model.artworkRevision
        )
    }
}

/// Which of the timeline's views need drawing again after a change, and
/// for the lanes, which parts when it isn't all of them.
struct TimelineDamage: Equatable {
    var ruler = false
    var headers = false
    var allLanes = false
    /// The lanes scrolled, sideways or up and down, without changing: their
    /// tiles move rather than paint.
    var lanesMoved = false
    /// The zoom or the lanes' heights changed: everything in them moved
    /// and changed size, and usually goes on changing (a zoom, a track's
    /// edge dragged).
    var lanesReshaped = false
    /// An edit: the lanes repaint the clips it changed (see `previewRects`).
    var lanesEdited = false
    /// Parts of the lanes, in their view coordinates.
    var laneRects: [CGRect] = []

    var isEmpty: Bool { !ruler && !headers && !allLanes && !lanesMoved && !lanesReshaped && !lanesEdited && laneRects.isEmpty }

    /// What changed from `old` to `new`. `layoutChanged` says whether the
    /// lanes moved (heights, tracks added, the transcript lane shown).
    static func between(_ old: TimelineDrawState, _ new: TimelineDrawState, layout: TimelineLayout, layoutChanged: Bool) -> TimelineDamage {
        var damage = TimelineDamage()
        if old.revision != new.revision {
            // An edit: markers, track names and clips can all change.
            damage.ruler = true
            damage.headers = true
            damage.lanesEdited = true
        }
        if old.scale.pixelsPerSecond != new.scale.pixelsPerSecond {
            damage.ruler = true
            damage.allLanes = true
            damage.lanesReshaped = true
        }
        if old.inPoint != new.inPoint || old.outPoint != new.outPoint {
            damage.ruler = true
            damage.allLanes = true
        }
        if old.scale.scrollSeconds != new.scale.scrollSeconds {
            damage.ruler = true
            damage.lanesMoved = true
        }
        if layoutChanged {
            damage.headers = true
            damage.allLanes = true
            damage.lanesReshaped = true
        }
        if old.verticalOffset != new.verticalOffset {
            damage.headers = true
            damage.lanesMoved = true
        }
        if old.renamingTrackID != new.renamingTrackID { damage.headers = true }
        if old.artworkRevision != new.artworkRevision { damage.allLanes = true }
        if !damage.allLanes {
            damage.laneRects = selectionRects(from: old, to: new, layout: layout)
        }
        return damage
    }

    /// Where the lanes look different because the selection changed: the
    /// clips that became or stopped being selected, the clips linked to
    /// them (drawn with a dashed edge), clips whose chosen keyframe
    /// changed, and the transitions selected before and after, with their
    /// sounds (dashed too).
    static func selectionRects(from old: TimelineDrawState, to new: TimelineDrawState, layout: TimelineLayout) -> [CGRect] {
        guard old.selection != new.selection || old.selectedKeyframe != new.selectedKeyframe
            || old.selectedTransitionID != new.selectedTransitionID else { return [] }
        let project = new.project
        func linkGroups(_ selection: Set<String>) -> Set<String> {
            Set(selection.compactMap { project.clip($0)?.linkGroup })
        }
        let oldGroups = linkGroups(old.selection)
        let newGroups = linkGroups(new.selection)
        func sound(_ transitionID: String?) -> String? {
            transitionID.flatMap { id in project.location(ofTransition: id).flatMap { project[$0.track].transitions[$0.index].soundClipID } }
        }
        let sounds = old.selectedTransitionID == new.selectedTransitionID ? [] : Set([sound(old.selectedTransitionID), sound(new.selectedTransitionID)].compactMap { $0 })
        let scale = new.scale
        var rects: [CGRect] = []
        for lane in layout.lanes {
            guard let trackID = lane.trackID, let track = project.track(trackID) else { continue }
            let y = lane.y - new.verticalOffset
            for clip in track.clips {
                let wasSelected = old.selection.contains(clip.id)
                let isSelected = new.selection.contains(clip.id)
                let wasLinked = !wasSelected && clip.linkGroup.map(oldGroups.contains) == true
                let isLinked = !isSelected && clip.linkGroup.map(newGroups.contains) == true
                let oldKeyframe = old.selectedKeyframe?.clipID == clip.id ? old.selectedKeyframe?.time : nil
                let newKeyframe = new.selectedKeyframe?.clipID == clip.id ? new.selectedKeyframe?.time : nil
                guard wasSelected != isSelected || wasLinked != isLinked || oldKeyframe != newKeyframe || sounds.contains(clip.id) else { continue }
                let x0 = scale.x(clip.start)
                let x1 = scale.x(clip.end)
                // Keyframe diamonds reach a few points past the clip's ends.
                rects.append(CGRect(x: x0, y: y, width: max(1, x1 - x0), height: lane.height).insetBy(dx: -keyframeReach, dy: -1))
            }
            guard old.selectedTransitionID != new.selectedTransitionID else { continue }
            let shifted = TimelineLane(trackID: lane.trackID, kind: lane.kind, style: lane.style, y: y, height: lane.height)
            for transition in track.transitions where transition.id == old.selectedTransitionID || transition.id == new.selectedTransitionID {
                if let rect = TransitionGeometry.paintRect(transition, on: track, lane: shifted, scale: scale) { rects.append(rect) }
            }
        }
        return rects
    }

    /// How far past a clip's ends its drawing can reach: half a selected
    /// keyframe diamond, and a little to spare.
    static let keyframeReach: CGFloat = KeyframeGeometry.size
}

/// What a drag or drop's preview shows in the lanes, so the next move
/// repaints only what it changes.
struct PreviewState {
    /// The project as it would be after the drag or drop.
    var project: Project
    /// Clips the preview moved or made, outlined.
    var previewed: Set<String>
    /// The track a drop would land on, tinted.
    var dropLaneID: String?
    /// A keyframe being dragged and where to.
    var keyframeClipID: String?
    var keyframeTime: Time?
}

extension TimelineDamage {
    /// The parts of the lanes, in view coordinates, that look different
    /// from one preview to the next: clips that moved, changed, came or
    /// went (both where they were and where they are), transitions likewise,
    /// the tinted lane, and the transcript when the take's sound changed.
    /// Nil when the tracks themselves changed, which moves every lane.
    static func previewRects(from old: PreviewState, to new: PreviewState, layout: TimelineLayout, scale: TimelineScale, offsetY: CGFloat, width: CGFloat) -> [CGRect]? {
        let oldTracks = Dictionary(uniqueKeysWithValues: old.project.allTracks.map { ($0.id, $0) })
        let newTracks = Dictionary(uniqueKeysWithValues: new.project.allTracks.map { ($0.id, $0) })
        guard Set(oldTracks.keys) == Set(newTracks.keys) else { return nil }
        var rects: [CGRect] = []
        func clipRect(_ clip: Clip, in lane: TimelineLane) -> CGRect {
            let x0 = scale.x(clip.start)
            let x1 = scale.x(clip.end)
            return CGRect(x: x0, y: lane.y - offsetY, width: max(1, x1 - x0), height: lane.height).insetBy(dx: -keyframeReach, dy: -1)
        }
        var soundChanged = false
        // Clips outlined in one preview and not the other, and the clips of
        // a dragged keyframe.
        var highlighted = old.previewed.symmetricDifference(new.previewed)
        if old.keyframeTime != new.keyframeTime || old.keyframeClipID != new.keyframeClipID {
            highlighted.formUnion([old.keyframeClipID, new.keyframeClipID].compactMap { $0 })
        }
        // A picked transition's sound is drawn dashed, so a transition that
        // changed sound repaints both clips, wherever they are.
        for (id, after) in newTracks {
            guard let before = oldTracks[id], before.transitions != after.transitions else { continue }
            var was: [String: String] = [:]
            for transition in before.transitions { was[transition.id] = transition.soundClipID ?? "" }
            for transition in after.transitions {
                guard let sound = was[transition.id], sound != transition.soundClipID ?? "" else { continue }
                highlighted.formUnion([sound, transition.soundClipID ?? ""].filter { !$0.isEmpty })
            }
        }
        for lane in layout.lanes {
            guard let id = lane.trackID, let before = oldTracks[id], let after = newTracks[id] else { continue }
            if (old.dropLaneID == id) != (new.dropLaneID == id) {
                rects.append(CGRect(x: 0, y: lane.y - offsetY, width: width, height: lane.height))
            }
            if before == after {
                // The same clips (which compares at once when the previews
                // share them): only outlines can have changed.
                if !highlighted.isEmpty {
                    for clip in after.clips where highlighted.contains(clip.id) { rects.append(clipRect(clip, in: lane)) }
                }
                continue
            }
            if before.name != after.name || before.kind != after.kind || before.hidden != after.hidden || before.muted != after.muted || before.locked != after.locked {
                // The track's style, dimming or hatching: all of it.
                rects.append(CGRect(x: 0, y: lane.y - offsetY, width: width, height: lane.height))
                if before.muted != after.muted, after.kind == .audio { soundChanged = true }
                continue
            }
            if (before.clips != after.clips && after.kind == .audio && after.rippleMode == .cut) || before.rippleMode != after.rippleMode { soundChanged = true }
            var beforeClips: [String: Clip] = [:]
            for clip in before.clips { beforeClips[clip.id] = clip }
            var afterClips: [String: Clip] = [:]
            for clip in after.clips { afterClips[clip.id] = clip }
            var moved = Set<String>()
            for clipID in Set(beforeClips.keys).union(afterClips.keys) {
                let was = beforeClips[clipID]
                let isNow = afterClips[clipID]
                if was != isNow { moved.insert(clipID) }
                guard was != isNow || highlighted.contains(clipID) else { continue }
                if let was { rects.append(clipRect(was, in: lane)) }
                if let isNow { rects.append(clipRect(isNow, in: lane)) }
            }
            // A transition that changed, or whose clips did (a roll moves
            // its box), where it was and where it is: its box can reach
            // past its clips' rectangles when zoomed out.
            if before.transitions != after.transitions || !moved.isEmpty {
                let shifted = TimelineLane(trackID: lane.trackID, kind: lane.kind, style: lane.style, y: lane.y - offsetY, height: lane.height)
                let unchanged = Set(before.transitions.filter { after.transitions.contains($0) }.map(\.id))
                for (track, transition) in before.transitions.map({ (before, $0) }) + after.transitions.map({ (after, $0) }) {
                    let clipsMoved = [transition.fromClipID, transition.toClipID].contains { $0.map(moved.contains) ?? false }
                    guard !unchanged.contains(transition.id) || clipsMoved else { continue }
                    if let rect = TransitionGeometry.paintRect(transition, on: track, lane: shifted, scale: scale) { rects.append(rect) }
                }
            }
        }
        if soundChanged, let transcript = layout.lanes.first(where: \.isTranscript) {
            rects.append(CGRect(x: 0, y: transcript.y - offsetY, width: width, height: transcript.height))
        }
        return rects
    }
}
