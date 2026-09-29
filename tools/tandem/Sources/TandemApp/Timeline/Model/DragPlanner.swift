import CoreGraphics
import Foundation
import TandemCore

/// The editing tools, Premiere style.
enum TimelineTool: String, CaseIterable, Codable {
    /// Select, move, and trim edges.
    case select
    /// Cuts clips where you click.
    case blade
    /// Trims an edge and moves everything after it.
    case rippleTrim
    /// Moves a cut between two touching clips.
    case roll
    /// Changes which part of the media a clip shows.
    case slip
    /// Moves a clip between its neighbours, trimming them.
    case slide

    var name: String {
        switch self {
        case .select: return "Select"
        case .blade: return "Blade"
        case .rippleTrim: return "Ripple trim"
        case .roll: return "Roll"
        case .slip: return "Slip"
        case .slide: return "Slide"
        }
    }

    /// What it does, for its tooltip.
    var summary: String {
        switch self {
        case .select: return "select, move and trim clips"
        case .blade: return "click a clip to cut it there"
        case .rippleTrim: return "trim an edge and close up the rest of the track"
        case .roll: return "move the cut between two touching clips"
        case .slip: return "change which part of the media a clip shows"
        case .slide: return "move a clip between its neighbours, trimming them"
        }
    }

    /// The keymap command that picks it.
    var command: EditorCommand {
        switch self {
        case .select: return .toolSelect
        case .blade: return .toolBlade
        case .rippleTrim: return .toolRippleTrim
        case .roll: return .toolRoll
        case .slip: return .toolSlip
        case .slide: return .toolSlide
        }
    }
}

/// What a drag started on the timeline will do.
enum DragKind: Equatable {
    /// Moving the selected clips. `anchorClipID` is the clip under the
    /// pointer, which decides the destination track.
    case move(clipIDs: [String], anchorClipID: String)
    case trim(clipID: String, edge: ClipEdge, ripple: Bool, includeLinked: Bool)
    case roll(leftClipID: String, rightClipID: String)
    case slip(clipID: String, includeLinked: Bool)
    case slide(clipID: String)

    /// Picks the drag for a press at `hit` with `tool`. Edges trim with the
    /// select tool (ripple when `rippleByDefault` or Cmd is down); Option
    /// trims one side of a linked group only.
    static func forPress(
        on hit: TimelineHit,
        tool: TimelineTool,
        project: Project,
        selection: Set<String>,
        rippleByDefault: Bool,
        command: Bool,
        option: Bool
    ) -> DragKind? {
        guard case .clip(let clipID, let trackID, let part) = hit, let track = project.track(trackID), !track.locked else { return nil }
        let includeLinked = !option
        switch tool {
        case .select, .rippleTrim:
            let ripple = tool == .rippleTrim || rippleByDefault || command
            switch part {
            case .head:
                return .trim(clipID: clipID, edge: .start, ripple: ripple, includeLinked: includeLinked)
            case .tail:
                return .trim(clipID: clipID, edge: .end, ripple: ripple, includeLinked: includeLinked)
            case .body:
                guard tool == .select else { return nil }
                let ids = selection.contains(clipID) ? TimelineEdits.ordered(selection, in: project) : [clipID]
                return .move(clipIDs: ids, anchorClipID: clipID)
            }
        case .roll:
            guard let clip = project.clip(clipID) else { return nil }
            switch part {
            case .head:
                if let left = track.clip(endingAt: clip.start, excluding: clip.id) { return .roll(leftClipID: left.id, rightClipID: clip.id) }
                return .trim(clipID: clipID, edge: .start, ripple: false, includeLinked: includeLinked)
            case .tail:
                if let right = track.clip(startingAt: clip.end, excluding: clip.id) { return .roll(leftClipID: clip.id, rightClipID: right.id) }
                return .trim(clipID: clipID, edge: .end, ripple: false, includeLinked: includeLinked)
            case .body:
                return nil
            }
        case .slip:
            return .slip(clipID: clipID, includeLinked: includeLinked)
        case .slide:
            return .slide(clipID: clipID)
        case .blade:
            return nil
        }
    }

