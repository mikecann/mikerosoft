import AppKit
import SwiftUI
import TandemAssets
import TandemCore

/// The Audio and Graphics tabs: the asset library's music, sound effects,
/// stickers, icons, logos and B-roll (and looks and fonts, inside the
/// Effects and Text tabs). Search the catalogue as you type, press Return
/// to ask the online sources too, hover to preview, Space for a big
/// preview, and double-click or drag to put an asset on the timeline, or
/// a look or font on a clip.
struct AssetBrowser: View {
    let model: EditorModel
    let sections: [AssetSection]
    @Binding var section: AssetSection
    /// Replaces the section tabs, for a browser inside another tab.
    var tabs: AnyView?

    @State private var results: [Asset] = []
    @State private var loaded = false
    @State private var showCredits = false

    private var host: AssetLibraryHost { .shared }

    var body: some View {
        let state = host.state(of: section)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                header
                SearchField(text: binding(\.text), prompt: section.searchPrompt, onSubmit: { host.searchOnline(section) }) {
                    FilterMenu(section: section, filters: binding(\.filters))
                }
                ScopeRow(scope: binding(\.scope))
                SourceChips(section: section, providers: AssetBrowsing.sources(for: section, in: host.providers), selected: binding(\.provider)) { preset in
                    addFolder(preset: preset)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content(state: state)
                }
                // minWidth 0: the column is the panel's width, whatever a
                // tile or grid would like.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { host.open() }
        .task(id: LoadKey(section: section, state: state, revision: host.revision, ready: host.state == .ready, projectID: model.project.id)) {
            await load(state)
        }
        .onChange(of: section) { _, _ in
            host.media.stopAudition()
            host.hovered = nil
        }
        .onDisappear {
            host.media.stopAudition()
            host.hovered = nil
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let tabs {
            tabs
        } else {
            sectionTabs
        }
    }

    private var sectionTabs: some View {
        HStack(spacing: 16) {
            ForEach(sections) { item in
                Button {
                    section = item
                } label: {
                    Text(item.title)
                        .font(.ui(13, item == section ? .bold : .regular))
                        .foregroundStyle(item == section ? Theme.text.color : Theme.textFaint.color)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            if section.isAudio {
                GenerateButton(model: model, kind: section == .music ? .music : .sfx)
            }
            Button("Credits") { showCredits = true }
                .buttonStyle(.plain)
                .font(.ui(11.5))
                .foregroundStyle(Theme.amber.color)
                .help("What this project's assets need in the video description")
                .popover(isPresented: $showCredits, arrowEdge: .bottom) {
                    CreditsView(model: model)
                }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<AssetLibraryHost.SectionState, Value>) -> Binding<Value> {
        let current = section
        return Binding(
            get: { host.state(of: current)[keyPath: path] },
            set: { value in host.update(current) { $0[keyPath: path] = value } }
        )
    }

    // MARK: - Results

    @ViewBuilder
    private func content(state: AssetLibraryHost.SectionState) -> some View {
        switch host.state {
        case .opening:
            QuietNote(text: "Opening the asset library…")
        case .failed(let message):
            QuietNote(text: "The asset library couldn't open: \(message)")
        case .ready:
            let online = host.onlineSearch(for: section)
            if results.isEmpty && loaded && online == nil {
                EmptyAssets(section: section, state: state, canSearchOnline: !state.text.isEmpty, searchOnline: { host.searchOnline(section) }) { preset in
                    addFolder(preset: preset)
                }
            } else if !results.isEmpty {
                AssetList(model: model, section: section, assets: results)
            }
            if !state.text.isEmpty && online == nil && !results.isEmpty {
                Button { host.searchOnline(section) } label: {
                    Text("Search \(onlineSourceNames) for \u{201C}\(state.text.trimmingCharacters(in: .whitespaces))\u{201D}")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.amber.color)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)
            }
            if online?.searching == true {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching \(onlineSourceNames)…").font(.ui(11.5)).foregroundStyle(Theme.textMuted.color)
                }
            }
            if let online, !online.searching, results.isEmpty, AssetBrowsing.onlineGroups(online.results, excluding: results).isEmpty {
                QuietNote(text: online.results.isEmpty
                          ? "No online source can search these yet. Pexels and Pixabay need a free key in the Keychain."
                          : "Nothing found online either.")
            }
            if let online, !online.searching {
                ForEach(AssetBrowsing.onlineGroups(online.results, excluding: results), id: \.provider) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(onlineTitle(group.provider, count: group.assets.count))
                            .font(.ui(11.5, .semibold))
                            .foregroundStyle(Theme.textMuted.color)
                        if let error = group.error {
                            Text(error).font(.ui(11)).foregroundStyle(Theme.textFaint.color).fixedSize(horizontal: false, vertical: true)
                        }
                        if !group.assets.isEmpty {
                            AssetList(model: model, section: section, assets: group.assets)
                        }
                    }
                }
            }
        }
    }

