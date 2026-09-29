import AppKit
import SwiftUI
import TandemAPI
import TandemAssets
import TandemCore

/// The Text tab's Segments: bits of timeline Mike saved to reuse (an
/// intro, an outro, like and subscribe, comment below), from the shared
/// library's Segments folder. They sit with the Text tab's templates
/// because they are templates: a group of clips that go in together,
/// linked, with words that can be asked for. Double-click puts one at the
/// playhead; drag one to the timeline.
struct SegmentLibrary: View {
    let model: EditorModel
    /// The Text tab's Titles, Templates, Segments and Fonts.
    let tabs: AnyView
    @State private var selected: String?
    @State private var search = ""

    private var host: AssetLibraryHost { .shared }

    var body: some View {
        let shown = SegmentLibraryText.filter(host.segments, by: search)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                tabs
                Text("Bits of timeline saved to reuse. Double-click to add at the playhead, or drag to the timeline.")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
                if host.segments.count > 6 {
                    SearchField(text: $search, prompt: "Search segments")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if host.state == .opening {
                        QuietNote(text: "Opening the library…")
                    } else if host.segments.isEmpty {
                        empty
                    } else if shown.isEmpty {
                        QuietNote(text: "No segment is called that.")
                    }
                    LazyVGrid(columns: TileGrid.columns(width: 130), alignment: .leading, spacing: 12) {
                        ForEach(shown, id: \.id) { segment in
                            tile(segment)
                        }
                    }
                    ForEach(host.segmentProblems, id: \.self) { problem in
                        QuietNote(text: problem)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            host.open()
            host.reloadSegments()
        }
    }

    private func tile(_ segment: StoredSegment) -> some View {
        LibraryTile(title: segment.name, selected: selected == segment.id, width: 130, height: 73, drag: .template(SegmentShelf.templateID(segment))) {
            SegmentPreview(segment: segment)
        } select: {
            selected = segment.id
        } add: {
            host.insert(segment, at: model.playback.time, in: model)
        }
        .help(SegmentLibraryText.help(segment))
        .contextMenu {
            Button("Add at the playhead", systemImage: "plus.rectangle.on.rectangle") { host.insert(segment, at: model.playback.time, in: model) }
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([segment.folder]) }
            Divider()
            Button("Move to the Trash", systemImage: "trash") { host.trash(segment) { model.show(.info, $0) } }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No segments yet. Select the clips of an intro, an outro or a call to action on the timeline, then choose Timeline > Save selection as segment, or right-click one of them.")
                .font(.ui(11.5))
                .foregroundStyle(Theme.textFaint.color)
                .fixedSize(horizontal: false, vertical: true)
            Text("Each is kept in the shared library with copies of the files it plays, ready for any project.")
                .font(.ui(11.5))
                .foregroundStyle(Theme.textFaint.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textFaint.color)
            Text(host.sharedRoot.map { ArchiveSheetView.display($0.appendingPathComponent("Segments").path) } ?? "Shared library")
                .font(.ui(10.5))
                .foregroundStyle(Theme.textFaint.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Show") {
                if let root = host.sharedRoot {
                    let folder = SharedLibrary(root: root).segmentsFolder
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            .buttonStyle(.plain)
            .font(.ui(10.5, .semibold))
            .foregroundStyle(Theme.amber.color)
            .help("Show the Segments folder in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border.color).frame(height: 1) }
    }
}

/// Words for segment tiles, kept apart so they can be tested.
enum SegmentLibraryText {
    /// Segments whose name has every word typed, in order of name.
    static func filter(_ segments: [StoredSegment], by text: String) -> [StoredSegment] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return segments }
        return segments.filter { segment in
            let name = segment.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
    }

    /// The tooltip: length, tracks, what it asks for, where it came from.
    static func help(_ segment: StoredSegment) -> String {
        let summary = segment.summary
        var lines = [segment.name, "\(seconds(summary.duration)) on \(summary.tracks.joined(separator: ", "))"]
        if !summary.fields.isEmpty {
            lines.append("Words to fill in: \(summary.fields.map(\.label).joined(separator: ", ")); edit them in the inspector once it's in.")
        }
        if !summary.missing.isEmpty { lines.append("Missing: \(summary.missing.joined(separator: ", "))") }
        if let from = summary.savedFrom { lines.append("Saved from \(from)") }
        lines.append("Double-click to add at the playhead, or drag to the timeline")
        return lines.joined(separator: "\n")
    }

    /// "3 s", "5.2 s".
    static func seconds(_ time: Time) -> String {
        let value = (time.seconds * 10).rounded() / 10
        return value == value.rounded() ? "\(Int(value)) s" : String(format: "%.1f s", value)
    }
}

/// A segment sketched as its tracks: one lane per track, a bar per clip,
/// coloured like the timeline's clips, with its length in the corner.
struct SegmentPreview: View {
    let segment: StoredSegment

    var body: some View {
        let lanes = SegmentLanes.of(segment.insertableTemplate())
        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                let inset: CGFloat = 10
                let width = size.width - inset * 2
                // The lanes sit in the middle, under the length.
                let laneHeight = min(12, (size.height - 24) / CGFloat(max(lanes.count, 1)))
                let top = max(16, (size.height - laneHeight * CGFloat(lanes.count)) / 2 + 4)
                let duration = max(segment.segment.template.duration.seconds, 0.001)
                for (row, lane) in lanes.enumerated() {
                    let y = top + CGFloat(row) * laneHeight
                    for bar in lane.bars {
                        let x = inset + CGFloat(bar.start / duration) * width
                        let barWidth = max(3, CGFloat(bar.length / duration) * width)
                        let rect = CGRect(x: x, y: y + 1, width: min(barWidth, inset + width - x), height: laneHeight - 2)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(bar.style.fill.color))
                        context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(bar.style.border.color), lineWidth: 1)
                    }
                }
            }
            Text(SegmentLibraryText.seconds(segment.segment.template.duration))
                .font(.ui(9.5, .semibold).monospacedDigit())
                .foregroundStyle(segment.missingFiles.isEmpty ? Theme.textMuted.color : Theme.red.color)
                .padding(.horizontal, 6)
                .padding(.top, 3)
        }
    }
}

