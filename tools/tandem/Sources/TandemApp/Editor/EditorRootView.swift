import SwiftUI
import TandemCore
import TandemMedia

/// The Graphite window: top bar, then media panel, viewer and inspector,
/// then the timeline and status bar. The split between the workspace and
/// the timeline can be dragged.
struct EditorRootView: View {
    let model: EditorModel
    let actions: EditorActions
    /// Set once the split is dragged; until then it follows the window.
    @State private var workspaceHeight: CGFloat?
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.height - Theme.Metrics.topBarHeight - Theme.Metrics.statusBarHeight
            let workspace = clampedWorkspace(workspaceHeight ?? defaultWorkspace(available: available), available: available)
            VStack(spacing: 0) {
                TopBar(model: model, actions: actions)
                HStack(spacing: 0) {
                    LibraryPanel(model: model, actions: actions)
                        .frame(width: Theme.Metrics.mediaPanelWidth)
                    Rectangle().fill(Theme.border.color).frame(width: 1)
                    ViewerPanel(model: model, actions: actions)
                        .frame(maxWidth: .infinity)
                    Rectangle().fill(Theme.border.color).frame(width: 1)
                    InspectorPanel(model: model, actions: actions)
                        .frame(width: Theme.Metrics.inspectorWidth - 1)
                }
                .frame(height: workspace)
                .clipped()
                SplitHandle()
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartHeight ?? workspace
                                if dragStartHeight == nil { dragStartHeight = workspace }
                                workspaceHeight = clampedWorkspace(start + value.translation.height, available: available)
                            }
                            .onEnded { _ in dragStartHeight = nil }
                    )
                TimelinePanel(model: model, actions: actions)
                    .frame(maxHeight: .infinity)
                StatusBar(model: model)
            }
            .overlay {
                if model.showExportSheet {
                    ExportSheetOverlay(model: model)
                }
            }
        }
        .background(Theme.window.color)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    /// The design's 524 pt workspace, shrunk so every track fits under it
    /// when the window is short.
    private func defaultWorkspace(available: CGFloat) -> CGFloat {
        let tracks = TimelineLayout.make(project: model.project, showTranscript: model.showTranscript, heightOverrides: model.timeline.trackHeights).contentHeight
        let timeline = Theme.Metrics.timelineToolbarHeight + Theme.Metrics.rulerHeight + tracks + 4
        return max(Theme.Metrics.minimumWorkspaceHeight, min(Theme.Metrics.workspaceHeight, available - 1 - timeline))
    }

    private func clampedWorkspace(_ value: CGFloat, available: CGFloat) -> CGFloat {
        let upper = max(Theme.Metrics.minimumWorkspaceHeight, available - Theme.Metrics.minimumTimelineHeight)
        return min(max(value, Theme.Metrics.minimumWorkspaceHeight), upper)
    }
}

/// The 1 pt line between the workspace and the timeline, with a taller
/// invisible grab area.
private struct SplitHandle: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border.color)
            .frame(height: 1)
            .overlay(Color.clear.frame(height: 7).contentShape(Rectangle()))
            .onHover { inside in
                (inside ? NSCursor.resizeUpDown : NSCursor.arrow).set()
            }
    }
}

// MARK: - Top bar

struct TopBar: View {
    let model: EditorModel
    let actions: EditorActions

    var body: some View {
        // The library tabs sit in the middle of the window, so they stay put
        // when the title or the agent chip changes width.
        ZStack {
            HStack(spacing: 14) {
                // The window's own traffic lights sit here.
                Color.clear.frame(width: 52, height: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.project.name)
                        .font(.ui(13, .bold))
                        .foregroundStyle(Theme.text.color)
                        .lineLimit(1)
                    Text("\(model.folderName) / \(model.fileName) · \(model.isDirty ? "edited" : "saved")")
                        .font(.ui(10.5))
                        .foregroundStyle(Theme.textFaint.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 260, alignment: .leading)
                Spacer(minLength: 12)
                AgentChip(model: model)
                Button {
                    model.showExportSheet = true
                } label: {
                    Text("Export")
                        .font(.ui(12.5, .bold))
                        .foregroundStyle(Theme.onAmber.color)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.amber.color))
                }
                .buttonStyle(.plain)
                .help("Export (⌘E)")
            }
            HStack(spacing: 2) {
                ForEach(LibraryTab.allCases) { tab in
                    LibraryTabButton(tab: tab, selected: model.libraryTab == tab) {
                        model.libraryTab = tab
                    }
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: Theme.Metrics.topBarHeight)
        .background(Theme.panel.color)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.color).frame(height: 1) }
    }
}

