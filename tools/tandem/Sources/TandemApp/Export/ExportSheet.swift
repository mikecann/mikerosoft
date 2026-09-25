import AppKit
import SwiftUI
import TandemCore
import TandemRender

/// The export sheet: presets on the left, what they'll do on the right, and
/// the output file. It drops from the top bar over a dimmed window, as in
/// the design.
struct ExportSheetOverlay: View {
    let model: EditorModel
    @State private var presetIndex = 0
    @State private var useRange = false
    @State private var output: URL?

    private var presets: [ExportPreset] { ExportPreset.all }
    private var preset: ExportPreset { presets[min(presetIndex, presets.count - 1)] }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.dimmer.color
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(spacing: 0) {
                header
                HStack(alignment: .top, spacing: 0) {
                    presetList
                    Rectangle().fill(Theme.sheetDivider.color).frame(width: 1)
                    settings
                }
                .fixedSize(horizontal: false, vertical: true)
                if !model.exports.jobs.isEmpty {
                    ExportJobList(model: model)
                }
                footer
            }
            .frame(width: 800)
            .background(Theme.raised.color)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
            .overlay(
                UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                    .stroke(Theme.controlBorder.color, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
            .padding(.top, Theme.Metrics.topBarHeight)
        }
        .onAppear {
            useRange = model.inOutRange != nil
            output = defaultOutput()
        }
        .onExitCommand(perform: close)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Export")
                .font(.ui(17, .bold))
                .foregroundStyle(Theme.text.color)
            Text("\(model.project.name) · \(Timecode.clock(model.project.duration.seconds))")
                .font(.ui(13))
                .foregroundStyle(Theme.textMuted.color)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.sheetDivider.color).frame(height: 1) }
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                let selected = index == presetIndex
                Button {
                    presetIndex = index
                    output = defaultOutput()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name)
                            .font(.ui(13, selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.text.color : Theme.textStrong.color)
                        Text(Self.detail(preset, settings: model.project.settings))
                            .font(.ui(11.5))
                            .foregroundStyle(selected ? Theme.textMuted.color : Theme.textFaint.color)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.presetSelected.color : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 230, alignment: .top)
    }

    private var settings: some View {
        let size = Self.size(of: preset, settings: model.project.settings)
        return VStack(alignment: .leading, spacing: 0) {
            SheetRow(label: "Video") {
                Text("\(preset.codec == .hevc ? "HEVC" : "H.264") on the hardware encoder, \(preset.videoBitrate / 1_000_000) Mbps")
            }
            SheetRow(label: "Size") {
                Text("\(size.width) × \(size.height), \(Self.fps(model.project.settings.frameRate)) fps, same as the timeline")
            }
            SheetRow(label: "Loudness") {
                VStack(alignment: .leading, spacing: 3) {
                    if let target = preset.loudnessTarget {
                        Text(String(format: "Master to %.0f LUFS, peaks under %.0f dB", target, preset.truePeakCeiling ?? -1).replacingOccurrences(of: "-", with: "−"))
                    } else {
                        Text("Left as mixed")
                    }
                    Text("Measured during the export")
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.textMuted.color)
                }
            }
            SheetRow(label: "Range") {
                GraphiteSegmented(
                    options: [false, true],
                    selected: useRange,
                    title: { ranged in
                        if ranged, let range = model.inOutRange {
                            return "In to out · \(Timecode.clock(range.duration.seconds))"
                        }
                        return ranged ? "In to out (none set)" : "Whole timeline"
                    },
                    action: { ranged in
                        if !ranged || model.inOutRange != nil { useRange = ranged }
                    }
                )
                .frame(maxWidth: 330)
            }
            SheetRow(label: "Save to", divider: false) {
                HStack(spacing: 10) {
                    Text(displayPath(output ?? defaultOutput()))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    OutlineButton(title: "Choose…") { chooseOutput() }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(estimate.title)
                    .font(.ui(13, .semibold))
                    .foregroundStyle(Theme.text.color)
                Text(estimate.detail)
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textMuted.color)
            }
            Spacer()
            Button(action: close) {
                Text("Cancel")
                    .font(.ui(12.5))
                    .foregroundStyle(Theme.text.color)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.buttonBorder.color, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            Button(action: export) {
                Text("Export")
                    .font(.ui(12.5, .bold))
                    .foregroundStyle(Theme.onAmber.color)
                    .padding(.horizontal, 18)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.amber.color))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Theme.panel.color)
        .overlay(alignment: .top) { Rectangle().fill(Theme.sheetDivider.color).frame(height: 1) }
    }

    // MARK: - Actions

    private func close() {
        model.showExportSheet = false
    }

    private func export() {
        var chosen = preset
        if useRange, let range = model.inOutRange { chosen.range = range }
        let url = output ?? defaultOutput()
        let context = RenderContext(project: model.project, folder: model.folder, analysis: model.session.analysis, useProxies: false, format: chosen.format)
        model.exports.enqueue(preset: chosen, output: url, context: context)
        model.show(.info, "Exporting \(url.lastPathComponent).")
        close()
    }

    private func defaultOutput() -> URL {
        let folder = model.folder.exportsFolder
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let name = VersionNaming.exportName(projectFile: model.fileName, preset: preset == ExportPreset.youtube4K ? "" : preset.name, existing: existing)
        return folder.appendingPathComponent(name)
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        let url = output ?? defaultOutput()
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent
        if panel.runModal() == .OK, let chosen = panel.url { output = chosen }
    }

    private func displayPath(_ url: URL) -> String {
        let root = model.folder.root.deletingLastPathComponent().path
        let path = url.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// How long it should take, from the speed of the last export.
    private var estimate: (title: String, detail: String) {
        let seconds = (useRange ? model.inOutRange?.duration : nil)?.seconds ?? model.project.duration.seconds
        let speed = UserDefaults.standard.double(forKey: ExportSpeed.defaultsKey)
        guard speed > 0 else {
            return ("\(Timecode.clock(seconds)) of video", "Runs in the background; the status bar shows progress.")
        }
        let wall = seconds / speed
        let minutes = Int(wall / 60)
        let rest = Int(wall.truncatingRemainder(dividingBy: 60))
        let title = minutes > 0 ? "About \(minutes) min \(rest) s" : "About \(max(rest, 1)) s"
        return (title, String(format: "Measured on this Mac: %.1f× realtime", speed))
    }

    // MARK: - Descriptions

    static func size(of preset: ExportPreset, settings: ProjectSettings) -> (width: Int, height: Int) {
        if let format = preset.format, let alternate = settings.alternateFormats.first(where: { $0.id == format }) {
            return (alternate.width, alternate.height)
        }
        if preset.format == OutputFormat.portrait.id { return (OutputFormat.portrait.width, OutputFormat.portrait.height) }
        return (preset.width ?? settings.width, preset.height ?? settings.height)
    }

    static func fps(_ rate: FrameRate) -> String {
        let value = rate.framesPerSecond
        return value == value.rounded() ? "\(Int(value))" : String(format: "%.2f", value)
    }

    static func detail(_ preset: ExportPreset, settings: ProjectSettings) -> String {
        let size = size(of: preset, settings: settings)
        let codec = preset.codec == .hevc ? "HEVC" : "H.264"
        return "\(codec) · \(size.width)×\(size.height) · \(fps(settings.frameRate))p"
    }
}