/// A segment's clips grouped into lanes, video tracks first, for the
/// sketch.
enum SegmentLanes {
    struct Bar {
        var start: Double
        var length: Double
        var style: Theme.ClipStyle
    }

    struct Lane {
        var track: String
        var bars: [Bar]
    }

    static func of(_ template: Template) -> [Lane] {
        var lanes: [Lane] = []
        let ordered = template.clips.filter { $0.trackKind == .video } + template.clips.filter { $0.trackKind == .audio }
        for item in ordered {
            let bar = Bar(start: item.offset.seconds, length: item.clip.duration.seconds, style: style(item))
            if let index = lanes.firstIndex(where: { $0.track == "\(item.trackKind.rawValue)|\(item.track)" }) {
                lanes[index].bars.append(bar)
            } else {
                lanes.append(Lane(track: "\(item.trackKind.rawValue)|\(item.track)", bars: [bar]))
            }
        }
        return lanes
    }

    static func style(_ item: TemplateClip) -> Theme.ClipStyle {
        if item.trackKind == .audio {
            return item.media?.role == .music || item.track.lowercased().contains("music") ? Theme.musicClip : Theme.sfxClip
        }
        switch item.clip.content {
        case .text: return Theme.textClip
        case .solid, .adjustment: return Theme.solidClip
        case .graphic: return Theme.graphicClip
        case .media: return item.media?.role == .broll || item.track.lowercased().contains("b-roll") ? Theme.brollClip : Theme.graphicClip
        }
    }
}
