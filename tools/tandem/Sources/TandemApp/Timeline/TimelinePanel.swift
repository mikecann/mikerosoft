import SwiftUI
import TandemCore

/// The timeline area: its toolbar and the AppKit timeline below it.
struct TimelinePanel: View {
    let model: EditorModel
    let actions: EditorActions

    var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar(model: model, actions: actions)
            TimelineRepresentable(model: model)
        }
        .background(Theme.window.color)
    }
}

struct TimelineRepresentable: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> TimelineContainerView {
        TimelineContainerView(model: model)
    }

    func updateNSView(_ view: TimelineContainerView, context: Context) {}
}

/// Tools, snapping and linking toggles, transcript lane and zoom.
struct TimelineToolbar: View {
    let model: EditorModel
    let actions: EditorActions
    @State private var showTighten = false

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(TimelineTool.allCases, id: \.self) { tool in
                    ToolButton(tool: tool, selected: model.tool == tool, key: key(for: tool)) {
                        model.tool = tool
                    }
                }
            }
            ToggleText(title: "Snap", on: model.snapping, help: "Snapping (S)") { model.snapping.toggle() }
            ToggleText(title: "Ripple", on: model.rippleTrims, help: "Edge drags ripple the rest of the timeline") { model.rippleTrims.toggle() }
            ToggleText(title: model.linkedSelection ? "Linked camera + screen" : "Linked selection off", on: model.linkedSelection, help: "Clicking a clip selects its linked picture and sound. Option-click picks one side.") {
                model.linkedSelection.toggle()
            }
            if let range = model.inOutRange {
                Text("In to out \(Timecode.string(range.duration, rate: model.frameRate))")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.amber.color)
            }
            Spacer(minLength: 8)
            Button {
                showTighten = true
            } label: {
                Text("Tighten pauses…")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textMuted.color)
            }
            .buttonStyle(.plain)
            .help("Remove long pauses from the take using its transcript")
            .popover(isPresented: $showTighten, arrowEdge: .top) {
                TightenPausesPopover(model: model) { showTighten = false }
            }
            ToggleText(title: "Transcript lane", on: model.showTranscript, help: "Show the transcript above the tracks (T)") { model.showTranscript.toggle() }
            GraphiteSlider(
                value: Binding(get: { model.timeline.zoomFraction }, set: { model.timeline.zoomFraction = $0 }),
                range: 0...1,
                track: Swatch(0x26292E),
                fill: Theme.textMuted
            )
            .frame(width: 84)
            .help("Zoom (⌘+ and ⌘−, Shift-Z to fit)")
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.Metrics.timelineToolbarHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderSubtle.color).frame(height: 1) }
    }

    private func key(for tool: TimelineTool) -> String {
        let command: EditorCommand
        switch tool {
        case .select: command = .toolSelect
        case .blade: command = .toolBlade
        case .rippleTrim: command = .toolRippleTrim
        case .roll: command = .toolRoll
        case .slip: command = .toolSlip
        case .slide: command = .toolSlide
        }
        return ProjectDocuments.shared.keymap.chords(for: command).first?.symbol ?? ""
    }
}

/// A text toggle: bright when on, muted when off, as in the design.
struct ToggleText: View {
    let title: String
    let on: Bool
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(11.5))
                .foregroundStyle(on ? Theme.text.color : Theme.textMuted.color)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ToolButton: View {
    let tool: TimelineTool
    let selected: Bool
    let key: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolIcon(tool: tool, color: selected ? Theme.text.color : Theme.textMuted.color)
                .frame(width: 13, height: 12)
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.tabSelected.color : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(key.isEmpty ? tool.name : "\(tool.name) (\(key))")
    }
}

