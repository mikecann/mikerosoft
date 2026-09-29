import AppKit
import SwiftUI
import TandemCore
import TandemMedia

/// The left panel: media from the project folder, the asset library's
/// audio and graphics, and the built-in titles, transitions and effects.
struct LibraryPanel: View {
    let model: EditorModel
    let actions: EditorActions

    var body: some View {
        Group {
            switch model.libraryTab {
            case .media:
                // Files and folders from Finder join the project folder and the media.
                FileDropZone(onFiles: { model.importFiles($0, at: nil, trackID: nil) }) {
                    MediaBrowser(model: model, title: "Media", filter: nil)
                }
            case .graphics:
                AssetBrowser(model: model, sections: AssetSection.graphics, section: Binding(get: { AssetLibraryHost.shared.graphicsSection }, set: { AssetLibraryHost.shared.graphicsSection = $0 }))
            case .audio:
                AssetBrowser(model: model, sections: AssetSection.audio, section: Binding(get: { AssetLibraryHost.shared.audioSection }, set: { AssetLibraryHost.shared.audioSection = $0 }))
            case .text: TitleLibrary(model: model)
            case .transitions, .effects:
                EffectsLibrary(model: model, showTransitions: Binding(
                    get: { model.libraryTab == .transitions },
                    set: { model.libraryTab = $0 ? .transitions : .effects }
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
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
                        Image(systemName: "plus")
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
            .scrollIndicators(.hidden)
        }
    }

    private func rescan() {
        model.rescanMedia(ifOlderThan: 0, announce: true)
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

struct SearchField<Accessory: View>: View {
    @Binding var text: String
    let prompt: String
    /// Return: after handing the keys back to the timeline.
    var onSubmit: (() -> Void)?
    /// Something at the end of the field, like a filter menu.
    @ViewBuilder var accessory: () -> Accessory
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textFaint.color)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.textFaint.color))
                .textFieldStyle(.plain)
                .font(.ui(12))
                .foregroundStyle(Theme.text.color)
                .focused($focused)
                // Return or Escape hands the keys back to the timeline.
                .onSubmit {
                    focused = false
                    onSubmit?()
                }
                .onExitCommand { focused = false }
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
            accessory()
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

extension SearchField where Accessory == EmptyView {
    init(text: Binding<String>, prompt: String, onSubmit: (() -> Void)? = nil) {
        self.init(text: text, prompt: prompt, onSubmit: onSubmit) { EmptyView() }
    }
}

/// Wraps its children onto new lines, for filter chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Asked for an ideal size: one line, so a parent never grows to a
        // made-up width.
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
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
        // Looks again when new thumbnails land.
        let revision = model.artworkRevision
        ZStack {
            RoundedRectangle(cornerRadius: corner).fill(Theme.thumbnailWell.color)
            if let item, let image = BrowserThumbnails.shared.image(for: item, analysis: model.session.analysis, revision: revision) {
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

}

/// One thumbnail per file for the browser, read from the analysis cache
/// once and kept, so scrolling the browser never touches the disk.
@MainActor
final class BrowserThumbnails {
    static let shared = BrowserThumbnails()
    private let images = NSCache<NSString, NSImage>()
    /// Files that had no thumbnails yet, and the artwork revision they were
    /// checked at.
    private var misses: [String: Int] = [:]

    func image(for item: MediaItem, analysis: MediaAnalysis, revision: Int) -> NSImage? {
        let key = "\(analysis.folder.root.path)|\(item.id)|\(item.fingerprint ?? item.path)" as NSString
        if let image = images.object(forKey: key) { return image }
        if misses[key as String] == revision { return nil }
        // A frame a third of the way in says more than the first one.
        guard let (strip, folder) = analysis.thumbnails(for: item), !strip.files.isEmpty,
              let image = NSImage(contentsOf: folder.appendingPathComponent(strip.files[strip.files.count > 2 ? strip.files.count / 3 : 0])) else {
            misses[key as String] = revision
            return nil
        }
        images.setObject(image, forKey: key)
        misses[key as String] = nil
        return image
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
        } else if let item, TranscriptPresence.isTranscribed(item, in: model) {
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

/// Whether takes have transcripts, looked up once each until the analysis
/// results change. The lookup goes to the disk, and TakeStatus asked on
/// every redraw of the list: about 20 ms a click with four takes listed.
@MainActor
enum TranscriptPresence {
    private static var memos: [ObjectIdentifier: RevisionMemo<Bool>] = [:]

    static func isTranscribed(_ item: MediaItem, in model: EditorModel) -> Bool {
        // Reading the revision here also redraws the list when one lands.
        let revision = model.artworkRevision
        let id = ObjectIdentifier(model)
        if memos[id] == nil, memos.count > 16 { memos.removeAll() }
        return memos[id, default: RevisionMemo()].value(for: "\(item.id)|\(item.fingerprint ?? "")", revision: revision) {
            model.session.analysis.isCached(.transcript, for: item)
        }
    }
}

/// Answers remembered by key until the revision they were worked out at
/// changes.
struct RevisionMemo<Value> {
    private(set) var revision = Int.min
    private var values: [String: Value] = [:]

    mutating func value(for key: String, revision: Int, compute: () -> Value) -> Value {
        if revision != self.revision {
            values.removeAll()
            self.revision = revision
        }
        if let known = values[key] { return known }
        let value = compute()
        values[key] = value
        return value
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
                .foregroundStyle(Theme.musicIcon.color)
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
