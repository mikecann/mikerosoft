import Foundation
import TandemAssets
import TandemCore
import TandemMedia

// Section cards at every section marker: `tandem cards`, the `cards` MCP
// tool and POST /v1/cards. A dry run returns the plan unless asked to
// apply; applying adds the cards (the `addSectionCards` command) with the
// section card whooshes from the asset library, as one undo step.

/// The two whooshes that go with the section cards, one for each sweep:
/// soft, airy swishes made with ElevenLabs on 2026-09-30 (the gentlest two
/// of three takes of one prompt, by measurement) and kept in Mike's asset
/// library, so every use is recorded there with its licence. They replaced
/// the first pair, whose whoosh in read as an explosion. A Mac whose
/// library doesn't have them makes silent cards. docs/ASSETS.md has the
/// prompt and the measurements, to make them again elsewhere.
public enum SectionCardSounds {
    public struct Sound: Equatable, Sendable {
        public var assetID: String
        /// Clip gain in dB for speech at -20 LUFS, Tandem's level: each
        /// lands at -35 LUFS over its loudest 400 ms, 15 LU under the voice,
        /// where Mike's own section swipes sit in Decision Models.
        /// `Resolved.levelled(for:)` moves it with a project whose speech
        /// plays elsewhere.
        public var gainDB: Double
        /// Seconds after its sweep starts; nil for the command's default.
        public var offset: Double?
    }

    /// The level the gains are set against: Tandem's speech level.
    public static let speechLevel = AudioLevels.defaultSpeechLoudness

    /// The gentlest: a smooth swell with almost no low end, loudest 0.46 s
    /// in, so starting with the sweep in it peaks as the middle band crosses
    /// the frame. -29.6 LUFS at its loudest.
    public static let whooshIn = Sound(assetID: "elevenlabs:sfx_4jhasduf", gainDB: -5.4, offset: 0)
    /// Its sibling, a touch brighter and lighter, loudest 0.40 s in: it
    /// starts with the sweep out. -26.7 LUFS at its loudest.
    public static let whooshOut = Sound(assetID: "elevenlabs:sfx_k2dvisxs", gainDB: -8.3, offset: 0)

    /// Both sounds copied into a project, ready for `addSectionCards`.
    public struct Resolved: Equatable, Sendable {
        public var media: [MediaItem]
        public var soundIn: SectionCardSound
        public var soundOut: SectionCardSound
        /// The speech level the sounds' gains are set against.
        public var speechLevel: Double

        public init(media: [MediaItem], soundIn: SectionCardSound, soundOut: SectionCardSound, speechLevel: Double = SectionCardSounds.speechLevel) {
            self.media = media
            self.soundIn = soundIn
            self.soundOut = soundOut
            self.speechLevel = speechLevel
        }

        /// The sounds with their gains moved by as much as `project`'s
        /// speech plays above or below the level they're set against
        /// (`AudioLevels.speechLevel(in:)`), so they sit as far under the
        /// voice in every project. An imported edit whose speech plays at
        /// -28.7 LUFS gets them 8.7 dB quieter. Levelling again for the
        /// same project changes nothing.
        public func levelled(for project: Project) -> Resolved {
            let level = AudioLevels.speechLevel(in: project)
            let shift = level - speechLevel
            guard abs(shift) >= 0.05 else { return self }
            var copy = self
            copy.soundIn.gainDB = ((soundIn.gainDB ?? SectionCard.soundGainDB) + shift).roundedToTenth
            copy.soundOut.gainDB = ((soundOut.gainDB ?? SectionCard.soundGainDB) + shift).roundedToTenth
            copy.speechLevel = level
            return copy
        }

        /// The commands that add what the project doesn't have yet, and the
        /// sounds pointing at the media it will have (a media item already
        /// at the copied file, which the folder watcher may have added under
        /// its own ID, is used as it is), levelled for its speech.
        public func prepared(for project: Project) -> (addMedia: [EditCommand], soundIn: SectionCardSound, soundOut: SectionCardSound) {
            let sounds = self.levelled(for: project)
            var commands: [EditCommand] = []
            var ids: [String: String] = [:]
            for item in media {
                if project.media(item.id) != nil {
                    ids[item.id] = item.id
                } else if let existing = project.media.first(where: { $0.path == item.path }) {
                    ids[item.id] = existing.id
                } else {
                    commands.append(.addMedia(item: item))
                    ids[item.id] = item.id
                }
            }
            var soundIn = sounds.soundIn, soundOut = sounds.soundOut
            soundIn.mediaID = ids[soundIn.mediaID] ?? soundIn.mediaID
            soundOut.mediaID = ids[soundOut.mediaID] ?? soundOut.mediaID
            return (commands, soundIn, soundOut)
        }
    }

