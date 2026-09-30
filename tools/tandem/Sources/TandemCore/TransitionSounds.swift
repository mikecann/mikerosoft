import Foundation

/// A sound effect to play with a transition, as `addTransition` takes it:
/// a media item already in the project, played as a clip of its own on
/// the first free SFX track, so it can be seen, nudged and trimmed like
/// any other sound.
public struct TransitionSound: Codable, Equatable, Sendable {
    public var mediaID: String
    /// Clip gain in dB. Default -15, sound effects' usual.
    public var gainDB: Double?
    /// When the sound starts, in seconds from the middle of the transition
    /// (the cut, for one between two clips), which is where a push or a
    /// wipe moves fastest: -0.39 starts it 0.39 s before, so a whoosh
    /// that's loudest 0.39 s in peaks on the cut. Default: as the
    /// transition starts.
    public var offset: Time?

    public init(mediaID: String, gainDB: Double? = nil, offset: Time? = nil) {
        self.mediaID = mediaID
        self.gainDB = gainDB
        self.offset = offset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaID = try c.decode(String.self, forKey: .mediaID)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB)
        offset = try c.decodeIfPresent(Time.self, forKey: .offset)
    }

    /// Sound effects' usual gain, as placing gives them.
    public static let defaultGainDB = -15.0
}

extension Transition {
    /// When it plays on `track`: centred on the cut between its two clips,
    /// or from its one clip's head or up to its tail (never longer than
    /// that clip). Nil when its clips aren't on `track` or don't meet.
    /// The render, the timeline and the transition's sound all use this.
    public func window(on track: Track) -> TimeRange? {
        guard duration > .zero else { return nil }
        let from = fromClipID.flatMap { id in track.clips.first { $0.id == id } }
        let to = toClipID.flatMap { id in track.clips.first { $0.id == id } }
        switch (from, to) {
        case let (from?, to?):
            guard from.end == to.start else { return nil }
            return TimeRange(start: from.end - Time(flicks: duration.flicks / 2), duration: duration)
        case let (from?, nil):
            let length = min(duration, from.duration)
            return TimeRange(start: from.end - length, duration: length)
        case let (nil, to?):
            return TimeRange(start: to.start, duration: min(duration, to.duration))
        case (nil, nil):
            return nil
        }
    }

    /// The middle of `window(on:)`, where a push or a wipe moves fastest:
    /// the cut itself for a transition between two clips. Its sound keeps
    /// its distance from here, so a swoosh stays on the cut however long
    /// the transition is.
    public func middle(on track: Track) -> Time? {
        guard let window = window(on: track) else { return nil }
        return window.start + Time(flicks: window.duration.flicks / 2)
    }
}

/// Keeps each transition's sound in step with it. The sound is an ordinary
/// clip, so Mike can nudge it, trim it or turn it down, and the transition
/// only holds its ID (`Transition.soundClipID`). After every command:
///
/// - A transition that went, whatever took it (a delete, its clips moved
///   apart or cut away, its track removed), takes its sound with it.
/// - A transition whose middle moved (the cut rolled, the take rippled,
///   its clips moved together, a fade at a clip's head made longer)
///   carries its sound along, as the sound was, so a ripple through the
///   sound doesn't chop it.
/// - A sound deleted or overwritten while its transition stayed put
///   leaves the transition silent.
///
/// Undo needs nothing of its own: it puts back the whole project.
enum TransitionSounds {
    /// A transition with a sound, before a command.
    struct Anchor {
        var middle: Time?
        /// The sound clip as it was, and its track.
        var sound: Clip?
        var soundTrackID: String?
    }