    private var onlineSourceNames: String {
        let usable = AssetBrowsing.sources(for: section, in: host.providers)
            .filter { $0.status.isUsable && $0.capabilities.search && $0.id != "import" }
            .map { AssetBrowsing.sourceName($0.displayName) }
        switch usable.count {
        case 0: return "online"
        case 1: return usable[0]
        default: return usable.dropLast().joined(separator: ", ") + " and " + usable.last!
        }
    }

    private func onlineTitle(_ provider: String, count: Int) -> String {
        let name = host.providers.first { $0.id == provider }.map { AssetBrowsing.sourceName($0.displayName) } ?? provider
        return count > 0 ? "From \(name)" : name
    }

    // MARK: - Loading

    private struct LoadKey: Equatable {
        var section: AssetSection
        var state: AssetLibraryHost.SectionState
        var revision: Int
        var ready: Bool
        var projectID: String
    }

    private func load(_ state: AssetLibraryHost.SectionState) async {
        guard host.state == .ready else { return }
        // Typing: wait for a pause before asking.
        if !state.text.isEmpty { try? await Task.sleep(nanoseconds: 120_000_000) }
        guard !Task.isCancelled else { return }
        let query = AssetBrowsing.query(section: section, scope: state.scope, text: state.text, provider: state.provider, filters: state.filters, projectID: model.project.id)
        let found = await host.search(query)
        guard !Task.isCancelled else { return }
        results = found
        loaded = true
    }

    private func addFolder(preset: String?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add folder"
        panel.message = "Choose a folder of assets you've downloaded. Tandem watches it and keeps its licence with every file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        host.addImportFolder(url, preset: preset) { message in model.show(.info, message) }
    }
}

// MARK: - Controls

/// All, Favourites, Recent, Downloaded, In project.
private struct ScopeRow: View {
    @Binding var scope: AssetScope

