import AppKit
import Foundation
import TandemAPI
import TandemAssets
import TandemCore

/// Mike's picks for the sound each type of transition plays, over Tandem's
/// own (`TransitionSoundDefaults`), from Tandem > Settings: asset IDs by
/// type name, "" for none. Kept in the app's preferences, like export
/// speed.
struct TransitionSoundSettings {
    static let key = "transitionSounds"
    var store: UserDefaults = AppDefaults.store

    var choices: [String: String] {
        store.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// What `type` plays: Mike's pick, else Tandem's. A pick is looked up
    /// in `library`, so without it only the sounds measured by hand play.
    func sound(for type: TransitionType, library: AssetLibrary?) -> TransitionSoundDefaults.Sound? {
        TransitionSoundDefaults.sound(
            for: type, choices: choices,
            asset: { id in library.flatMap { try? $0.asset(id) } ?? nil },
            waveform: { asset in library?.waveform(for: asset) }
        )
    }

    /// Mike's pick for `type`: an asset ID, "" for none, or nil when he
    /// hasn't picked (Tandem's then).
    func choice(for type: TransitionType) -> String? {
        choices[type.rawValue]
    }

    /// Picks `assetID` for `type` ("" for none); nil goes back to Tandem's.
    func set(_ assetID: String?, for type: TransitionType) {
        var all = choices
        all[type.rawValue] = assetID
        store.set(all, forKey: Self.key)
    }
}

/// Transition sounds already copied into a project, by folder and asset,
/// so a drop can add its sound at once: a drop builds its edit there and
/// then, so the tile copies the sound in when a drag starts (an APFS
/// clone, done long before the drop).
@MainActor
final class TransitionSoundCache {
    static let shared = TransitionSoundCache()
    private var ready: [URL: [String: TransitionSoundDefaults.Resolved]] = [:]

    func sound(_ assetID: String, for model: EditorModel) -> TransitionSoundDefaults.Resolved? {
        guard let resolved = ready[model.folder.root]?[assetID],
              FileManager.default.fileExists(atPath: model.folder.url(forPath: resolved.media.path).path) else { return nil }
        return resolved
    }

    func set(_ resolved: TransitionSoundDefaults.Resolved, for model: EditorModel) {
        ready[model.folder.root, default: [:]][resolved.assetID] = resolved
    }
}

/// Transitions with their sounds, in the app: dropped or double-clicked
/// from Effects, Cmd-D, a new type, and the inspector's Sound menu. Each
/// brings its sound in from the asset library first (`library.use`, so
/// it's in `assets/sfx/` and credited), then makes one edit.
@MainActor
enum TransitionSoundActions {
    static var settings = TransitionSoundSettings()

    /// A type's sound as far as it could be got: what it plays, and that
    /// copied into the project, which is nil when it plays nothing or this
    /// Mac's library doesn't have it (`missing`).
    struct Prepared {
        var sound: TransitionSoundDefaults.Sound?
        var resolved: TransitionSoundDefaults.Resolved?
        var missing: Bool { sound != nil && resolved == nil }
    }

    static func prepare(_ type: TransitionType, in model: EditorModel) async -> Prepared {
        let library = await SectionCardActions.library()
        guard let sound = settings.sound(for: type, library: library) else { return Prepared() }
        return Prepared(sound: sound, resolved: await resolve(sound, in: model, library: library))
    }

