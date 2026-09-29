import Foundation
import TandemCore
import TandemMedia

extension EditorModel {
    /// Files and folders from Finder: brought into the project folder
    /// (copied, or linked from another disk), probed, added to the media,
    /// and with `at`, placed on the timeline there. One undoable edit.
    /// A Live Photo's motion clip comes along beside its still and is kept
    /// on it, rather than added as a video of its own.
    func importFiles(_ urls: [URL], at time: Time?, trackID: String?) {
        let files = FileImport.mediaFiles(in: urls)
        guard !files.isEmpty else {
            show(.info, "Nothing there Tandem can use. It takes video, audio and pictures.")
            return
        }
        let folder = self.folder
        let counted = FileImport.countedFiles(files)
        let copying = FileImport.plan(counted, folder: folder) { FileImport.onSameVolume($0, as: folder.root) }.filter { $0.action != .inPlace }.count
        show(.info, copying == 0 ? "Adding \(counted.count == 1 ? counted[0].lastPathComponent : "\(counted.count) files")…" : "Bringing \(copying == 1 ? "1 file" : "\(copying) files") into \(folderName)/…")
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[MediaItem], Error> in
                do {
                    let clips = await LivePhotos.motionClips(among: files)
                    let plan = FileImport.plan(files, folder: folder, motionClips: clips) { FileImport.onSameVolume($0, as: folder.root) }
                    let placed = try FileImport.perform(plan, folder: folder)
                    var items: [MediaItem] = []
                    for (entry, url) in zip(plan, placed) where entry.livePhotoOf == nil {
                        items.append(try await MediaScanner.probe(url, folder: folder))
                    }
                    return .success(FileImport.withMotionClips(items, plan: plan))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.show(.error, "Couldn't add the files: \(Self.describe(error))")
            case .success(let items):
                // Worked out against the coordinator's project as it is when
                // it's applied: the folder watcher may have added some of the
                // files meanwhile, and this window may not have heard yet.
                let committed: (batch: EditBatch, result: ProjectCoordinator.CommitResult)?
                do {
                    committed = try FileImport.commit(items, to: self.session.coordinator, folder: self.folder, at: time, trackID: trackID)
                } catch {
                    self.show(.error, "Couldn't add the files: \(Self.describe(error))")
                    return
                }
                self.refresh()
                guard let (batch, applied) = committed else {
                    self.show(.info, "Those files are already in the project.")
                    return
                }
                let created = SelectionRules.pruned(Set(applied.createdIDs), in: self.project)
                if !created.isEmpty { self.selection = created }
                self.session.analysis.requestNeeded(for: self.project)
                self.show(.info, batch.label + ".")
            }
        }
    }
}