    /// Every transition with a sound, keyed by its ID. Empty (and cheap)
    /// when no transition has one, which is most projects.
    static func anchors(in p: Project) -> [String: Anchor] {
        var result: [String: Anchor] = [:]
        var wanted: [String: String] = [:]
        for track in p.allTracks {
            for transition in track.transitions {
                guard let soundID = transition.soundClipID else { continue }
                wanted[soundID] = transition.id
                result[transition.id] = Anchor(middle: transition.middle(on: track))
            }
        }
        guard !result.isEmpty else { return result }
        for track in p.audioTracks {
            for clip in track.clips {
                guard let transitionID = wanted[clip.id] else { continue }
                result[transitionID]?.sound = clip
                result[transitionID]?.soundTrackID = track.id
            }
        }
        return result
    }

    /// Brings every transition's sound back in step after a command, from
    /// where things were before it (`anchors(in:)`). Works in timeline
    /// order, so a replay of the journal makes the same tracks.
    static func reconcile(_ p: inout Project, from before: [String: Anchor], _ context: inout EditContext) {
        var after: [(transition: Transition, track: TrackLocation)] = []
        var claimed = Set<String>()
        for location in p.trackLocations {
            for transition in p[location].transitions {
                after.append((transition, location))
                if let soundID = transition.soundClipID { claimed.insert(soundID) }
            }
        }
        guard !before.isEmpty || !claimed.isEmpty else { return }

        // Sounds whose transitions went.
        let remaining = Set(after.map(\.transition.id))
        for id in before.keys.sorted() where !remaining.contains(id) {
            guard let sound = before[id]?.sound, !claimed.contains(sound.id), let (location, index) = p.location(ofClip: sound.id) else { continue }
            if p[location].locked {
                context.warn("The sound of a removed transition stays on \"\(p[location].name)\": the track is locked.")
                continue
            }
            p[location].clips.remove(at: index)
        }

        for (transition, location) in after {
            guard let soundID = transition.soundClipID, !context.placedSounds.contains(soundID) else { continue }
            let present = p.location(ofClip: soundID)
            let middle = transition.middle(on: p[location])
            guard let anchor = before[transition.id], let was = anchor.sound, was.id == soundID,
                  let old = anchor.middle, let middle, middle != old else {
                // The transition stayed put (or is new): whatever happened
                // to the sound was done to the sound. Gone means silent.
                if present == nil { untie(transition.id, in: &p) }
                continue
            }
            // The transition moved: its sound goes with it, as it was.
            var moved = was
            moved.start += middle - old
            if let present, p[present.track].clips[present.index] == moved { continue }
            if !place(moved, preferring: present.map { p[$0.track].id } ?? anchor.soundTrackID, in: &p, &context) {
                untie(transition.id, in: &p)
            }
        }
    }

    /// Clears a transition's sound, leaving it silent.
    static func untie(_ transitionID: String, in p: inout Project) {
        guard let (location, index) = p.location(ofTransition: transitionID) else { return }
        p[location].transitions[index].soundClipID = nil
    }

    /// Puts `clip` (a transition's sound, by its ID) where it says: on
    /// `preferring` (the track it's on) when that's free there, else on the
    /// first free SFX track, making one when none is. A sound on a locked
    /// track stays where it is. False when nothing of it is left to place
    /// (it would end before the timeline starts), and the clip is gone.
    @discardableResult
    static func place(_ clip: Clip, preferring trackID: String?, in p: inout Project, _ context: inout EditContext) -> Bool {
        if let (location, index) = p.location(ofClip: clip.id) {
            if p[location].locked {
                context.warn("A transition's sound on \"\(p[location].name)\" didn't move with it: the track is locked.")
                return true
            }
            p[location].clips.remove(at: index)
        }
        var clip = clip
        if clip.start < .zero {
            // Nearer the start than the sound's lead: its head is cut, so
            // what's left still lands where it should.
            guard clip.end > .zero else { return false }
            clip.moveHead(to: .zero)
        }
        if let trackID, let location = p.location(ofTrack: trackID), location.kind == .audio,
           !p[location].locked, p[location].isFree(clip.range) {
            p[location].add(clip)
            return true
        }
        let index = Editing.freeSFXTrack(for: clip.range, in: &p, &context)
        p.audioTracks[index].add(clip)
        return true
    }
}

