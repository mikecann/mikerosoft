import AppKit
import SwiftUI
import TandemCore
import TandemRender

/// The Text tab: title styles from the render module's presets, and
/// templates (a section card, calls to action). Double-click to add at the
/// playhead, or drag to the timeline.
struct TitleLibrary: View {
    let model: EditorModel
    @State private var showTemplates = false
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    SubTab(title: "Titles", selected: !showTemplates) { showTemplates = false }
                    SubTab(title: "Templates", selected: showTemplates) { showTemplates = true }
                    Spacer(minLength: 4)
                    Text(verbatim: String(showTemplates ? BuiltInTemplates.all.count : TitlePresets.builtIn.count))
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.textFaint.color)
                }
                Text(showTemplates
                     ? "A group of clips that go in together, linked. Edit the words in the inspector."
                     : "Styles from Mike's Filmora titles. Double-click to add at the playhead, or drag to the timeline.")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            ScrollView {
                LazyVGrid(columns: TileGrid.columns(2, width: 130), alignment: .leading, spacing: 12) {
                    if showTemplates {
                        ForEach(BuiltInTemplates.all) { template in
                            LibraryTile(title: template.name, selected: selected == template.id, width: 130, height: 73, drag: .template(template.id)) {
                                TemplatePreview(template: template)
                            } select: {
                                selected = template.id
                            } add: {
                                model.apply(LibraryDrops.template(template, at: model.playback.time))
                            }
                        }
                    } else {
                        ForEach(TitlePresets.builtIn, id: \.id) { preset in
                            LibraryTile(title: preset.name, selected: selected == preset.id, width: 130, height: 73, drag: .title(preset.id)) {
                                TitlePreview(preset: preset)
                            } select: {
                                selected = preset.id
                            } add: {
                                addTitle(preset)
                            }
                            .help(preset.summary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func addTitle(_ preset: TitlePreset) {
        guard let batch = LibraryDrops.title(preset, at: model.playback.time, in: model.project) else {
            model.show(.info, "Add a video track for text first, or unlock the Text track.")
            return
        }
        if let result = model.apply(batch) {
            model.selection = SelectionRules.pruned(Set(result.createdIDs), in: model.project)
            model.inspectorTab = .video
        }
    }
}

/// A title style in miniature, drawn from the preset itself.
private struct TitlePreview: View {
    let preset: TitlePreset

    var body: some View {
        let style = preset.style
        let lines = TitleSamples.text(for: preset.id).components(separatedBy: "\n")
        let size = max(9, min(22, CGFloat(style.size) * 0.13))
        VStack(spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let first = index == 0 && lines.count > 1
                text(line, first: first)
                    .font(.system(size: first ? size * CGFloat(preset.firstLineScale ?? 1) : size, weight: weight(style.weight), design: .rounded))
                    .foregroundStyle(first ? colour(preset.firstLineColor ?? style.color) : colour(style.color))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .padding(.horizontal, style.backgroundColor == nil ? 0 : 7)
        .padding(.vertical, style.backgroundColor == nil ? 0 : 3)
        .background {
            if let background = style.backgroundColor {
                RoundedRectangle(cornerRadius: 3).fill(colour(background))
            }
        }
        .shadow(color: .black.opacity(style.shadow ? 0.6 : 0), radius: 1.5, y: 1)
        .padding(10)
    }

    private func text(_ line: String, first: Bool) -> Text {
        let shown = preset.style.uppercase ? line.uppercased() : line
        // Word captions light up the word being said.
        guard let highlight = preset.highlightColor else { return Text(shown) }
        let words = shown.split(separator: " ").map(String.init)
        return words.enumerated().reduce(Text("")) { result, item in
            let word = Text(item.element + (item.offset < words.count - 1 ? " " : ""))
            return result + (item.offset == 1 ? word.foregroundColor(colour(highlight)) : word)
        }
    }

    private func weight(_ value: Double) -> Font.Weight {
        switch value {
        case ..<450: return .regular
        case ..<650: return .semibold
        case ..<850: return .heavy
        default: return .black
        }
    }

    private func colour(_ rgba: RGBA) -> Color {
        Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

/// A template sketched: a card for the section card, a pill for calls to
/// action, as in the design.
private struct TemplatePreview: View {
    let template: Template

    var body: some View {
        switch template.id {
        case "sectionCard":
            VStack(alignment: .leading, spacing: 3) {
                Text("SECTION 1")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(Color(.sRGB, red: 1, green: 0.8, blue: 0.16))
                Text("THE LEADERBOARD")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Theme.text.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
        default:
            HStack(spacing: 5) {
                Image(systemName: template.id == "commentBelow" ? "text.bubble.fill" : "circle.fill")
                    .font(.system(size: template.id == "commentBelow" ? 9 : 7))
                    .foregroundStyle(template.id == "commentBelow" ? Theme.onAmber.color : Theme.red.color)
                Text(template.name)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.onAmber.color)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.text.color))
        }
    }
}

/// A sub-tab label in a library header: bold when selected.
struct SubTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(13, selected ? .bold : .regular))
                .foregroundStyle(selected ? Theme.text.color : Theme.textFaint.color)
        }
        .buttonStyle(.plain)
    }
}

/// A tile in the Text, Transitions and Effects libraries: a preview well,
/// the name under it, click to select, double-click to add, drag to the
/// timeline.
struct LibraryTile<Preview: View>: View {
    let title: String
    let selected: Bool
    let width: CGFloat
    let height: CGFloat
    let drag: LibraryDrag
    @ViewBuilder var preview: () -> Preview
    let select: () -> Void
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: width > 100 ? 7 : 6).fill(Theme.raised.color)
                preview()
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: width > 100 ? 7 : 6))
            .overlay(
                RoundedRectangle(cornerRadius: width > 100 ? 7 : 6)
                    .stroke(selected ? Theme.amber.color : (hovering ? Theme.textFaint.color : .clear), lineWidth: selected ? 1.5 : 1)
            )
            Text(title)
                .font(.ui(width > 100 ? 11.5 : 11))
                .foregroundStyle(selected ? Theme.text.color : Theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: add)
        .onTapGesture(count: 1, perform: select)
        .onDrag { NSItemProvider(object: drag.payload as NSString) }
    }
}

/// Columns for the libraries' tile grids: fixed tiles 10 points apart,
/// with no spacing after the last column so the grid is exactly as wide
/// as its tiles.
enum TileGrid {
    static func columns(_ count: Int, width: CGFloat) -> [GridItem] {
        (0..<count).map { GridItem(.fixed(width), spacing: $0 == count - 1 ? 0 : 10, alignment: .top) }
    }
}
