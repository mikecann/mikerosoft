import Foundation

/// Collects side information while a batch runs, and hands out new IDs.
///
/// IDs come from a generator seeded per batch, so replaying a batch from the
/// journal after a crash recreates exactly the same clip IDs.
public struct EditContext: Sendable {
    /// IDs of things the batch created (clips, tracks, transitions,
    /// markers), in creation order.
    public var createdIDs: [String] = []
    /// Things worth telling the user that didn't block the edit.
    public var warnings: [String] = []
    public let seed: UInt64
    private var generator: SplitMix64
    /// When linked clips are split at the same time, their right-hand pieces
    /// join one new link group. Keyed by "<old group>@<flicks>".
    private var splitGroups: [String: String] = [:]

    public init(seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        self.seed = seed
        self.generator = SplitMix64(seed: seed)
    }

    public mutating func makeID(_ prefix: String) -> String {
        IDs.make(prefix, using: &generator)
    }

    mutating func linkGroup(afterSplitting group: String, at time: Time) -> String {
        let key = "\(group)@\(time.flicks)"
        if let existing = splitGroups[key] { return existing }
        let new = makeID("lnk")
        splitGroups[key] = new
        return new
    }

    mutating func warn(_ message: String) {
        if !warnings.contains(message) { warnings.append(message) }
    }
}

// MARK: - Clip edits

extension Clip {
    /// Splits at a timeline time strictly inside the clip. The left part
    /// keeps this clip's ID; the right part gets `rightID`.
    func split(at time: Time, rightID: String) -> (left: Clip, right: Clip)? {
        guard time > start, time < end else { return nil }
        var left = self
        var right = self
        right.id = rightID
        left.moveTail(to: time)
        right.moveHead(to: time)
        if var audio = left.audio {
            audio.fadeOut = .zero
            left.audio = audio
        }
        if var audio = right.audio {
            audio.fadeIn = .zero
            right.audio = audio
        }
        if case .text(var text) = left.content {
            text.animationOut = nil
            left.content = .text(text)
        }
        if case .text(var text) = right.content {
            text.animationIn = nil
            right.content = .text(text)
        }
        return (left, right)
    }

    /// Moves the start edge. The content stays where it is on the timeline,
    /// so the clip shows more or less of the media's beginning.
    mutating func moveHead(to newStart: Time) {
        let delta = newStart - start
        guard delta != .zero else { return }
        start = newStart
        duration -= delta
        if !freezeFrame { sourceStart += delta.scaled(by: speed) }
        keyframes = KeyframeEditing.shifted(keyframes, by: -delta)
        tidy()
    }

    /// Moves the end edge.
    mutating func moveTail(to newEnd: Time) {
        duration = newEnd - start
        tidy()
    }

    /// Head trim for a ripple edit: the clip stays where it starts but its
    /// content begins `delta` later (or earlier when negative).
    mutating func rippleHead(by delta: Time) {
        guard delta != .zero else { return }
        duration -= delta
        if !freezeFrame { sourceStart += delta.scaled(by: speed) }
        keyframes = KeyframeEditing.shifted(keyframes, by: -delta)
        tidy()
    }

    /// Keeps fades and keyframes consistent with the current duration.
    mutating func tidy() {
        if var audio = audio {
            audio.fadeIn = min(audio.fadeIn, duration)
            audio.fadeOut = min(audio.fadeOut, duration)
            self.audio = audio
        }
        if !keyframes.isEmpty {
            keyframes = KeyframeEditing.pruned(keyframes, duration: duration)
        }
    }
}

// MARK: - Track edits

extension Track {
    mutating func sortClips() {
        clips.sort { $0.start < $1.start }
    }

    mutating func add(_ clip: Clip) {
        let index = clips.firstIndex { $0.start > clip.start } ?? clips.endIndex
        clips.insert(clip, at: index)
    }

    /// Splits the clip under `time`. Returns the new right-hand clip's ID.
    @discardableResult
    mutating func split(at time: Time, context: inout EditContext) -> String? {
        guard let i = clips.firstIndex(where: { $0.start < time && time < $0.end }) else { return nil }
        let original = clips[i]
        let rightID = context.makeID("clip")
        guard let parts = original.split(at: time, rightID: rightID) else { return nil }
        var left = parts.left
        var right = parts.right
        if let group = original.linkGroup {
            right.linkGroup = context.linkGroup(afterSplitting: group, at: time)
        }
        left.linkGroup = original.linkGroup
        clips[i] = left
        clips.insert(right, at: i + 1)
        for j in transitions.indices where transitions[j].fromClipID == original.id {
            transitions[j].fromClipID = rightID
        }
        context.createdIDs.append(rightID)
        return rightID
    }