extension Editing {
    /// The first SFX track ("SFX", "SFX 2"...) that's unlocked and free
    /// over `range`, making the next one when none is, so no sound already
    /// there is cut. An index into `audioTracks`.
    static func freeSFXTrack(for range: TimeRange, in p: inout Project, _ context: inout EditContext) -> Int {
        func isSFX(_ name: String) -> Bool {
            let lower = name.lowercased()
            return lower == "sfx" || (lower.hasPrefix("sfx ") && Int(lower.dropFirst(4)) != nil)
        }
        let candidates = p.audioTracks.indices.filter { isSFX(p.audioTracks[$0].name) }
        if let free = candidates.first(where: { !p.audioTracks[$0].locked && p.audioTracks[$0].isFree(range) }) { return free }
        var id = context.makeID("trk")
        while p.allIDs.contains(id) { id = context.makeID("trk") }
        let name = candidates.isEmpty ? "SFX" : "SFX \(candidates.count + 1)"
        p.audioTracks.append(Track(id: id, kind: .audio, name: name, rippleMode: .follow))
        context.createdIDs.append(id)
        return p.audioTracks.count - 1
    }

    /// Puts a transition's sound on the first free SFX track and ties it
    /// to the transition. Returns the sound clip's ID.
    @discardableResult
    static func addTransitionSound(_ p: inout Project, _ sound: TransitionSound, to transitionID: String, _ context: inout EditContext) throws -> String {
        guard let (location, index) = p.location(ofTransition: transitionID) else { throw EditError.notFound("transition \(transitionID)") }
        let transition = p[location].transitions[index]
        guard let window = transition.window(on: p[location]), let middle = transition.middle(on: p[location]) else {
            throw EditError.invalid("transition \(transitionID) isn't on its clips, so its sound has nowhere to go")
        }
        let item = try soundMedia(sound.mediaID, in: p)
        let clip = Clip(
            id: context.makeID("clip"),
            content: .media(mediaID: item.id),
            start: middle + (sound.offset ?? (window.start - middle)),
            duration: soundLength(item),
            audio: AudioProperties(gainDB: sound.gainDB ?? TransitionSound.defaultGainDB)
        )
        guard TransitionSounds.place(clip, preferring: nil, in: &p, &context) else {
            throw EditError.invalid("the sound would end before the timeline starts; give it a later offset")
        }
        if let placed = p.clip(clip.id) { try checkSource(placed, in: p) }
        guard let (after, position) = p.location(ofTransition: transitionID) else { throw EditError.notFound("transition \(transitionID)") }
        p[after].transitions[position].soundClipID = clip.id
        context.createdIDs.append(clip.id)
        context.placedSounds.insert(clip.id)
        return clip.id
    }

    /// How long a sound plays: its whole file.
    static func soundLength(_ item: MediaItem) -> Time {
        item.duration.flatMap { $0 > .zero ? $0 : nil } ?? Time(seconds: 1)
    }

    /// A sound effect's media: in the project, with sound.
    static func soundMedia(_ mediaID: String, in p: Project) throws -> MediaItem {
        guard let item = p.media(mediaID) else { throw EditError.notFound("media \(mediaID) for the transition's sound") }
        guard item.hasAudio else { throw EditError.invalid("\(item.path) has no sound, so it can't be a transition's sound") }
        return item
    }

    /// A clip already on the timeline given as a new transition's sound
    /// (`soundClipID` in `addTransition`): on an audio track, and not
    /// another transition's.
    static func checkTieable(_ clipID: String, in p: Project) throws {
        guard let (location, _) = p.location(ofClip: clipID) else { throw EditError.notFound("clip \(clipID) for the transition's sound") }
        guard location.kind == .audio else { throw EditError.invalid("clip \(clipID) isn't on an audio track, so it can't be a transition's sound") }
        for track in p.allTracks {
            if let other = track.transitions.first(where: { $0.soundClipID == clipID }) {
                throw EditError.invalid("clip \(clipID) is already the sound of transition \(other.id)")
            }
        }
    }

