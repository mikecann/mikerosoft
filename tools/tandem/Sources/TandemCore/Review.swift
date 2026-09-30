import Foundation

/// Who made an edit. Mike's edits in the app are credited to "user",
/// Tandem's own (new media found in the folder, a reload) to "system", and
/// anything else is an agent or a command line tool, whose edits wait in
/// the review log until he's looked at them.
public enum EditAuthor {
    public static let person = "user"
    public static let system = "system"

    /// Old files and journals can have an empty author, which was Mike too.
    public static func isPerson(_ author: String) -> Bool {
        author == person || author.isEmpty
    }

    public static func isAgent(_ author: String) -> Bool {
        !isPerson(author) && author != system
    }
}

/// A place an agent took something out: a stretch of the take cut by a
/// ripple delete, a clip lifted or deleted, a transition removed. There's
/// no clip left to highlight, so the timeline marks the join, pinned to
/// the clip after it so the mark moves when that clip does.
public struct ReviewRemoval: Codable, Equatable, Sendable {
    public var trackID: String
    /// Where the join was when it was recorded, for when the clip it's
    /// pinned to has gone as well.
    public var time: Time
    /// How much was taken out.
    public var duration: Time
    /// The clip the mark stays with: the one after the join, or the one
    /// before it when nothing follows.
    public var anchorClipID: String?
    /// The anchor's start for the clip after the join, its end for the one
    /// before.
    public var anchorEdge: ClipEdge?
    /// From that edge to the mark. Zero at a ripple delete's join; the
    /// width of the gap before the next clip for a lift.
    public var offset: Time
    /// The clips (or transition) it took from, so an undo that puts them
    /// back can be told apart from later edits.
    public var from: [String]

    public init(trackID: String, time: Time, duration: Time, anchorClipID: String? = nil, anchorEdge: ClipEdge? = nil, offset: Time = .zero, from: [String]) {
        self.trackID = trackID
        self.time = time
        self.duration = duration
        self.anchorClipID = anchorClipID
        self.anchorEdge = anchorEdge
        self.offset = offset
        self.from = from
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try c.decode(String.self, forKey: .trackID)
        time = try c.decode(.time, or: .zero)
        duration = try c.decode(.duration, or: .zero)
        anchorClipID = try c.decodeIfPresent(String.self, forKey: .anchorClipID)
        anchorEdge = try c.decodeIfPresent(ClipEdge.self, forKey: .anchorEdge)
        offset = try c.decode(.offset, or: .zero)
        from = try c.decode(.from, or: [])
    }

    /// Where the mark is in `project`: beside its anchor wherever that has
    /// moved, or where it was recorded when the anchor's gone.
    public func time(in project: Project) -> Time {
        guard let anchorClipID, let clip = project.clip(anchorClipID) else { return time }
        return (anchorEdge == .end ? clip.end : clip.start) + offset
    }
}

/// One agent batch waiting for Mike's review: who, what and when, and the
/// clips it touched by ID, so the highlight follows them through later
/// moves and ripples.
public struct ReviewEntry: Codable, Equatable, Identifiable, Sendable {
    /// The revision the batch made. Revisions only go up, so it names the
    /// batch within the project.
    public var revision: Int
    public var label: String
    public var author: String
    public var date: Date
    public var added: [String]
    public var changed: [String]
    public var transitions: [String]
    public var removals: [ReviewRemoval]
    /// Fingerprints of the changed clips and transitions, and of what the
    /// removals took from, as they were before the batch (`ReviewDiff`).
    public var before: [String: String]

    public var id: Int { revision }

    public init(revision: Int, label: String, author: String, date: Date, changes: ReviewChanges) {
        self.revision = revision
        self.label = label
        self.author = author
        self.date = date
        added = changes.added
        changed = changes.changed
        transitions = changes.transitions
        removals = changes.removals
        before = changes.before
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(.revision, or: 0)
        label = try c.decode(.label, or: "Edit")
        author = try c.decode(.author, or: "agent")
        date = try c.decode(.date, or: Date(timeIntervalSince1970: 0))
        added = try c.decode(.added, or: [])
        changed = try c.decode(.changed, or: [])
        transitions = try c.decode(.transitions, or: [])
        removals = try c.decode(.removals, or: [])
        before = try c.decode(.before, or: [:])
    }

    /// Nothing left to show: its clips are gone or were put back.
    public var isEmpty: Bool {
        added.isEmpty && changed.isEmpty && transitions.isEmpty && removals.isEmpty
    }