    /// Copies a sound into the model's project, once. A copy already on
    /// its way (a drag's, when the drop comes before it's done) is waited
    /// for rather than made again, so the library records one use.
    static func resolve(_ sound: TransitionSoundDefaults.Sound, in model: EditorModel, library: AssetLibrary?) async -> TransitionSoundDefaults.Resolved? {
        if let ready = TransitionSoundCache.shared.sound(sound.assetID, for: model) { return ready }
        guard let library else { return nil }
        let key = model.folder.root.path + "\n" + sound.assetID
        if let running = copying[key] { return await running.value }
        let copy = Task { @MainActor () -> TransitionSoundDefaults.Resolved? in
            guard let resolved = try? await TransitionSoundDefaults.use(sound, in: library, folder: model.folder, projectID: model.project.id, projectFile: model.fileURL) else { return nil }
            TransitionSoundCache.shared.set(resolved, for: model)
            return resolved
        }
        copying[key] = copy
        let resolved = await copy.value
        copying[key] = nil
        return resolved
    }

    /// Copies under way, by project folder and asset.
    private static var copying: [String: Task<TransitionSoundDefaults.Resolved?, Never>] = [:]

    /// What each type plays, Mike's picks over Tandem's, as far as this
    /// Mac's library knows them: for a drop on a transition, whose sound
    /// follows its type.
    static func soundFor() -> (TransitionType) -> TransitionSoundDefaults.Sound? {
        let settings = settings
        let library = AssetLibraryHost.shared.library
        return { settings.sound(for: $0, library: library) }
    }

    /// A drag of a transition's tile has started: have its sound ready
    /// for the drop.
    static func prepareForDrop(_ type: TransitionType, in model: EditorModel) {
        Task { _ = await prepare(type, in: model) }
    }

    /// The sound a drop can use right away, for its preview.
    static func cached(_ type: TransitionType, in model: EditorModel) -> TransitionSoundDefaults.Resolved? {
        settings.sound(for: type, library: AssetLibraryHost.shared.library).flatMap { TransitionSoundCache.shared.sound($0.assetID, for: model) }
    }

    /// A transition of `type` on the cut nearest `time` (on `trackID`, or
    /// with `anyTrack` on any track when that has none in reach, as a
    /// double-click in Effects does), with its sound, as one undo step. A
    /// cut that has one already gets the new type.
    static func add(_ type: TransitionType, at time: Time, trackID: String?, anyTrack: Bool = false, in model: EditorModel) {
        Task {
            let prepared = await prepare(type, in: model)
            let soundFor = soundFor()
            let project = model.project
            guard let batch = LibraryDrops.transition(type, at: time, trackID: trackID, in: project, sound: prepared.resolved, soundFor: soundFor)
                    ?? (trackID == nil || !anyTrack ? nil : LibraryDrops.transition(type, at: time, trackID: nil, in: project, sound: prepared.resolved, soundFor: soundFor)) else {
                model.show(.info, "Put the playhead on a cut between two clips.")
                return
            }
            finish(batch, type: type, prepared: prepared, in: model)
        }
    }

    /// Cmd-D: a dissolve (or whatever it's bound to add) on the cut nearest
    /// the playhead, with its sound. False when there's no cut there.
    @discardableResult
    static func addDefault(in model: EditorModel) -> Bool {
        let playhead = model.playback.time
        let selection = model.selection
        guard TimelineEdits.addDefaultTransition(model.project, playhead: playhead, selection: selection) != nil else {
            model.show(.info, "Put the playhead on a cut between two clips.")
            return false
        }
        Task {
            let prepared = await prepare(.dissolve, in: model)
            guard let batch = TimelineEdits.addDefaultTransition(model.project, playhead: playhead, selection: selection, sound: prepared.resolved) else { return }
            finish(batch, type: .dissolve, prepared: prepared, in: model)
        }
        return true
    }

    /// Applies a transition's edit, picks the transition and says when
    /// its sound couldn't come.
    private static func finish(_ batch: EditBatch, type: TransitionType, prepared: Prepared, in model: EditorModel) {
        guard let result = model.apply(batch) else { return }
        let id = result.createdIDs.first { $0.hasPrefix("tr_") } ?? batch.commands.lazy.compactMap { command -> String? in
            if case .updateTransition(let id, _) = command { return id }
            return nil
        }.first
        if let id {
            model.selection = []
            model.selectedTransitionID = id
        }
        if prepared.missing {
            model.show(.info, "The \(type.displayName.lowercased())'s sound isn't in this Mac's asset library, so it's silent. Pick another in Tandem > Settings.")
        }
    }

