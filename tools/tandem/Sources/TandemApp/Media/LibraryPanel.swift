import AppKit
import SwiftUI
import TandemCore
import TandemMedia

/// The left panel: media from the project folder, and the text,
/// transition, effect, graphics and audio libraries.
struct LibraryPanel: View {
    let model: EditorModel
    let actions: EditorActions

    var body: some View {
        Group {
            switch model.libraryTab {
            case .media: MediaBrowser(model: model, title: "Media", filter: nil)
            case .graphics: MediaBrowser(model: model, title: "Graphics", filter: [.graphics, .images])
            case .audio: MediaBrowser(model: model, title: "Audio", filter: [.music, .sfx])
            case .text: TextLibrary(model: model)
            case .transitions: TransitionLibrary(model: model)
            case .effects: EffectLibrary(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.panel.color)
    }
}

/// Panel title row: a bold name and a quiet detail.
struct PanelHeader<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.ui(13, .bold))
                .foregroundStyle(Theme.text.color)
            if let detail {
                Text(detail)
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textFaint.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            trailing()
        }
    }
}

// MARK: - Media browser

struct MediaBrowser: View {
    let model: EditorModel
    let title: String
    /// Groups to show; nil shows everything with filter chips.
    let filter: Set<MediaGroupKind>?
    @State private var chip: MediaGroupKind?
    @State private var selectedEntry: String?
    @State private var scanning = false

    var body: some View {
        let all = MediaCatalog.groups(for: model.project, search: model.mediaSearch)
        let groups = all.filter { group in
            (filter?.contains(group.kind) ?? true) && (chip == nil || chip == group.kind)
        }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: title, detail: "from \(model.folderName)/") {
                    Button {
                        rescan()
                    } label: {
                        Image(systemName: scanning ? "arrow.triangle.2.circlepath" : "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textMuted.color)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Look for new files in the project folder")
                }
                SearchField(text: Binding(get: { model.mediaSearch }, set: { model.mediaSearch = $0 }), prompt: "Search clips and what's said in them")
                if filter == nil {
                    FlowLayout(spacing: 6) {
                        ChipView(title: "All", selected: chip == nil) { chip = nil }
                        ForEach(all.map(\.kind), id: \.self) { kind in
                            ChipView(title: kind.chip, selected: chip == kind) { chip = chip == kind ? nil : kind }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if groups.isEmpty {
                        EmptyMediaNote(hasMedia: !model.project.media.isEmpty, searching: !model.mediaSearch.isEmpty)
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        Text(group.detail.map { "\(group.kind.title) · \($0)" } ?? group.kind.title)
                            .font(.ui(11.5, .semibold))
                            .foregroundStyle(Theme.textMuted.color)
                            .padding(.horizontal, 6)
                            .padding(.top, index == 0 ? 6 : 10)
                            .padding(.bottom, 4)
                        if group.kind.isGrid {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3), alignment: .leading, spacing: 10) {
                                ForEach(group.entries) { entry in
                                    MediaTile(model: model, entry: entry, selected: selectedEntry == entry.id)
                                        .modifier(MediaEntryInteractions(model: model, entry: entry, selected: $selectedEntry))
                                }
                            }
                            .padding(.horizontal, 6)
                        } else {
                            ForEach(group.entries) { entry in
                                Group {
                                    if group.kind == .recordings {
                                        TakeRow(model: model, entry: entry, selected: selectedEntry == entry.id)
                                    } else {
                                        AudioRow(model: model, entry: entry, selected: selectedEntry == entry.id)
                                    }
                                }
                                .modifier(MediaEntryInteractions(model: model, entry: entry, selected: $selectedEntry))
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 10)
            }
        }
    }

    private func rescan() {
        guard !scanning else { return }
        scanning = true
        Task { @MainActor in
            do {
                let found = try await model.session.refreshMedia()
                model.refresh()
                model.show(.info, found.isEmpty ? "No new files in \(model.folderName)/." : "Found \(found.count) new \(found.count == 1 ? "file" : "files").")
            } catch {
                model.show(.error, "Couldn't scan the folder: \(EditorModel.describe(error))")
            }
            scanning = false
        }
    }
}

/// Click to select, double-click to place at the playhead, drag to the
/// timeline, and a context menu.
private struct MediaEntryInteractions: ViewModifier {
    let model: EditorModel
    let entry: MediaEntry
    @Binding var selected: String?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { place(insert: false) }
            .onTapGesture { selected = entry.id }
            .onDrag {
                model.draggedMediaIDs = entry.mediaIDs
                return NSItemProvider(object: MediaDrag.payload(entry.mediaIDs) as NSString)
            }
            .contextMenu {
                Button("Place at playhead") { place(insert: false) }
                Button("Insert at playhead") { place(insert: true) }
                Divider()
                Button("Show in Finder") {
                    let urls = entry.mediaIDs.compactMap { model.project.media($0) }.map { model.folder.url(for: $0) }
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            }
            .help(entry.mediaIDs.compactMap { model.project.media($0)?.path }.joined(separator: "\n"))
    }

