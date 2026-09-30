import Foundation
import TandemAssets
import TandemCore
import TandemMedia

/// The sound each type of transition plays unless Mike picks another: push,
/// slide, cut slide and wipe get the light swoosh he likes on a push, and
/// dissolves, fades and zooms stay silent. Mike's own picks (Tandem >
/// Settings) are kept by the app and passed in as `choices`. Sounds come
/// from the asset library, so their licences and every use are recorded,
/// and are copied into the project's `assets/sfx/` when they're used.
public enum TransitionSoundDefaults {
    /// A library sound effect, set up to play with a transition.
    public struct Sound: Codable, Equatable, Sendable {
        public var assetID: String
        /// Clip gain in dB for speech at Tandem's -20 LUFS, moved with a
        /// project whose speech plays elsewhere (`Resolved.levelled(for:)`).
        public var gainDB: Double
        /// Seconds from the transition's middle to the sound's start, so
        /// its loudest moment lands on the middle, where the motion is
        /// fastest.
        public var offset: Double

        public init(assetID: String, gainDB: Double, offset: Double) {
            self.assetID = assetID
            self.gainDB = gainDB
            self.offset = offset
        }
    }

    /// The level the gains are set against: Tandem's speech level.
    public static let speechLevel = AudioLevels.defaultSpeechLoudness

    /// Where a sound effect's loudest moment sits under the voice: 15 LU,
    /// like the section card whooshes and Mike's own swipes in Decision
    /// Models (docs/ASSETS.md).
    public static let underSpeech = 15.0

    /// "A quick light swoosh sweeping from left to right…", made with
    /// ElevenLabs on 2026-09-29: the one on a push in Mike's ESLint video,
    /// which he asked for on every push. It swells from the left, passes
    /// at 0.39 s (its loudest moment, where it crosses to the right) and
    /// tails off by 0.65 s, so it starts 0.39 s before the middle and
    /// peaks on the cut. Its loudest 400 ms measures -11.7 LUFS, a hard
    /// peak with 114 clipped samples (why it lost its place on the section
    /// card), so -23.3 dB puts it at -35 LUFS, 15 LU under speech at -20.
    public static let lightSwoosh = Sound(assetID: "elevenlabs:sfx_2ybnc2tu", gainDB: -23.3, offset: -0.39)

    /// Sounds measured by hand, used as measured whatever picks them.
    public static let measured: [Sound] = [lightSwoosh]

    /// Tandem's own choice for a type, before Mike's.
    public static func builtIn(_ type: TransitionType) -> Sound? {
        switch type {
        case .push, .slide, .cutSlide, .wipe: return lightSwoosh
        case .dissolve, .fadeToBlack, .fadeFromBlack, .zoom: return nil
        }
    }

    /// What a type plays: Mike's pick when he's made one (an asset ID, or
    /// "" for none), else Tandem's. A pick the library doesn't know plays
    /// nothing. `asset` looks an ID up, `waveform` its peaks.
    public static func sound(for type: TransitionType, choices: [String: String], asset: (String) -> Asset?, waveform: (Asset) -> Waveform?) -> Sound? {
        guard let choice = choices[type.rawValue] else { return builtIn(type) }
        guard !choice.isEmpty else { return nil }
        if let known = measured.first(where: { $0.assetID == choice }) { return known }
        guard let found = asset(choice) else { return nil }
        return sound(for: found, waveform: waveform(found))
    }

    /// Level and timing for any library sound: the measured ones as they
    /// were measured; others 15 LU under speech by the library's loudness
    /// measurement (-15 dB, sound effects' usual, when there isn't one),
    /// with their loudest 50 ms (by the waveform's peaks) on the middle.
    public static func sound(for asset: Asset, waveform: Waveform?) -> Sound {
        if let known = measured.first(where: { $0.assetID == asset.id }) { return known }
        var gain = TransitionSound.defaultGainDB
        if let measured = asset.loudness?.integratedLUFS, measured.isFinite {
            gain = min(max(speechLevel - underSpeech - measured, -40), 6)
        }
        return Sound(assetID: asset.id, gainDB: (gain * 10).rounded() / 10, offset: -loudestMoment(waveform, length: asset.duration))
    }