    /// `sound` in an `updateTransition` patch: `null` removes the sound,
    /// an object changes it (`mediaID` swaps the file, `gainDB` and
    /// `offset` set those), or adds one when there's none (`mediaID` is
    /// needed then). What's left out stays as the sound has it, including
    /// its distance from the transition's middle, which was at
    /// `middleBefore` before the rest of the patch.
    static func patchTransitionSound(_ p: inout Project, _ transitionID: String, _ patch: JSONValue, middleBefore: Time? = nil, _ context: inout EditContext) throws {
        guard let (location, index) = p.location(ofTransition: transitionID) else { throw EditError.notFound("transition \(transitionID)") }
        let transition = p[location].transitions[index]
        let current = transition.soundClipID.flatMap { p.location(ofClip: $0) }
        if case .null = patch {
            guard let current else {
                p[location].transitions[index].soundClipID = nil
                return
            }
            try requireUnlocked(p[current.track])
            p[current.track].clips.remove(at: current.index)
            p[location].transitions[index].soundClipID = nil
            return
        }
        guard case .object(let fields) = patch else {
            throw EditError.invalid("a transition's sound is an object like {\"mediaID\": \"med_x\"}, or null for none")
        }
        for key in fields.keys.sorted() where !["mediaID", "gainDB", "offset"].contains(key) {
            throw EditError.invalid("a transition's sound has mediaID, gainDB and offset, not \"\(key)\"")
        }
        func number(_ key: String) throws -> Double? {
            switch fields[key] {
            case nil, .null?: return nil
            case .number(let value)?: return value
            default: throw EditError.invalid("the sound's \(key) must be a number")
            }
        }
        let mediaID: String?
        switch fields["mediaID"] {
        case nil, .null?: mediaID = nil
        case .string(let id)?: mediaID = id
        default: throw EditError.invalid("the sound's mediaID must be a string")
        }
        let gain = try number("gainDB")
        let offset = try number("offset").map { Time(seconds: $0) }

        guard let current else {
            guard let mediaID else {
                throw EditError.invalid("transition \(transitionID) has no sound yet; give its mediaID")
            }
            try addTransitionSound(&p, TransitionSound(mediaID: mediaID, gainDB: gain, offset: offset), to: transitionID, &context)
            return
        }
        try requireUnlocked(p[current.track])
        guard let middle = transition.middle(on: p[location]) else {
            throw EditError.invalid("transition \(transitionID) isn't on its clips, so its sound has nowhere to go")
        }
        var clip = p[current.track].clips[current.index]
        if let mediaID, mediaID != clip.mediaID {
            // Another file in its place, all of it, where the old one
            // started unless the offset says otherwise.
            let item = try soundMedia(mediaID, in: p)
            clip.content = .media(mediaID: item.id)
            clip.sourceStart = .zero
            clip.speed = 1
            clip.freezeFrame = false
            clip.keyframes = [:]
            clip.duration = soundLength(item)
        }
        if let gain {
            var audio = clip.audio ?? AudioProperties()
            audio.gainDB = gain
            clip.audio = audio
        }
        if let offset {
            clip.start = middle + offset
        } else if let middleBefore {
            clip.start += middle - middleBefore
        }
        clip.tidy()
        guard TransitionSounds.place(clip, preferring: p[current.track].id, in: &p, &context) else {
            throw EditError.invalid("the sound would end before the timeline starts; give it a later offset")
        }
        if let placed = p.clip(clip.id) { try checkSource(placed, in: p) }
        context.placedSounds.insert(clip.id)
    }
}