    /// The clips it highlights.
    public var clipIDs: [String] { added + changed }
}

/// The agent edits Mike hasn't reviewed yet, kept in
/// `.tandem/<name>.review.json` beside the journal so it survives
/// restarts. `ReviewRecorder` keeps it as edits commit; Mark reviewed in
/// the app clears it.
public struct ReviewLog: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Oldest first.
    public var entries: [ReviewEntry]

    public init(entries: [ReviewEntry] = []) {
        version = Self.currentVersion
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(.version, or: Self.currentVersion)
        entries = try c.decode(.entries, or: [])
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Records a batch if an agent made it and it changed the timeline.
    /// Mike's own edits (and Tandem's) never are. A batch already here (the
    /// journal replaying one the log heard before a crash) isn't recorded
    /// twice.
    @discardableResult
    public mutating func record(label: String, author: String, revision: Int, date: Date = Date(), before: Project, after: Project) -> Bool {
        guard EditAuthor.isAgent(author) else { return false }
        guard !entries.contains(where: { $0.revision == revision && $0.label == label && $0.author == author }) else { return false }
        let changes = ReviewDiff.between(before, after)
        guard !changes.isEmpty else { return false }
        // Whole seconds, so the log reads back exactly as it was written.
        let second = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        entries.append(ReviewEntry(revision: revision, label: label, author: author, date: second, changes: changes))
        return true
    }

    /// Carries the highlights through an edit, whoever made it: both
    /// halves of a highlighted clip that was cut in two stay highlighted,
    /// a highlighted clip put back unchanged with a new ID (an agent
    /// rebuilding a track) stays highlighted, and a removal whose anchor
    /// went is pinned again where its join is now.
    @discardableResult
    public mutating func follow(from before: Project, to after: Project) -> Bool {
        guard !entries.isEmpty else { return false }
        let remaining = Set(after.allTracks.flatMap { $0.clips.map(\.id) })
        let beforeIDs = Set(before.allTracks.flatMap { $0.clips.map(\.id) })
        // Nothing new and nothing highlighted or pinned gone: nothing to carry.
        let tracked = Set(entries.flatMap(\.clipIDs))
        let anchors = Set(entries.flatMap { $0.removals.compactMap(\.anchorClipID) })
        guard !remaining.subtracting(beforeIDs).isEmpty || !tracked.union(anchors).isSubset(of: remaining) else { return false }
        let c = ReviewDiff.Correspondence(before, after)
        var changed = false
        // New clips that carry on a highlighted one: its right half, or it
        // put back the same.
        var successors: [(new: String, old: String)] = c.pieces.map { ($0.key, $0.value) } + c.replacements.map { ($0.key, $0.value) }
        successors = successors.filter { tracked.contains($0.old) }.sorted { $0.new < $1.new }
        for (successor, original) in successors {
            for index in entries.indices {
                if entries[index].added.contains(original), !entries[index].added.contains(successor) {
                    entries[index].added.append(successor)
                    changed = true
                }
                if entries[index].changed.contains(original), !entries[index].changed.contains(successor) {
                    entries[index].changed.append(successor)
                    changed = true
                }
            }
        }
        for index in entries.indices {
            for slot in entries[index].removals.indices {
                let removal = entries[index].removals[slot]
                guard let anchor = removal.anchorClipID, !remaining.contains(anchor) else { continue }
                var moved = removal
                moved.time = c.map.start(removal.time(in: before))
                entries[index].removals[slot] = ReviewDiff.pinned(moved, in: after)
                changed = true
            }
        }
        return changed
    }

    /// Drops what's no longer on the timeline to review: clips and
    /// transitions that have gone. After an undo or a reload (`reverts`)
    /// it also drops changes whose clips are back as they were before the
    /// agent's batch, and removals whose clips came back, which is what
    /// undoing the batch does. Entries with nothing left go.
    @discardableResult
    public mutating func prune(in project: Project, reverts: Bool) -> Bool {
        guard !entries.isEmpty else { return false }
        let objects = ReviewFingerprint.Objects(project)
        var changed = false
        for index in entries.indices.reversed() {
            var entry = entries[index]
            let fingerprints = entry.before
            func putBack(_ id: String) -> Bool {
                guard reverts, let was = fingerprints[id] else { return false }
                return objects.fingerprint(id) == was
            }
            entry.added.removeAll { !objects.hasClip($0) }
            entry.changed.removeAll { !objects.hasClip($0) || putBack($0) }
            entry.transitions.removeAll { !objects.hasTransition($0) || putBack($0) }
            if reverts {
                entry.removals.removeAll { !$0.from.isEmpty && $0.from.allSatisfy(putBack) }
            }
            let referenced = Set(entry.changed + entry.transitions + entry.removals.flatMap(\.from))
            entry.before = entry.before.filter { referenced.contains($0.key) }
            if entry.isEmpty {
                entries.remove(at: index)
                changed = true
            } else if entry != entries[index] {
                entries[index] = entry
                changed = true
            }
        }
        return changed
    }
}