    private func place(insert: Bool) {
        let batch = TimelineEdits.placeMedia(model.project, mediaIDs: entry.mediaIDs, at: model.playback.time, trackID: nil, insert: insert)
        if let result = model.apply(batch) {
            model.selection = SelectionRules.pruned(Set(result.createdIDs), in: model.project)
        }
    }
}

private struct EmptyMediaNote: View {
    let hasMedia: Bool
    let searching: Bool

    var body: some View {
        Text(searching ? "Nothing matches." : (hasMedia ? "Nothing here yet." : "Files in the project folder show up here: takes in source/, B-roll, graphics, music and SFX."))
            .font(.ui(12))
            .foregroundStyle(Theme.textFaint.color)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textFaint.color)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.textFaint.color))
                .textFieldStyle(.plain)
                .font(.ui(12))
                .foregroundStyle(Theme.text.color)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint.color)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field.color))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.fieldBorder.color, lineWidth: 1))
    }
}

struct ChipView: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(11, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.onAmber.color : Theme.textSecondary.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Theme.text.color : Theme.field.color))
        }
        .buttonStyle(.plain)
    }
}

/// Wraps its children onto new lines, for filter chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + spacing
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A thumbnail from the analysis cache, or a quiet placeholder.
struct MediaThumbnail: View {
    let model: EditorModel
    let mediaID: String?
    var corner: CGFloat = 4
    var border: Swatch? = nil

    var body: some View {
        let item = mediaID.flatMap { model.project.media($0) }
        ZStack {
            RoundedRectangle(cornerRadius: corner).fill(Swatch(0x1F2328).color)
            if let item, let image = Self.image(for: item, analysis: model.session.analysis) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let item {
                Image(systemName: Self.symbol(for: item))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.tick.color)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay {
            if let border { RoundedRectangle(cornerRadius: corner).stroke(border.color, lineWidth: 1.5) }
        }
    }

    static func symbol(for item: MediaItem) -> String {
        switch item.role {
        case .camera: return "person.crop.rectangle"
        case .screen: return "display"
        case .graphic, .sticker: return "chart.bar.xaxis"
        case .music: return "music.note"
        case .sfx: return "waveform"
        case .image: return "photo"
        case .broll, .other: return item.kind == .audio ? "waveform" : "film"
        }
    }

    static func image(for item: MediaItem, analysis: MediaAnalysis) -> NSImage? {
        guard let (strip, folder) = analysis.thumbnails(for: item), !strip.files.isEmpty else { return nil }
        let index = strip.files.count > 2 ? strip.files.count / 3 : 0
        return NSImage(contentsOf: folder.appendingPathComponent(strip.files[index]))
    }
}

private struct TakeRow: View {
    let model: EditorModel
    let entry: MediaEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                MediaThumbnail(model: model, mediaID: entry.secondaryMediaID ?? entry.primaryMediaID)
                    .frame(width: 64, height: 36)
                if entry.secondaryMediaID != nil {
                    MediaThumbnail(model: model, mediaID: entry.primaryMediaID, border: selected ? Theme.rowSelected : Theme.panel)
                        .frame(width: 48, height: 30)
                        .offset(x: 24, y: 14)
                }
            }
            .frame(width: 72, height: 44, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.ui(12.5, .semibold))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.ui(11))
                    .foregroundStyle(Theme.textMuted.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TakeStatus(model: model, entry: entry)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.rowSelected.color : .clear))
    }
}

/// Transcription state for a take, from the analysis jobs.
private struct TakeStatus: View {
    let model: EditorModel
    let entry: MediaEntry

    var body: some View {
        let jobs = model.jobs.filter { entry.mediaIDs.contains($0.mediaID) && $0.kind == .transcript }
        let item = model.project.media(entry.primaryMediaID)
        if let running = jobs.first(where: { $0.state == .running }) {
            VStack(alignment: .trailing, spacing: 4) {
                Text("Transcribing")
                    .font(.ui(10.5))
                    .foregroundStyle(Theme.amber.color)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.controlBorder.color).frame(width: 56, height: 3)
                    Capsule().fill(Theme.amber.color).frame(width: 56 * CGFloat(min(max(running.progress, 0), 1)), height: 3)
                }
            }
        } else if let item, model.session.analysis.transcript(for: item) != nil {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.green.color)
                Text("Transcribed")
                    .font(.ui(10.5))
                    .foregroundStyle(Theme.textMuted.color)
            }
        } else if jobs.contains(where: { $0.state == .queued }) {
            Text("Queued")
                .font(.ui(10.5))
                .foregroundStyle(Theme.textFaint.color)
        }
    }
}

private struct MediaTile: View {
    let model: EditorModel
    let entry: MediaEntry
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MediaThumbnail(model: model, mediaID: entry.primaryMediaID, corner: 5)
                .aspectRatio(84.0 / 47.0, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Theme.amber.color : .clear, lineWidth: 1.5))
            Text(entry.duration.map { "\(entry.title) · \(Timecode.duration($0.seconds))" } ?? entry.title)
                .font(.ui(10.5))
                .foregroundStyle(Theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct AudioRow: View {
    let model: EditorModel
    let entry: MediaEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.group == .music ? "music.note" : (entry.group == .sfx ? "waveform" : "doc"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Swatch(0x8FA3CF).color)
                .frame(width: 14)
            Text(entry.title)
                .font(.ui(12))
                .foregroundStyle(Theme.text.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.subtitle)
                .font(.ui(11))
                .foregroundStyle(Theme.textFaint.color)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.rowSelected.color : .clear))
    }
}