/// Remembers how fast exports run, for the next estimate.
enum ExportSpeed {
    static let defaultsKey = "exportSpeed"

    static func record(_ result: ExportResult) {
        guard result.elapsed > 0.5, result.duration.seconds > 1 else { return }
        UserDefaults.standard.set(result.duration.seconds / result.elapsed, forKey: defaultsKey)
    }
}

private struct SheetRow<Content: View>: View {
    let label: String
    var divider = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.ui(12.5))
                .foregroundStyle(Theme.textMuted.color)
                .frame(width: 120, alignment: .leading)
            content()
                .font(.ui(12.5))
                .foregroundStyle(Theme.text.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Theme.border.color).frame(height: 1) }
        }
    }
}

/// Exports in this session with their state.
private struct ExportJobList: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("This session")
                    .font(.ui(11.5, .semibold))
                    .foregroundStyle(Theme.textMuted.color)
                Spacer()
                if model.exports.jobs.contains(where: \.isFinished) {
                    Button("Clear finished") { model.exports.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.ui(11.5))
                        .foregroundStyle(Theme.textMuted.color)
                }
            }
            ForEach(model.exports.jobs.suffix(4)) { job in
                HStack(spacing: 10) {
                    Text(job.output.lastPathComponent)
                        .font(.ui(12))
                        .foregroundStyle(Theme.text.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Self.state(job))
                        .font(.ui(11.5))
                        .foregroundStyle(Self.colour(job).color)
                        .lineLimit(1)
                    if case .done = job.state {
                        OutlineButton(title: "Show") { NSWorkspace.shared.activateFileViewerSelecting([job.output]) }
                    } else if !job.isFinished {
                        OutlineButton(title: "Cancel") { model.exports.cancel(job.id) }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.sheetDivider.color).frame(height: 1) }
    }

    static func state(_ job: ExportJob) -> String {
        switch job.state {
        case .queued: return "Queued"
        case .running(let progress): return "\(Int(progress * 100))%"
        case .done(let result):
            let lufs = result.integratedLUFS.map { String(format: " · %.1f LUFS", $0).replacingOccurrences(of: "-", with: "−") } ?? ""
            return "Done in \(Int(result.elapsed)) s\(lufs)"
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }

    static func colour(_ job: ExportJob) -> Swatch {
        switch job.state {
        case .failed: return Theme.red
        case .done: return Theme.green
        case .running: return Theme.amber
        default: return Theme.textMuted
        }
    }
}
