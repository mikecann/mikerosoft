import SwiftUI
import TandemAPI
import TandemAssets
import TandemCore

/// The transition inspector's sound: which one (none, its type's, or a
/// sound effect from the library) and how loud. The sound is a clip on
/// SFX, so it can be nudged and trimmed there too.
struct TransitionSoundRows: View {
    let model: EditorModel
    let transition: TandemCore.Transition
    @State private var choices: [Asset] = []

    private var clip: Clip? { transition.soundClipID.flatMap { model.project.clip($0) } }

    var body: some View {
        HStack(spacing: 10) {
            Text("Sound")
                .font(.ui(12))
                .foregroundStyle(Theme.textMuted.color)
                .frame(width: SliderRow.labelWidth, alignment: .leading)
                .tip(TransitionSoundText.soundRowTip)
            Menu(clip.map { TransitionTips.soundName($0, in: model.project) } ?? "None") {
                Button("None") { TransitionSoundActions.setSound(.none, of: transition.id, in: model) }
                    .disabled(clip == nil)
                Button(TransitionSoundText.defaultItem(transition.type, choices: choices)) {
                    TransitionSoundActions.setSound(.typeDefault, of: transition.id, in: model)
                }
                if !choices.isEmpty {
                    Divider()
                    Section("Sound effects") {
                        ForEach(choices, id: \.id) { asset in
                            Button(asset.name) { TransitionSoundActions.setSound(.asset(asset), of: transition.id, in: model) }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tip(TransitionSoundText.soundMenuTip(transition.type))
            if let clip {
                IconButton(symbol: "scope", help: "Select the sound's clip on \(model.project.track(containingClip: clip.id)?.name ?? "SFX"), to nudge or trim it (, and . nudge)") {
                    model.selectedTransitionID = nil
                    model.selection = [clip.id]
                    model.inspectorTab = .audio
                }
            }
        }
        .task(id: transition.id) { choices = await TransitionSoundActions.choices() }
        if let clip {
            SliderRow(
                label: "Sound level", value: clip.audio?.gainDB ?? 0, range: -40...6, valueWidth: 60,
                format: { String(format: "%.1f dB", $0).replacingOccurrences(of: "-", with: "−") },
                help: "How loud the sound plays, in dB. Its type's sound starts 15 LU under the voice, like the section card whooshes.",
                step: 0.1
            ) { gain in
                TransitionSoundActions.setGain(gain, of: transition.id, in: model)
            }
        }
    }
}

/// Words about transition sounds for tips, menus and Settings.
@MainActor
enum TransitionSoundText {
    static let soundRowTip = "A sound effect that plays with the transition: a clip on SFX that moves with it and goes when it goes"

    static func soundMenuTip(_ type: TransitionType) -> String {
        "None, the \(type.displayName.lowercased())'s own sound (Tandem > Settings picks it), or a favourite or recently used sound effect from the library"
    }

    /// "Push's own: Light swoosh", or "Dissolve's own: none".
    static func defaultItem(_ type: TransitionType, choices: [Asset]) -> String {
        "\(type.displayName)'s own: \(name(of: assetID(for: type), choices: choices))"
    }

    /// What a type plays: Mike's pick, else Tandem's, "" for none.
    static func assetID(for type: TransitionType) -> String {
        TransitionSoundActions.settings.choice(for: type) ?? TransitionSoundDefaults.builtIn(type)?.assetID ?? ""
    }

    /// A sound's name as the pickers show it: "Light swoosh" for the one
    /// Tandem ships with, else its name in the library, or "none".
    static func name(of assetID: String, choices: [Asset]) -> String {
        if assetID.isEmpty { return "none" }
        if assetID == TransitionSoundDefaults.lightSwoosh.assetID { return "Light swoosh" }
        return choices.first { $0.id == assetID }?.name ?? AssetLibraryHost.shared.library.flatMap { try? $0.asset(assetID) }?.name ?? assetID
    }

    /// The Effects tab's tile.
    static func tileTip(_ type: TransitionType) -> String {
        let length = String(format: "%.2f s", type.defaultDuration.seconds)
        let choice = assetID(for: type)
        let sound = choice.isEmpty ? "" : " with \(name(of: choice, choices: []).lowercased())"
        return "\(type.displayName), \(length)\(sound). Double-click for the cut nearest the playhead, or drag onto a cut. Tandem > Settings picks each type's sound."
    }
}