    var body: some View {
        // The row when it fits; a menu in a narrow panel.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(AssetScope.allCases) { item in
                    Button {
                        scope = item
                    } label: {
                        Text(item.title)
                            .font(.ui(11, item == scope ? .semibold : .regular))
                            .foregroundStyle(item == scope ? Theme.text.color : Theme.textFaint.color)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker("Show", selection: $scope) {
                ForEach(AssetScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// The sources for a section, plus adding a folder of downloaded assets.
private struct SourceChips: View {
    let section: AssetSection
    let providers: [ProviderInfo]
    @Binding var selected: String?
    let addFolder: (String?) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ChipView(title: "All sources", selected: selected == nil) { selected = nil }
            ForEach(providers, id: \.id) { provider in
                ChipView(title: AssetBrowsing.sourceName(provider.displayName), selected: selected == provider.id) {
                    selected = selected == provider.id ? nil : provider.id
                }
                .opacity(provider.status.isUsable ? 1 : 0.45)
                .help(help(for: provider))
            }
            Menu {
                Button("Folder without a licence note…") { addFolder(nil) }
                Divider()
                ForEach(FolderLicence.presets.keys.sorted(), id: \.self) { key in
                    Button("\(FolderLicence.presets[key]!.source) folder…") { addFolder(key) }
                }
            } label: {
                Text("Add folder")
                    .font(.ui(11))
                    .foregroundStyle(Theme.textMuted.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().stroke(Theme.controlBorder.color, lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Watch a folder of downloads, with the licence they came under")
        }
    }

    private func help(for provider: ProviderInfo) -> String {
        var lines = [provider.displayName]
        switch provider.status.state {
        case .ready: break
        case .limited: lines.append(provider.status.message ?? "Partly working.")
        case .needsKey: lines.append(provider.status.message ?? "Needs an API key in the Keychain.")
        case .disabled: lines.append(provider.status.message ?? "Turned off.")
        case .stub: lines.append(provider.status.message ?? "Not set up yet.")
        }
        lines += provider.rules.notes.prefix(2)
        return lines.joined(separator: "\n")
    }
}

/// Licence, length, tempo and transparency, where they apply.
private struct FilterMenu: View {
    let section: AssetSection
    @Binding var filters: AssetFilters

    var body: some View {
        Menu {
            Section("Licence") {
                ForEach(LicenceClass.allCases, id: \.self) { licence in
                    Toggle(licence.label, isOn: Binding(
                        get: { filters.licences.contains(licence) },
                        set: { on in if on { filters.licences.insert(licence) } else { filters.licences.remove(licence) } }
                    ))
                }
            }
            if section.isAudio || section == .broll {
                Picker("Length", selection: $filters.duration) {
                    ForEach(AssetFilters.Length.allCases) { Text($0.title).tag($0) }
                }
            }
            if section == .music {
                Picker("Tempo", selection: $filters.tempo) {
                    ForEach(AssetFilters.Tempo.allCases) { Text($0.title).tag($0) }
                }
            }
            if section.hasPictures {
                Toggle("Transparent only", isOn: $filters.transparentOnly)
            }
            if filters.isActive {
                Divider()
                Button("Clear filters") { filters = AssetFilters() }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(filters.isActive ? Theme.amber.color : Theme.textFaint.color)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by licence, length and more")
    }
}

struct QuietNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.ui(11.5))
            .foregroundStyle(Theme.textFaint.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}

/// What to do when a section has nothing to show.
private struct EmptyAssets: View {
    let section: AssetSection
    let state: AssetLibraryHost.SectionState
    let canSearchOnline: Bool
    let searchOnline: () -> Void
    let addFolder: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.ui(11.5))
                .foregroundStyle(Theme.textFaint.color)
                .fixedSize(horizontal: false, vertical: true)
            if canSearchOnline {
                Button("Search online", action: searchOnline)
                    .buttonStyle(.plain)
                    .font(.ui(11.5, .semibold))
                    .foregroundStyle(Theme.amber.color)
            } else if state.scope == .all && (section.isAudio || section == .looks) {
                Button("Add a folder of \(section == .music ? "music" : section == .sfx ? "sound effects" : "looks")…") { addFolder(nil) }
                    .buttonStyle(.plain)
                    .font(.ui(11.5, .semibold))
                    .foregroundStyle(Theme.amber.color)
            }
        }
        .padding(.top, 4)
    }

    private var message: String {
        if !state.text.isEmpty { return "Nothing in the library matches. Press Return to search online too." }
        switch state.scope {
        case .favourites: return "No favourites here yet. Hover a tile and click the star."
        case .recent: return "Nothing used yet."
        case .downloaded: return "Nothing downloaded yet. Assets download the first time you use them."
        case .inProject: return "This project doesn't use any of these yet."
        case .all:
            switch section {
            case .music: return "No music in the library yet. Add a folder of tracks you've licensed (Epidemic, Artlist, Envato), or generate a cue with ElevenLabs."
            case .sfx: return "No sound effects yet. Add a folder of effects you've licensed, search online, or generate one with ElevenLabs."
            case .broll: return "No B-roll yet. Pexels and Pixabay need a free API key in the Keychain, or add a folder of clips."
            case .stickers, .icons: return "Nothing here yet. Search online to find more."
            case .looks: return "No looks yet. Add a folder of .cube LUTs you've downloaded, with the licence they came under."
            case .fonts: return "No fonts downloaded yet. Type a name and press Return to search Google Fonts."
            }
        }
    }
}

// MARK: - Lists

/// Rows for audio and fonts, a grid of tiles for everything else.
private struct AssetList: View {
    let model: EditorModel
    let section: AssetSection
    let assets: [Asset]

    var body: some View {
        if section.isAudio {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(assets) { asset in
                    AssetAudioRow(model: model, asset: asset)
                }
            }
        } else if section == .fonts {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(assets) { asset in
                    AssetFontRow(model: model, asset: asset)
                }
            }
        } else {
            let tileHeight = (82 / section.tileAspect).rounded()
            LazyVGrid(columns: TileGrid.columns(width: 82), alignment: .leading, spacing: 12) {
                ForEach(assets) { asset in
                    AssetTile(model: model, asset: asset, height: tileHeight)
                }
            }
        }
    }
}

/// What a tile or row shows under its name: where it's from and its licence.
private struct LicenceLine: View {
    let asset: Asset

    var body: some View {
        Text(AssetBrowsing.licenceLabel(asset.licenceClass))
            .font(.ui(10.5))
            .foregroundStyle(colour)
            .lineLimit(1)
    }

    private var colour: Color {
        // Only a missing licence is worth colour; credits are gathered in
        // the Credits panel.
        asset.licenceClass == .unknown ? Theme.red.color.opacity(0.85) : Theme.textFaint.color
    }
}

/// Favourite, download, place and copy, for tiles and rows, and the
/// hovered asset for Space.
private struct AssetActions: ViewModifier {
    let model: EditorModel
    let asset: Asset

    func body(content: Content) -> some View {
        let host = AssetLibraryHost.shared
        content
            .onHover { inside in
                if inside {
                    host.hovered = asset
                } else if host.hovered?.id == asset.id {
                    host.hovered = nil
                }
            }
            .onDisappear { if host.hovered?.id == asset.id { host.hovered = nil } }
            .onTapGesture(count: 2) { host.use(asset, in: model) }
            .onDrag {
                host.dragged = asset
                return NSItemProvider(object: LibraryDrag.asset(asset.id).payload as NSString)
            }
            .contextMenu {
                Button(useTitle, systemImage: "plus.rectangle.on.rectangle") { host.use(asset, in: model) }
                Button("Preview", systemImage: "eye") { host.previewing = asset }
                Button(asset.isFavourite ? "Remove from favourites" : "Add to favourites", systemImage: asset.isFavourite ? "star.slash" : "star") { host.setFavourite(asset, !asset.isFavourite) }
                if asset.state < .original {
                    Button("Download", systemImage: "arrow.down.circle") { host.download(asset) { model.show(.info, $0) } }
                }
                Divider()
                Button("Copy asset ID", systemImage: "doc.on.clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(asset.id, forType: .string)
                    model.show(.info, "Copied \(asset.id) for tandem assets use.")
                }
                if let page = asset.pageURL {
                    Button("Open its page", systemImage: "safari") { NSWorkspace.shared.open(page) }
                }
            }
            .help(tooltip)
    }

    private var tooltip: String {
        var lines = [asset.name]
        let source = AssetLibraryHost.shared.providers.first { $0.id == asset.provider }.map { AssetBrowsing.sourceName($0.displayName) } ?? asset.provider
        lines.append("\(source) · \(asset.licenceClass.label)")
        if let credit = asset.creditLine { lines.append("Credit: \(credit)") }
        let details = AssetBrowsing.details(asset)
        if !details.isEmpty { lines.append(details) }
        lines.append(asset.state >= .original ? "Downloaded" : "Downloads when you use it")
        switch asset.kind {
        case .lut: lines.append("Double-click to grade the selected clips, or drag onto a clip")
        case .font: lines.append("Double-click to set the selected titles in it, or drag onto a title")
        default: lines.append("Double-click to add at the playhead, or drag to the timeline")
        }
        lines.append("Space for a big preview")
        return lines.joined(separator: "\n")
    }

    private var useTitle: String {
        switch asset.kind {
        case .lut: return "Grade the selected clips"
        case .font: return "Use for the selected titles"
        default: return "Add at the playhead"
        }
    }
}

/// A sticker, icon, logo or clip: its picture, scrubbed by hovering when
/// it moves, its name and licence.
private struct AssetTile: View {
    let model: EditorModel
    let asset: Asset
    let height: CGFloat
    @State private var image: NSImage?
    @State private var frame: CGImage?
    @State private var hovering = false

    var body: some View {
        let host = AssetLibraryHost.shared
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                // Logos drawn for light backgrounds sit on a light well.
                RoundedRectangle(cornerRadius: 6).fill(forLightBackground ? Theme.text.color : Theme.thumbnailWell.color)
                picture
                    .padding(fills ? 0 : 12)
                    .frame(width: 82, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if hovering || asset.isFavourite {
                    FavouriteStar(on: asset.isFavourite) { host.setFavourite(asset, !asset.isFavourite) }
                        .padding(4)
                }
                if let busy = host.busy[asset.id] {
                    BusyOverlay(text: busy).frame(width: 82, height: height)
                }
            }
            .frame(width: 82, height: height)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(hovering ? Theme.textFaint.color : .clear, lineWidth: 1))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovering = true
                    scrub(to: point.x / 82)
                case .ended:
                    hovering = false
                    frame = nil
                }
            }
            Text(asset.name)
                .font(.ui(11))
                .foregroundStyle(Theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
            LicenceLine(asset: asset)
        }
        .frame(width: 82, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(AssetActions(model: model, asset: asset))
        .task(id: asset.id + (asset.files.thumbnail ?? "")) {
            image = host.media.cachedThumbnail(for: asset)
            if image == nil { image = await host.media.thumbnail(for: asset) }
        }
    }

