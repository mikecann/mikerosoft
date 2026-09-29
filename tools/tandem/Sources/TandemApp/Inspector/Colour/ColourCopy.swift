import Foundation
import TandemCore

/// Copying a take's grade to other files: Mike grades one camera file, and
/// the rest of the shoot, filmed in the same light, should match it.
enum ColourCopy {
    /// Files a grade can go to: the other files of the same kind and role,
    /// so a camera grade goes to camera files and never to a screen
    /// recording. In name order, take 2 before take 10.
    static func candidates(for item: MediaItem, in project: Project) -> [MediaItem] {
        project.media
            .filter { $0.id != item.id && $0.kind == item.kind && $0.role == item.role && $0.hasVideo }
            .sorted { MediaCatalog.fileName($0).localizedStandardCompare(MediaCatalog.fileName($1)) == .orderedAscending }
    }

    /// True when `other` has the same grade as `item`, whatever the effect IDs.
    static func hasSameLook(_ other: MediaItem, as item: MediaItem) -> Bool {
        withoutIDs(other.look) == withoutIDs(item.look)
    }

    /// One edit giving each of `targets` a copy of `source`'s grade in
    /// place of its own. Each copy gets its own effect IDs. Nil when they
    /// all have it already.
    static func copy(from source: MediaItem, to targets: [MediaItem], newID: () -> String = { IDs.make("fx") }) -> EditBatch? {
        let changing = targets.filter { !hasSameLook($0, as: source) }
        guard !changing.isEmpty else { return nil }
        var commands: [EditCommand] = []
        for target in changing {
            let effects = source.look.map { effect -> Effect in
                var copy = effect
                copy.id = newID()
                return copy
            }
            guard let batch = InspectorEdits.look(target.id, effects, label: "") else { return nil }
            commands += batch.commands
        }
        let label = changing.count == 1 ? "Copy grade to \(MediaCatalog.fileName(changing[0]))" : "Copy grade to \(changing.count) files"
        return EditBatch(label: label, commands: commands)
    }

    private static func withoutIDs(_ effects: [Effect]) -> [Effect] {
        effects.map { effect in
            var plain = effect
            plain.id = ""
            return plain
        }
    }
}
