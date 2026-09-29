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
    /// Parts of the lanes, in their view coordinates.
    var laneRects: [CGRect] = []

    var isEmpty: Bool { !ruler && !headers && !allLanes && laneRects.isEmpty }

    /// What changed from `old` to `new`. `layoutChanged` says whether the
    /// lanes moved (heights, tracks added, the transcript lane shown).
    static func between(_ old: TimelineDrawState, _ new: TimelineDrawState, layout: TimelineLayout, layoutChanged: Bool) -> TimelineDamage {
        var damage = TimelineDamage()
        if old.revision != new.revision {
            // An edit: names, clips and markers can all change.
            return TimelineDamage(ruler: true, headers: true, allLanes: true)
        }
        if old.scale != new.scale || old.inPoint != new.inPoint || old.outPoint != new.outPoint {
            damage.ruler = true
            damage.allLanes = true
        }
        if layoutChanged || old.verticalOffset != new.verticalOffset {
            damage.headers = true
            damage.allLanes = true
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
    /// changed, and the transitions selected before and after.
    static func selectionRects(from old: TimelineDrawState, to new: TimelineDrawState, layout: TimelineLayout) -> [CGRect] {
        guard old.selection != new.selection || old.selectedKeyframe != new.selectedKeyframe
            || old.selectedTransitionID != new.selectedTransitionID else { return [] }
        let project = new.project
        func linkGroups(_ selection: Set<String>) -> Set<String> {
            Set(selection.compactMap { project.clip($0)?.linkGroup })
        }
        let oldGroups = linkGroups(old.selection)
        let newGroups = linkGroups(new.selection)
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
                guard wasSelected != isSelected || wasLinked != isLinked || oldKeyframe != newKeyframe else { continue }
                let x0 = scale.x(clip.start)
                let x1 = scale.x(clip.end)
                // Keyframe diamonds reach a few points past the clip's ends.
                rects.append(CGRect(x: x0, y: y, width: max(1, x1 - x0), height: lane.height).insetBy(dx: -keyframeReach, dy: -1))
            }
            guard old.selectedTransitionID != new.selectedTransitionID else { continue }
            let shifted = TimelineLane(trackID: lane.trackID, kind: lane.kind, style: lane.style, y: y, height: lane.height)
            for transition in track.transitions where transition.id == old.selectedTransitionID || transition.id == new.selectedTransitionID {
                let parts = [
                    TransitionGeometry.bandRect(transition, on: track, lane: shifted, scale: scale),
                    TransitionGeometry.chipRect(transition, on: track, lane: shifted, scale: scale)
                ].compactMap { $0 }
                if let first = parts.first {
                    rects.append(parts.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -2, dy: -1))
                }
            }
        }
        return rects
    }

    /// How far past a clip's ends its drawing can reach: half a selected
    /// keyframe diamond, and a little to spare.
    static let keyframeReach: CGFloat = KeyframeGeometry.size
}