    /// True when `library` has both sounds' files, without copying anything.
    public static func available(in library: AssetLibrary) -> Bool {
        [whooshIn, whooshOut].allSatisfy { sound in
            guard let asset = try? library.asset(sound.assetID), let file = library.playableURL(for: asset) else { return false }
            return FileManager.default.fileExists(atPath: file.path)
        }
    }

    /// Copies both sounds into the project's `assets/sfx/` and records the
    /// use (for credits), or explains why they aren't there.
    /// (Levelled for Tandem's speech level; `Resolved.levelled(for:)` moves
    /// them for the project's.)
    public static func use(in library: AssetLibrary, folder: ProjectFolder, projectID: String, projectFile: URL?) async throws -> Resolved {
        guard available(in: library) else {
            throw ServiceError(.notFound, "The section card whooshes (\(whooshIn.assetID), \(whooshOut.assetID)) aren't in this Mac's asset library, so the cards are silent. docs/ASSETS.md has how to make them.")
        }
        var media: [MediaItem] = []
        var sounds: [SectionCardSound] = []
        for sound in [whooshIn, whooshOut] {
            let placement = try await library.use(sound.assetID, in: folder, projectID: projectID, projectFile: projectFile)
            guard let item = placement.mediaItem else { throw ServiceError(.internalError, "\(sound.assetID) isn't a sound.") }
            media.append(item)
            sounds.append(SectionCardSound(mediaID: item.id, gainDB: sound.gainDB, offset: sound.offset.map { Time(seconds: $0) }))
        }
        return Resolved(media: media, soundIn: sounds[0], soundOut: sounds[1])
    }
}

public struct CardsRequest: ServiceCall {
    public static let operation = ServiceOperation.cards
    /// Marker IDs to put cards at. Default: every section marker after the
    /// start.
    public var markers: [String]?
    /// Every card's length. Default: each fitted to its words (4 to 7 s,
    /// `SectionCard.fittedDuration(for:)`).
    public var duration: Time?
    /// "Section" or "Tip", shown as "SECTION 1 OF 3" beside the chip.
    public var kicker: String?
    /// The video track for the cards. Default Graphics.
    public var track: String?
    /// Make room at each marker, so the card is a pause (the whole take moves).
    public var insert: Bool?
    /// The whooshes from the asset library. Default true.
    public var sounds: Bool?
    /// Make the edit. Without it this is a dry run that returns the plan.
    public var apply: Bool?
    public var label: String?
    public var author: String?
    public var expectedRevision: Int?

    public init(
        markers: [String]? = nil, duration: Time? = nil, kicker: String? = nil, track: String? = nil,
        insert: Bool? = nil, sounds: Bool? = nil, apply: Bool? = nil,
        label: String? = nil, author: String? = nil, expectedRevision: Int? = nil
    ) {
        self.markers = markers
        self.duration = duration
        self.kicker = kicker
        self.track = track
        self.insert = insert
        self.sounds = sounds
        self.apply = apply
        self.label = label
        self.author = author
        self.expectedRevision = expectedRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markers = try c.decodeIfPresent([String].self, forKey: .markers)
        duration = try c.decodeTime(.duration)
        kicker = try c.decodeIfPresent(String.self, forKey: .kicker)
        track = try c.decodeIfPresent(String.self, forKey: .track)
        insert = try c.decodeIfPresent(Bool.self, forKey: .insert)
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds)
        apply = try c.decodeIfPresent(Bool.self, forKey: .apply)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> CardsResult {
        try await service.cards(self, context: context)
    }
}

public struct PlannedCard: Codable, Equatable, Sendable {
    public var number: String
    public var title: String
    public var subtitle: String?
    public var markerID: String
    /// The marker's time.
    public var at: Time
    public var start: Time
    public var end: Time
    /// A card already at the marker, which is renumbered and keeps its words.
    public var existingClipID: String?
}

public struct CardsResult: Codable, Sendable {
    public var revision: Int
    public var cards: [PlannedCard]
    /// What the new cards sound like.
    public var sounds: String
    /// The batch. A dry run's leaves the sounds out, since they're copied
    /// into the project only when it's applied.
    public var commands: [EditCommand]
    public var applied: ApplyResult?
    public var warnings: [String]
}

