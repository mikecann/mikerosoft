import Foundation
import TandemCore
import TandemMedia

extension EditorModel {
    /// Files and folders from Finder: brought into the project folder
    /// (copied, or linked from another disk), probed, added to the media,
    /// and with `at`, placed on the timeline there. One undoable edit.
    func importFiles(_ urls: [URL], at time: Time?, trackID: String?) {
        let files = FileImport.mediaFiles(in: urls)
        guard !files.isEmpty else {
            show(.info, "Nothing there Tandem can use. It takes video, audio and pictures.")
            return
        }
        let folder = self.folder
        let plan = FileImport.plan(files, folder: folder) { FileImport.onSameVolume($0, as: folder.root) }
        let copying = plan.filter { $0.action != .inPlace }.count
        show(.info, copying == 0 ? "Adding \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")…" : "Bringing \(copying == 1 ? "1 file" : "\(copying) files") into \(folderName)/…")
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[MediaItem], Error> in
                do {
                    let placed = try FileImport.perform(plan, folder: folder)
                    var items: [MediaItem] = []
                    for url in placed { items.append(try await MediaScanner.probe(url, folder: folder)) }
                    return .success(items)
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.show(.error, "Couldn't add the files: \(Self.describe(error))")
            case .success(let items):
                // Built against the project as it is now: the folder watcher
                // may have added some of the files meanwhile.
                guard let batch = FileImport.batch(items, into: self.project, at: time, trackID: trackID) else {
                    self.show(.info, "Those files are already in the project.")
                    return
                }
                guard let applied = self.apply(batch) else { return }
                let created = SelectionRules.pruned(Set(applied.createdIDs), in: self.project)
                if !created.isEmpty { self.selection = created }
                let used = Set(self.project.allTracks.flatMap(\.clips).compactMap(\.mediaID))
                let paths = Set(items.map(\.path))
                self.session.analysis.requestDefaults(for: self.project.media.filter { paths.contains($0.path) }, usedOnTimeline: used)
                self.show(.info, batch.label + ".")
            }
        }
    }
}