    /// Clips and looks fill the tile; everything else sits inside it.
    private var fills: Bool { asset.kind == .video || asset.kind == .lut }

    @ViewBuilder
    private var picture: some View {
        if let frame {
            Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: fills ? .fill : .fit)
        } else if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: fills ? .fill : .fit)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(Theme.tick.color)
        }
    }

    private var forLightBackground: Bool {
        asset.kind == .logo && asset.tags.contains { $0.lowercased() == "light" }
    }

    private var symbol: String {
        switch asset.kind {
        case .sticker: return "face.smiling"
        case .icon: return "star"
        case .logo: return "seal"
        case .video, .overlay: return "film"
        case .lut: return "camera.filters"
        default: return "photo"
        }
    }

    private func scrub(to fraction: Double) {
        guard asset.kind == .sticker || asset.kind == .video || asset.kind == .overlay else { return }
        Task {
            let next = await AssetLibraryHost.shared.media.frame(for: asset, at: fraction)
            if hovering, let next { frame = next }
        }
    }
}

/// A music track or sound effect: name, length, licence and a waveform
/// strip that plays from wherever the pointer is.
struct AssetAudioRow: View {
    let model: EditorModel
    let asset: Asset
    @State private var peaks: [Float]?
    @State private var hoverFraction: Double?
    @State private var lastAudition: (fraction: Double, at: Date)?
    @State private var hovering = false

