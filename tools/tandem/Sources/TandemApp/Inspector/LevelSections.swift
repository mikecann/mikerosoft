import SwiftUI
import TandemCore

/// The Audio tab's Level section: the clip's gain, mute and normalise
/// switch, what its file measured and what normalising adds to it, and a
/// line on how the two combine.
struct LevelSection: View {
    let model: EditorModel
    /// The audio clips being edited. The first one's values show; changes
    /// go to all of them.
    let targets: [Clip]

    var body: some View {
        let first = targets[0]
        let audio = first.audio ?? AudioProperties()
        let ids = targets.map(\.id)
        let noun = targets.count == 1 ? "clip" : "\(targets.count) clips"
        let settings = model.project.settings
        // Animated gain follows the playhead.
        let gain = first.keyframes["audio.gainDB"] == nil ? audio.gainDB : first.resolvedAudio(at: model.clipTime(of: first)).gainDB
        let loudness = model.media(for: first).flatMap { model.session.analysis.loudness(for: $0) }
        var shown = audio
        shown.gainDB = gain
        return InspectorSection(title: "Level", icon: Icons.level) {
            SliderRow(label: "Gain", value: gain, range: -60...12, bipolar: true, valueWidth: 62,
                      format: { AudioLevelText.minus(String(format: "%+.1f dB", $0)) },
                      parse: { Double($0.replacingOccurrences(of: "−", with: "-").filter { "-+0123456789.".contains($0) }) },
                      accessory: targets.count == 1 ? AnyView(KeyframeButton(model: model, clip: first, parameter: "audio.gainDB")) : nil,
                      onCommit: { value in
                          let db = (value * 10).rounded() / 10
                          if targets.count == 1 {
                              model.setParameter("audio.gainDB", to: .number(db), in: first, label: "Gain") { InspectorEdits.audio(ids, ["gainDB": .number(db)], label: "Gain") }
                          } else {
                              model.apply(InspectorEdits.audio(ids, ["gainDB": .number(db)], label: "Gain"))
                          }
                      })
                .help("Clip gain in dB, added after normalising. 0 leaves the \(noun) at the level Normalise sets.")
            switchRow("Muted", value: audio.muted ? "Yes" : "No", isOn: audio.muted,
                      help: audio.muted ? "Muted: this \(noun) plays nothing. Click to hear it again." : "Silences this \(noun) without removing it.") {
                model.apply(InspectorEdits.audio(ids, ["muted": .bool(!audio.muted)], label: audio.muted ? "Unmute \(noun)" : "Mute \(noun)"))
            }
            switchRow("Normalise", value: audio.normalizeTo.map { "to \(AudioLevelText.lufs($0))" } ?? "Off", isOn: audio.normalizeTo != nil,
                      help: AudioLevelText.normaliseHelp(normalizeTo: audio.normalizeTo, speechLevel: settings.speechLoudness)) {
                let value: JSONValue = audio.normalizeTo == nil ? .number(settings.speechLoudness) : .null
                model.apply(InspectorEdits.audio(ids, ["normalizeTo": value], label: audio.normalizeTo == nil ? "Normalise \(noun)" : "Stop normalising \(noun)"))
            }
            if let measured = AudioLevelText.measured(lufs: loudness?.integratedLUFS, peak: loudness?.truePeakDBTP, normalizeTo: audio.normalizeTo) {
                InfoRow(label: "Measured", value: measured)
                    .help("The file's integrated loudness (EBU R128), measured in the background, and the gain normalising adds to reach its level (at most ±30 dB). A take is levelled as a whole, so every cut of it gets the same gain.")
            }
            if audio.normalizeTo != nil || gain != 0, let plays = AudioLevels.playbackLoudness(shown, measuredLUFS: loudness?.integratedLUFS) {
                InfoRow(label: "Plays at", value: "about \(AudioLevelText.lufs(plays, decimals: 1))")
                    .help("Measured loudness, plus normalising, plus gain: how loud this \(noun) plays in the viewer. Export then turns the whole mix up or down to \(AudioLevelText.lufs(settings.loudnessTarget)).")
            }
            Text(AudioLevelText.combineNote(settings))
                .font(.ui(11))
                .foregroundStyle(Theme.textFaint.color)
                .fixedSize(horizontal: false, vertical: true)
                .help("Normalise and Gain make one level per clip, and the viewer, review clips and export all play it the same.")
        }
    }

    private func switchRow(_ label: String, value: String, isOn: Bool, help: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.ui(12))
                .foregroundStyle(Theme.text.color)
            Spacer()
            GraphiteSwitch(isOn: isOn, action: action)
        }
        .contentShape(Rectangle())
        .help(help)
    }
}

/// The project's speech level, which every speech clip is normalised to,
/// and the button that sets them all to it.
struct SpeechLevelSection: View {
    let model: EditorModel