extension TandemService {
    public func cards(_ request: CardsRequest, context: CallContext) async throws -> CardsResult {
        let (project, revision) = coordinator.snapshot()
        if let expected = request.expectedRevision, expected != revision {
            throw ServiceError.wrap(EditError.staleRevision(expected: expected, actual: revision))
        }
        let placements: [SectionCard.Placement]
        do {
            placements = try SectionCard.placements(in: project, markerIDs: request.markers, duration: request.duration, kicker: request.kicker)
        } catch {
            throw ServiceError.wrap(error)
        }
        let apply = request.apply == true

        var commands: [EditCommand] = []
        var soundIn: SectionCardSound?
        var soundOut: SectionCardSound?
        let needsSounds = placements.contains { $0.existingClipID == nil }
        var sounds = "no sounds"
        if request.sounds == false {
            sounds = "no sounds (asked for none)"
        } else if !needsSounds {
            sounds = "the cards there keep their sounds"
        } else if let library = cardSoundLibrary() {
            if apply {
                do {
                    let resolved = try await SectionCardSounds.use(in: library, folder: folder, projectID: project.id, projectFile: session.fileURL)
                    let prepared = resolved.prepared(for: project)
                    commands += prepared.addMedia
                    soundIn = prepared.soundIn
                    soundOut = prepared.soundOut
                    sounds = "a whoosh on each sweep, from the asset library, on SFX"
                } catch {
                    sounds = "silent: \(ServiceError.wrap(error).message)"
                }
            } else {
                sounds = SectionCardSounds.available(in: library)
                    ? "a whoosh on each sweep, from the asset library, on SFX (copied into the project when applied)"
                    : "silent: the section card whooshes aren't in this Mac's asset library"
            }
        } else {
            sounds = "silent: the asset library couldn't be opened"
        }
        commands.append(.addSectionCards(
            markerIDs: request.markers, trackID: request.track, duration: request.duration, kicker: request.kicker,
            mode: request.insert == true ? .insert : nil, soundIn: soundIn, soundOut: soundOut
        ))

        let cards = placements.map { placement -> PlannedCard in
            let existing = placement.existingClipID.flatMap { project.clip($0) }
            let props = existing.flatMap { SectionCard.props(of: $0) }
            let title = props.map { $0.title.isEmpty ? placement.marker.name : $0.title } ?? placement.marker.name
            let subtitle = props?.subtitle ?? placement.marker.note
            return PlannedCard(
                number: placement.number, title: title,
                subtitle: (subtitle?.isEmpty ?? true) ? nil : subtitle,
                markerID: placement.marker.id, at: placement.marker.time,
                start: placement.start,
                end: placement.start + placement.duration,
                existingClipID: placement.existingClipID
            )
        }
        let count = cards.count
        let applyRequest = ApplyRequest(
            label: request.label ?? "Add \(count) section card\(count == 1 ? "" : "s")",
            author: request.author, commands: commands,
            expectedRevision: revision, dryRun: !apply
        )
        let applied = try self.apply(applyRequest, context: context)
        return CardsResult(
            revision: revision, cards: cards, sounds: sounds, commands: commands,
            applied: apply ? applied : nil, warnings: applied.warnings
        )
    }
}

extension CardsResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        let mode = applied == nil ? "dry run" : "applied"
        lines.append("\(cards.count) section card\(cards.count == 1 ? "" : "s") (\(mode), revision \(revision)):")
        for card in cards {
            var line = "  \(card.number)  \(card.at)  \"\(card.title)\""
            if let subtitle = card.subtitle { line += " / \"\(subtitle)\"" }
            line += "  card \(card.start)-\(card.end) (\(String(format: "%.1f", (card.end - card.start).seconds)) s)"
            if card.existingClipID != nil { line += "  already there, renumbered" }
            lines.append(line)
        }
        lines.append("Sound: \(sounds).")
        for warning in warnings { lines.append("Warning: \(warning)") }
        if let applied {
            lines.append("Applied as revision \(applied.revision) (\"\(applied.label)\"). Undo with `tandem undo`.")
        } else {
            lines.append("Nothing changed yet. Run again with --apply (or apply: true) to add them.")
        }
        return lines.joined(separator: "\n")
    }
}

private extension Double {
    var roundedToTenth: Double { (self * 10).rounded() / 10 }
}