    var body: some View {
        let host = AssetLibraryHost.shared
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(asset.name)
                    .font(.ui(12, .semibold))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let busy = host.busy[asset.id] {
                    Text(busy).font(.ui(10.5)).foregroundStyle(Theme.amber.color)
                }
                Text(AssetBrowsing.details(asset))
                    .font(.ui(10.5))
                    .foregroundStyle(Theme.textFaint.color)
                FavouriteStar(on: asset.isFavourite) { host.setFavourite(asset, !asset.isFavourite) }
                    .opacity(hovering || asset.isFavourite ? 1 : 0)
            }
            GeometryReader { geometry in
                WaveformStripView(asset: asset, peaks: peaks, hoverFraction: hoverFraction)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let fraction = min(max(point.x / max(geometry.size.width, 1), 0), 1)
                            hoverFraction = fraction
                            audition(from: fraction)
                        case .ended:
                            hoverFraction = nil
                            lastAudition = nil
                            if host.media.auditioning == asset.id { host.media.stopAudition() }
                        }
                    }
            }
            .frame(height: 22)
            LicenceLine(asset: asset)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.rowSelected.color : Theme.raised.color))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(AssetActions(model: model, asset: asset))
        .task(id: asset.id + asset.state.rawValue) {
            peaks = await host.media.waveform(for: asset, allowDownload: false)
        }
    }

    /// Plays from the hovered point, without re-seeking for every pixel.
    private func audition(from fraction: Double) {
        if let last = lastAudition, abs(last.fraction - fraction) < 0.02, Date().timeIntervalSince(last.at) < 0.4 { return }
        lastAudition = (fraction, Date())
        Task {
            let media = AssetLibraryHost.shared.media
            await media.audition(asset, from: fraction)
            if peaks == nil { peaks = await media.waveform(for: asset, allowDownload: true) }
        }
    }
}