    /// Seconds from a sound's start to the middle of its loudest 50 ms, by
    /// its peaks (0 without them). A peak held flat (a clipped one) counts
    /// from its middle.
    public static func loudestMoment(_ waveform: Waveform?, length: Double?) -> Double {
        guard let waveform, waveform.samplesPerSecond > 0, !waveform.peaks.isEmpty else { return 0 }
        let peaks = waveform.peaks
        let half = max(0, Int((0.025 * Double(waveform.samplesPerSecond)).rounded()))
        let scores = peaks.indices.map { index in
            peaks[max(0, index - half)...min(peaks.count - 1, index + half)].reduce(0, +)
        }
        let best = scores.max() ?? 0
        let tops = scores.indices.filter { scores[$0] >= best - 1e-6 }
        let index = tops[tops.count / 2]
        let seconds = (Double(index) + 0.5) / Double(waveform.samplesPerSecond)
        return (min(seconds, length ?? seconds) * 100).rounded() / 100
    }

    /// A sound copied into a project, ready for `addTransition`.
    public struct Resolved: Equatable, Sendable {
        public var assetID: String
        public var name: String
        public var media: MediaItem
        public var sound: TransitionSound
        /// The speech level the sound's gain is set against.
        public var speechLevel: Double

        public init(assetID: String, name: String, media: MediaItem, sound: TransitionSound, speechLevel: Double = TransitionSoundDefaults.speechLevel) {
            self.assetID = assetID
            self.name = name
            self.media = media
            self.sound = sound
            self.speechLevel = speechLevel
        }

        /// The gain moved by as much as `project`'s speech plays above or
        /// below the level it's set against (`AudioLevels.speechLevel(in:)`),
        /// so it sits as far under the voice in every project. Levelling
        /// again for the same project changes nothing.
        public func levelled(for project: Project) -> Resolved {
            let level = AudioLevels.speechLevel(in: project)
            let shift = level - speechLevel
            guard abs(shift) >= 0.05 else { return self }
            var copy = self
            copy.sound.gainDB = (((sound.gainDB ?? TransitionSound.defaultGainDB) + shift) * 10).rounded() / 10
            copy.speechLevel = level
            return copy
        }

        /// The command that adds the file when the project doesn't have it
        /// (a media item already at its path, which the folder watcher may
        /// have added under its own ID, is used as it is), and the sound
        /// pointing at it, levelled for the project's speech.
        public func prepared(for project: Project) -> (addMedia: [EditCommand], sound: TransitionSound) {
            var sound = levelled(for: project).sound
            if project.media(media.id) != nil {
                return ([], sound)
            }
            if let existing = project.media.first(where: { $0.path == media.path }) {
                sound.mediaID = existing.id
                return ([], sound)
            }
            return ([.addMedia(item: media)], sound)
        }
    }

    /// True when `library` has the sound's file, without copying anything.
    public static func available(_ sound: Sound, in library: AssetLibrary) -> Bool {
        guard let asset = try? library.asset(sound.assetID), let file = library.playableURL(for: asset) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// Copies the sound into the project's `assets/sfx/` and records the
    /// use (for credits).
    public static func use(_ sound: Sound, in library: AssetLibrary, folder: ProjectFolder, projectID: String, projectFile: URL?) async throws -> Resolved {
        let placement = try await library.use(sound.assetID, in: folder, projectID: projectID, projectFile: projectFile)
        guard let item = placement.mediaItem, item.hasAudio else {
            throw ServiceError(.badRequest, "\(sound.assetID) isn't a sound, so it can't play with a transition.")
        }
        return Resolved(
            assetID: sound.assetID,
            name: placement.asset.name,
            media: item,
            sound: TransitionSound(mediaID: item.id, gainDB: sound.gainDB, offset: Time(seconds: sound.offset))
        )
    }
}
