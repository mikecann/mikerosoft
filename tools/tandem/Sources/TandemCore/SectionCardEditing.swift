import Foundation

/// A sound that goes with each new section card: a media item already in
/// the project, placed on an SFX track when its sweep starts.
public struct SectionCardSound: Codable, Equatable, Sendable {
    public var mediaID: String
    /// Clip gain in dB. Default -15, Mike's usual for sound effects.
    public var gainDB: Double?
    /// When the sound starts, in seconds after its sweep starts. Default
    /// 0.2 for the sweep in (so a whoosh that peaks early lands as the
    /// bands cross the middle) and 0 for the sweep out.
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
}

extension SectionCard {
    /// Sound effects' usual gain.
    public static let soundGainDB = -15.0
    public static let soundInOffset = Time(seconds: 0.2)

    /// One card `addSectionCards` puts at a marker.
    public struct Placement: Equatable, Sendable {
        public var marker: Marker
        /// "01", "02"... in time order.
        public var number: String
        /// Where the card starts: early enough that it hides the whole frame
        /// from the marker on, so the cut between sections is never seen.
        /// On a frame.
        public var start: Time
        /// A section card already over the marker, which is renumbered
        /// instead of getting a new one.
        public var existingClipID: String?
    }

    /// The cards for `markerIDs` (every section marker after the start
    /// when nil), in time order, for cards `duration` long.
    public static func placements(in p: Project, markerIDs: [String]?, duration: Time = defaultDuration) throws -> [Placement] {
        var markers: [Marker]
        if let markerIDs {
            var seen = Set<String>()
            markers = try markerIDs.compactMap { id in
                guard let marker = p.markers.first(where: { $0.id == id }) else { throw EditError.notFound("marker \(id)") }
                return seen.insert(id).inserted ? marker : nil
            }
        } else {
            // A section marker at the very start marks the cold open, which
            // gets no card: there's no shot before it to wipe from.
            markers = p.markers.filter { $0.kind == .section && $0.time > .zero }
        }
        markers.sort { $0.time < $1.time }
        guard !markers.isEmpty else {
            throw EditError.invalid(markerIDs == nil
                ? "there are no section markers after the start to put cards on. Mark where each section starts with a section marker (addMarker with kind section, or a marker's Kind menu in the app)"
                : "no markers given")
        }
        let covered = try coverage(of: duration, in: p)
        let rate = p.settings.frameRate
        return markers.enumerated().map { offset, marker in
            let ideal = marker.time - Time(seconds: covered.lowerBound)
            let start = max(.zero, Time.frames(ideal.frameIndex(at: rate), at: rate))
            return Placement(
                marker: marker,
                number: numberText(offset + 1),
                start: start,
                existingClipID: existingCard(at: marker.time, in: p)?.id
            )
        }
    }

    /// When a card `duration` long hides the whole frame, in seconds from
    /// its start, on this project's canvas.
    static func coverage(of duration: Time, in p: Project) throws -> ClosedRange<Double> {
        guard duration >= Time(seconds: 1) else { throw EditError.invalid("a section card needs at least 1 s") }
        let motion = Motion(duration: duration, width: p.settings.width, height: p.settings.height)
        guard let covered = motion.covered else {
            throw EditError.invalid("a \(String(format: "%.2f", duration.seconds)) s card is too short to cover the frame")
        }
        return covered
    }

    /// A section card on any video track whose time covers `time`.
    public static func existingCard(at time: Time, in p: Project) -> Clip? {
        for track in p.videoTracks {
            if let clip = track.clips.first(where: { isCard($0.content) && $0.range.contains(time) }) { return clip }
        }
        return nil
    }
}