    /// Clips that shouldn't be snap targets while this drag runs.
    func movingClipIDs(in project: Project) -> Set<String> {
        switch self {
        case .move(let ids, _): return Set(ids)
        case .trim(let id, _, _, let linked): return Set(linked ? project.linkedClipIDs(of: id) : [id])
        case .roll(let left, let right): return [left, right]
        case .slip(let id, _): return [id]
        case .slide(let id): return Set(project.linkedClipIDs(of: id))
        }
    }
}

/// Where the pointer is, relative to where the drag started.
struct DragPointer: Equatable {
    /// Pixels moved horizontally since the press.
    var deltaX: CGFloat
    /// The pointer's lane-space y now.
    var y: CGFloat
    /// Cmd held: moves insert instead of overwriting.
    var insert: Bool = false
    /// Shift held: snapping is inverted for this drag, like Premiere.
    var invertSnap: Bool = false
}

/// The state a drag is planned against.
struct DragContext {
    var project: Project
    var scale: TimelineScale
    var layout: TimelineLayout
    var snapping: Bool
    var playhead: Time
    var inPoint: Time? = nil
    var outPoint: Time? = nil
}

/// A planned drag: the batch to commit on mouse up and what to show now.
struct DragPlan: Equatable {
    var batch: EditBatch?
    /// The time the drag snapped to, for drawing the snap line.
    var snappedTo: Time?
    /// How far the drag has gone, shown by the pointer ("+00:00:12").
    var delta: Time
    /// The track a move lands on, when it changes track.
    var destinationTrackID: String?
}

/// Turns a drag into an edit batch, with snapping and limits. The timeline
/// view previews the batch on a copy of the project while the mouse moves
/// and commits it once on mouse up.
enum DragPlanner {
    static func plan(_ kind: DragKind, pointer: DragPointer, context: DragContext) -> DragPlan {
        let project = context.project
        let rate = project.settings.frameRate
        let raw = Time(seconds: Double(pointer.deltaX) / context.scale.pixelsPerSecond).roundedToFrame(rate)
        let snapping = context.snapping != pointer.invertSnap
        let tolerance = context.scale.duration(forPixels: Theme.Metrics.snapDistance)
        let targets = snapping ? SnapTargets.collect(
            in: project, excluding: kind.movingClipIDs(in: project),
            playhead: context.playhead, inPoint: context.inPoint, outPoint: context.outPoint
        ) : SnapTargets([])

        switch kind {
        case .move(let ids, let anchorID):
            let clips = ids.compactMap { project.clip($0) }
            guard let earliest = clips.map(\.start).min(), let latest = clips.map(\.end).max() else {
                return DragPlan(batch: nil, snappedTo: nil, delta: .zero)
            }
            var delta = raw
            var snapped: Time?
            if let hit = targets.snappedDelta(delta, edges: [earliest, latest], within: tolerance) {
                delta = hit.delta
                snapped = hit.target
            }
            if earliest + delta < .zero {
                delta = -earliest
                snapped = nil
            }
            var destination: String?
            if let anchorTrack = project.track(containingClip: anchorID),
               Set(clips.compactMap { project.track(containingClip: $0.id)?.id }).count == 1,
               let lane = context.layout.nearestTrackLane(toY: pointer.y, kind: anchorTrack.kind),
               let trackID = lane.trackID, trackID != anchorTrack.id,
               project.track(trackID)?.locked == false {
                destination = trackID
            }
            let batch = TimelineEdits.move(project, clipIDs: ids, delta: delta, toTrackID: destination, insert: pointer.insert)
            return DragPlan(batch: batch, snappedTo: snapped, delta: delta, destinationTrackID: destination)

        case .trim(let id, let edge, let ripple, let includeLinked):
            guard let clip = project.clip(id) else { return DragPlan(batch: nil, snappedTo: nil, delta: .zero) }
            let original = edge == .start ? clip.start : clip.end
            var target = original + raw
            var snapped: Time?
            if let hit = targets.nearest(to: target, within: tolerance) {
                target = hit
                snapped = hit
            }
            let limits = trimLimits(project, clip: clip, edge: edge, ripple: ripple, includeLinked: includeLinked)
            let clamped = min(max(target, limits.lowerBound), limits.upperBound)
            if clamped != target { snapped = nil }
            let batch = TimelineEdits.trim(project, clipID: id, edge: edge, to: clamped, ripple: ripple, includeLinked: includeLinked)
            return DragPlan(batch: batch, snappedTo: snapped, delta: clamped - original)

        case .roll(let leftID, let rightID):
            guard let left = project.clip(leftID), let right = project.clip(rightID) else { return DragPlan(batch: nil, snappedTo: nil, delta: .zero) }
            var cut = left.end + raw
            var snapped: Time?
            if let hit = targets.nearest(to: cut, within: tolerance) {
                cut = hit
                snapped = hit
            }
            let limits = rollLimits(project, left: left, right: right)
            let clamped = min(max(cut, limits.lowerBound), limits.upperBound)
            if clamped != cut { snapped = nil }
            let delta = clamped - left.end
            return DragPlan(batch: TimelineEdits.roll(leftClipID: leftID, rightClipID: rightID, delta: delta), snappedTo: snapped, delta: delta)

        case .slip(let id, let includeLinked):
            guard let clip = project.clip(id) else { return DragPlan(batch: nil, snappedTo: nil, delta: .zero) }
            let limits = slipLimits(project, clip: clip, includeLinked: includeLinked)
            let delta = min(max(raw, limits.lowerBound), limits.upperBound)
            return DragPlan(batch: TimelineEdits.slip(project, clipID: id, timelineDelta: delta, includeLinked: includeLinked), snappedTo: nil, delta: delta)

        case .slide(let id):
            guard let clip = project.clip(id) else { return DragPlan(batch: nil, snappedTo: nil, delta: .zero) }
            var delta = raw
            var snapped: Time?
            if let hit = targets.snappedDelta(delta, edges: [clip.start, clip.end], within: tolerance) {
                delta = hit.delta
                snapped = hit.target
            }
            let limits = slideLimits(project, clip: clip)
            let clamped = min(max(delta, limits.lowerBound), limits.upperBound)
            if clamped != delta { snapped = nil }
            return DragPlan(batch: TimelineEdits.slide(clipID: id, delta: clamped), snappedTo: snapped, delta: clamped)
        }
    }

