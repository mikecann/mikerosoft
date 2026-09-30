import Foundation

/// Applies `EditCommand`s to a project.
///
/// These are plain functions over value types. `ProjectCoordinator` runs a
/// whole batch on a copy of the project and only commits it if every command
/// succeeds and the result validates.
public enum Editing {
    public static func apply(_ command: EditCommand, to project: inout Project, context: inout EditContext) throws {
        // Transitions' sounds are kept in step with them after whatever
        // this command does (`TransitionSounds`).
        let sounds = TransitionSounds.anchors(in: project)
        context.placedSounds = []
        switch command {
        case .updateProject(let patch):
            try updateProject(&project, patch)
        case .updateSettings(let patch):
            try updateSettings(&project, patch, &context)
        case .addTrack(let kind, let name, let index, let id):
            try addTrack(&project, kind: kind, name: name, index: index, id: id, &context)
        case .removeTrack(let trackID):
            try removeTrack(&project, trackID)
        case .moveTrack(let trackID, let index):
            try moveTrack(&project, trackID, index)
        case .updateTrack(let trackID, let patch):
            try updateTrack(&project, trackID, patch)
        case .addMedia(let item):
            try addMedia(&project, item)
        case .updateMedia(let mediaID, let patch):
            try updateMedia(&project, mediaID, patch)
        case .removeMedia(let mediaID):
            try removeMedia(&project, mediaID)
        case .placeMedia(let mediaIDs, let at, let sourceStart, let duration, let mode, let videoTrackID, let audioTrackID, let includeAudio):
            try placeMedia(
                &project, mediaIDs: mediaIDs, at: at, sourceStart: sourceStart, duration: duration,
                mode: mode ?? .place, videoTrackID: videoTrackID, audioTrackID: audioTrackID,
                includeAudio: includeAudio, &context
            )
        case .insertClip(let trackID, let clip, let mode):
            try insertClip(&project, trackID: trackID, clip: clip, mode: mode ?? .place, &context)
        case .removeClips(let clipIDs, let ripple, let includeLinked):
            try removeClips(&project, clipIDs, ripple: ripple ?? false, includeLinked: includeLinked ?? true, &context)
        case .rippleDeleteRange(let range, let trackIDs):
            try rippleDeleteRange(&project, range, trackIDs: trackIDs, &context)
        case .closeGap(let trackID, let at):
            try closeGap(&project, trackID: trackID, at: at, &context)
        case .insertTime(let at, let duration, let trackIDs):
            try insertTime(&project, at: at, duration: duration, trackIDs: trackIDs, &context)
        case .insertTemplate(let template, let at, let values, let mode):
            try insertTemplate(&project, template, at: at, values: values ?? [:], mode: mode ?? .place, &context)
        case .addSectionCards(let markerIDs, let trackID, let duration, let kicker, let mode, let soundIn, let soundOut):
            try addSectionCards(
                &project, markerIDs: markerIDs, trackID: trackID, duration: duration, kicker: kicker,
                mode: mode ?? .overwrite, soundIn: soundIn, soundOut: soundOut, &context
            )
        case .fitSectionCards(let clipIDs):
            try fitSectionCards(&project, clipIDs: clipIDs, &context)
        case .blade(let at, let trackIDs, let clipIDs):
            try blade(&project, at: at, trackIDs: trackIDs, clipIDs: clipIDs, &context)
        case .trim(let clipID, let edge, let to, let ripple, let includeLinked):
            try trim(&project, clipID: clipID, edge: edge, to: to, ripple: ripple ?? false, includeLinked: includeLinked ?? true, &context)
        case .roll(let leftClipID, let rightClipID, let delta):
            try roll(&project, leftClipID, rightClipID, delta: delta, &context)
        case .slip(let clipID, let delta, let includeLinked):
            try slip(&project, clipID, delta: delta, includeLinked: includeLinked ?? true)
        case .slide(let clipID, let delta):
            try slide(&project, clipID, delta: delta, &context)
        case .setSpeed(let clipID, let speed, let ripple, let includeLinked):
            try setSpeed(&project, clipID, speed: speed, ripple: ripple ?? false, includeLinked: includeLinked ?? true, &context)
        case .moveClips(let clipIDs, let delta, let toTrackID, let includeLinked, let mode):
            try moveClips(&project, clipIDs, delta: delta ?? .zero, toTrackID: toTrackID, includeLinked: includeLinked ?? true, mode: mode ?? .place, &context)
        case .updateClip(let clipID, let patch):
            try updateClip(&project, clipID, patch)
        case .link(let clipIDs):
            try link(&project, clipIDs, &context)
        case .unlink(let clipIDs):
            try unlink(&project, clipIDs)
        case .applyLayout(let clipIDs, let preset):
            try applyLayout(&project, clipIDs, preset, &context)
        case .zoomToRegion(let clipID, let rect, let at, let duration):
            try zoomToRegion(&project, clipID, rect: rect, at: at, duration: duration)
        case .addMotion(let clipIDs, let style, let amount):
            try addMotion(&project, clipIDs, style: style, amount: amount)
        case .setFormatLayout(let clipIDs, let format, let slot, let cutout):
            try setFormatLayout(&project, clipIDs, format: format, slot: slot, cutout: cutout)
        case .addTransition(let trackID, let transition, let sound):
            try addTransition(&project, trackID: trackID, transition, sound: sound, &context)
        case .updateTransition(let transitionID, let patch):
            try updateTransition(&project, transitionID, patch, &context)
        case .removeTransition(let transitionID):
            try removeTransition(&project, transitionID)
        case .addEffect(let clipID, let effect, let index):
            try addEffect(&project, clipID, effect, index: index, &context)
        case .updateEffect(let clipID, let effectID, let patch):
            try updateEffect(&project, clipID, effectID, patch)
        case .removeEffect(let clipID, let effectID):
            try removeEffect(&project, clipID, effectID)
        case .moveEffect(let clipID, let effectID, let index):
            try moveEffect(&project, clipID, effectID, index)
        case .setKeyframes(let clipID, let parameter, let keyframes):
            try setKeyframes(&project, clipID, parameter, keyframes, &context)
        case .normalizeSpeech:
            try normalizeSpeech(&project, &context)
        case .addMarker(let marker):
            try addMarker(&project, marker, &context)
        case .updateMarker(let markerID, let patch):
            try updateMarker(&project, markerID, patch)
        case .removeMarker(let markerID):
            try removeMarker(&project, markerID)
        }
        TransitionSounds.reconcile(&project, from: sounds, &context)
        context.placedSounds = []
        project.normalizeLinkGroups()
    }

    // MARK: - Lookups

    static func requireTrack(_ p: Project, _ id: String) throws -> TrackLocation {
        guard let location = p.location(ofTrack: id) else { throw EditError.notFound("track \(id)") }
        return location
    }

    static func requireClip(_ p: Project, _ id: String) throws -> (track: TrackLocation, index: Int) {
        guard let location = p.location(ofClip: id) else { throw EditError.notFound("clip \(id)") }
        return location
    }

    static func requireUnlocked(_ track: Track) throws {
        if track.locked { throw EditError.locked("track \"\(track.name)\" is locked") }
    }