    /// Removes everything inside `range` without moving anything else, like
    /// a lift or an overwrite. Clips crossing the edges are trimmed.
    mutating func clear(_ range: TimeRange, context: inout EditContext) {
        guard !range.isEmpty else { return }
        var result: [Clip] = []
        var removed = Set<String>()
        for clip in clips {
            guard clip.range.overlaps(range) else {
                result.append(clip)
                continue
            }
            let hasLeft = clip.start < range.start
            let hasRight = clip.end > range.end
            if hasLeft {
                var left = clip
                left.moveTail(to: range.start)
                if var audio = left.audio, hasRight {
                    audio.fadeOut = .zero
                    left.audio = audio
                }
                result.append(left)
            }
            if hasRight {
                var right = clip
                right.moveHead(to: range.end)
                if hasLeft {
                    right.id = context.makeID("clip")
                    context.createdIDs.append(right.id)
                    if var audio = right.audio {
                        audio.fadeIn = .zero
                        right.audio = audio
                    }
                    for j in transitions.indices where transitions[j].fromClipID == clip.id {
                        transitions[j].fromClipID = right.id
                    }
                }
                if let group = clip.linkGroup {
                    right.linkGroup = context.linkGroup(afterSplitting: group, at: range.end)
                }
                result.append(right)
            }
            if !hasLeft && !hasRight { removed.insert(clip.id) }
        }
        clips = result
        sortClips()
        removeTransitions(referencing: removed)
    }

    /// Moves every clip that starts at or after `time`.
    mutating func shiftClips(from time: Time, by delta: Time, excluding: Set<String> = []) {
        guard delta != .zero else { return }
        for i in clips.indices where clips[i].start >= time && !excluding.contains(clips[i].id) {
            clips[i].start += delta
        }
        sortClips()
    }

    /// Cuts `range` out and closes the gap.
    mutating func cutOut(_ range: TimeRange, context: inout EditContext) {
        guard !range.isEmpty else { return }
        clear(range, context: &context)
        shiftClips(from: range.end, by: -range.duration)
    }

    /// Follows a removal on another track: clips keep their content from the
    /// head and move with the time around them. A clip spanning the removed
    /// time loses that much from its tail; one entirely inside it is removed.
    mutating func followRemoval(of range: TimeRange, context: inout EditContext) {
        guard !range.isEmpty else { return }
        let a = range.start
        let b = range.end
        func map(_ t: Time) -> Time {
            t <= a ? t : (t < b ? a : t - range.duration)
        }
        var result: [Clip] = []
        var removed = Set<String>()
        for var clip in clips {
            let newStart = map(clip.start)
            let newEnd = map(clip.end)
            if newEnd <= newStart {
                removed.insert(clip.id)
                context.warn("Removed \(clip.name ?? clip.id) from \(name): it sat entirely inside the deleted time.")
                continue
            }
            if newStart != clip.start || newEnd != clip.end {
                clip.start = newStart
                clip.moveTail(to: newEnd)
            }
            result.append(clip)
        }
        clips = result
        sortClips()
        removeTransitions(referencing: removed)
    }

    /// Opens `duration` of empty time at `time`. With `split` a clip under
    /// `time` is cut and its second half moves too; without, it stays whole
    /// and only clips starting later move.
    mutating func openTime(at time: Time, duration: Time, split: Bool, context: inout EditContext) {
        guard duration > .zero else { return }
        if split { self.split(at: time, context: &context) }
        shiftClips(from: time, by: duration)
    }

    mutating func removeTransitions(referencing ids: Set<String>) {
        guard !ids.isEmpty else { return }
        transitions.removeAll { t in
            (t.fromClipID.map(ids.contains) ?? false) || (t.toClipID.map(ids.contains) ?? false)
        }
    }

    /// Drops transitions whose clips are gone or no longer meet.
    mutating func repairTransitions(context: inout EditContext) {
        let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        transitions.removeAll { t in
            let from = t.fromClipID.flatMap { byID[$0] }
            let to = t.toClipID.flatMap { byID[$0] }
            let dangling = (t.fromClipID != nil && from == nil) || (t.toClipID != nil && to == nil)
            if dangling { return true }
            if let from, let to, from.end != to.start {
                context.warn("Removed a \(t.type.rawValue) transition on \(name): its clips no longer meet.")
                return true
            }
            return false
        }
    }
}
