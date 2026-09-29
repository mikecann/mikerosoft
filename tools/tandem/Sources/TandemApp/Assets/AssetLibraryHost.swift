import AVFoundation
import AppKit
import Foundation
import Observation
import TandemAPI
import TandemAssets
import TandemCore

/// The per-user asset library, shared by every window: opened once off
/// the main thread (with the starter set added on first run), and the
/// browser's state per section, which survives switching tabs.
///
/// It's the same library the CLI and MCP use (`AssetService.standard`), so
/// `$TANDEM_ASSETS_ROOT` and `$TANDEM_ASSETS_OFFLINE` move it for tests.
@MainActor
@Observable
final class AssetLibraryHost {
    static let shared = AssetLibraryHost()

    enum State: Equatable {
        case opening
        case ready
        case failed(String)
    }

    /// What one section of the browser is showing.
    struct SectionState: Equatable {
        var scope: AssetScope = .all
        var text = ""
        var provider: String?
        var filters = AssetFilters()
    }

    private(set) var state: State = .opening
    /// Sources with their status, for the chips.
    private(set) var providers: [ProviderInfo] = []
    /// Goes up when favourites, uses, downloads or online results change
    /// the catalogue, so lists look again.
    private(set) var revision = 0
    /// Assets being downloaded or placed, and what's happening to them.
    private(set) var busy: [String: String] = [:]
    var sections: [AssetSection: SectionState] = [:]
    /// The section each tab shows.
    var audioSection: AssetSection = .music
    var graphicsSection: AssetSection = .stickers
    /// The asset being dragged, so the timeline can name it before the drop.
    var dragged: Asset?
    /// The tile or row under the pointer, for Space. Nothing draws from it.
    @ObservationIgnored var hovered: Asset?
    /// The asset in the big preview Space opens.
    var previewing: Asset?
    /// The Effects tab shows looks (LUTs), and the Text tab fonts, instead
    /// of their built-in items.
    var looksShown = false
    var fontsShown = false
    /// The Text tab shows saved segments.
    var segmentsShown = false
    /// ElevenLabs permissions the key was refused (`sound_generation`,
    /// `music_generation`), remembered by the provider.
    private(set) var refused: Set<String> = []
    /// The shared library folder (`~/Movies/Tandem Library`), once the
    /// library is open.
    private(set) var sharedRoot: URL?
    /// Its saved segments, by name, and folders that couldn't be read.
    private(set) var segments: [StoredSegment] = []
    private(set) var segmentProblems: [String] = []

    /// A generation in progress or done, per kind (music, sfx).
    struct Generation: Equatable {
        var running = false
        var takes: [Asset] = []
        var failures: [String] = []
        var error: String?
    }
    private(set) var generations: [AssetKind: Generation] = [:]
    /// The Generate form per kind, kept while the popover is closed.
    var forms: [AssetKind: GenerationForm] = [:]

    /// What the online sources said for a section's search.
    struct OnlineSearch: Equatable {
        /// The section, text and source it was for.
        var key: String
        var results: [AssetLibrary.ProviderResults] = []
        var searching = true

        static func == (a: OnlineSearch, b: OnlineSearch) -> Bool {
            a.key == b.key && a.searching == b.searching && a.results.map(\.provider) == b.results.map(\.provider)
                && a.results.map { $0.assets.map(\.id) } == b.results.map { $0.assets.map(\.id) }
        }
    }
    private(set) var online: [AssetSection: OnlineSearch] = [:]

    @ObservationIgnored private(set) var library: AssetLibrary?
    @ObservationIgnored private var opened = false
    @ObservationIgnored let media = AssetMedia()

    func state(of section: AssetSection) -> SectionState {
        sections[section] ?? SectionState()
    }

    func update(_ section: AssetSection, _ change: (inout SectionState) -> Void) {
        var value = state(of: section)
        change(&value)
        sections[section] = value
    }

    // MARK: - Opening