    /// The listed clips plus, when asked, every clip linked to them. Keeps
    /// the order stable and drops duplicates.
    static func expand(_ p: Project, _ ids: [String], includeLinked: Bool) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for id in ids {
            guard p.clip(id) != nil else { throw EditError.notFound("clip \(id)") }
            for member in includeLinked ? p.linkedClipIDs(of: id) : [id] where !seen.contains(member) {
                seen.insert(member)
                result.append(member)
            }
        }
        return result
    }

    static func requireObject(_ patch: JSONValue, forbidden: [String], what: String) throws {
        guard case .object(let fields) = patch else { throw EditError.invalid("\(what) patch must be a JSON object") }
        for key in forbidden where fields[key] != nil {
            throw EditError.invalid("\(what) patch can't change \"\(key)\"")
        }
    }

    // MARK: - Project and tracks

    private struct ProjectHeader: Codable {
        var name: String
        var metadata: [String: String]
    }

    static func updateProject(_ p: inout Project, _ patch: JSONValue) throws {
        guard case .object(let fields) = patch else { throw EditError.invalid("project patch must be a JSON object") }
        for key in fields.keys where key != "name" && key != "metadata" {
            throw EditError.invalid("updateProject can change name and metadata (use updateSettings for \"\(key)\")")
        }
        let header = try JSONValue.applyMergePatch(patch, to: ProjectHeader(name: p.name, metadata: p.metadata))
        p.name = header.name
        p.metadata = header.metadata
    }

    static func updateSettings(_ p: inout Project, _ patch: JSONValue, _ context: inout EditContext) throws {
        let old = p.settings
        let settings = try JSONValue.applyMergePatch(patch, to: p.settings)
        guard settings.width > 0, settings.height > 0 else { throw EditError.invalid("canvas size must be positive") }
        guard settings.frameRate.numerator > 0, settings.frameRate.denominator > 0 else {
            throw EditError.invalid("frame rate must be positive")
        }
        if settings.frameRate != old.frameRate {
            context.warn("Frame rate changed to \(settings.frameRate.framesPerSecond) fps. Existing cuts keep their times, so some may fall between frames.")
        }
        if settings.speechLoudness != old.speechLoudness {
            let range = AudioLevels.speechLoudnessRange
            guard range.contains(settings.speechLoudness) else {
                throw EditError.invalid("the speech level must be between \(AudioLevels.number(range.lowerBound)) and \(AudioLevels.number(range.upperBound)) LUFS")
            }
            moveNormalizedClips(&p, from: old.speechLoudness, to: settings.speechLoudness, &context)
        }
        p.settings = settings
    }

    /// Clips normalised to the old speech level move to the new one, so
    /// changing the setting moves the voice. Other levels (a clip set to
    /// -24 by hand, Filmora's own) stay.
    static func moveNormalizedClips(_ p: inout Project, from old: Double, to new: Double, _ context: inout EditContext) {
        for location in p.trackLocations where location.kind == .audio {
            var track = p[location]
            let indices = track.clips.indices.filter { track.clips[$0].audio?.normalizeTo == old }
            guard !indices.isEmpty else { continue }
            if track.locked {
                context.warn("Locked track \"\(track.name)\" keeps its clips at \(AudioLevels.number(old)) LUFS.")
                continue
            }
            for i in indices { track.clips[i].audio?.normalizeTo = new }
            p[location] = track
        }
    }

    // MARK: - Levelling speech

    /// Sets every speech clip (`AudioLevels.isSpeech`) to the project's
    /// speech level with no clip gain. Fades, mutes, voice isolation,
    /// effects and gain keyframes stay; music and sound effects aren't
    /// touched. Locked tracks are left as they are, with a warning.
    static func normalizeSpeech(_ p: inout Project, _ context: inout EditContext) throws {
        let level = p.settings.speechLoudness
        var speech = 0
        var changed = 0
        var animated = 0
        for location in p.trackLocations where location.kind == .audio {
            var track = p[location]
            let indices = track.clips.indices.filter { AudioLevels.isSpeech(track.clips[$0], on: track, in: p) }
            speech += indices.count
            let unlevelled = indices.filter { !AudioLevels.isLevelled(track.clips[$0], at: level) }
            animated += indices.filter { track.clips[$0].keyframes["audio.gainDB"]?.isEmpty == false }.count
            guard !unlevelled.isEmpty else { continue }
            if track.locked {
                context.warn("Locked track \"\(track.name)\" was left as it was.")
                continue
            }
            for i in unlevelled {
                var audio = track.clips[i].audio ?? AudioProperties()
                audio.normalizeTo = level
                audio.gainDB = 0
                track.clips[i].audio = audio
            }
            changed += unlevelled.count
            p[location] = track
        }
        if speech == 0 {
            context.warn("There are no speech clips to normalise: camera or voice sound, or clips on a take track like Voice.")
        } else if changed == 0 {
            context.warn("Every speech clip is already at \(AudioLevels.number(level)) LUFS with no gain.")
        }
        if animated > 0 {
            context.warn("\(animated == 1 ? "1 speech clip keeps its" : "\(animated) speech clips keep their") gain animation, which plays on top of the level.")
        }
    }

    static func addTrack(_ p: inout Project, kind: TrackKind, name: String?, index: Int?, id: String?, _ context: inout EditContext) throws {
        let trackID = id ?? context.makeID("trk")
        guard !p.allIDs.contains(trackID) else { throw EditError.invalid("ID \(trackID) is already in use") }
        let count = kind == .video ? p.videoTracks.count : p.audioTracks.count
        let track = Track(id: trackID, kind: kind, name: name ?? "\(kind == .video ? "Video" : "Audio") \(count + 1)")
        let at = min(max(index ?? count, 0), count)
        if kind == .video {
            p.videoTracks.insert(track, at: at)
        } else {
            p.audioTracks.insert(track, at: at)
        }
        context.createdIDs.append(trackID)
    }

    static func removeTrack(_ p: inout Project, _ trackID: String) throws {
        let location = try requireTrack(p, trackID)
        try requireUnlocked(p[location])
        if location.kind == .video {
            p.videoTracks.remove(at: location.index)
        } else {
            p.audioTracks.remove(at: location.index)
        }
    }

    static func moveTrack(_ p: inout Project, _ trackID: String, _ index: Int) throws {
        let location = try requireTrack(p, trackID)
        if location.kind == .video {
            let track = p.videoTracks.remove(at: location.index)
            p.videoTracks.insert(track, at: min(max(index, 0), p.videoTracks.count))
        } else {
            let track = p.audioTracks.remove(at: location.index)
            p.audioTracks.insert(track, at: min(max(index, 0), p.audioTracks.count))
        }
    }

    static func updateTrack(_ p: inout Project, _ trackID: String, _ patch: JSONValue) throws {
        let location = try requireTrack(p, trackID)
        try requireObject(patch, forbidden: ["id", "kind", "clips", "transitions"], what: "track")
        p[location] = try JSONValue.applyMergePatch(patch, to: p[location])
    }

    // MARK: - Media

    static func addMedia(_ p: inout Project, _ item: MediaItem) throws {
        guard !p.allIDs.contains(item.id) else { throw EditError.invalid("ID \(item.id) is already in use") }
        guard !item.path.isEmpty else { throw EditError.invalid("media needs a path") }
        p.media.append(item)
    }

    static func updateMedia(_ p: inout Project, _ mediaID: String, _ patch: JSONValue) throws {
        guard let index = p.media.firstIndex(where: { $0.id == mediaID }) else { throw EditError.notFound("media \(mediaID)") }
        try requireObject(patch, forbidden: ["id"], what: "media")
        p.media[index] = try JSONValue.applyMergePatch(patch, to: p.media[index])
    }

    static func removeMedia(_ p: inout Project, _ mediaID: String) throws {
        guard let index = p.media.firstIndex(where: { $0.id == mediaID }) else { throw EditError.notFound("media \(mediaID)") }
        let users = p.allTracks.flatMap(\.clips).filter { $0.mediaID == mediaID }
        guard users.isEmpty else {
            throw EditError.invalid("media \(mediaID) is used by \(users.count) clip(s); remove them first")
        }
        p.media.remove(at: index)
    }

    // MARK: - Checks shared by placement commands

    /// Throws when a clip's content can't go on a track of this kind.
    static func checkContent(_ clip: Clip, fits track: Track, in p: Project) throws {
        switch clip.content {
        case .media(let mediaID):
            guard let item = p.media(mediaID) else { throw EditError.notFound("media \(mediaID)") }
            if track.kind == .video && !(item.hasVideo || item.kind == .image) {
                throw EditError.invalid("\(item.path) has no picture, so it can't go on video track \"\(track.name)\"")
            }
            if track.kind == .audio && !item.hasAudio {
                throw EditError.invalid("\(item.path) has no sound, so it can't go on audio track \"\(track.name)\"")
            }
        case .text, .graphic, .solid, .adjustment:
            if track.kind == .audio {
                throw EditError.invalid("audio track \"\(track.name)\" can only hold media clips")
            }
        }
    }

    /// Throws when a clip reaches outside its media.
    static func checkSource(_ clip: Clip, in p: Project) throws {
        guard clip.duration > .zero else { throw EditError.invalid("clip \(clip.id) would have no duration") }
        guard clip.speed > 0 else { throw EditError.invalid("clip \(clip.id) needs a speed above 0") }
        guard clip.mediaID != nil else { return }
        let tolerance = p.settings.frameRate.frameDuration
        if clip.sourceStart < -tolerance {
            throw EditError.invalid("clip \(clip.id) would start \(-clip.sourceStart) before the beginning of its media")
        }
        if let limit = p.sourceLimit(for: clip), clip.sourceEnd > limit + tolerance {
            throw EditError.invalid("clip \(clip.id) needs media up to \(clip.sourceEnd) but the file is \(limit) long")
        }
    }

    // MARK: - Placing clips

    static func insertClip(_ p: inout Project, trackID: String, clip: Clip, mode: InsertMode, _ context: inout EditContext) throws {
        let location = try requireTrack(p, trackID)
        try requireUnlocked(p[location])
        guard !p.allIDs.contains(clip.id) else { throw EditError.invalid("ID \(clip.id) is already in use") }
        guard clip.start >= .zero else { throw EditError.invalid("clips can't start before 0") }
        try checkContent(clip, fits: p[location], in: p)
        try checkSource(clip, in: p)
        switch mode {
        case .place:
            guard p[location].isFree(clip.range) else {
                throw EditError.overlap("\"\(p[location].name)\" already has a clip between \(clip.start) and \(clip.end)")
            }
        case .overwrite:
            p[location].clear(clip.range, context: &context)
        case .insert:
            try rippleOpen(&p, at: clip.start, duration: clip.duration, edited: [trackID], &context)
        }
        p[location].add(clip)
        context.createdIDs.append(clip.id)
    }

    /// Default track name for a media role.
    static func trackName(for role: MediaRole, kind: TrackKind) -> String? {
        switch (role, kind) {
        case (.camera, .video): return "Camera"
        case (.screen, .video): return "Screen"
        case (.broll, .video), (.image, .video): return "B-roll"
        case (.graphic, .video), (.sticker, .video): return "Graphics"
        case (.camera, .audio), (.screen, .audio), (.other, .audio): return "Voice"
        case (.music, .audio): return "Music"
        case (.sfx, .audio), (.broll, .audio), (.sticker, .audio), (.graphic, .audio): return "SFX"
        default: return nil
        }
    }

    static func defaultIncludesAudio(_ role: MediaRole) -> Bool {
        switch role {
        case .camera, .music, .sfx, .other: return true
        case .screen, .broll, .graphic, .sticker, .image: return false
        }
    }

    /// Picks the track a new clip of `role` should land on: the named track
    /// for the role, else the first track of the right kind that's free,
    /// else a new track.
    static func routeTrack(
        _ p: inout Project,
        role: MediaRole,
        kind: TrackKind,
        range: TimeRange,
        requireFree: Bool,
        _ context: inout EditContext
    ) throws -> TrackLocation {
        if let name = trackName(for: role, kind: kind), let track = p.track(named: name, kind: kind),
           let location = p.location(ofTrack: track.id), !track.locked {
            return location
        }
        let tracks = kind == .video ? p.videoTracks : p.audioTracks
        if let index = tracks.firstIndex(where: { !$0.locked && (!requireFree || $0.isFree(range)) }) {
            return TrackLocation(kind: kind, index: index)
        }
        try addTrack(&p, kind: kind, name: trackName(for: role, kind: kind), index: nil, id: nil, &context)
        return TrackLocation(kind: kind, index: (kind == .video ? p.videoTracks.count : p.audioTracks.count) - 1)
    }

    static func placeMedia(
        _ p: inout Project,
        mediaIDs: [String],
        at: Time,
        sourceStart: Time?,
        duration: Time?,
        mode: InsertMode,
        videoTrackID: String?,
        audioTrackID: String?,
        includeAudio: Bool?,
        _ context: inout EditContext
    ) throws {
        guard !mediaIDs.isEmpty else { throw EditError.invalid("placeMedia needs at least one media ID") }
        guard at >= .zero else { throw EditError.invalid("clips can't start before 0") }
        let items = try mediaIDs.map { id -> MediaItem in
            guard let item = p.media(id) else { throw EditError.notFound("media \(id)") }
            return item
        }
        // Files from one take are aligned by their take offsets.
        let takeIDs = Set(items.compactMap(\.takeID))
        let isTake = items.count > 1 && takeIDs.count == 1 && items.allSatisfy { $0.takeID != nil }
        let offsets = items.map { isTake ? ($0.takeOffset ?? .zero) : .zero }
        let takeStart = sourceStart ?? (offsets.max() ?? .zero)
        let starts = zip(items, offsets).map { takeStart - $0.1 }
        for (item, start) in zip(items, starts) where start < .zero {
            throw EditError.invalid("\(item.path) starts \(-start) later in the take than the requested source start")
        }
        let available = zip(items, starts).compactMap { item, start -> Time? in
            guard item.kind != .image, let length = item.duration else { return nil }
            return length - start
        }
        let length = duration ?? available.min() ?? Time(seconds: 5)
        guard length > .zero else { throw EditError.invalid("nothing left to place after the source start") }
        let range = TimeRange(start: at, duration: length)

        // Work out every clip and its track first.
        var planned: [(TrackLocation, Clip)] = []
        for (item, start) in zip(items, starts) {
            var parts: [TrackKind] = []
            if item.hasVideo || item.kind == .image { parts.append(.video) }
            if item.hasAudio && (includeAudio ?? defaultIncludesAudio(item.role)) { parts.append(.audio) }
            for kind in parts {
                let explicitID = kind == .video ? videoTrackID : audioTrackID
                let location: TrackLocation
                if let explicitID, items.count == 1 {
                    location = try requireTrack(p, explicitID)
                    guard p[location].kind == kind else {
                        throw EditError.invalid("track \(explicitID) is a \(p[location].kind.rawValue) track")
                    }
                } else {
                    location = try routeTrack(&p, role: item.role, kind: kind, range: range, requireFree: mode == .place, &context)
                }
                try requireUnlocked(p[location])
                var clip = Clip(
                    id: context.makeID("clip"),
                    name: URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent,
                    content: .media(mediaID: item.id),
                    start: at,
                    duration: length,
                    sourceStart: item.kind == .image ? .zero : start
                )
                if kind == .audio {
                    clip.audio = AudioLevels.placedAudio(role: item.role, on: p[location], settings: p.settings)
                }
                planned.append((location, clip))
            }
        }
        guard !planned.isEmpty else { throw EditError.invalid("none of those files has picture or sound to place") }
        if planned.count > 1 {
            let group = context.makeID("lnk")
            for i in planned.indices { planned[i].1.linkGroup = group }
        }
        for (_, clip) in planned { try checkSource(clip, in: p) }

        switch mode {
        case .place:
            for (location, clip) in planned where !p[location].isFree(clip.range) {
                throw EditError.overlap("\"\(p[location].name)\" already has a clip between \(clip.start) and \(clip.end)")
            }
        case .overwrite:
            for (location, clip) in planned { p[location].clear(clip.range, context: &context) }
        case .insert:
            let edited = Set(planned.map { p[$0.0].id })
            try rippleOpen(&p, at: at, duration: length, edited: edited, &context)
        }
        for (location, clip) in planned {
            p[location].add(clip)
            context.createdIDs.append(clip.id)
        }
    }

    // MARK: - Ripple helpers

    /// Opens time at `time` for a ripple edit on the `edited` tracks, which
    /// the caller has already handled or wants split. If any edited track is
    /// a `.cut` track the whole timeline moves: `.cut` tracks split, `.follow`
    /// tracks shift, `.off` tracks stay. Otherwise only the edited tracks move.
    static func rippleOpen(
        _ p: inout Project,
        at time: Time,
        duration: Time,
        edited: Set<String>,
        handled: Set<String> = [],
        _ context: inout EditContext
    ) throws {
        guard duration > .zero else { return }
        let global = edited.contains { p.track($0)?.rippleMode == .cut }
        for location in p.trackLocations {
            var track = p[location]
            if handled.contains(track.id) { continue }
            let split: Bool
            if edited.contains(track.id) {
                split = true
            } else if global {
                switch track.rippleMode {
                case .cut: split = true
                case .follow: split = false
                case .off: continue
                }
            } else {
                continue
            }
            if track.locked {
                if track.clips.contains(where: { $0.end > time }) {
                    context.warn("Locked track \"\(track.name)\" didn't move with the edit.")
                }
                continue
            }
            track.openTime(at: time, duration: duration, split: split, context: &context)
            p[location] = track
        }
        if global {
            for i in p.markers.indices where p.markers[i].time >= time {
                p.markers[i].time += duration
            }
        }
    }

    /// Removes `range` for a ripple edit. `cut` tracks lose the range. If any
    /// of them is a `.cut` track the edit is global: other `.cut` tracks are
    /// cut too (or, with `strict`, must be empty there), `.follow` tracks
    /// follow and markers move. Otherwise only the `cut` tracks change.
    static func rippleRemove(
        _ p: inout Project,
        _ range: TimeRange,
        cut: Set<String>,
        handled: Set<String> = [],
        strict: Bool = false,
        _ context: inout EditContext
    ) throws {
        guard !range.isEmpty else { return }
        let global = cut.contains { p.track($0)?.rippleMode == .cut }
        for location in p.trackLocations {
            var track = p[location]
            if handled.contains(track.id) { continue }
            enum Action { case cut, follow }
            let action: Action
            if cut.contains(track.id) {
                action = .cut
            } else if global {
                switch track.rippleMode {
                case .cut:
                    if strict && !track.clips(intersecting: range).isEmpty {
                        throw EditError.invalid("\"\(track.name)\" has clips between \(range.start) and \(range.end), so closing this gap would cut them")
                    }
                    action = .cut
                case .follow: action = .follow
                case .off: continue
                }
            } else {
                continue
            }
            if track.locked {
                if track.clips.contains(where: { $0.end > range.start }) {
                    context.warn("Locked track \"\(track.name)\" didn't move with the edit.")
                }
                continue
            }
            switch action {
            case .cut: track.cutOut(range, context: &context)
            case .follow: track.followRemoval(of: range, context: &context)
            }
            track.repairTransitions(context: &context)
            p[location] = track
        }
        if global {
            let a = range.start
            let b = range.end
            func map(_ t: Time) -> Time { t <= a ? t : (t < b ? a : t - range.duration) }
            for i in p.markers.indices {
                let start = map(p.markers[i].time)
                let end = map(p.markers[i].time + p.markers[i].duration)
                p.markers[i].time = start
                p.markers[i].duration = end - start
            }
            p.markers.sort { $0.time < $1.time }
        }
    }

    // MARK: - Removing

    static func removeClips(_ p: inout Project, _ clipIDs: [String], ripple: Bool, includeLinked: Bool, _ context: inout EditContext) throws {
        let ids = try expand(p, clipIDs, includeLinked: includeLinked)
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        var ranges: [TimeRange] = []
        var touched = Set<String>()
        for id in ids {
            let (location, index) = try requireClip(p, id)
            try requireUnlocked(p[location])
            ranges.append(p[location].clips[index].range)
            touched.insert(p[location].id)
        }
        for location in p.trackLocations where touched.contains(p[location].id) {
            p[location].clips.removeAll { idSet.contains($0.id) }
            p[location].removeTransitions(referencing: idSet)
        }
        guard ripple else { return }
        let merged = TimeRange.union(ranges)
        for trackID in touched {
            guard let track = p.track(trackID) else { continue }
            for range in merged where !track.clips(intersecting: range).isEmpty {
                throw EditError.invalid("ripple delete needs the selected clips to line up: \"\(track.name)\" still has clips between \(range.start) and \(range.end). Lift them instead, or delete a time range.")
            }
        }
        for range in merged.reversed() {
            try rippleRemove(&p, range, cut: touched, &context)
        }
    }

    static func rippleDeleteRange(_ p: inout Project, _ range: TimeRange, trackIDs: [String]?, _ context: inout EditContext) throws {
        guard range.duration > .zero else { throw EditError.invalid("the range is empty") }
        guard range.start >= .zero else { throw EditError.invalid("the range starts before 0") }
        var cut: Set<String>
        if let trackIDs {
            for id in trackIDs { _ = try requireTrack(p, id) }
            cut = Set(trackIDs)
        } else {
            cut = Set(p.allTracks.filter { $0.rippleMode == .cut }.map(\.id))
            if cut.isEmpty { cut = Set(p.allTracks.filter { $0.rippleMode != .off }.map(\.id)) }
        }
        try rippleRemove(&p, range, cut: cut, &context)
    }

    static func closeGap(_ p: inout Project, trackID: String, at: Time, _ context: inout EditContext) throws {
        let location = try requireTrack(p, trackID)
        let track = p[location]
        if let clip = track.clip(at: at) {
            throw EditError.invalid("there's no gap at \(at) on \"\(track.name)\" (clip \(clip.id) is there)")
        }
        let start = track.clips.filter { $0.end <= at }.map(\.end).max() ?? .zero
        guard let end = track.clips.filter({ $0.start > at }).map(\.start).min() else {
            throw EditError.invalid("nothing after \(at) on \"\(track.name)\" to close the gap up to")
        }
        try rippleRemove(&p, TimeRange(start: start, end: end), cut: [trackID], strict: true, &context)
    }

    static func insertTime(_ p: inout Project, at: Time, duration: Time, trackIDs: [String]?, _ context: inout EditContext) throws {
        guard duration > .zero else { throw EditError.invalid("duration must be positive") }
        let edited: Set<String>
        if let trackIDs {
            for id in trackIDs { _ = try requireTrack(p, id) }
            edited = Set(trackIDs)
        } else {
            edited = Set(p.allTracks.filter { $0.rippleMode == .cut }.map(\.id))
        }
        try rippleOpen(&p, at: at, duration: duration, edited: edited, &context)
    }

    // MARK: - Cutting and trimming

    static func blade(_ p: inout Project, at: Time, trackIDs: [String]?, clipIDs: [String]?, _ context: inout EditContext) throws {
        var targets: [String] = []
        if let clipIDs {
            targets = try expand(p, clipIDs, includeLinked: true)
        } else {
            let locations: [TrackLocation]
            if let trackIDs {
                locations = try trackIDs.map { try requireTrack(p, $0) }
            } else {
                locations = p.trackLocations.filter { p[$0].targeted }
            }
            var seen = Set<String>()
            for location in locations {
                guard let clip = p[location].clip(at: at) else { continue }
                for id in p.linkedClipIDs(of: clip.id) where !seen.contains(id) {
                    seen.insert(id)
                    targets.append(id)
                }
            }
        }
        var cutCount = 0
        for id in targets {
            guard let (location, index) = p.location(ofClip: id) else { continue }
            let clip = p[location].clips[index]
            guard clip.start < at && at < clip.end else { continue }
            if p[location].locked {
                context.warn("Didn't cut \"\(p[location].name)\": the track is locked.")
                continue
            }
            if p[location].split(at: at, context: &context) != nil { cutCount += 1 }
        }
        if cutCount == 0 { context.warn("Nothing to cut at \(at).") }
    }

    static func trim(_ p: inout Project, clipID: String, edge: ClipEdge, to: Time, ripple: Bool, includeLinked: Bool, _ context: inout EditContext) throws {
        let (primaryLocation, primaryIndex) = try requireClip(p, clipID)
        let primary = p[primaryLocation].clips[primaryIndex]
        let delta = edge == .start ? to - primary.start : to - primary.end
        guard delta != .zero else { return }
        let ids = includeLinked ? p.linkedClipIDs(of: clipID) : [clipID]
        var touched = Set<String>()
        for id in ids {
            let (location, index) = try requireClip(p, id)
            var track = p[location]
            try requireUnlocked(track)
            var clip = track.clips[index]
            let oldEnd = clip.end
            switch (edge, ripple) {
            case (.end, _):
                clip.moveTail(to: clip.end + delta)
            case (.start, false):
                clip.moveHead(to: clip.start + delta)
                guard clip.start >= .zero else { throw EditError.invalid("clip \(id) can't start before 0") }
            case (.start, true):
                clip.rippleHead(by: delta)
            }
            guard clip.duration > .zero else { throw EditError.invalid("that trim would leave clip \(id) with no duration") }
            try checkSource(clip, in: p)
            track.clips[index] = clip
            if ripple {
                let shift = clip.end - oldEnd
                track.shiftClips(from: oldEnd, by: shift, excluding: [clip.id])
            } else if !track.isFree(clip.range, ignoring: [clip.id]) {
                throw EditError.overlap("trimming clip \(id) would run into the next clip on \"\(track.name)\"")
            }
            track.sortClips()
            p[location] = track
            touched.insert(track.id)
        }
        guard ripple else { return }
        // Keep the rest of the timeline in sync with the trimmed clip.
        switch edge {
        case .end:
            if delta < .zero {
                try rippleRemove(&p, TimeRange(start: primary.end + delta, end: primary.end), cut: touched, handled: touched, &context)
            } else {
                try rippleOpen(&p, at: primary.end, duration: delta, edited: touched, handled: touched, &context)
            }
        case .start:
            if delta > .zero {
                try rippleRemove(&p, TimeRange(start: primary.start, duration: delta), cut: touched, handled: touched, &context)
            } else {
                try rippleOpen(&p, at: primary.start, duration: -delta, edited: touched, handled: touched, &context)
            }
        }
    }

    static func roll(_ p: inout Project, _ leftID: String, _ rightID: String, delta: Time, _ context: inout EditContext) throws {
        let (location, leftIndex) = try requireClip(p, leftID)
        guard let rightIndex = p[location].index(ofClip: rightID) else {
            throw EditError.invalid("clips \(leftID) and \(rightID) aren't on the same track")
        }
        let left = p[location].clips[leftIndex]
        let right = p[location].clips[rightIndex]
        guard left.end == right.start else { throw EditError.invalid("clips \(leftID) and \(rightID) don't meet") }
        guard delta != .zero else { return }
        // Roll the same cut on linked tracks, where the partners meet too.
        var pairs: [(TrackLocation, String, String)] = [(location, leftID, rightID)]
        if let lg = left.linkGroup, let rg = right.linkGroup {
            for other in p.trackLocations where other != location {
                let track = p[other]
                if let l = track.clips.first(where: { $0.linkGroup == lg && $0.end == left.end }),
                   let r = track.clips.first(where: { $0.linkGroup == rg && $0.start == right.start }) {
                    pairs.append((other, l.id, r.id))
                }
            }
        }
        for (trackLocation, lID, rID) in pairs {
            var track = p[trackLocation]
            try requireUnlocked(track)
            guard let li = track.index(ofClip: lID), let ri = track.index(ofClip: rID) else { continue }
            let cut = track.clips[li].end + delta
            guard cut > track.clips[li].start, cut < track.clips[ri].end else {
                throw EditError.invalid("rolling by \(delta) would leave a clip with no duration")
            }
            track.clips[li].moveTail(to: cut)
            track.clips[ri].moveHead(to: cut)
            try checkSource(track.clips[li], in: p)
            try checkSource(track.clips[ri], in: p)
            p[trackLocation] = track
        }
    }

    static func slip(_ p: inout Project, _ clipID: String, delta: Time, includeLinked: Bool) throws {
        guard delta != .zero else { return }
        for id in includeLinked ? p.linkedClipIDs(of: clipID) : [clipID] {
            let (location, index) = try requireClip(p, id)
            try requireUnlocked(p[location])
            var clip = p[location].clips[index]
            clip.sourceStart += delta
            try checkSource(clip, in: p)
            p[location].clips[index] = clip
        }
    }

    static func slide(_ p: inout Project, _ clipID: String, delta: Time, _ context: inout EditContext) throws {
        guard delta != .zero else { return }
        _ = try requireClip(p, clipID)
        for id in p.linkedClipIDs(of: clipID) {
            let (location, index) = try requireClip(p, id)
            var track = p[location]
            try requireUnlocked(track)
            var clip = track.clips[index]
            let previous = track.clip(endingAt: clip.start, excluding: clip.id)
            let next = track.clip(startingAt: clip.end, excluding: clip.id)
            clip.start += delta
            guard clip.start >= .zero else { throw EditError.invalid("clip \(id) can't slide before 0") }
            if let previous, let pi = track.index(ofClip: previous.id) {
                track.clips[pi].moveTail(to: clip.start)
                guard track.clips[pi].duration > .zero else {
                    throw EditError.invalid("sliding \(id) by \(delta) would swallow the clip before it")
                }
                try checkSource(track.clips[pi], in: p)
            }
            if let next, let ni = track.index(ofClip: next.id) {
                track.clips[ni].moveHead(to: clip.end)
                guard track.clips[ni].duration > .zero else {
                    throw EditError.invalid("sliding \(id) by \(delta) would swallow the clip after it")
                }
                try checkSource(track.clips[ni], in: p)
            }
            track.clips[index] = clip
            guard track.isFree(clip.range, ignoring: [clip.id]) else {
                throw EditError.overlap("sliding clip \(id) by \(delta) runs into another clip on \"\(track.name)\"")
            }
            track.sortClips()
            p[location] = track
        }
    }

    static func setSpeed(_ p: inout Project, _ clipID: String, speed: Double, ripple: Bool, includeLinked: Bool, _ context: inout EditContext) throws {
        guard speed > 0, speed <= 100 else { throw EditError.invalid("speed must be between 0 and 100") }
        let (primaryLocation, primaryIndex) = try requireClip(p, clipID)
        let primary = p[primaryLocation].clips[primaryIndex]
        guard !primary.freezeFrame else { throw EditError.invalid("clip \(clipID) is a freeze frame, so speed doesn't apply") }
        let newPrimaryDuration = Time(seconds: primary.sourceDuration.seconds / speed)
        let delta = newPrimaryDuration - primary.duration
        var touched = Set<String>()
        for id in includeLinked ? p.linkedClipIDs(of: clipID) : [clipID] {
            let (location, index) = try requireClip(p, id)
            var track = p[location]
            try requireUnlocked(track)
            var clip = track.clips[index]
            guard !clip.freezeFrame else { continue }
            let oldEnd = clip.end
            let oldSpeed = clip.speed
            let newDuration = Time(seconds: clip.sourceDuration.seconds / speed)
            clip.keyframes = KeyframeEditing.scaled(clip.keyframes, by: oldSpeed / speed)
            clip.speed = speed
            clip.duration = newDuration
            clip.tidy()
            try checkSource(clip, in: p)
            track.clips[index] = clip
            if ripple {
                track.shiftClips(from: oldEnd, by: clip.end - oldEnd, excluding: [clip.id])
            } else if !track.isFree(clip.range, ignoring: [clip.id]) {
                throw EditError.overlap("at \(speed)x clip \(id) would run into the next clip on \"\(track.name)\"; use ripple")
            }
            p[location] = track
            touched.insert(track.id)
        }
        guard ripple, delta != .zero else { return }
        if delta < .zero {
            try rippleRemove(&p, TimeRange(start: primary.end + delta, end: primary.end), cut: touched, handled: touched, &context)
        } else {
            try rippleOpen(&p, at: primary.end, duration: delta, edited: touched, handled: touched, &context)
        }
    }

    // MARK: - Moving and editing clips

    static func moveClips(_ p: inout Project, _ clipIDs: [String], delta: Time, toTrackID: String?, includeLinked: Bool, mode: MoveMode, _ context: inout EditContext) throws {
        let ids = try expand(p, clipIDs, includeLinked: includeLinked)
        let idSet = Set(ids)
        var destination: [String: TrackLocation] = [:]
        if let toTrackID {
            let target = try requireTrack(p, toTrackID)
            let sources = Set(clipIDs.compactMap { p.location(ofClip: $0)?.track })
            guard sources.count == 1 else {
                throw EditError.invalid("to move clips to another track, pick clips from one track")
            }
            for id in clipIDs { destination[id] = target }
        }
        // Take the clips out, remembering the transitions that can travel.
        var moving: [(Clip, TrackLocation)] = []
        var carried: [(Transition, TrackLocation)] = []
        for id in ids {
            let (location, index) = try requireClip(p, id)
            try requireUnlocked(p[location])
            var clip = p[location].clips[index]
            clip.start += delta
            guard clip.start >= .zero else { throw EditError.invalid("clip \(id) can't move before 0") }
            let target = destination[id] ?? location
            try checkContent(clip, fits: p[target], in: p)
            moving.append((clip, target))
        }
        for location in p.trackLocations {
            var track = p[location]
            guard track.clips.contains(where: { idSet.contains($0.id) }) else { continue }
            for transition in track.transitions {
                let from = transition.fromClipID
                let to = transition.toClipID
                let fromMoving = from.map(idSet.contains) ?? false
                let toMoving = to.map(idSet.contains) ?? false
                guard fromMoving || toMoving else { continue }
                let owner = (fromMoving ? from : to)!
                let target = destination[owner] ?? location
                let bothTravel = (from == nil || fromMoving) && (to == nil || toMoving)
                let sameTarget = [from, to].compactMap { $0 }.allSatisfy { (destination[$0] ?? location) == target }
                if bothTravel && sameTarget {
                    carried.append((transition, target))
                } else {
                    context.warn("Removed a \(transition.type.rawValue) transition: its clips were moved apart.")
                }
            }
            track.clips.removeAll { idSet.contains($0.id) }
            track.removeTransitions(referencing: idSet)
            p[location] = track
        }
        for (clip, location) in moving {
            try requireUnlocked(p[location])
            switch mode {
            case .place:
                guard p[location].isFree(clip.range) else {
                    throw EditError.overlap("\"\(p[location].name)\" already has a clip between \(clip.start) and \(clip.end)")
                }
            case .overwrite:
                p[location].clear(clip.range, context: &context)
            }
            p[location].add(clip)
        }
        for (transition, location) in carried {
            p[location].transitions.append(transition)
        }
        for location in p.trackLocations {
            p[location].repairTransitions(context: &context)
        }
    }

    static func updateClip(_ p: inout Project, _ clipID: String, _ patch: JSONValue) throws {
        let (location, index) = try requireClip(p, clipID)
        try requireUnlocked(p[location])
        try requireObject(patch, forbidden: ["id"], what: "clip")
        let clip = try JSONValue.applyMergePatch(patch, to: p[location].clips[index])
        try checkContent(clip, fits: p[location], in: p)
        try checkSource(clip, in: p)
        p[location].clips[index] = clip
        p[location].sortClips()
    }

    static func link(_ p: inout Project, _ clipIDs: [String], _ context: inout EditContext) throws {
        let ids = try expand(p, clipIDs, includeLinked: true)
        guard ids.count > 1 else { throw EditError.invalid("link needs at least two clips") }
        let group = context.makeID("lnk")
        let idSet = Set(ids)
        for location in p.trackLocations {
            for i in p[location].clips.indices where idSet.contains(p[location].clips[i].id) {
                p[location].clips[i].linkGroup = group
            }
        }
    }

    static func unlink(_ p: inout Project, _ clipIDs: [String]) throws {
        for id in clipIDs {
            let (location, index) = try requireClip(p, id)
            p[location].clips[index].linkGroup = nil
        }
    }

    // MARK: - Layout

    static func applyLayout(_ p: inout Project, _ clipIDs: [String], _ preset: LayoutPreset, _ context: inout EditContext) throws {
        var changed = 0
        for id in clipIDs {
            let (location, index) = try requireClip(p, id)
            guard p[location].kind == .video else { continue }
            try requireUnlocked(p[location])
            var clip = p[location].clips[index]
            let item = clip.mediaID.flatMap { p.media($0) }
            clip.video = preset.apply(
                to: clip.video, role: item?.role, shadowID: context.makeID("fx"),
                sourceSize: sourceSize(of: clip, in: p),
                canvasSize: (Double(p.settings.width), Double(p.settings.height))
            )
            for key in ["video.transform.position", "video.transform.scale", "video.transform.rotation"] {
                clip.keyframes.removeValue(forKey: key)
            }
            p[location].clips[index] = clip
            changed += 1
        }
        if changed == 0 { throw EditError.invalid("none of those clips are on a video track") }
    }

    /// The pixel size a clip shows: its media's, or the canvas for text,
    /// solids and media that hasn't been probed.
    static func sourceSize(of clip: Clip, in p: Project) -> (width: Double, height: Double) {
        if let mediaID = clip.mediaID, let item = p.media(mediaID), let width = item.width, let height = item.height, width > 0, height > 0 {
            return (Double(width), Double(height))
        }
        return (Double(p.settings.width), Double(p.settings.height))
    }

    static func addMotion(_ p: inout Project, _ clipIDs: [String], style: MotionStyle, amount: Double?) throws {
        let amount = amount ?? 1.12
        guard amount >= 1, amount <= 3 else { throw EditError.invalid("amount is how much bigger the zoom gets, from 1 to 3 (1.12 is gentle)") }
        var changed = 0
        for id in clipIDs {
            let (location, index) = try requireClip(p, id)
            guard p[location].kind == .video else { continue }
            try requireUnlocked(p[location])
            var clip = p[location].clips[index]
            let size = sourceSize(of: clip, in: p)
            let base = (clip.video ?? VideoProperties()).transform
            let (start, end) = style.keyframes(
                from: base, amount: amount, sourceWidth: size.width, sourceHeight: size.height,
                canvasWidth: Double(p.settings.width), canvasHeight: Double(p.settings.height)
            )
            // An even, unhurried move from the first frame to the last.
            clip.keyframes["video.transform.scale"] = [
                Keyframe(time: .zero, value: .number(start.scale), interpolation: .linear),
                Keyframe(time: clip.duration, value: .number(end.scale), interpolation: .linear)
            ]
            clip.keyframes["video.transform.position"] = [
                Keyframe(time: .zero, value: .point(start.position), interpolation: .linear),
                Keyframe(time: clip.duration, value: .point(end.position), interpolation: .linear)
            ]
            p[location].clips[index] = clip
            changed += 1
        }
        if changed == 0 { throw EditError.invalid("none of those clips are on a video track") }
    }

    static func zoomToRegion(_ p: inout Project, _ clipID: String, rect: Rect, at: Time?, duration: Time?) throws {
        let (location, index) = try requireClip(p, clipID)
        try requireUnlocked(p[location])
        guard p[location].kind == .video else { throw EditError.invalid("clip \(clipID) isn't on a video track") }
        guard rect.width > 0, rect.height > 0, rect.x >= 0, rect.y >= 0, rect.x + rect.width <= 1.0001, rect.y + rect.height <= 1.0001 else {
            throw EditError.invalid("the zoom rectangle must sit inside the frame (0...1)")
        }
        var clip = p[location].clips[index]
        guard let mediaID = clip.mediaID, let item = p.media(mediaID), let width = item.width, let height = item.height else {
            throw EditError.invalid("clip \(clipID) needs probed media (width and height) to zoom")
        }
        let target = Transform.showing(
            rect, sourceWidth: Double(width), sourceHeight: Double(height),
            canvasWidth: Double(p.settings.width), canvasHeight: Double(p.settings.height)
        )
        var video = clip.video ?? VideoProperties()
        guard let at else {
            video.transform.position = target.position
            video.transform.scale = target.scale
            video.layoutPreset = nil
            clip.video = video
            clip.keyframes.removeValue(forKey: "video.transform.position")
            clip.keyframes.removeValue(forKey: "video.transform.scale")
            p[location].clips[index] = clip
            return
        }
        let length = duration ?? Time(seconds: 0.5)
        let startTime = at - clip.start
        let endTime = startTime + length
        guard startTime >= .zero, endTime <= clip.duration else {
            throw EditError.invalid("the zoom has to happen inside clip \(clipID) (\(clip.start) to \(clip.end))")
        }
        let from = clip.resolvedVideo(at: startTime).transform
        func animate(_ key: String, _ a: ParamValue, _ b: ParamValue) {
            var frames = (clip.keyframes[key] ?? []).filter { $0.time < startTime || $0.time > endTime }
            if frames.isEmpty && startTime > .zero {
                // Hold the current value until the zoom starts.
                frames.append(Keyframe(time: .zero, value: a, interpolation: .hold))
            }
            frames.append(Keyframe(time: startTime, value: a, interpolation: .easeInOut))
            frames.append(Keyframe(time: endTime, value: b, interpolation: .easeInOut))
            clip.keyframes[key] = frames.sorted { $0.time < $1.time }
        }
        animate("video.transform.scale", .number(from.scale), .number(target.scale))
        animate("video.transform.position", .point(from.position), .point(target.position))
        video.layoutPreset = nil
        clip.video = video
        p[location].clips[index] = clip
    }

    static func setFormatLayout(_ p: inout Project, _ clipIDs: [String], format: String, slot: PortraitSlot, cutout: Bool?) throws {
        guard let output = p.settings.alternateFormats.first(where: { $0.id == format }) else {
            throw EditError.notFound("output format \(format); add it to settings.alternateFormats first")
        }
        for id in clipIDs {
            let (location, index) = try requireClip(p, id)
            guard p[location].kind == .video else { continue }
            try requireUnlocked(p[location])
            var clip = p[location].clips[index]
            // Stills, text and solids without a known size fill as 16:9.
            var width = Double(p.settings.width)
            var height = Double(p.settings.height)
            if let mediaID = clip.mediaID, let item = p.media(mediaID), let w = item.width, let h = item.height {
                width = Double(w)
                height = Double(h)
            }
            var video = clip.video ?? VideoProperties()
            var override = video.formatOverrides[format] ?? FormatOverride()
            override.transform = Transform.filling(slot, sourceWidth: width, sourceHeight: height, canvasWidth: Double(output.width), canvasHeight: Double(output.height))
            override.crop = Crop()
            override.hidden = false
            if let cutout { override.cutout = cutout }
            video.formatOverrides[format] = override
            clip.video = video
            p[location].clips[index] = clip
        }
    }

    // MARK: - Transitions

    /// Checks a transition against the clips it joins. `ignoring` is the ID
    /// of the transition being replaced, if any.
    static func validateTransition(_ t: Transition, on track: Track, in p: Project, ignoring: String? = nil) throws {
        guard t.duration > .zero else { throw EditError.invalid("transition duration must be positive") }
        let others = track.transitions.filter { $0.id != ignoring }
        let from = try t.fromClipID.map { id -> Clip in
            guard let clip = track.clips.first(where: { $0.id == id }) else {
                throw EditError.notFound("clip \(id) on \"\(track.name)\"")
            }
            return clip
        }
        let to = try t.toClipID.map { id -> Clip in
            guard let clip = track.clips.first(where: { $0.id == id }) else {
                throw EditError.notFound("clip \(id) on \"\(track.name)\"")
            }
            return clip
        }
        if let from, others.contains(where: { $0.fromClipID == from.id }) {
            throw EditError.invalid("clip \(from.id) already has a transition at its end")
        }
        if let to, others.contains(where: { $0.toClipID == to.id }) {
            throw EditError.invalid("clip \(to.id) already has a transition at its start")
        }
        switch (from, to) {
        case (nil, nil):
            throw EditError.invalid("a transition needs fromClipID, toClipID or both")
        case (let from?, let to?):
            guard from.end == to.start else {
                throw EditError.invalid("clips \(from.id) and \(to.id) don't meet, so they can't share a transition")
            }
            let half = Time(flicks: t.duration.flicks / 2)
            guard half <= from.duration, half <= to.duration else {
                throw EditError.invalid("a \(t.duration) transition is longer than one of its clips")
            }

        case (let from?, nil):
            guard t.duration <= from.duration else { throw EditError.invalid("the transition is longer than clip \(from.id)") }
        case (nil, let to?):
            guard t.duration <= to.duration else { throw EditError.invalid("the transition is longer than clip \(to.id)") }
        }
    }

    static func addTransition(_ p: inout Project, trackID: String, _ transition: Transition, sound: TransitionSound? = nil, _ context: inout EditContext) throws {
        let location = try requireTrack(p, trackID)
        try requireUnlocked(p[location])
        guard !p.allIDs.contains(transition.id) else { throw EditError.invalid("ID \(transition.id) is already in use") }
        try validateTransition(transition, on: p[location], in: p)
        if let clipID = transition.soundClipID {
            // A sound already on the timeline, tied to it from now on.
            guard sound == nil else { throw EditError.invalid("give a transition sound or soundClipID, not both") }
            try checkTieable(clipID, in: p)
        }
        for note in heldFrames(transition, on: p[location], in: p) { context.warn(note) }
        p[location].transitions.append(transition)
        context.createdIDs.append(transition.id)
        if let sound { try addTransitionSound(&p, sound, to: transition.id, &context) }
    }

    static func updateTransition(_ p: inout Project, _ transitionID: String, _ patch: JSONValue, _ context: inout EditContext) throws {
        guard let (location, index) = p.location(ofTransition: transitionID) else {
            throw EditError.notFound("transition \(transitionID)")
        }
        try requireUnlocked(p[location])
        try requireObject(patch, forbidden: ["id"], what: "transition")
        guard case .object(var fields) = patch else { return }
        let current = p[location].transitions[index]
        // The sound is changed with `sound`, not by pointing at another
        // clip; sending back the one it has already changes nothing.
        if let clipID = fields.removeValue(forKey: "soundClipID"), clipID != (current.soundClipID.map(JSONValue.string) ?? .null) {
            throw EditError.invalid("change a transition's sound with \"sound\" ({\"mediaID\": ...}, or null for none), not soundClipID")
        }
        let sound = fields.removeValue(forKey: "sound")
        let middle = current.middle(on: p[location])
        let updated = try JSONValue.applyMergePatch(.object(fields), to: current)
        try validateTransition(updated, on: p[location], in: p, ignoring: transitionID)
        for note in heldFrames(updated, on: p[location], in: p) { context.warn(note) }
        p[location].transitions[index] = updated
        if let sound { try patchTransitionSound(&p, transitionID, sound, middleBefore: middle, &context) }
    }

    /// A centred transition plays half its length past each side of the
    /// cut. A clip with no frames there (a file used to its last frame, or
    /// from its first) holds that edge frame instead, as Premiere and
    /// Filmora do, so any cut can take a transition. These say where.
    static func heldFrames(_ t: Transition, on track: Track, in p: Project) -> [String] {
        guard let fromID = t.fromClipID, let toID = t.toClipID,
              let from = track.clips.first(where: { $0.id == fromID }),
              let to = track.clips.first(where: { $0.id == toID }) else { return [] }
        let half = Time(flicks: t.duration.flicks / 2)
        var notes: [String] = []
        if !from.freezeFrame, let limit = p.sourceLimit(for: from) {
            let short = from.sourceEnd + half.scaled(by: from.speed) - limit
            if short > .zero {
                notes.append("\(name(of: from, in: p)) has no frames after its end, so its last frame holds for \(seconds(short.scaled(by: 1 / from.speed))) of the \(t.type.rawValue).")
            }
        }
        // Stills can show any amount of themselves.
        if !to.freezeFrame, let mediaID = to.mediaID, p.media(mediaID)?.kind != .image {
            let short = half.scaled(by: to.speed) - to.sourceStart
            if short > .zero {
                notes.append("\(name(of: to, in: p)) has no frames before its start, so its first frame holds for \(seconds(short.scaled(by: 1 / to.speed))) of the \(t.type.rawValue).")
            }
        }
        return notes
    }

    private static func name(of clip: Clip, in p: Project) -> String {
        if let name = clip.name, !name.isEmpty { return name }
        if let mediaID = clip.mediaID, let item = p.media(mediaID) {
            return URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent
        }
        return "Clip \(clip.id)"
    }

    private static func seconds(_ time: Time) -> String {
        let value = (time.seconds * 100).rounded() / 100
        return value == value.rounded() ? "\(Int(value)) s" : "\(value) s"
    }

    static func removeTransition(_ p: inout Project, _ transitionID: String) throws {
        guard let (location, index) = p.location(ofTransition: transitionID) else {
            throw EditError.notFound("transition \(transitionID)")
        }
        try requireUnlocked(p[location])
        p[location].transitions.remove(at: index)
    }

    // MARK: - Effects and keyframes

    static func addEffect(_ p: inout Project, _ clipID: String, _ effect: Effect, index: Int?, _ context: inout EditContext) throws {
        let (location, clipIndex) = try requireClip(p, clipID)
        try requireUnlocked(p[location])
        var clip = p[location].clips[clipIndex]
        let definition = EffectRegistry.standard.definition(effect.type)
        if definition == nil {
            context.warn("Unknown effect type \"\(effect.type)\". It's kept, but nothing renders it yet.")
        }
        let domain = definition?.domain ?? (p[location].kind == .video ? .video : .audio)
        switch domain {
        case .video:
            guard p[location].kind == .video else {
                throw EditError.invalid("\(effect.type) is a video effect and clip \(clipID) is on an audio track")
            }
            var video = clip.video ?? VideoProperties()
            guard !video.effects.contains(where: { $0.id == effect.id }) else {
                throw EditError.invalid("clip \(clipID) already has effect \(effect.id)")
            }
            video.effects.insert(effect, at: min(max(index ?? video.effects.count, 0), video.effects.count))
            clip.video = video
        case .audio:
            guard p[location].kind == .audio else {
                throw EditError.invalid("\(effect.type) is an audio effect and clip \(clipID) is on a video track")
            }
            var audio = clip.audio ?? AudioProperties()
            guard !audio.effects.contains(where: { $0.id == effect.id }) else {
                throw EditError.invalid("clip \(clipID) already has effect \(effect.id)")
            }
            audio.effects.insert(effect, at: min(max(index ?? audio.effects.count, 0), audio.effects.count))
            clip.audio = audio
        }
        p[location].clips[clipIndex] = clip
        context.createdIDs.append(effect.id)
    }

    /// Runs `body` on the effect list (video or audio) that holds `effectID`.
    static func withEffects(_ p: inout Project, _ clipID: String, _ effectID: String, _ body: (inout [Effect], Int) throws -> Void) throws {
        let (location, clipIndex) = try requireClip(p, clipID)
        try requireUnlocked(p[location])
        var clip = p[location].clips[clipIndex]
        if var video = clip.video, let i = video.effects.firstIndex(where: { $0.id == effectID }) {
            try body(&video.effects, i)
            clip.video = video
        } else if var audio = clip.audio, let i = audio.effects.firstIndex(where: { $0.id == effectID }) {
            try body(&audio.effects, i)
            clip.audio = audio
        } else {
            throw EditError.notFound("effect \(effectID) on clip \(clipID)")
        }
        p[location].clips[clipIndex] = clip
    }

    static func updateEffect(_ p: inout Project, _ clipID: String, _ effectID: String, _ patch: JSONValue) throws {
        try requireObject(patch, forbidden: ["id"], what: "effect")
        try withEffects(&p, clipID, effectID) { effects, i in
            effects[i] = try JSONValue.applyMergePatch(patch, to: effects[i])
        }
    }

    static func removeEffect(_ p: inout Project, _ clipID: String, _ effectID: String) throws {
        try withEffects(&p, clipID, effectID) { effects, i in effects.remove(at: i) }
        // Animations of the removed effect go too.
        if let (location, index) = p.location(ofClip: clipID) {
            let prefixes = ["video.effects.\(effectID).", "audio.effects.\(effectID)."]
            p[location].clips[index].keyframes = p[location].clips[index].keyframes.filter { key, _ in
                !prefixes.contains { key.hasPrefix($0) }
            }
        }
    }

    static func moveEffect(_ p: inout Project, _ clipID: String, _ effectID: String, _ index: Int) throws {
        try withEffects(&p, clipID, effectID) { effects, i in
            let effect = effects.remove(at: i)
            effects.insert(effect, at: min(max(index, 0), effects.count))
        }
    }

    static func setKeyframes(_ p: inout Project, _ clipID: String, _ parameter: String, _ keyframes: [Keyframe], _ context: inout EditContext) throws {
        let (location, index) = try requireClip(p, clipID)
        try requireUnlocked(p[location])
        if !AnimatableParameter.isKnown(parameter) {
            context.warn("\"\(parameter)\" isn't a known animatable parameter, so nothing will use these keyframes.")
        }
        if keyframes.isEmpty {
            p[location].clips[index].keyframes.removeValue(forKey: parameter)
        } else {
            p[location].clips[index].keyframes[parameter] = keyframes.sorted { $0.time < $1.time }
        }
    }

    // MARK: - Markers

    static func addMarker(_ p: inout Project, _ marker: Marker, _ context: inout EditContext) throws {
        guard !p.allIDs.contains(marker.id) else { throw EditError.invalid("ID \(marker.id) is already in use") }
        guard marker.time >= .zero, marker.duration >= .zero else { throw EditError.invalid("markers need a time of 0 or later") }
        p.markers.append(marker)
        p.markers.sort { $0.time < $1.time }
        context.createdIDs.append(marker.id)
    }

    static func updateMarker(_ p: inout Project, _ markerID: String, _ patch: JSONValue) throws {
        guard let index = p.markers.firstIndex(where: { $0.id == markerID }) else { throw EditError.notFound("marker \(markerID)") }
        try requireObject(patch, forbidden: ["id"], what: "marker")
        p.markers[index] = try JSONValue.applyMergePatch(patch, to: p.markers[index])
        p.markers.sort { $0.time < $1.time }
    }

    static func removeMarker(_ p: inout Project, _ markerID: String) throws {
        guard let index = p.markers.firstIndex(where: { $0.id == markerID }) else { throw EditError.notFound("marker \(markerID)") }
        p.markers.remove(at: index)
    }
}