    /// Picks made on each transition still bringing their sounds in, so
    /// the next waits its turn: picks land in the order they were made,
    /// whichever sound took longest to come.
    private static var pending: [String: (turn: Int, task: Task<Void, Never>)] = [:]
    private static var turns = 0

    /// Runs `work` on `transitionID` after the picks before it.
    private static func inTurn(_ transitionID: String, _ work: @escaping @MainActor () async -> Void) {
        turns += 1
        let turn = turns
        let before = pending[transitionID]?.task
        let task = Task { @MainActor in
            await before?.value
            await work()
            if pending[transitionID]?.turn == turn { pending[transitionID] = nil }
        }
        pending[transitionID] = (turn, task)
    }

    /// Waits for every pick still bringing its sound in (for tests).
    static func settle() async {
        while let task = pending.values.first?.task { await task.value }
    }

    /// A new type for a transition (its inspector, its menu): its sound
    /// follows the type when it had none or its old type's.
    static func changeType(_ transitionID: String, to type: TransitionType, in model: EditorModel) {
        inTurn(transitionID) {
            let library = await SectionCardActions.library()
            let newSound = settings.sound(for: type, library: library)
            let resolved: TransitionSoundDefaults.Resolved?
            if let newSound { resolved = await resolve(newSound, in: model, library: library) } else { resolved = nil }
            guard let location = model.project.location(ofTransition: transitionID) else { return }
            let transition = model.project[location.track].transitions[location.index]
            guard transition.type != type else { return }
            let commands = TransitionSoundEdits.typeChange(
                transition, to: type, in: model.project,
                oldSound: settings.sound(for: transition.type, library: library), newSound: newSound, resolved: resolved
            )
            model.apply(EditBatch(label: "Change to \(type.displayName.lowercased())", commands: commands))
        }
    }

    /// What the inspector's Sound menu can set.
    enum Choice {
        case none
        /// Its type's sound.
        case typeDefault
        case asset(Asset)
    }

    static func setSound(_ choice: Choice, of transitionID: String, in model: EditorModel) {
        guard model.project.location(ofTransition: transitionID) != nil else { return }
        switch choice {
        case .none:
            let none: @MainActor () -> Void = {
                apply(nil, to: transitionID, label: "No transition sound", in: model)
            }
            // At once, unless a pick before it is still on its way.
            if pending[transitionID] == nil { none() } else { inTurn(transitionID) { none() } }
        case .typeDefault:
            inTurn(transitionID) {
                // Its type now, after any type change picked before.
                guard let location = model.project.location(ofTransition: transitionID) else { return }
                let type = model.project[location.track].transitions[location.index].type
                let prepared = await prepare(type, in: model)
                if prepared.missing {
                    model.show(.info, "The \(type.displayName.lowercased())'s sound isn't in this Mac's asset library.")
                    return
                }
                apply(prepared.resolved, to: transitionID, label: "Transition sound", in: model)
            }
        case .asset(let asset):
            inTurn(transitionID) {
                guard let library = await SectionCardActions.library() else { return }
                let sound = TransitionSoundDefaults.sound(for: asset, waveform: library.waveform(for: asset))
                guard let resolved = await resolve(sound, in: model, library: library) else {
                    model.show(.error, "Couldn't bring \(asset.name) into the project.")
                    return
                }
                apply(resolved, to: transitionID, label: "Transition sound", in: model)
            }
        }
    }