    /// Opens the library the first time anything asks for it. The first
    /// time after installing, that makes the shared library folder.
    func open() {
        guard !opened else { return }
        opened = true
        Task.detached(priority: .userInitiated) {
            do {
                let library = try AssetService.standard().library
                // First run, or a library that lost its starter rows: add
                // the emoji, icons and logos (catalogue rows only).
                if try library.count(AssetQuery(text: StarterContent.tag, limit: 1)) == 0 {
                    try library.installStarterContent()
                }
                // The shared library, made with its folders and READMEs if
                // it isn't there (never from the tests).
                if !Self.isTesting { _ = try? library.createSharedLibrary() }
                let providers = await library.providerInfo()
                let refused = Self.refusals(in: library)
                // Downloaded fonts, so the Fonts list shows each in its face,
                // and the shared library's, so titles can use them.
                _ = try? await library.registerFonts()
                _ = await library.registerSharedFonts()
                await MainActor.run {
                    let host = AssetLibraryHost.shared
                    host.library = library
                    host.providers = providers
                    host.refused = refused
                    host.media.library = library
                    host.sharedRoot = library.sharedLibrary.root
                    host.state = .ready
                    host.revision += 1
                    host.watchImportFolders()
                    host.watchSharedLibrary()
                    host.reloadSegments()
                }
                // Files added to the import folders and the shared library
                // while Tandem was closed.
                _ = try? await library.rescanImportFolders()
                _ = try? await library.rescanSharedLibrary()
                await MainActor.run { AssetLibraryHost.shared.revision += 1 }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                await MainActor.run { AssetLibraryHost.shared.state = .failed(message) }
            }
        }
    }

    @ObservationIgnored private var watcher: ImportFolderWatcher?

    /// Rescans an import folder when its files change, so downloads saved
    /// into it show up without adding it again.
    private func watchImportFolders() {
        guard let library else { return }
        watcher = try? library.watchImportFolders { _ in
            Task { @MainActor in AssetLibraryHost.shared.revision += 1 }
        }
    }

    /// True under XCTest, which must never make the real shared library.
    nonisolated static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    // MARK: - The shared library

    @ObservationIgnored private var sharedWatcher: ImportFolderWatcher?

    /// Rescans the shared library when anything in it changes: new files
    /// show up in their tabs, changed ones a project uses are converted
    /// again, fonts are registered, and the segments list reloads.
    private func watchSharedLibrary() {
        guard let library else { return }
        sharedWatcher = library.watchSharedLibrary { report in
            Task.detached(priority: .utility) {
                await MainActor.run {
                    AssetLibraryHost.shared.revision += 1
                    AssetLibraryHost.shared.reloadSegments()
                }
                let refreshed = await library.refreshChangedSharedFiles(report)
                _ = await library.registerSharedFonts()
                if !refreshed.isEmpty { await MainActor.run { AssetLibraryHost.shared.revision += 1 } }
            }
        }
    }

    /// Reads the saved segments again, off the main thread.
    func reloadSegments() {
        guard let library else { return }
        let store = SegmentStore(library: library.sharedLibrary)
        Task.detached(priority: .utility) {
            let (segments, problems) = store.list()
            SegmentShelf.shared.update(segments)
            await MainActor.run {
                AssetLibraryHost.shared.segments = segments
                AssetLibraryHost.shared.segmentProblems = problems
            }
        }
    }

    /// Moves the shared library to `folder` (nil for the default,
    /// ~/Movies/Tandem Library), making it there with its folders, and
    /// watches it there.
    func moveSharedLibrary(to folder: URL?, report: @escaping (String) -> Void) {
        guard let library else { return }
        Task {
            do {
                let scan = try await library.moveSharedLibrary(to: folder)
                self.sharedRoot = library.sharedLibrary.root
                self.watchSharedLibrary()
                self.reloadSegments()
                self.revision += 1
                _ = await library.registerSharedFonts()
                let files = scan.map { $0.added + $0.updated + $0.unchanged } ?? 0
                report("The shared library is \(ArchiveSheetView.display(library.sharedLibrary.root.path)) now, with \(files) file\(files == 1 ? "" : "s").")
            } catch {
                report("Couldn't move the shared library: \(Self.describe(error))")
            }
        }
    }

