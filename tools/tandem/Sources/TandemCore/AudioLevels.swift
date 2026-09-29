import Foundation

/// How Tandem levels sound: which clips are speech, the gain a clip's
/// normalisation adds, and what new clips start with. Placement, the
/// render, the loudness report and the app's Audio tab all use these, so
/// they agree.
///
/// Speech is levelled per take to the project's speech level
/// (`ProjectSettings.speechLoudness`, -20 LUFS unless changed) with no clip
/// gain. Music and sound effects keep plain gains (-31 and -15 dB from the
/// Filmora audit), set by ear against a voice at about that level. The
/// export then brings the whole mix to the loudness target (-14 LUFS) under
/// the true peak ceiling (-1 dBTP), so the speech level sets the balance
/// and how loud the viewer plays, not how loud the video is.
///
/// Why -20 (docs/RENDER.md has the measurements): it's where Mike's voice
/// played in his Filmora cuts, because Filmora's Auto Normalization levels
/// a file to about -24 LUFS before his +2 to +4 dB, so the music and SFX
/// gains keep the balance he mixed. It's the quiet end of the -16 to -20
/// LUFS that AES recommends for speech. And the viewer plays the mix before
/// the master: at -20 his takes stay under 0 dBFS but for a few plosives,
/// where -16 would clip 58 clips of the demo by up to 6 dB.
public enum AudioLevels {
    /// The speech level a project starts with, in LUFS.
    public static let defaultSpeechLoudness = -20.0

    /// The speech levels a project accepts, in LUFS.
    public static let speechLoudnessRange: ClosedRange<Double> = -40 ... -10

    /// Normalising never changes a clip by more than this many dB, so a
    /// file that's nearly silent isn't pushed up into its noise.
    public static let normalizeLimitDB = 30.0

    /// The gain in dB that normalising to `target` adds to a file measured
    /// at `measuredLUFS`: the difference, within ±30 dB. A silent file
    /// (measured as -inf) has nothing to level, so 0. Nil while the file
    /// hasn't been measured. The clip's own `gainDB` is added after it.
    public static func normalizeGainDB(target: Double, measuredLUFS: Double?) -> Double? {
        guard let measured = measuredLUFS else { return nil }
        guard measured.isFinite else { return 0 }
        return min(max(target - measured, -normalizeLimitDB), normalizeLimitDB)
    }

    /// A level for messages: "-20", "-18.5".
    public static func number(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e9 else { return "\(value)" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// About how loud a clip plays, in LUFS: its file's loudness, plus
    /// normalisation and then the clip gain (not fades or gain keyframes).
    /// Nil until the file is measured, and for a silent file.
    public static func playbackLoudness(_ audio: AudioProperties, measuredLUFS: Double?) -> Double? {
        guard let measured = measuredLUFS, measured.isFinite else { return nil }
        let normalise = audio.normalizeTo.flatMap { normalizeGainDB(target: $0, measuredLUFS: measured) } ?? 0
        return measured + normalise + audio.gainDB
    }

    // MARK: - Speech

    /// Media roles whose sound is speech: camera takes, and files with no
    /// clearer role (a rendered intro, a voice-over), which placing sends
    /// to Voice.
    public static let speechRoles: Set<MediaRole> = [.camera, .other]

    /// An audio track that ripples with the take, like Voice: whatever
    /// plays on it is speech. Muted ones count, so their clips are ready
    /// when they're unmuted. (The transcript tools skip muted tracks, since
    /// they want what's heard, and fall back to every audio track when none
    /// ripples with the take; levelling does neither, so a music bed is
    /// never levelled as speech.)
    public static func isSpeechTrack(_ track: Track) -> Bool {
        track.kind == .audio && track.rippleMode == .cut
    }

    /// Whether a clip on `track` is speech: sound from a camera (or
    /// unclassified) file, or any sound on a speech track.
    public static func isSpeech(_ clip: Clip, on track: Track, in project: Project) -> Bool {
        guard track.kind == .audio, let mediaID = clip.mediaID else { return false }
        if isSpeechTrack(track) { return true }
        return project.media(mediaID).map { speechRoles.contains($0.role) } ?? false
    }

    /// Every speech clip, track by track in timeline order.
    public static func speechClips(in project: Project) -> [(track: Track, clip: Clip)] {
        project.audioTracks.flatMap { track in
            track.clips.filter { isSpeech($0, on: track, in: project) }.map { (track, $0) }
        }
    }

    /// True when a clip already sits at `level` with no gain, the way
    /// `normalizeSpeech` leaves it.
    public static func isLevelled(_ clip: Clip, at level: Double) -> Bool {
        let audio = clip.audio ?? AudioProperties()
        return audio.normalizeTo == level && audio.gainDB == 0
    }

    // MARK: - New clips

    /// The sound a clip placed on `track` starts with. Speech is normalised
    /// to the project's speech level with no gain. Music gets Mike's usual
    /// bed, -31 dB with a 2 s fade out, and sound effects -15 dB.
    public static func placedAudio(role: MediaRole, on track: Track, settings: ProjectSettings) -> AudioProperties? {
        if isSpeechTrack(track) || speechRoles.contains(role) {
            return AudioProperties(normalizeTo: settings.speechLoudness)
        }
        switch role {
        case .music: return AudioProperties(gainDB: -31, fadeOut: Time(seconds: 2))
        case .sfx: return AudioProperties(gainDB: -15)
        default: return nil
        }
    }
}