// MARK: - Text, transitions and effects

/// Built-in title styles until title packs arrive: each adds a text clip on
/// the Text track at the playhead.
struct TextLibrary: View {
    let model: EditorModel

    struct Preset: Identifiable {
        let id: String
        let name: String
        let detail: String
        let text: String
        let style: TextStyle
        let seconds: Double
    }

    static let presets: [Preset] = [
        Preset(id: "title", name: "Plain title", detail: "Big and bold, centred", text: "Title", style: TextStyle(size: 96, weight: 800), seconds: 3),
        Preset(id: "section", name: "Section card", detail: "Two lines, for chapters", text: "Section\nThe leaderboard", style: TextStyle(size: 72, weight: 800, backgroundColor: RGBA(r: 0.07, g: 0.07, b: 0.08, a: 0.85)), seconds: 3),
        Preset(id: "label", name: "Label", detail: "Small callout over the screen", text: "Label", style: TextStyle(size: 44, weight: 700, color: RGBA(r: 0.05, g: 0.05, b: 0.06), backgroundColor: RGBA(r: 1, g: 0.7, b: 0.14)), seconds: 2.5),
        Preset(id: "caption", name: "Caption", detail: "Bottom of frame, with a shadow", text: "Caption", style: TextStyle(size: 48, weight: 700, shadow: true), seconds: 3)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Text", detail: "adds at the playhead") { EmptyView() }
            ForEach(Self.presets) { preset in
                LibraryRow(title: preset.name, detail: preset.detail) { add(preset) }
            }
            Spacer()
        }
        .padding(14)
    }

    private func add(_ preset: Preset) {
        let project = model.project
        guard let track = project.track(named: "Text", kind: .video) ?? project.videoTracks.last else {
            model.show(.info, "Add a video track for text first.")
            return
        }
        let clip = Clip(
            name: preset.name,
            content: .text(TextContent(text: preset.text, preset: preset.id, style: preset.style, animationIn: "fadeIn", animationOut: "fadeOut")),
            start: model.playback.time,
            duration: Time(seconds: preset.seconds)
        )
        if let result = model.apply(EditBatch(label: "Add \(preset.name.lowercased())", commands: [.insertClip(trackID: track.id, clip: clip, mode: .overwrite)])) {
            model.selection = Set(result.createdIDs)
        }
    }
}

struct TransitionLibrary: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: "Transitions", detail: "on the cut nearest the playhead") { EmptyView() }
            ForEach(TransitionType.allCases, id: \.self) { type in
                LibraryRow(title: type.displayName, detail: String(format: "%.2f s", type.defaultDuration.seconds)) {
                    let batch = TimelineEdits.addDefaultTransition(model.project, playhead: model.playback.time, selection: model.selection, type: type)
                    if batch == nil { model.show(.info, "Put the playhead on a cut between two clips.") }
                    model.apply(batch)
                }
            }
            Spacer()
        }
        .padding(14)
    }
}

struct EffectLibrary: View {
    let model: EditorModel

    var body: some View {
        let definitions = EffectRegistry.standard.sorted
        let categories = Array(Set(definitions.map(\.category))).sorted()
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeader(title: "Effects", detail: "adds to the selected clips") { Text("\(definitions.count)").font(.ui(11.5)).foregroundStyle(Theme.textFaint.color) }
                ForEach(categories, id: \.self) { category in
                    Text(category)
                        .font(.ui(11.5, .semibold))
                        .foregroundStyle(Theme.textMuted.color)
                        .padding(.top, 4)
                    ForEach(definitions.filter { $0.category == category }, id: \.type) { definition in
                        LibraryRow(title: definition.name, detail: definition.summary) { add(definition) }
                    }
                }
            }
            .padding(14)
        }
    }

    private func add(_ definition: EffectDefinition) {
        let kind: TrackKind = definition.domain == .video ? .video : .audio
        let targets = TimelineEdits.ordered(model.selection, in: model.project).filter { model.project.location(ofClip: $0)?.track.kind == kind }
        guard !targets.isEmpty else {
            model.show(.info, "Select a \(kind == .video ? "video" : "sound") clip to add \(definition.name.lowercased()) to.")
            return
        }
        model.apply(EditBatch(label: "Add \(definition.name.lowercased())", commands: targets.map { .addEffect(clipID: $0, effect: Effect(type: definition.type)) }))
        model.inspectorTab = definition.category == "Colour" ? .colour : (kind == .audio ? .audio : .video)
    }
}

struct LibraryRow: View {
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.ui(12.5, .semibold))
                    .foregroundStyle(Theme.text.color)
                Text(detail)
                    .font(.ui(11))
                    .foregroundStyle(Theme.textMuted.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.rowSelected.color : Theme.field.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