    /// Puts a saved segment on the timeline at `time`, over what's there,
    /// as one undoable edit.
    func insert(_ segment: StoredSegment, at time: Time, in model: EditorModel) {
        let missing = segment.missingFiles
        guard missing.isEmpty else {
            model.show(.error, "\(segment.name) is missing \(missing.joined(separator: ", ")) from its folder in the shared library.")
            return
        }
        if let result = model.apply(segment.insertBatch(at: max(.zero, time), mode: .overwrite, label: "Add \(segment.name.lowercased())")) {
            let created = SelectionRules.pruned(Set(result.createdIDs), in: model.project)
            if !created.isEmpty { model.selection = created }
            // Warnings the edit had stay up.
            if result.warnings.isEmpty { model.show(.info, "Added \(segment.name) at \(Timecode.string(time, rate: model.frameRate)).") }
        }
    }

    /// Moves a saved segment's folder to the Trash.
    func trash(_ segment: StoredSegment, report: @escaping (String) -> Void) {
        do {
            try FileManager.default.trashItem(at: segment.folder, resultingItemURL: nil)
            reloadSegments()
            report("Moved \(segment.name) to the Trash.")
        } catch {
            report("Couldn't move \(segment.name) to the Trash: \(error.localizedDescription)")
        }
    }

    /// Asks the providers how they are again (a key added, a permission).
    func refreshProviders() {
        guard let library else { return }
        Task {
            let providers = await library.providerInfo()
            self.providers = providers
            self.refused = Self.refusals(in: library)
        }
    }

    nonisolated private static func refusals(in library: AssetLibrary) -> Set<String> {
        (library.provider("elevenlabs") as? ElevenLabsProvider).map { Set($0.refusals().keys) } ?? []
    }

    /// Shows a section in its library tab.
    func show(_ section: AssetSection, in model: EditorModel) {
        switch section.libraryTab {
        case .audio: audioSection = section
        case .graphics: graphicsSection = section
        default: break
        }
        looksShown = section == .looks
        fontsShown = section == .fonts
        if fontsShown { segmentsShown = false }
        model.libraryTab = section.libraryTab
    }

    // MARK: - Browsing

    /// The catalogue's answer, read off the main thread.
    func search(_ query: AssetQuery) async -> [Asset] {
        guard let library else { return [] }
        return await Task.detached(priority: .userInitiated) { (try? library.search(query)) ?? [] }.value
    }

    /// The key an online search is kept under: section, text and source.
    func onlineKey(_ section: AssetSection) -> String {
        let state = state(of: section)
        return "\(section.rawValue)|\(state.text.trimmingCharacters(in: .whitespaces).lowercased())|\(state.provider ?? "")"
    }

    /// Asks the providers what they have for a section's search text. What
    /// they find is kept in the catalogue, so it can be fetched and used by
    /// ID, and the answer stays with the section until the text changes.
    func searchOnline(_ section: AssetSection) {
        let state = state(of: section)
        let text = state.text.trimmingCharacters(in: .whitespaces)
        guard let library, !text.isEmpty else { return }
        let key = onlineKey(section)
        if let current = online[section], current.key == key, current.searching { return }
        online[section] = OnlineSearch(key: key)
        let query = AssetBrowsing.providerQuery(section: section, text: text, filters: state.filters)
        Task {
            let results = await library.searchProviders(query, providerIDs: state.provider.map { [$0] })
            guard self.online[section]?.key == key else { return }
            self.online[section] = OnlineSearch(key: key, results: results, searching: false)
            self.revision += 1
        }
    }

    /// The online answer for a section, if it's for what's in the search
    /// box now.
    func onlineSearch(for section: AssetSection) -> OnlineSearch? {
        guard let search = online[section], search.key == onlineKey(section) else { return nil }
        return search
    }