    // MARK: - Limits
    //
    // Clamping to what the edit can actually do keeps the preview glued to
    // the pointer's side of the limit instead of refusing the whole drag.

    /// How much media a clip has left before and after what it shows, in
    /// timeline time. Unlimited for text, solids and stills.
    static func handles(_ project: Project, clip: Clip) -> (head: Time?, tail: Time?) {
        guard clip.mediaID != nil, !clip.freezeFrame else { return (nil, nil) }
        let head = Time(seconds: max(0, clip.sourceStart.seconds) / clip.speed)
        guard let limit = project.sourceLimit(for: clip) else { return (head, nil) }
        let tail = Time(seconds: max(0, (limit - clip.sourceEnd).seconds) / clip.speed)
        return (head, tail)
    }

    /// Where a trimmed edge may go, across the clip and its linked partners.
    static func trimLimits(_ project: Project, clip: Clip, edge: ClipEdge, ripple: Bool, includeLinked: Bool) -> ClosedRange<Time> {
        let frame = project.settings.frameRate.frameDuration
        let far = Time(seconds: 24 * 3_600)
        var lower = Time(flicks: Int64.min / 4)
        var upper = Time(flicks: Int64.max / 4)
        let delta0 = edge == .start ? clip.start : clip.end
        let ids = includeLinked ? project.linkedClipIDs(of: clip.id) : [clip.id]
        for id in ids {
            guard let member = project.clip(id), let track = project.track(containingClip: id) else { continue }
            // Express each member's limits as a delta, then map back onto
            // the primary clip's edge.
            let (head, tail) = handles(project, clip: member)
            var minDelta = -far
            var maxDelta = far
            switch (edge, ripple) {
            case (.start, false):
                minDelta = -(head ?? far)
                let previousEnd = track.clips.filter { $0.id != member.id && $0.end <= member.start }.map(\.end).max() ?? .zero
                minDelta = max(minDelta, previousEnd - member.start)
                maxDelta = member.duration - frame
            case (.start, true):
                minDelta = -(head ?? far)
                maxDelta = member.duration - frame
            case (.end, false):
                minDelta = -(member.duration - frame)
                maxDelta = tail ?? far
                if let nextStart = track.clips.filter({ $0.id != member.id && $0.start >= member.end }).map(\.start).min() {
                    maxDelta = min(maxDelta, nextStart - member.end)
                }
            case (.end, true):
                minDelta = -(member.duration - frame)
                maxDelta = tail ?? far
            }
            lower = max(lower, delta0 + minDelta)
            upper = min(upper, delta0 + maxDelta)
        }
        if edge == .start && !ripple { lower = max(lower, .zero) }
        if upper < lower { return delta0...delta0 }
        return lower...upper
    }