private struct LibraryTabButton: View {
    let tab: LibraryTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                LibraryIcon(tab: tab, color: selected ? Theme.text.color : Theme.textMuted.color)
                    .frame(width: 16, height: 14)
                Text(tab.title)
                    .font(.ui(10.5, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text.color : Theme.textMuted.color)
            }
            .padding(.vertical, 5)
            .frame(width: 62)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.tabSelected.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The small line icons on the library tabs, drawn from the design's SVGs.
struct LibraryIcon: View {
    let tab: LibraryTab
    let color: Color

    var body: some View {
        Canvas { context, size in
            let sx = size.width / 16
            let sy = size.height / 14
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            switch tab {
            case .media:
                let rect = Path(roundedRect: CGRect(x: 1 * sx, y: 1 * sy, width: 14 * sx, height: 12 * sy), cornerRadius: 2)
                context.stroke(rect, with: .color(color), lineWidth: 1.3)
                var line = Path()
                line.move(to: p(1, 5))
                line.addLine(to: p(15, 5))
                context.stroke(line, with: .color(color), lineWidth: 1.3)
            case .text:
                var path = Path()
                path.move(to: p(3, 2))
                path.addLine(to: p(13, 2))
                path.move(to: p(8, 2))
                path.addLine(to: p(8, 12))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            case .transitions:
                var path = Path()
                path.move(to: p(1, 2)); path.addLine(to: p(8, 7)); path.addLine(to: p(1, 12)); path.closeSubpath()
                path.move(to: p(15, 2)); path.addLine(to: p(8, 7)); path.addLine(to: p(15, 12)); path.closeSubpath()
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            case .effects:
                let points: [(CGFloat, CGFloat)] = [(8, 1), (9.6, 5.2), (14, 5.4), (10.6, 8.2), (11.8, 12.5), (8, 10), (4.2, 12.5), (5.4, 8.2), (2, 5.4), (6.4, 5.2)]
                var path = Path()
                path.move(to: p(points[0].0, points[0].1))
                for point in points.dropFirst() { path.addLine(to: p(point.0, point.1)) }
                path.closeSubpath()
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            case .graphics:
                for (x, y, h) in [(2.0, 7.0, 6.0), (6.5, 4.0, 9.0), (11.0, 1.0, 12.0)] {
                    context.fill(Path(roundedRect: CGRect(x: x * sx, y: y * sy, width: 3 * sx, height: h * sy), cornerRadius: 1), with: .color(color))
                }
            case .audio:
                let points: [(CGFloat, CGFloat)] = [(1, 7), (3, 7), (5, 3), (8, 11), (10, 5), (12, 9), (13, 7), (15, 7)]
                var path = Path()
                path.move(to: p(points[0].0, points[0].1))
                for point in points.dropFirst() { path.addLine(to: p(point.0, point.1)) }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Shows which agent last edited, and opens the activity feed.
private struct AgentChip: View {
    let model: EditorModel

    var body: some View {
        // Ticks over every few seconds, so "is editing" settles into
        // "connected" and then "edited" without any new events.
        SwiftUI.TimelineView(.periodic(from: .now, by: 5)) { context in
            let state = AgentChipState.of(model.agentPresence, serving: model.apiProblem == nil, now: context.date)
            Button {
                model.inspectorTab = .activity
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(state.isActive ? Theme.green.color : Theme.textFainter.color)
                        .frame(width: 7, height: 7)
                    Text(state.name)
                        .font(.ui(12, .semibold))
                        .foregroundStyle(Theme.text.color)
                    Text(state.detail)
                        .font(.ui(12))
                        .foregroundStyle(Theme.textMuted.color)
                }
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(Capsule().fill(Theme.raised.color))
                .overlay(Capsule().stroke(Theme.controlBorder.color, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }

    private var help: String {
        if let port = model.apiPort {
            return "Agents reach this project through the local API on port \(port). Their edits show in the activity feed."
        }
        if let problem = model.apiProblem { return "The local API couldn't start: \(problem)" }
        return "Starting the local API"
    }
}

// MARK: - Status bar

struct StatusBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(activeJobs.prefix(3).enumerated()), id: \.offset) { index, text in
                HStack(spacing: 6) {
                    if index == 0 {
                        Circle().fill(Theme.amber.color).frame(width: 6, height: 6)
                    }
                    Text(text)
                        .font(.ui(11))
                        .foregroundStyle(index == 0 ? Theme.textSecondary.color : Theme.textFaint.color)
                        .lineLimit(1)
                }
            }
            if let status = model.status {
                Text(status.text)
                    .font(.ui(11))
                    .foregroundStyle(color(for: status.kind))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let warning = PreviewWarnings.summary(model.playback.warnings, media: model.project.media) {
                // Where the preview can't match the export yet, kept quiet.
                Text(warning)
                    .font(.ui(11))
                    .foregroundStyle(Theme.textFaint.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.playback.warnings.map { PreviewWarnings.short($0, media: model.project.media) }.joined(separator: "\n"))
            }
            Spacer(minLength: 8)
            // The last agent edit stays here once its status message has
            // gone, so the bar never says the same thing twice.
            if let entry = model.activity.lastAgentEntry {
                let text = "\(ActivityLog.displayName(entry.author)): \(entry.label)"
                if model.status?.text != text {
                    Text(text)
                        .font(.ui(11))
                        .foregroundStyle(Theme.textFaint.color)
                        .lineLimit(1)
                }
            }
            Text(formatSummary)
                .font(.ui(11))
                .foregroundStyle(Theme.textSecondary.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.Metrics.statusBarHeight)
        .background(Theme.statusBar.color)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderSubtle.color).frame(height: 1) }
    }

    private func color(for kind: StatusMessage.Kind) -> Color {
        switch kind {
        case .info: return Theme.textMuted.color
        case .warning: return Theme.amber.color
        case .error: return Theme.red.color
        }
    }

    /// Running exports and analysis jobs, most important first.
    private var activeJobs: [String] {
        var lines: [String] = []
        if let job = model.exports.active, case .running(let progress) = job.state {
            lines.append("Exporting \(job.preset.name) · \(Int(progress * 100))%")
        }
        if model.exports.waiting > 0 {
            lines.append("\(model.exports.waiting) more \(model.exports.waiting == 1 ? "export" : "exports") queued")
        }
        // Two running jobs by name, then a count, so warnings keep room.
        let running = model.jobs.filter { $0.state == .running }
        for job in running.prefix(2) {
            lines.append(JobText.describe(job, in: model.project))
        }
        let more = max(0, running.count - 2) + model.jobs.filter { $0.state == .queued }.count
        if more > 0 { lines.append("\(more) more analysis \(more == 1 ? "job" : "jobs")") }
        return lines
    }

    private var formatSummary: String {
        let settings = model.project.settings
        let size: String
        switch (settings.width, settings.height) {
        case (3840, 2160): size = "4K"
        case (1920, 1080): size = "1080p"
        case (1080, 1920): size = "9:16"
        case (let w, let h): size = "\(w)×\(h)"
        }
        let fps = settings.frameRate.framesPerSecond
        let rate = fps == fps.rounded() ? "\(Int(fps))p" : String(format: "%.2fp", fps)
        let loudness: String
        if let measured = model.exports.jobs.last(where: { if case .done = $0.state { return true } else { return false } }),
           case .done(let result) = measured.state, let lufs = result.integratedLUFS {
            loudness = String(format: "%.1f LUFS", lufs).replacingOccurrences(of: "-", with: "−")
        } else {
            loudness = String(format: "Target %.0f LUFS", settings.loudnessTarget).replacingOccurrences(of: "-", with: "−")
        }
        return "\(loudness) · \(size) \(rate)"
    }
}

/// Sentence-case descriptions of analysis jobs for the status bar.
enum JobText {
    static func describe(_ job: JobStatus, in project: Project) -> String {
        let name = project.media(job.mediaID).map(MediaCatalog.shortName) ?? "media"
        let verb: String
        switch job.kind {
        case .thumbnails: verb = "Thumbnails"
        case .waveform: verb = "Waveform"
        case .loudness: verb = "Measuring loudness"
        case .proxy: verb = "Proxy"
        case .transcript: verb = "Transcribing"
        case .matte: verb = "Cutout matte"
        case .isolatedVoice: verb = "Isolating voice"
        }
        let percent = job.progress > 0 ? " · \(Int(job.progress * 100))%" : ""
        return "\(verb) \(name)\(percent)"
    }
}