    func setFavourite(_ asset: Asset, _ favourite: Bool) {
        guard let library else { return }
        do {
            try library.setFavourite(asset.id, favourite)
            revision += 1
        } catch {
            NSSound.beep()
        }
    }

    /// Downloads and normalises an asset without placing it.
    func download(_ asset: Asset, report: @escaping (String) -> Void) {
        guard let library, busy[asset.id] == nil else { return }
        busy[asset.id] = "Downloading"
        Task {
            defer { self.busy[asset.id] = nil }
            do {
                _ = try await library.fetch(asset.id)
                self.revision += 1
                report("Downloaded \(asset.name).")
            } catch {
                report("Couldn't download \(asset.name): \(Self.describe(error))")
            }
        }
    }

    // MARK: - Using

    /// Fetches the asset if needed, copies it into the project and places
    /// it at `time` on the track for its kind, as one undoable edit. It
    /// goes over what's there, or pushes it along with `insert`.
    func place(_ asset: Asset, at time: Time, in model: EditorModel, insert: Bool = false) {
        guard let library else { return }
        guard busy[asset.id] == nil else {
            model.show(.info, "\(asset.name) is on its way.")
            return
        }
        busy[asset.id] = asset.state >= .original ? "Adding" : "Downloading"
        if asset.state < .original { model.show(.info, "Downloading \(asset.name)…") }
        Task {
            defer { self.busy[asset.id] = nil }
            do {
                let placement = try await library.use(asset.id, in: model.folder, projectID: model.project.id, projectFile: model.fileURL)
                self.revision += 1
                let commands = AssetPlacing.commands(for: placement, at: time, in: model.project, mode: insert ? .insert : .overwrite)
                guard !commands.isEmpty else {
                    model.show(.info, "Installed \(asset.name). Fonts and LUTs are used from the inspector.")
                    return
                }
                let label = "Add \(asset.name)"
                if let result = model.apply(EditBatch(label: label, commands: commands)) {
                    let created = SelectionRules.pruned(Set(result.createdIDs), in: model.project)
                    if !created.isEmpty { model.selection = created }
                    model.show(.info, "Added \(asset.name) at \(Timecode.string(time, rate: model.frameRate)).")
                }
            } catch {
                model.show(.error, "Couldn't add \(asset.name): \(Self.describe(error))")
            }
        }
    }

    /// Double-click: a look or font changes the selected clips it suits;
    /// anything else goes in at the playhead.
    func use(_ asset: Asset, in model: EditorModel) {
        guard AssetApplying.appliesToClips(asset.kind) else {
            return place(asset, at: model.playback.time, in: model)
        }
        let targets = AssetApplying.targets(for: asset, among: TimelineEdits.ordered(model.selection, in: model.project), in: model.project)
        guard !targets.isEmpty else { return model.show(.info, AssetApplying.selectHint(for: asset)) }
        apply(asset, to: targets, in: model)
    }

    /// Fetches a look or font if needed, copies it into the project and
    /// changes the clips it suits, as one undoable edit.
    func apply(_ asset: Asset, to clipIDs: [String], in model: EditorModel) {
        guard let library else { return }
        guard busy[asset.id] == nil else {
            model.show(.info, "\(asset.name) is on its way.")
            return
        }
        busy[asset.id] = asset.state >= .original ? "Applying" : "Downloading"
        if asset.state < .original { model.show(.info, "Downloading \(asset.name)…") }
        Task {
            defer { self.busy[asset.id] = nil }
            do {
                let placement = try await library.use(asset.id, in: model.folder, projectID: model.project.id, projectFile: model.fileURL)
                self.revision += 1
                // The family as the font file names it, which is what the
                // renderer looks up.
                let family = asset.kind == .font
                    ? placement.files.lazy.compactMap { FontInstaller.faces(in: model.folder.url(forPath: $0)).first?.family }.first { !$0.isEmpty }
                    : nil
                let project = model.project
                let targets = AssetApplying.targets(for: asset, among: clipIDs, in: project)
                let commands = targets.compactMap { project.clip($0) }.flatMap { AssetApplying.commands(for: placement, on: $0, family: family) }
                guard !commands.isEmpty else {
                    model.show(.info, AssetApplying.selectHint(for: asset))
                    return
                }
                if model.apply(EditBatch(label: AssetApplying.label(for: asset, count: targets.count), commands: commands)) != nil {
                    model.selection = Set(targets)
                    model.inspectorTab = asset.kind == .lut ? .colour : .video
                    model.show(.info, asset.kind == .font ? "Set in \(family ?? asset.name)." : "Graded with \(asset.name).")
                }
            } catch {
                model.show(.error, "Couldn't use \(asset.name): \(Self.describe(error))")
            }
        }
    }

