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

    /// Opens the library the first time anything asks for it.
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
                let providers = await library.providerInfo()
                await MainActor.run {
                    let host = AssetLibraryHost.shared
                    host.library = library
                    host.providers = providers
                    host.media.library = library
                    host.state = .ready
                    host.revision += 1
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                await MainActor.run { AssetLibraryHost.shared.state = .failed(message) }
            }
        }
    }

    /// Asks the providers how they are again (a key added, a permission).
    func refreshProviders() {
        guard let library else { return }
        Task {
            let providers = await library.providerInfo()
            self.providers = providers
        }
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
