import Foundation
import TandemAssets
import TandemCore

/// Assets that change a clip rather than going on the timeline: a look (a
/// LUT) grades a picture and a font sets a title's typeface. Media assets
/// are always placed, since swapping a clip's media isn't an edit Tandem
/// has.
enum AssetApplying {
    /// True for kinds that are dropped on a clip instead of placed.
    static func appliesToClips(_ kind: AssetKind) -> Bool {
        kind == .lut || kind == .font
    }

    /// True when `asset` can change `clip`, on a track of `trackKind`:
    /// looks go on pictures (not titles), fonts on titles.
    static func canApply(_ asset: Asset, to clip: Clip, trackKind: TrackKind) -> Bool {
        let isTitle: Bool
        if case .text = clip.content { isTitle = true } else { isTitle = false }
        switch asset.kind {
        case .lut: return trackKind == .video && !isTitle
        case .font: return isTitle
        default: return false
        }
    }

    /// The clips among `ids` that `asset` can change, skipping locked tracks.
    static func targets(for asset: Asset, among ids: [String], in project: Project) -> [String] {
        ids.filter { id in
            guard let location = project.location(ofClip: id), !project[location.track].locked else { return false }
            return canApply(asset, to: project[location.track].clips[location.index], trackKind: location.track.kind)
        }
    }

    /// The edit for one clip once the asset is in the project. A look
    /// replaces the file of a LUT the clip already has rather than stacking
    /// a second one. `family` is the font's family as its file names it,
    /// when that differs from the asset's name.
    static func commands(for placement: AssetPlacement, on clip: Clip, family: String? = nil, effectID: String = IDs.make("fx")) -> [EditCommand] {
        switch placement.asset.kind {
        case .lut:
            guard let path = placement.files.first else { return [] }
            if let existing = clip.video?.effects.first(where: { $0.type == "lut" }) {
                return [.updateEffect(clipID: clip.id, effectID: existing.id, patch: .object([
                    "enabled": .bool(true),
                    "params": .object(["path": .string(path)])
                ]))]
            }
            return [.addEffect(clipID: clip.id, effect: Effect(id: effectID, type: "lut", params: ["path": .string(path), "intensity": .number(1)]))]
        case .font:
            let name = family ?? placement.asset.name
            return [.updateClip(clipID: clip.id, patch: .object(["content": .object(["text": .object(["style": .object(["font": .string(name)])])])]))]
        default:
            return []
        }
    }

    /// The undo label.
    static func label(for asset: Asset, count: Int) -> String {
        if asset.kind == .font {
            return count == 1 ? "Set the title in \(asset.name)" : "Set \(count) titles in \(asset.name)"
        }
        return count == 1 ? "Apply \(asset.name)" : "Apply \(asset.name) to \(count) clips"
    }

    /// What a drag over a clip says it will do.
    static func dropLabel(for asset: Asset, clipName: String) -> String {
        asset.kind == .font ? "Set \(clipName) in \(asset.name)" : "Grade \(clipName) with \(asset.name)"
    }

    /// What a drag says when it isn't over a clip it can change.
    static func dropHint(for asset: Asset) -> String {
        asset.kind == .font ? "Drop on a title" : "Drop on a picture clip"
    }

    /// What double-clicking says with nothing suitable selected.
    static func selectHint(for asset: Asset) -> String {
        asset.kind == .font ? "Select a title to set in \(asset.name)." : "Select a clip to grade with \(asset.name)."
    }
}

/// What Space does: plays and pauses, except over the asset browser, where
/// it opens a big preview of the hovered asset (and closes it again), as
/// Quick Look does in Finder.
enum SpaceKey {
    enum Action: Equatable {
        case playPause
        case open(String)
        case close
    }

    static func action(previewing: String?, hovered: String?) -> Action {
        if let hovered, hovered != previewing { return .open(hovered) }
        if previewing != nil { return .close }
        return .playPause
    }
}

/// The Generate form for ElevenLabs music and sound effects: what it
/// sends, kept to what the API accepts, and what it costs.
struct GenerationForm: Equatable {
    var kind: AssetKind
    var prompt = ""
    var seconds: Double
    var takes = 1
    /// Sound effects only.
    var loop = false
    /// Music only.
    var instrumental = true

    /// Each take is a separate paid request, so a handful at most.
    static let maxTakes = 4

    init(kind: AssetKind) {
        self.kind = kind
        seconds = kind == .music ? 30 : 3
    }

    /// Seconds ElevenLabs makes: sound effects 0.5 to 30, music 3 to 600.
    var range: ClosedRange<Double> { kind == .music ? 3...600 : 0.5...30 }

    var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the form can't be sent yet.
    var problem: String? {
        guard trimmedPrompt.isEmpty else { return nil }
        return kind == .music ? "Describe the music you want." : "Describe the sound you want."
    }

    var request: GenerationRequest {
        GenerationRequest(
            kind: kind,
            prompt: trimmedPrompt,
            duration: min(max(seconds, range.lowerBound), range.upperBound),
            loop: kind == .sfx && loop,
            instrumental: kind == .music ? instrumental : true,
            variations: min(max(takes, 1), Self.maxTakes)
        )
    }

    /// The price before pressing the button. Sound effects are 40 credits
    /// a second when the length is set (the provider's rules); music is
    /// priced by ElevenLabs per request.
    var costNote: String {
        let request = request
        guard kind == .sfx else {
            return request.variations == 1 ? "One paid request." : "\(request.variations) paid requests, one a take."
        }
        let credits = Int(((request.duration ?? 0) * 40 * Double(request.variations)).rounded())
        return "About \(credits) credits, at 40 a second\(request.variations > 1 ? " for each take" : "")."
    }

    /// The ElevenLabs permission a kind needs on the key.
    static func permission(for kind: AssetKind) -> String {
        kind == .music ? "music_generation" : "sound_generation"
    }

    /// Why a kind can't be made right now: ElevenLabs has no key or is
    /// off (`canTry` false), or the key was refused the permission before
    /// (`canTry` true, since it may have been turned on since).
    static func blocker(for kind: AssetKind, status: ProviderStatus?, refused: Set<String>) -> (message: String, canTry: Bool)? {
        guard let status else { return ("ElevenLabs isn't set up in this asset library.", false) }
        guard status.isUsable else { return (status.message ?? "ElevenLabs isn't available.", false) }
        guard refused.contains(permission(for: kind)) else { return nil }
        let what = kind == .music ? "Music is" : "Sound effects are"
        return ("\(what) off for this ElevenLabs key. Turn on the \(permission(for: kind)) permission for the key in ElevenLabs, then try again.", true)
    }
}