// MARK: - Reading and writing

extension ReviewLog {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The log at `url`, or an empty one when there's none or it can't be
    /// read: a broken review log mustn't stop a project opening.
    public static func load(from url: URL) -> ReviewLog {
        guard let data = try? Data(contentsOf: url), let log = try? decoder().decode(ReviewLog.self, from: data) else { return ReviewLog() }
        return log
    }

    /// Writes the log atomically, or removes the file once nothing waits.
    public func save(to url: URL) throws {
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder().encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - What a batch did

/// What one batch did to the timeline, clip by clip.
public struct ReviewChanges: Equatable, Sendable {
    /// Clips it put on the timeline.
    public var added: [String] = []
    /// Clips whose content changed, or whose timing did beyond riding
    /// along with a ripple.
    public var changed: [String] = []
    /// Transitions it added or changed.
    public var transitions: [String] = []
    /// Places it took something out.
    public var removals: [ReviewRemoval] = []
    /// Fingerprints of the changed clips and transitions, and of what the
    /// removals took from, as they were before.
    public var before: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool {
        added.isEmpty && changed.isEmpty && transitions.isEmpty && removals.isEmpty
    }
}

/// Works out what a batch did by comparing the project before and after
/// it, clip by clip.
///
/// The hard part is telling an edit from its side effects. A ripple delete
/// in the take moves every clip after it, cuts the take clip it runs
/// through in two (the right half gets a new ID) and shortens a music bed
/// over it; none of that is news, only the join is. So:
///
/// - A new clip that carries on the media of a clip that's still there,
///   with the same settings, is that clip's other half, not an addition.
/// - The take (the `cut` tracks) is what everything else is placed
///   against. Its surviving media gives a map from old times to new ones,
///   and a clip off the take that moved exactly as the take around it did
///   rode along with a ripple. One that moved any other way was moved.
/// - Media the take lost is a removal at the join, where the map puts it.
/// - An agent that rebuilds a track puts most clips back as they were with
///   new IDs. One put back the same, where it was, is the same clip.
public enum ReviewDiff {
    /// Differences smaller than this are rounding, not edits.
    static let tolerance = Time(seconds: 0.002)

    struct Placed {
        var clip: Clip
        var trackID: String
    }

    struct PlacedTransition {
        var transition: Transition
        var trackID: String
    }

    /// A stretch of take media that went, in the old timeline's time.
    struct TakeCut {
        var trackID: String
        var range: TimeRange
        var clipID: String
    }

    /// How the clips and transitions before an edit correspond to the ones
    /// after it.
    struct Correspondence {
        let old: [String: Placed]
        let new: [String: Placed]
        /// The `cut` tracks, before the edit.
        let take: Set<String>
        /// New clip ID to the clip it's the right half of.
        let pieces: [String: String]
        /// Clip ID to the right halves it was cut into.
        let families: [String: [Clip]]
        let map: ReviewTimeMap
        let takeCuts: [TakeCut]
        /// New clip ID to the clip it was put back in place of, the same.
        let replacements: [String: String]
        let oldTransitions: [String: PlacedTransition]
        let newTransitions: [String: PlacedTransition]
        /// New transition ID to the one it was put back in place of.
        let transitionReplacements: [String: String]

        init(_ before: Project, _ after: Project) {
            let old = ReviewDiff.index(before)
            let new = ReviewDiff.index(after)
            let take = Set(before.allTracks.filter { $0.rippleMode == .cut }.map(\.id))
            var pieces: [String: String] = [:]
            for track in after.allTracks {
                guard let oldTrack = before.track(track.id) else { continue }
                for clip in track.clips where old[clip.id] == nil {
                    if let original = ReviewDiff.original(ofPiece: clip, among: oldTrack.clips, new: new) { pieces[clip.id] = original }
                }
            }
            var families: [String: [Clip]] = [:]
            for (pieceID, originalID) in pieces.sorted(by: { $0.key < $1.key }) {
                if let piece = new[pieceID] { families[originalID, default: []].append(piece.clip) }
            }
            let (map, cuts) = ReviewDiff.timeMap(before: before, take: take, new: new, families: families)

            // Clips that went and clips that came, paired where one was put
            // back as the other was, where it was.
            var gone: [String: [Placed]] = [:]
            for (id, was) in old where new[id] == nil && families[id] == nil { gone[was.trackID, default: []].append(was) }
            var replacements: [String: String] = [:]
            if !gone.isEmpty {
                let fresh = new.values.filter { old[$0.clip.id] == nil && pieces[$0.clip.id] == nil }.sorted { ($0.clip.start, $0.clip.id) < ($1.clip.start, $1.clip.id) }
                for now in fresh {
                    guard let candidates = gone[now.trackID],
                          let match = candidates.firstIndex(where: { ReviewDiff.same($0.clip, now.clip, map: map) }) else { continue }
                    replacements[now.clip.id] = candidates[match].clip.id
                    gone[now.trackID]?.remove(at: match)
                }
            }
            let replaced = Set(replacements.values)

            let oldTransitions = ReviewDiff.transitions(in: before)
            let newTransitions = ReviewDiff.transitions(in: after)
            var transitionReplacements: [String: String] = [:]
            var goneTransitions = oldTransitions.filter { newTransitions[$0.key] == nil }
            if !goneTransitions.isEmpty {
                for (id, now) in newTransitions.sorted(by: { $0.key < $1.key }) where oldTransitions[id] == nil {
                    guard let cut = ReviewDiff.cutTime(of: now.transition, in: after) else { continue }
                    let match = goneTransitions.sorted { $0.key < $1.key }.first { _, was in
                        was.trackID == now.trackID && ReviewDiff.looksSame(was.transition, now.transition)
                            && ReviewDiff.cutTime(of: was.transition, in: before).map { ReviewDiff.near(map.start($0), cut) } == true
                    }
                    guard let match else { continue }
                    transitionReplacements[id] = match.key
                    goneTransitions.removeValue(forKey: match.key)
                }
            }

            self.old = old
            self.new = new
            self.take = take
            self.pieces = pieces
            self.families = families
            self.map = map
            self.takeCuts = cuts.filter { !replaced.contains($0.clipID) }
            self.replacements = replacements
            self.oldTransitions = oldTransitions
            self.newTransitions = newTransitions
            self.transitionReplacements = transitionReplacements
        }
    }

    public static func between(_ before: Project, _ after: Project) -> ReviewChanges {
        let c = Correspondence(before, after)
        let (old, new, map) = (c.old, c.new, c.map)
        let replaced = Set(c.replacements.values)

        var changed = Set<String>()
        for (id, was) in old {
            guard let now = new[id] else { continue }
            if isChanged(was, now, pieces: c.families[id] ?? [], isTake: c.take.contains(was.trackID), map: map) {
                changed.insert(id)
            }
        }
        // Halves of a clip off the take that didn't stay with their media.
        for (originalID, list) in c.families {
            guard let original = old[originalID], !c.take.contains(original.trackID) else { continue }
            for piece in list where !stayed(piece, from: original.clip, map: map) { changed.insert(piece.id) }
        }
        // A new look on a file changes every clip of it.
        let relooked = Set(after.media.filter { item in before.media(item.id).map { $0.look != item.look } ?? false }.map(\.id))
        if !relooked.isEmpty {
            for (id, now) in new where (old[id] != nil || c.replacements[id] != nil) && now.clip.mediaID.map(relooked.contains) == true {
                changed.insert(id)
            }
        }
        let added = Set(new.keys.filter { old[$0] == nil && c.pieces[$0] == nil && c.replacements[$0] == nil })

        var changes = ReviewChanges()
        func position(_ id: String) -> (Time, String) { (new[id]?.clip.start ?? .zero, id) }
        changes.added = added.sorted { position($0) < position($1) }
        changes.changed = changed.sorted { position($0) < position($1) }
        let beforeObjects = ReviewFingerprint.Objects(before)
        for id in changes.changed where old[id] != nil {
            changes.before[id] = beforeObjects.fingerprint(id)
        }

        // Transitions added or changed. Their clip IDs change when a clip is
        // cut, so only what they look like counts.
        var transitionIDs: [String] = []
        for (id, now) in c.newTransitions where c.transitionReplacements[id] == nil {
            guard let was = c.oldTransitions[id] else {
                transitionIDs.append(id)
                continue
            }
            if !looksSame(was.transition, now.transition) {
                transitionIDs.append(id)
                changes.before[id] = beforeObjects.fingerprint(id)
            }
        }
        changes.transitions = transitionIDs.sorted()

        // Removals: what the take lost, clips off the take that went, and
        // transitions that went.
        var removals: [ReviewRemoval] = c.takeCuts.map {
            ReviewRemoval(trackID: $0.trackID, time: map.start($0.range.start), duration: $0.range.duration, from: [$0.clipID])
        }
        for (id, was) in old where new[id] == nil && c.families[id] == nil && !c.take.contains(was.trackID) && !replaced.contains(id) {
            removals.append(ReviewRemoval(trackID: was.trackID, time: map.start(was.clip.start), duration: was.clip.duration, from: [id]))
        }
        let replacedTransitions = Set(c.transitionReplacements.values)
        for (id, was) in c.oldTransitions where c.newTransitions[id] == nil && !replacedTransitions.contains(id) {
            guard let cut = cutTime(of: was.transition, in: before) else { continue }
            removals.append(ReviewRemoval(trackID: was.trackID, time: map.start(cut), duration: .zero, from: [id]))
        }
        removals = merged(removals)
        // Something new starting where something went replaced it; the new
        // clip's highlight says so.
        let addedByTrack = Dictionary(grouping: added.compactMap { new[$0] }, by: \.trackID)
        removals.removeAll { removal in
            addedByTrack[removal.trackID]?.contains { $0.clip.start - tolerance <= removal.time && removal.time < $0.clip.end - tolerance } ?? false
        }
        changes.removals = removals.map { pinned($0, in: after) }.sorted { ($0.time, $0.trackID) < ($1.time, $1.trackID) }
        for removal in changes.removals {
            for id in removal.from where changes.before[id] == nil {
                changes.before[id] = beforeObjects.fingerprint(id)
            }
        }
        return changes
    }

    // MARK: Pieces

    static func index(_ project: Project) -> [String: Placed] {
        var result: [String: Placed] = [:]
        for track in project.allTracks {
            for clip in track.clips { result[clip.id] = Placed(clip: clip, trackID: track.id) }
        }
        return result
    }

    /// The clip `piece` was cut from: one on the same track, still there,
    /// with the same settings, whose media carries on into the piece.
    private static func original(ofPiece piece: Clip, among candidates: [Clip], new: [String: Placed]) -> String? {
        let shape = splitSignature(piece)
        for was in candidates {
            guard let survivor = new[was.id]?.clip, piece.start >= survivor.start else { continue }
            guard splitSignature(was) == shape || splitSignature(survivor) == shape else { continue }
            if was.freezeFrame {
                if near(piece.sourceStart, was.sourceStart) { return was.id }
                continue
            }
            if piece.sourceStart >= survivor.sourceEnd - tolerance, piece.sourceEnd <= was.sourceEnd + tolerance {
                return was.id
            }
        }
        return nil
    }

    /// Whether `now` is `was` put back unchanged, where the edit moved its
    /// time to.
    private static func same(_ was: Clip, _ now: Clip, map: ReviewTimeMap) -> Bool {
        // The cheap tests first: a rebuilt track pairs dozens of clips.
        near(now.duration, was.duration) && near(now.sourceStart, was.sourceStart) && now.content == was.content
            && near(now.start, map.start(was.start))
            && signature(was) == signature(now) && was.keyframes == now.keyframes
            && was.audio?.fadeIn ?? .zero == now.audio?.fadeIn ?? .zero && was.audio?.fadeOut ?? .zero == now.audio?.fadeOut ?? .zero
    }

    // MARK: The take

    /// The map from the take's surviving media, and the take media that
    /// went.
    private static func timeMap(before: Project, take: Set<String>, new: [String: Placed], families: [String: [Clip]]) -> (ReviewTimeMap, [TakeCut]) {
        var segments: [ReviewTimeMap.Segment] = []
        var cuts: [TakeCut] = []
        for track in before.allTracks where take.contains(track.id) {
            for was in track.clips {
                var family = families[was.id] ?? []
                if let survivor = new[was.id], survivor.trackID == track.id { family.append(survivor.clip) }
                // A clip still where it was hasn't moved the time around it,
                // whatever it shows now (a slip): the rest stays put too.
                if family.count == 1, let survivor = family.first, survivor.id == was.id,
                   near(survivor.start, was.start), near(survivor.duration, was.duration) {
                    segments.append(ReviewTimeMap.Segment(oldStart: was.start, oldEnd: was.end, newStart: survivor.start, newEnd: survivor.end))
                    continue
                }
                // A still frame has no media to follow; its own clip is all.
                if was.freezeFrame || was.speed <= 0 || was.sourceDuration <= tolerance {
                    if let survivor = family.first(where: { $0.id == was.id }) {
                        segments.append(ReviewTimeMap.Segment(oldStart: was.start, oldEnd: was.end, newStart: survivor.start, newEnd: survivor.end))
                    } else if family.isEmpty {
                        cuts.append(TakeCut(trackID: track.id, range: was.range, clipID: was.id))
                    }
                    continue
                }
                var kept: [(Time, Time)] = []
                for member in family where !member.freezeFrame && member.speed > 0 {
                    let lower = max(was.sourceStart, member.sourceStart)
                    let upper = min(was.sourceEnd, member.sourceEnd)
                    guard upper > lower else { continue }
                    kept.append((lower, upper))
                    segments.append(ReviewTimeMap.Segment(
                        oldStart: timelineTime(ofSource: lower, in: was), oldEnd: timelineTime(ofSource: upper, in: was),
                        newStart: timelineTime(ofSource: lower, in: member), newEnd: timelineTime(ofSource: upper, in: member)
                    ))
                }
                // Media only counts as taken out when the clip got shorter:
                // a slip shows other media in the same time, which makes
                // the clip changed rather than leaving a join.
                let playing = family.reduce(Time.zero) { $0 + $1.duration }
                guard playing < was.duration - tolerance else { continue }
                for gap in uncovered(was.sourceStart, was.sourceEnd, kept) where gap.1 - gap.0 > tolerance {
                    let range = TimeRange(start: timelineTime(ofSource: gap.0, in: was), end: timelineTime(ofSource: gap.1, in: was))
                    cuts.append(TakeCut(trackID: track.id, range: range, clipID: was.id))
                }
            }
        }
        return (ReviewTimeMap(segments), cuts)
    }

    /// Where media time `source` plays on the timeline in `clip`.
    static func timelineTime(ofSource source: Time, in clip: Clip) -> Time {
        guard !clip.freezeFrame, clip.speed > 0 else { return clip.start }
        return clip.start + (source - clip.sourceStart).scaled(by: 1 / clip.speed)
    }

    /// The parts of `lower..<upper` that none of `kept` covers.
    private static func uncovered(_ lower: Time, _ upper: Time, _ kept: [(Time, Time)]) -> [(Time, Time)] {
        var gaps: [(Time, Time)] = []
        var cursor = lower
        for (start, end) in kept.sorted(by: { $0.0 < $1.0 }) {
            if start > cursor { gaps.append((cursor, min(start, upper))) }
            cursor = max(cursor, end)
        }
        if cursor < upper { gaps.append((cursor, upper)) }
        return gaps
    }

    // MARK: Changed or not

    private static func isChanged(_ was: Placed, _ now: Placed, pieces: [Clip], isTake: Bool, map: ReviewTimeMap) -> Bool {
        if was.trackID != now.trackID { return true }
        let a = was.clip
        let b = now.clip
        if signature(a) != signature(b) { return true }
        let retimed = a.duration != b.duration || a.sourceStart != b.sourceStart || !pieces.isEmpty
        if !fadesExplained(a, b, retimed: retimed) || !keyframesExplained(a, b, retimed: retimed) { return true }
        if isTake {
            // The take is what everything else is measured against, so its
            // moving is the map itself. New media showing (an end pulled
            // out, a slip) is a change.
            return ([b] + pieces).contains { showsMore(than: a, $0) }
        }
        guard near(b.start, map.start(a.start)), near(b.sourceStart, a.sourceStart) else { return true }
        // The halves of a cut clip are checked on their own.
        guard pieces.isEmpty else { return false }
        // Where a ripple cut the take under it, a clip loses as much from
        // its end; where time opened after its start, it keeps its length.
        return !(near(b.end, map.end(a.end)) || near(b.duration, a.duration))
    }

    private static func showsMore(than original: Clip, _ member: Clip) -> Bool {
        member.sourceStart < original.sourceStart - tolerance || member.sourceEnd > original.sourceEnd + tolerance
    }

    /// Whether the right half of a clip off the take stayed where its
    /// media was, as the take moved.
    private static func stayed(_ piece: Clip, from original: Clip, map: ReviewTimeMap) -> Bool {
        near(piece.start, map.start(timelineTime(ofSource: piece.sourceStart, in: original)))
    }

    /// Everything about a clip but where it is and which part of the media
    /// it plays, and the things edits change as a side effect: fades and
    /// keyframes (checked on their own), the link group, name and tags.
    static func signature(_ clip: Clip) -> Clip {
        var shape = clip
        shape.id = ""
        shape.name = nil
        shape.start = .zero
        shape.duration = .zero
        shape.sourceStart = .zero
        shape.linkGroup = nil
        shape.keyframes = [:]
        shape.tags = []
        if var audio = shape.audio {
            audio.fadeIn = .zero
            audio.fadeOut = .zero
            shape.audio = audio
        }
        return shape
    }

    /// The signature a cut leaves the same on both halves: a cut also
    /// drops the title animations at the cut.
    static func splitSignature(_ clip: Clip) -> Clip {
        var shape = signature(clip)
        if case .text(var text) = shape.content {
            text.animationIn = nil
            text.animationOut = nil
            shape.content = .text(text)
        }
        return shape
    }

    /// Fades a cut or a trim cleared or shortened, which isn't news.
    private static func fadesExplained(_ a: Clip, _ b: Clip, retimed: Bool) -> Bool {
        let old = (a.audio?.fadeIn ?? .zero, a.audio?.fadeOut ?? .zero)
        let new = (b.audio?.fadeIn ?? .zero, b.audio?.fadeOut ?? .zero)
        if old == new { return true }
        guard retimed else { return false }
        func shortened(_ was: Time, _ now: Time) -> Bool { now == was || now == .zero || now == min(was, b.duration) }
        return shortened(old.0, new.0) && shortened(old.1, new.1)
    }

    /// Keyframes a trim or a cut moved with the clip's media and dropped
    /// where the clip no longer reaches: the same keyframes, measured from
    /// the media rather than the clip's start.
    private static func keyframesExplained(_ a: Clip, _ b: Clip, retimed: Bool) -> Bool {
        if a.keyframes == b.keyframes { return true }
        guard retimed else { return false }
        func anchored(_ keyframe: Keyframe, in clip: Clip) -> Time {
            clip.freezeFrame ? clip.start + keyframe.time : clip.sourceStart + keyframe.time.scaled(by: clip.speed)
        }
        for (path, list) in b.keyframes {
            guard let olds = a.keyframes[path] else { return false }
            for keyframe in list {
                let at = anchored(keyframe, in: b)
                let same = olds.contains { near(anchored($0, in: a), at) && $0.value == keyframe.value && $0.interpolation == keyframe.interpolation }
                if !same { return false }
            }
        }
        return true
    }

    // MARK: Transitions and removals

    private static func transitions(in project: Project) -> [String: PlacedTransition] {
        var result: [String: PlacedTransition] = [:]
        for track in project.allTracks {
            for transition in track.transitions { result[transition.id] = PlacedTransition(transition: transition, trackID: track.id) }
        }
        return result
    }

    /// What a transition looks like: its clips don't count, since cutting
    /// one of them hands the transition to its right half.
    private static func looksSame(_ a: Transition, _ b: Transition) -> Bool {
        a.type == b.type && a.direction == b.direction && a.duration == b.duration
    }

    /// The cut a transition sits on, or the head or tail it fades.
    private static func cutTime(of transition: Transition, in project: Project) -> Time? {
        if let from = transition.fromClipID.flatMap(project.clip) { return from.end }
        if let to = transition.toClipID.flatMap(project.clip) { return to.start }
        return nil
    }

    /// One removal per track and place: a ripple delete across two clips
    /// of a track takes from both.
    private static func merged(_ removals: [ReviewRemoval]) -> [ReviewRemoval] {
        var result: [ReviewRemoval] = []
        for removal in removals.sorted(by: { ($0.trackID, $0.time) < ($1.trackID, $1.time) }) {
            if let last = result.last, last.trackID == removal.trackID, near(last.time, removal.time) {
                result[result.count - 1].duration += removal.duration
                result[result.count - 1].from += removal.from.filter { !last.from.contains($0) }
            } else {
                result.append(removal)
            }
        }
        return result
    }

    /// Pins a removal to the clip after its join on its track, or the clip
    /// before it when nothing follows.
    static func pinned(_ removal: ReviewRemoval, in project: Project) -> ReviewRemoval {
        var removal = removal
        removal.anchorClipID = nil
        removal.anchorEdge = nil
        removal.offset = .zero
        guard let track = project.track(removal.trackID) else { return removal }
        let time = removal.time
        if let next = track.clips.first(where: { $0.start >= time - tolerance }) {
            removal.anchorClipID = next.id
            removal.anchorEdge = .start
            removal.offset = time - next.start
        } else if let previous = track.clips.last(where: { $0.end <= time + tolerance }) {
            removal.anchorClipID = previous.id
            removal.anchorEdge = .end
            removal.offset = time - previous.end
        }
        return removal
    }

    static func near(_ a: Time, _ b: Time) -> Bool {
        abs(a.flicks - b.flicks) <= tolerance.flicks
    }
}

/// Where old times land after an edit, from the take's surviving media:
/// each piece of it is a segment from where it played to where it plays
/// now. Between segments, time keeps the shift of the take before it
/// unless that would run past the take after it, which is where a ripple
/// delete collapses the time it removed to the join.
struct ReviewTimeMap {
    struct Segment {
        var oldStart: Time
        var oldEnd: Time
        var newStart: Time
        var newEnd: Time

        func map(_ time: Time) -> Time {
            let oldLength = oldEnd - oldStart
            let newLength = newEnd - newStart
            if oldLength == newLength { return newStart + (time - oldStart) }
            guard oldLength > .zero else { return newStart }
            let fraction = Double((time - oldStart).flicks) / Double(oldLength.flicks)
            return newStart + Time(flicks: Int64((Double(newLength.flicks) * fraction).rounded()))
        }
    }

    let segments: [Segment]

    init(_ segments: [Segment]) {
        // The take's tracks are cut together, so most segments come three
        // times over; one of each is enough.
        var unique: [Segment] = []
        for segment in segments.sorted(by: { ($0.oldStart, $0.newStart, $0.oldEnd) < ($1.oldStart, $1.newStart, $1.oldEnd) }) {
            if let last = unique.last, last.oldStart == segment.oldStart, last.oldEnd == segment.oldEnd,
               last.newStart == segment.newStart, last.newEnd == segment.newEnd { continue }
            unique.append(segment)
        }
        self.segments = unique
    }

    /// Where a clip starting at `time` would start now.
    func start(_ time: Time) -> Time {
        if let segment = segments.first(where: { $0.oldStart <= time && time < $0.oldEnd }) { return segment.map(time) }
        return between(time)
    }

    /// Where a clip ending at `time` would end now: the same, but an end
    /// belongs to the take before it.
    func end(_ time: Time) -> Time {
        if let segment = segments.first(where: { $0.oldStart < time && time <= $0.oldEnd }) { return segment.map(time) }
        return between(time)
    }

    private func between(_ time: Time) -> Time {
        var before: Segment?
        var after: Segment?
        for segment in segments {
            if segment.oldEnd <= time, before.map({ segment.oldEnd > $0.oldEnd }) ?? true { before = segment }
            if segment.oldStart > time, after == nil { after = segment }
        }
        switch (before, after) {
        case let (before?, after?):
            return min(time + (before.newEnd - before.oldEnd), after.newStart)
        case let (before?, nil):
            return time + (before.newEnd - before.oldEnd)
        case let (nil, after?):
            return max(.zero, time + (after.newStart - after.oldStart))
        case (nil, nil):
            return time
        }
    }
}

/// A stable fingerprint of a clip or transition, to recognise one put back
/// exactly as it was. A clip's includes its file's look, which changes how
/// it looks without changing the clip.
enum ReviewFingerprint {
    /// A project's clips and transitions by ID, for fingerprinting several.
    struct Objects {
        private var clips: [String: Clip] = [:]
        private var transitions: [String: Transition] = [:]
        private var looks: [String: [Effect]] = [:]
        private let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return encoder
        }()

        init(_ project: Project) {
            for track in project.allTracks {
                for clip in track.clips { clips[clip.id] = clip }
                for transition in track.transitions { transitions[transition.id] = transition }
            }
            for item in project.media where !item.look.isEmpty { looks[item.id] = item.look }
        }

        func hasClip(_ id: String) -> Bool { clips[id] != nil }
        func hasTransition(_ id: String) -> Bool { transitions[id] != nil }

        func fingerprint(_ id: String) -> String? {
            if let clip = clips[id] {
                guard var data = try? encoder.encode(clip) else { return nil }
                if let look = clip.mediaID.flatMap({ looks[$0] }), let encoded = try? encoder.encode(look) { data.append(encoded) }
                return ReviewFingerprint.hash(data)
            }
            if let transition = transitions[id], let data = try? encoder.encode(transition) {
                return ReviewFingerprint.hash(data)
            }
            return nil
        }
    }

    /// FNV-1a, 64 bits, as hex: stable across launches, unlike `Hasher`.
    static func hash(_ data: Data) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return String(value, radix: 16)
    }
}