extension Editing {
    /// Puts a numbered section card at section markers. See
    /// `EditCommand.addSectionCards`.
    static func addSectionCards(
        _ p: inout Project,
        markerIDs: [String]?,
        trackID: String?,
        duration: Time?,
        kicker: String?,
        mode: InsertMode,
        soundIn: SectionCardSound?,
        soundOut: SectionCardSound?,
        _ context: inout EditContext
    ) throws {
        let length = duration ?? SectionCard.defaultDuration
        let placements = try SectionCard.placements(in: p, markerIDs: markerIDs, duration: length)
        let covered = try SectionCard.coverage(of: length, in: p)
        let motion = SectionCard.Motion(duration: length, width: p.settings.width, height: p.settings.height)
        let rate = p.settings.frameRate

        // Where the cards go: the named track, else Graphics (made on top if
        // the project has none).
        let cardTrack: TrackLocation
        if let trackID {
            cardTrack = try requireTrack(p, trackID)
            guard cardTrack.kind == .video else { throw EditError.invalid("section cards go on a video track, and \"\(p[cardTrack].name)\" is an audio track") }
        } else if let graphics = p.track(named: "Graphics", kind: .video), let found = p.location(ofTrack: graphics.id) {
            cardTrack = found
        } else {
            try addTrack(&p, kind: .video, name: "Graphics", index: nil, id: nil, &context)
            cardTrack = TrackLocation(kind: .video, index: p.videoTracks.count - 1)
            p[cardTrack].rippleMode = .follow
        }
        try requireUnlocked(p[cardTrack])
        let cardTrackID = p[cardTrack].id

        for sound in [soundIn, soundOut].compactMap({ $0 }) {
            guard let item = p.media(sound.mediaID) else { throw EditError.notFound("media \(sound.mediaID) for the section cards' sound") }
            guard item.hasAudio else { throw EditError.invalid("\(item.path) has no sound, so it can't be a section card's sound") }
        }

        let total = placements.count
        let kickerWord = kicker?.trimmingCharacters(in: .whitespaces)
        if mode != .insert {
            for (a, b) in zip(placements, placements.dropFirst()) where a.existingClipID == nil && b.start < a.start + length {
                context.warn("The sections \"\(a.marker.name)\" and \"\(b.marker.name)\" are closer than a card is long, so the first card cuts into the second one's wipe in.")
            }
        }
        // Latest first, so making room at one marker leaves the earlier
        // ones (and the cards already placed after it) where they belong.
        for placement in placements.reversed() {
            let marker = placement.marker
            // A card already at this marker is renumbered and keeps its own
            // words, colours, length and sounds.
            if let id = placement.existingClipID, let (location, index) = p.location(ofClip: id) {
                try requireUnlocked(p[location])
                var props = SectionCard.props(of: p[location].clips[index]) ?? SectionCard.Props()
                props.number = placement.number
                props.total = total
                if props.title.isEmpty { props.title = marker.name }
                if let kickerWord { props.kicker = kickerWord }
                p[location].clips[index].content = SectionCard.content(props)
                continue
            }

            let props = SectionCard.Props(
                title: marker.name,
                subtitle: (marker.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                number: placement.number,
                total: total,
                kicker: kickerWord ?? ""
            )
            let start = placement.start
            if mode == .insert {
                // Room for the hold: the shot before plays under the wipe in
                // up to the marker, and the next one starts as the wipe out
                // shows it.
                let reveal = start + Time(seconds: covered.upperBound)
                let room = Time.frames((reveal - marker.time).frameIndex(at: rate), at: rate)
                if room > .zero { try insertTime(&p, at: marker.time, duration: room, trackIDs: nil, &context) }
            }
            let group = soundIn != nil || soundOut != nil ? context.makeID("lnk") : nil
            let card = Clip(
                id: context.makeID("clip"),
                content: SectionCard.content(props),
                start: start,
                duration: length,
                linkGroup: group
            )
            guard let location = p.location(ofTrack: cardTrackID) else { throw EditError.notFound("track \(cardTrackID)") }
            if mode == .place, !p[location].isFree(card.range) {
                throw EditError.overlap("\"\(p[location].name)\" already has a clip between \(card.start) and \(card.end), where the card for \"\(marker.name)\" goes")
            }
            p[location].clear(card.range, context: &context)
            p[location].add(card)
            context.createdIDs.append(card.id)

            let sweeps: [(SectionCardSound?, Time, Time)] = [
                (soundIn, start + Time(seconds: motion.inStart(0)), SectionCard.soundInOffset),
                (soundOut, start + Time(seconds: motion.outStart(0)), .zero)
            ]
            for case let (sound?, sweep, defaultOffset) in sweeps {
                try placeCardSound(&p, sound, at: max(.zero, sweep + (sound.offset ?? defaultOffset)), group: group, &context)
            }
        }
    }

    /// Puts a card's sound on the first SFX track that's free then ("SFX",
    /// "SFX 2"...), making the next one when none is, so no sound already
    /// there is cut.
    static func placeCardSound(_ p: inout Project, _ sound: SectionCardSound, at start: Time, group: String?, _ context: inout EditContext) throws {
        guard let item = p.media(sound.mediaID) else { throw EditError.notFound("media \(sound.mediaID)") }
        let length = item.duration.flatMap { $0 > .zero ? $0 : nil } ?? Time(seconds: 1)
        let range = TimeRange(start: start, duration: length)
        func isSFX(_ name: String) -> Bool {
            let lower = name.lowercased()
            return lower == "sfx" || (lower.hasPrefix("sfx ") && Int(lower.dropFirst(4)) != nil)
        }
        let candidates = p.audioTracks.indices.filter { isSFX(p.audioTracks[$0].name) }
        var index = candidates.first { !p.audioTracks[$0].locked && p.audioTracks[$0].isFree(range) }
        if index == nil {
            let name = candidates.isEmpty ? "SFX" : "SFX \(candidates.count + 1)"
            try addTrack(&p, kind: .audio, name: name, index: nil, id: nil, &context)
            index = p.audioTracks.count - 1
            p.audioTracks[index!].rippleMode = .follow
        }
        let clip = Clip(
            id: context.makeID("clip"),
            content: .media(mediaID: item.id),
            start: start,
            duration: length,
            linkGroup: group,
            audio: AudioProperties(gainDB: sound.gainDB ?? SectionCard.soundGainDB)
        )
        try checkSource(clip, in: p)
        p.audioTracks[index!].add(clip)
        context.createdIDs.append(clip.id)
    }
}