    /// Where a rolled cut may go.
    static func rollLimits(_ project: Project, left: Clip, right: Clip) -> ClosedRange<Time> {
        let frame = project.settings.frameRate.frameDuration
        let cut = left.end
        var lower = left.start + frame
        var upper = right.end - frame
        let (_, leftTail) = handles(project, clip: left)
        let (rightHead, _) = handles(project, clip: right)
        if let leftTail { upper = min(upper, cut + leftTail) }
        if let rightHead { lower = max(lower, cut - rightHead) }
        if upper < lower { return cut...cut }
        return lower...upper
    }

    /// How far (in timeline time) a clip can slip each way.
    static func slipLimits(_ project: Project, clip: Clip, includeLinked: Bool) -> ClosedRange<Time> {
        var lower = Time(seconds: -24 * 3_600)
        var upper = Time(seconds: 24 * 3_600)
        for id in includeLinked ? project.linkedClipIDs(of: clip.id) : [clip.id] {
            guard let member = project.clip(id) else { continue }
            let (head, tail) = handles(project, clip: member)
            // Dragging right reveals earlier media, so it spends the head.
            if let head { upper = min(upper, head) }
            if let tail { lower = max(lower, -tail) }
        }
        if upper < lower { return .zero ... .zero }
        return lower...upper
    }

    /// How far a clip can slide before a neighbour runs out of room or media.
    static func slideLimits(_ project: Project, clip: Clip) -> ClosedRange<Time> {
        let frame = project.settings.frameRate.frameDuration
        var lower = -clip.start
        var upper = Time(seconds: 24 * 3_600)
        for id in project.linkedClipIDs(of: clip.id) {
            guard let member = project.clip(id), let track = project.track(containingClip: id) else { continue }
            lower = max(lower, -member.start)
            if let previous = track.clip(endingAt: member.start, excluding: member.id) {
                lower = max(lower, -(previous.duration - frame))
                if let tail = handles(project, clip: previous).tail { upper = min(upper, tail) }
            } else if let previousEnd = track.clips.filter({ $0.end <= member.start && $0.id != member.id }).map(\.end).max() {
                lower = max(lower, previousEnd - member.start)
            }
            if let next = track.clip(startingAt: member.end, excluding: member.id) {
                upper = min(upper, next.duration - frame)
                if let head = handles(project, clip: next).head { lower = max(lower, -head) }
            } else if let nextStart = track.clips.filter({ $0.start >= member.end && $0.id != member.id }).map(\.start).min() {
                upper = min(upper, nextStart - member.end)
            }
        }
        if upper < lower { return .zero ... .zero }
        return lower...upper
    }
}

/// Applies a batch to a copy of the project for drag previews, without the
/// coordinator. Returns nil when the batch wouldn't apply.
enum EditPreview {
    static func apply(_ batch: EditBatch, to project: Project) -> Project? {
        var working = project
        var context = EditContext(seed: 1)
        do {
            for command in batch.commands {
                try Editing.apply(command, to: &working, context: &context)
            }
            return working
        } catch {
            return nil
        }
    }
}