/// A font: its name in its own letters once downloaded, what it has and
/// its licence.
private struct AssetFontRow: View {
    let model: EditorModel
    let asset: Asset
    @State private var face: String?
    @State private var hovering = false

    var body: some View {
        let host = AssetLibraryHost.shared
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.name)
                    .font(face.map { Font.custom($0, size: 17) } ?? .ui(14, .semibold))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.ui(10.5))
                    .foregroundStyle(Theme.textFaint.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let busy = host.busy[asset.id] {
                Text(busy).font(.ui(10.5)).foregroundStyle(Theme.amber.color)
            }
            FavouriteStar(on: asset.isFavourite) { host.setFavourite(asset, !asset.isFavourite) }
                .opacity(hovering || asset.isFavourite ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.rowSelected.color : Theme.raised.color))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(AssetActions(model: model, asset: asset))
        .task(id: asset.id + asset.state.rawValue) { face = await host.fontFace(for: asset) }
    }

    /// "sans-serif, 9 weights, OFL-1.1", and whether it's downloaded.
    private var detail: String {
        let what = asset.summary ?? asset.licenceClass.label
        return asset.state >= .original ? what : "\(what) · downloads when used"
    }
}

/// Peaks as bars, with the hovered point and the playhead of the audition.
private struct WaveformStripView: View {
    let asset: Asset
    let peaks: [Float]?
    let hoverFraction: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: hoverFraction == nil)) { _ in
            Canvas { context, size in
                let columns = WaveformStrip.columns(peaks ?? [], count: max(1, Int(size.width / 2)))
                let mid = size.height / 2
                let colour = asset.kind == .music ? Theme.musicClip.detail : Theme.sfxClip.detail
                if peaks == nil {
                    context.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(colour.color.opacity(0.35)))
                } else {
                    var path = Path()
                    for (index, value) in columns.enumerated() {
                        let height = max(1, CGFloat(value) * (size.height - 2))
                        path.addRect(CGRect(x: CGFloat(index) * 2, y: mid - height / 2, width: 1.2, height: height))
                    }
                    context.fill(path, with: .color(colour.color.opacity(hoverFraction == nil ? 0.55 : 0.85)))
                }
                if let hoverFraction {
                    context.fill(Path(CGRect(x: CGFloat(hoverFraction) * size.width, y: 0, width: 1, height: size.height)), with: .color(Theme.textMuted.color))
                }
                if let progress = AssetLibraryHost.shared.media.auditionProgress(of: asset) {
                    context.fill(Path(CGRect(x: CGFloat(progress) * size.width, y: 0, width: 1.5, height: size.height)), with: .color(Theme.amber.color))
                }
            }
        }
    }
}

struct FavouriteStar: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? Theme.amber.color : Theme.textSecondary.color)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.window.color.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .help(on ? "Remove from favourites" : "Add to favourites")
    }
}

private struct BusyOverlay: View {
    let text: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Theme.window.color.opacity(0.72))
            VStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text(text).font(.ui(10)).foregroundStyle(Theme.textSecondary.color)
            }
        }
    }
}