    /// Gives a transition `resolved` as its sound (none when nil), with
    /// the file added first when the project hasn't got it.
    private static func apply(_ resolved: TransitionSoundDefaults.Resolved?, to transitionID: String, label: String, in model: EditorModel) {
        // Deleted while its sound was on its way: nothing to do.
        guard model.project.location(ofTransition: transitionID) != nil else { return }
        guard let resolved else {
            model.apply(EditBatch(label: label, commands: [.updateTransition(transitionID: transitionID, patch: .object(["sound": .null]))]))
            return
        }
        let prepared = resolved.prepared(for: model.project)
        guard let sound = try? JSONValue.from(prepared.sound) else { return }
        model.apply(EditBatch(label: label, commands: prepared.addMedia + [.updateTransition(transitionID: transitionID, patch: .object(["sound": sound]))]))
    }

    /// The inspector's gain.
    static func setGain(_ gain: Double, of transitionID: String, in model: EditorModel) {
        model.apply(EditBatch(label: "Transition sound level", commands: [
            .updateTransition(transitionID: transitionID, patch: .object(["sound": .object(["gainDB": .number(gain)])]))
        ]))
    }

    /// The sounds the pickers offer: the library's favourite and recently
    /// used sound effects, and the ones measured by hand, by name. None
    /// under tests, which never open Mike's library.
    static func choices() async -> [Asset] {
        guard !AssetLibraryHost.isTesting, let library = await SectionCardActions.library() else { return [] }
        let host = AssetLibraryHost.shared
        var found = await host.search(.favourites([.sfx]))
        found += await host.search(.recentlyUsed([.sfx], limit: 30))
        for sound in TransitionSoundDefaults.measured {
            if let asset = try? library.asset(sound.assetID) { found.append(asset) }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Plays a library sound, to hear a pick before making it.
    static func preview(_ assetID: String) {
        guard let library = AssetLibraryHost.shared.library, let asset = try? library.asset(assetID),
              let file = library.playableURL(for: asset) else { return }
        NSSound(contentsOf: file, byReference: true)?.play()
    }
}

/// How a transition's sound follows its type (a drop on it, the Type
/// menus): it takes the new type's sound when it has none or has its old
/// type's, while a sound Mike picked for it stays.
enum TransitionSoundEdits {
    /// The commands that make `transition` a `type`: the file to add, if
    /// any, then one `updateTransition`. `oldSound` and `newSound` are what
    /// the types play; `resolved` is `newSound` in the project (nil when it
    /// couldn't come, which leaves the sound alone).
    static func typeChange(_ transition: Transition, to type: TransitionType, in project: Project, oldSound: TransitionSoundDefaults.Sound?, newSound: TransitionSoundDefaults.Sound?, resolved: TransitionSoundDefaults.Resolved?) -> [EditCommand] {
        var fields: [String: JSONValue] = ["type": .string(type.rawValue)]
        var commands: [EditCommand] = []
        let current = transition.soundClipID.flatMap { project.clip($0) }
        let follows = current == nil || (oldSound.map { plays(current, $0.assetID, in: project) } ?? false)
        if follows, !(newSound.map { plays(current, $0.assetID, in: project) } ?? false) {
            if newSound == nil {
                if current != nil { fields["sound"] = .null }
            } else if let resolved {
                let prepared = resolved.prepared(for: project)
                commands += prepared.addMedia
                fields["sound"] = try? JSONValue.from(prepared.sound)
            }
        }
        commands.append(.updateTransition(transitionID: transition.id, patch: .object(fields)))
        return commands
    }

    /// Whether `clip` plays the library asset `assetID`'s file: by the
    /// media ID using it gives, or by the code in the file's name where the
    /// folder watcher added it first under its own ID.
    static func plays(_ clip: Clip?, _ assetID: String, in project: Project) -> Bool {
        guard let mediaID = clip?.mediaID else { return false }
        let known = AssetLibrary.mediaID(for: assetID)
        if mediaID == known { return true }
        guard let path = project.media(mediaID)?.path else { return false }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return stem.hasSuffix("-" + known.dropFirst("med_".count))
    }
}
