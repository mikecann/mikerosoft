import Foundation
import TandemAPI
import TandemAssets
import TandemCore

/// The section card whooshes last copied into a project, for the next
/// drop of the Section card tile. A drop builds its edit on the spot and
/// can't wait for the asset library, so the tile copies them in when a drag
/// starts (it's an APFS clone, done long before the drop).
final class SectionCardSoundCache: @unchecked Sendable {
    static let shared = SectionCardSoundCache()
    private let lock = NSLock()
    private var prepared: (folder: URL, sounds: SectionCardSounds.Resolved)?

    /// The sounds copied into the project in `folder`, if any.
    func sounds(for folder: URL) -> SectionCardSounds.Resolved? {
        lock.withLock { prepared?.folder == folder ? prepared?.sounds : nil }
    }

    /// The most recently copied sounds, whichever project they're for: the
    /// drop's own window almost always.
    var latest: SectionCardSounds.Resolved? { lock.withLock { prepared?.sounds } }

    func set(_ sounds: SectionCardSounds.Resolved, for folder: URL) {
        lock.withLock { prepared = (folder, sounds) }
    }

    func clear() {
        lock.withLock { prepared = nil }
    }
}

/// The section card in the app: the Text tab's tile (double-click adds a
/// card at the playhead) and Timeline > Add section cards at section
/// markers. Both bring the whooshes in from the asset library first, so the
/// card and its sounds go in as one undo step; without them the cards go in
/// silent.
@MainActor
enum SectionCardActions {
    /// The asset library, once it's open (it opens on first use).
    static func library() async -> AssetLibrary? {
        let host = AssetLibraryHost.shared
        host.open()
        for _ in 0..<100 {
            if let library = host.library { return library }
            if case .failed = host.state { return nil }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return host.library
    }

    /// The whooshes copied into the model's project and levelled for its
    /// speech, or nil when the library doesn't have them.
    static func sounds(for model: EditorModel) async -> SectionCardSounds.Resolved? {
        if let ready = SectionCardSoundCache.shared.sounds(for: model.folder.root),
           ready.media.allSatisfy({ FileManager.default.fileExists(atPath: model.folder.url(forPath: $0.path).path) }) {
            return ready.levelled(for: model.project)
        }
        guard let library = await library(), SectionCardSounds.available(in: library) else { return nil }
        let folder = model.folder
        let projectID = model.project.id
        let file = model.fileURL
        guard let copied = try? await SectionCardSounds.use(in: library, folder: folder, projectID: projectID, projectFile: file) else { return nil }
        let sounds = copied.levelled(for: model.project)
        SectionCardSoundCache.shared.set(sounds, for: folder.root)
        return sounds
    }

    /// A drag of the tile has started: have the sounds ready for the drop.
    static func prepareForDrop(in model: EditorModel) {
        Task { _ = await sounds(for: model) }
    }

    /// Double-clicking the tile: a card at `time`, with its whooshes.
    static func insert(at time: Time, in model: EditorModel) {
        Task {
            let sounds = await sounds(for: model)
            let template = BuiltInTemplates.makeSectionCard(sounds: sounds)
            guard let result = model.apply(LibraryDrops.template(template, at: time)) else { return }
            let card = result.createdIDs.first { id in model.project.clip(id).map { SectionCard.isCard($0.content) } ?? false }
            if let card { model.selection = [card] }
            model.inspectorTab = .video
            if sounds == nil { model.show(.info, "Added a section card without its whooshes: they aren't in this Mac's asset library.") }
        }
    }

    /// Timeline > Add section cards at section markers.
    static func addAtMarkers(in model: EditorModel) {
        guard SectionCardBatches.canAddAtMarkers(model.project) else {
            model.show(.info, "Mark where each section starts first: add a marker (M) and set its kind to Section from its menu on the ruler.")
            return
        }
        Task {
            let sounds = await sounds(for: model)
            guard let batch = SectionCardBatches.atMarkers(model.project, sounds: sounds) else { return }
            guard let result = model.apply(batch) else { return }
            let cards = result.createdIDs.filter { id in model.project.clip(id).map { SectionCard.isCard($0.content) } ?? false }
            let count = (try? SectionCard.placements(in: model.project, markerIDs: nil).count) ?? cards.count
            let renumbered = count - cards.count
            var text = cards.isEmpty ? "Renumbered the \(count) section cards." : "Added \(cards.count) section card\(cards.count == 1 ? "" : "s")"
            if !cards.isEmpty && renumbered > 0 { text += " and renumbered \(renumbered)" }
            if !cards.isEmpty { text += "." }
            if sounds == nil && !cards.isEmpty { text += " The whooshes aren't in this Mac's asset library, so they're silent." }
            model.show(.info, text)
            if !cards.isEmpty { model.selection = Set(cards) }
        }
    }
}

/// The edits behind the actions, apart from the app so tests can check them.
enum SectionCardBatches {
    /// True when there's a section marker after the start to put a card at.
    static func canAddAtMarkers(_ project: Project) -> Bool {
        project.markers.contains { $0.kind == .section && $0.time > .zero }
    }

    /// A card at every section marker after the start, with the whooshes
    /// when there are some, as one undo step.
    static func atMarkers(_ project: Project, sounds: SectionCardSounds.Resolved?, kicker: String? = nil) -> EditBatch? {
        guard let placements = try? SectionCard.placements(in: project, markerIDs: nil) else { return nil }
        var commands: [EditCommand] = []
        var soundIn: SectionCardSound?
        var soundOut: SectionCardSound?
        if let sounds, placements.contains(where: { $0.existingClipID == nil }) {
            let prepared = sounds.prepared(for: project)
            commands += prepared.addMedia
            soundIn = prepared.soundIn
            soundOut = prepared.soundOut
        }
        commands.append(.addSectionCards(kicker: kicker, soundIn: soundIn, soundOut: soundOut))
        let count = placements.count
        return EditBatch(label: "Section cards at \(count) marker\(count == 1 ? "" : "s")", commands: commands)
    }
}