    // MARK: - Fonts

    @ObservationIgnored private var faces: [String: String] = [:]

    /// The PostScript name to draw a downloaded font's name in, once its
    /// files are registered. Nil for fonts that aren't downloaded.
    func fontFace(for asset: Asset) async -> String? {
        guard asset.kind == .font, asset.state >= .original, let library else { return nil }
        if let known = faces[asset.id] { return known }
        let face = await Task.detached(priority: .utility) { () -> String? in
            guard let original = library.url(for: asset, .original) else { return nil }
            let folder = library.folder(for: asset)
            let extras = (asset.remote["extraFiles"] ?? "").split(separator: "\n").map { folder.appendingPathComponent(String($0)) }
            let files = ([original] + extras).filter { FileManager.default.fileExists(atPath: $0.path) }
            await FontInstaller.register(files)
            let all = files.flatMap(FontInstaller.faces(in:))
            // The regular face if there is one.
            return (all.first { $0.style.lowercased() == "regular" } ?? all.first)?.postScriptName
        }.value
        if let face { faces[asset.id] = face }
        return face
    }

    // MARK: - Generating

    /// ElevenLabs as the library last saw it.
    var elevenLabs: ProviderInfo? {
        providers.first { $0.id == "elevenlabs" }
    }

    /// Makes new music or sound effects with ElevenLabs. They join the
    /// library (and the list) as they're saved, whatever happens to the
    /// popover.
    func generate(_ form: GenerationForm) {
        guard let library, generations[form.kind]?.running != true, form.problem == nil else { return }
        let request = form.request
        generations[form.kind] = Generation(running: true)
        Task {
            var outcome = Generation()
            do {
                let result = try await library.generate(request)
                outcome.takes = result.assets
                outcome.failures = result.failures
            } catch {
                outcome.error = Self.describe(error)
            }
            self.generations[form.kind] = outcome
            self.revision += 1
            // A refused permission is remembered by the provider.
            self.refreshProviders()
        }
    }

    /// The description credits for everything the project uses.
    func credits(for model: EditorModel) -> Result<ProjectCredits, Error> {
        guard let library else { return .failure(AssetError.invalid("the asset library isn't open")) }
        return Result { try library.credits(for: model.project, in: model.folder) }
    }

    /// Adds a folder of downloaded assets with a licence note from the
    /// presets (or none, which leaves it unknown until a note is added).
    func addImportFolder(_ url: URL, preset: String?, report: @escaping (String) -> Void) {
        guard let library else { return }
        let licence = preset.flatMap { FolderLicence.presets[$0] }
        Task {
            do {
                let scan = try await library.addImportFolder(url, licence: licence)
                self.revision += 1
                self.refreshProviders()
                // A watcher covers the folders it was made with.
                self.watchImportFolders()
                let note = scan.missingLicence ? " It has no licence note, so its files show as No licence until one is added." : ""
                report("Added \(url.lastPathComponent): \(scan.added) \(scan.added == 1 ? "file" : "files").\(note)")
            } catch {
                report("Couldn't add \(url.lastPathComponent): \(Self.describe(error))")
            }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? EditorModel.describe(error)
    }
}