    var body: some View {
        let project = model.project
        let level = project.settings.speechLoudness
        let speech = AudioLevels.speechClips(in: project)
        let unlevelled = speech.filter { !AudioLevels.isLevelled($0.clip, at: level) }.count
        return InspectorSection(title: "Project speech level", icon: Icons.speechLevel) {
            SliderRow(label: "Level", value: level, range: AudioLevels.speechLoudnessRange, valueWidth: 70,
                      format: { AudioLevelText.lufs(($0 * 2).rounded() / 2) },
                      parse: { Double($0.replacingOccurrences(of: "−", with: "-").filter { "-+0123456789.".contains($0) }) },
                      onCommit: { value in
                          let rounded = (value * 2).rounded() / 2
                          guard rounded != level else { return }
                          model.apply(EditBatch(
                              label: "Speech level \(AudioLevelText.lufs(rounded))",
                              commands: [.updateSettings(patch: .object(["speechLoudness": .number(rounded)]))]
                          ))
                      })
                .help("The level speech is normalised to, for the whole project. Camera and voice clips get it when they're placed, and so does every clip Normalise speech clips sets. Changing it moves the clips normalised to the old level. Export still brings the mix to \(AudioLevelText.lufs(project.settings.loudnessTarget)).")
            Text(AudioLevelText.speechStatus(speech: speech.count, unlevelled: unlevelled, level: level))
                .font(.ui(11.5))
                .foregroundStyle(Theme.textMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .help("Speech clips are the camera's sound, voice files, and anything on a take track like Voice.")
            OutlineButton(title: "Normalise speech clips") {
                model.apply(EditBatch(label: "Normalise speech clips", commands: [.normalizeSpeech]))
            }
            .disabled(unlevelled == 0)
            .opacity(unlevelled == 0 ? 0.45 : 1)
            .help("Sets every speech clip to \(AudioLevelText.lufs(level)) with no gain, as one undo step. Music and sound effects keep their gains.")
        }
    }
}

/// Words and numbers for the Audio tab's levels, with real minus signs.
enum AudioLevelText {
    static func minus(_ text: String) -> String {
        text.replacingOccurrences(of: "-", with: "−")
    }

    /// "−20 LUFS", "−18.5 LUFS"; with `decimals: 1`, "−18.0 LUFS".
    static func lufs(_ value: Double, decimals: Int? = nil) -> String {
        minus("\(number(value, decimals: decimals)) LUFS")
    }

    /// "+12.2 dB", "−3.5 dB", "0 dB".
    static func gain(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == 0 ? "0 dB" : minus(String(format: "%+.1f dB", rounded))
    }

    static func number(_ value: Double, decimals: Int? = nil) -> String {
        if let decimals { return String(format: "%.\(decimals)f", value) }
        return value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// The Measured row: the file's loudness and, when the clip is
    /// normalised, the gain that adds and the level it reaches, like
    /// "−32.2 LUFS · +12.2 dB to −20". Nil hides the row.
    static func measured(lufs: Double?, peak: Double?, normalizeTo target: Double?) -> String? {
        guard let lufs else { return target == nil ? nil : "Not measured yet, so not levelled" }
        guard lufs.isFinite else { return target == nil ? "Silent" : "Silent, nothing to level" }
        guard let target else {
            return minus(String(format: "%.1f LUFS · peak %.1f dBTP", lufs, peak ?? lufs))
        }
        let added = AudioLevels.normalizeGainDB(target: target, measuredLUFS: lufs) ?? 0
        let capped = abs(target - lufs) > AudioLevels.normalizeLimitDB ? " (the most it adds)" : ""
        return minus(String(format: "%.1f LUFS · ", lufs)) + gain(added) + capped + " to " + minus(number(target))
    }

    static func normaliseHelp(normalizeTo: Double?, speechLevel: Double) -> String {
        guard let normalizeTo else {
            return "Levels this clip to the project's speech level, \(lufs(speechLevel)), from its file's measured loudness. Gain is added after it."
        }
        if normalizeTo == speechLevel {
            return "Levelled to the project's speech level from its file's measured loudness; Gain is added after it. Click to play the file at its own level."
        }
        return "Levelled to \(lufs(normalizeTo)), not the project's speech level (\(lufs(speechLevel))). Switch it off and on, or use Normalise speech clips, to move it."
    }

    /// How gain and normalise combine, under the Level section.
    static func combineNote(_ settings: ProjectSettings) -> String {
        "Normalise sets the clip's level from its file's measured loudness, then Gain is added on top. Export brings the whole mix to \(lufs(settings.loudnessTarget)) with peaks under \(minus(number(settings.truePeakCeiling))) dBTP."
    }

    /// "All 229 speech clips are at −20 LUFS." or "96 of 229 speech clips
    /// have their own gain or level."
    static func speechStatus(speech: Int, unlevelled: Int, level: Double) -> String {
        if speech == 0 { return "No speech clips on the timeline yet." }
        if unlevelled == 0 {
            return speech == 1 ? "The speech clip is at \(lufs(level))." : "All \(speech) speech clips are at \(lufs(level))."
        }
        if speech == 1 { return "The speech clip has its own gain or level." }
        return unlevelled == 1 ? "1 of \(speech) speech clips has its own gain or level." : "\(unlevelled) of \(speech) speech clips have their own gain or level."
    }
}