/// Small line icons for the timeline tools.
struct ToolIcon: View {
    let tool: TimelineTool
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            var path = Path()
            let stroke = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
            switch tool {
            case .select:
                path.move(to: CGPoint(x: w * 0.17, y: h * 0.12))
                path.addLine(to: CGPoint(x: w * 0.83, y: h * 0.5))
                path.addLine(to: CGPoint(x: w * 0.53, y: h * 0.58))
                path.addLine(to: CGPoint(x: w * 0.4, y: h * 0.88))
                path.closeSubpath()
                context.fill(path, with: .color(color))
                return
            case .blade:
                // A razor: a slanted blade with its cutting edge.
                path.move(to: CGPoint(x: w * 0.3, y: h * 0.05))
                path.addLine(to: CGPoint(x: w * 0.7, y: h * 0.05))
                path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.62))
                path.closeSubpath()
                context.fill(path, with: .color(color))
                var line = Path()
                line.move(to: CGPoint(x: w * 0.5, y: h * 0.62))
                line.addLine(to: CGPoint(x: w * 0.5, y: h * 0.98))
                context.stroke(line, with: .color(color), style: stroke)
                return
            case .rippleTrim:
                path.move(to: CGPoint(x: w * 0.35, y: h * 0.08))
                path.addLine(to: CGPoint(x: w * 0.15, y: h * 0.08))
                path.addLine(to: CGPoint(x: w * 0.15, y: h * 0.92))
                path.addLine(to: CGPoint(x: w * 0.35, y: h * 0.92))
                path.move(to: CGPoint(x: w * 0.45, y: h * 0.5))
                path.addLine(to: CGPoint(x: w * 0.92, y: h * 0.5))
                path.move(to: CGPoint(x: w * 0.75, y: h * 0.32))
                path.addLine(to: CGPoint(x: w * 0.92, y: h * 0.5))
                path.addLine(to: CGPoint(x: w * 0.75, y: h * 0.68))
            case .roll:
                path.move(to: CGPoint(x: w * 0.25, y: h * 0.08))
                path.addLine(to: CGPoint(x: w * 0.45, y: h * 0.08))
                path.addLine(to: CGPoint(x: w * 0.45, y: h * 0.92))
                path.addLine(to: CGPoint(x: w * 0.25, y: h * 0.92))
                path.move(to: CGPoint(x: w * 0.75, y: h * 0.08))
                path.addLine(to: CGPoint(x: w * 0.55, y: h * 0.08))
                path.addLine(to: CGPoint(x: w * 0.55, y: h * 0.92))
                path.addLine(to: CGPoint(x: w * 0.75, y: h * 0.92))
            case .slip:
                path.move(to: CGPoint(x: w * 0.1, y: h * 0.1))
                path.addLine(to: CGPoint(x: w * 0.1, y: h * 0.9))
                path.move(to: CGPoint(x: w * 0.9, y: h * 0.1))
                path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.9))
                path.move(to: CGPoint(x: w * 0.28, y: h * 0.5))
                path.addLine(to: CGPoint(x: w * 0.72, y: h * 0.5))
                path.move(to: CGPoint(x: w * 0.4, y: h * 0.36))
                path.addLine(to: CGPoint(x: w * 0.28, y: h * 0.5))
                path.addLine(to: CGPoint(x: w * 0.4, y: h * 0.64))
                path.move(to: CGPoint(x: w * 0.6, y: h * 0.36))
                path.addLine(to: CGPoint(x: w * 0.72, y: h * 0.5))
                path.addLine(to: CGPoint(x: w * 0.6, y: h * 0.64))
            case .slide:
                path.addRoundedRect(in: CGRect(x: w * 0.3, y: h * 0.2, width: w * 0.4, height: h * 0.6), cornerSize: CGSize(width: 1.5, height: 1.5))
                path.move(to: CGPoint(x: w * 0.02, y: h * 0.5))
                path.addLine(to: CGPoint(x: w * 0.2, y: h * 0.5))
                path.move(to: CGPoint(x: w * 0.8, y: h * 0.5))
                path.addLine(to: CGPoint(x: w * 0.98, y: h * 0.5))
            }
            context.stroke(path, with: .color(color), style: stroke)
        }
    }
}
